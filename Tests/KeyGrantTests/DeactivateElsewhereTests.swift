import Foundation
import Testing

@testable import KeyGrant

/// A profile copied or restored from another PC carries that PC's activation: releasing it would
/// lock that PC out at its next check-in. `deactivate()` drops it here and asks nothing.
@Suite("deactivate, when the activation stored is another device's", suiteTimeLimit)
struct DeactivateElsewhereTests {
    /// A lease for this key and activation, its seat keyed by the machine id `device` (none: nil).
    func lease(_ h: Harness, device: String?, kind: DeviceKind = .machine, signer: Signer? = nil, at: Int = NOW) -> String {
        (signer ?? h.signer).lease(fp: device.map(fingerprintClaim), fpk: device == nil ? nil : kind, at: at)
    }

    func holding(_ h: Harness, _ lease: String, _ edit: (inout StoredState) -> Void = { _ in }) {
        var state = StoredState(key: KEY, activationId: "act_1", lease: lease, lastSeen: NOW, checkedMajor: 1)
        edit(&state)
        h.storage.set(state)
        h.http.on("deactivate", status: 200, json: ["ok": true])
    }

    @Test func dropsItHereWithoutReleasingThatDevicesSeat() async throws {
        let h = try Harness()
        holding(h, lease(h, device: "fp-other-pc"))
        #expect(try await h.license.deactivate() == DeactivateResult(released: true))
        #expect(!h.http.called("deactivate"))
        #expect(h.stored?.key == nil && h.stored?.activationId == nil && h.stored?.lease == nil)
        #expect(h.stored?.verdictAt == NOW)
    }

    @Test func readsWhoseSeatItIsFromALeaseThatHasRunOutToo() async throws {
        let h = try Harness()
        holding(h, lease(h, device: "fp-other-pc", at: NOW - 40 * DAY))
        #expect(try await h.license.deactivate() == DeactivateResult(released: true))
        #expect(!h.http.called("deactivate"))
        #expect(h.stored?.key == nil)
    }

    @Test func takesADeviceRefusalThatStandsForThisDeviceAsTheSame() async throws {
        let h = try Harness()
        holding(h, lease(h, device: "fp-test")) { state in
            state.refused = .device
            state.refusedFor = [fingerprintClaim("fp-test")]
        }
        #expect(try await h.license.deactivate() == DeactivateResult(released: true))
        #expect(!h.http.called("deactivate"))
        #expect(h.stored?.key == nil && h.stored?.refused == nil)
    }

    @Test func stillReleasesThisDevicesOwnSeatAndOneHeldToNoMachine() async throws {
        let other = Signer()
        let cases: [(String, (Harness) -> String)] = [
            ("this device's own seat", { h in lease(h, device: "fp-test") }),
            ("a seat held to no machine", { h in lease(h, device: nil) }),
            ("a seat keyed by another device's host name", { h in lease(h, device: "fp-other-pc", kind: .hostname) }),
            // Whose seat a lease names is believed only from a lease whose signature holds.
            ("a lease that does not verify", { h in lease(h, device: "fp-other-pc", signer: other) }),
        ]
        for (name, make) in cases {
            let h = try Harness()
            holding(h, make(h))
            #expect(try await h.license.deactivate() == DeactivateResult(released: true), "\(name)")
            #expect(h.http.called("deactivate"), "\(name)")
            #expect(h.stored?.key == nil, "\(name)")
        }
    }

    @Test func releasesTheSeatOnARunThatCannotTellWhoTheDeviceIs() async throws {
        let h = try Harness(fingerprinter: GetFingerprinter { throw FakeHTTP.NetworkDown() })
        holding(h, lease(h, device: "fp-other-pc"))
        #expect(try await h.license.deactivate() == DeactivateResult(released: true))
        #expect(h.http.called("deactivate"))
    }
}
