import Foundation
import Testing

@testable import KeyGrant

/// Two instances of the app (two processes) on one state file, each with its own `License`.
@Suite("answers saved by two instances of the app", suiteTimeLimit)
struct TwoInstancesTests {
    let signer = Signer()

    /// One state file holding `stored`, the file system under it.
    func oneFile(_ stored: StoredState) -> MemoryFileSystem {
        MemoryFileSystem([statePath: JSONText.text(stored.json)])
    }

    /// An instance whose clock reads `now`, whose server answers each action as `answers` says.
    func instance(
        _ fs: MemoryFileSystem, now: Int, answers: [String: LicenseHTTPResponse], fingerprinter: any Fingerprinter = GetFingerprinter()
    ) throws -> License {
        let http = FakeHTTP()
        for (action, response) in answers { http.on(action) { _ in response } }
        return try License(LicenseConfig(
            product: PRODUCT, apiBaseURL: apiBase, publicJWK: signer.publicJWK,
            adapters: LicenseAdapters(storage: storage(fs), clock: FakeClock(now), fingerprinter: fingerprinter, http: http)
        ))
    }

    /// `first` held at its first save until `between` has run, then let finish.
    func interleave<T: Sendable>(_ fs: MemoryFileSystem, _ first: @escaping @Sendable () async -> T, _ between: () async throws -> Void) async rethrows -> T {
        let saving = fs.holdNext(.create)
        let running = Task { await first() }
        await eventually { saving.reached }
        try await between()
        saving.release()
        return await running.value
    }

    func saved(_ fs: MemoryFileSystem) -> StoredState {
        StoredState(json: fs.files[statePath].flatMap(JSONText.parse) ?? .null)
    }

    var held: StoredState {
        StoredState(key: KEY, activationId: "act_1", lease: signer.lease(at: NOW - DAY), lastSeen: NOW - DAY, checkedMajor: 1, rev: 1)
    }

    func lease(_ lease: String, aid: String = "act_1") -> LicenseHTTPResponse {
        LicenseHTTPResponse(status: 200, json: ["lease": .string(lease), "activationId": .string(aid)])
    }

    let revoked = LicenseHTTPResponse(status: 403, json: ["error": "revoked"])

    @Test func keepsTheNewerAnswerARefusalAskedForLaterSurvivesTheReMergeOfAnOlderAsksLease() async throws {
        let fs = oneFile(held)
        // A asks first and is answered with a lease; B asks a second later and is refused.
        let a = try instance(fs, now: NOW, answers: ["validate": lease(signer.lease())])
        let b = try instance(fs, now: NOW + 1_000, answers: ["validate": revoked])
        let answered = await interleave(fs, { await a.refresh() }) {
            #expect(await b.refresh() == LicenseStatus(state: .invalid, reason: .revoked, key: KEY))
        }
        #expect(answered == LicenseStatus(state: .licensed, key: KEY))
        #expect(saved(fs).refused == .revoked && saved(fs).verdictAt == NOW + 1_000)
        #expect(saved(fs).lease == nil)
        #expect(fs.ops.filter { $0.hasPrefix("create") }.count == 3)
    }

    @Test func keepsTheLaterAsksAnswerWhenTheClockWasPutBackBetweenTheTwoAsks() async throws {
        let fs = oneFile(held)
        let a = try instance(fs, now: NOW, answers: ["validate": lease(signer.lease())])
        // B asks after the clock was put back a minute: its own clock reads earlier than A's ask.
        let b = try instance(fs, now: NOW - 60_000, answers: ["validate": revoked])
        _ = await interleave(fs, { await a.refresh() }) {
            // A save made at NOW + 2 s, before the clock went back, raised the guard.
            var raised = saved(fs)
            raised.lastSeen = NOW + 2_000
            raised.rev = (raised.rev ?? 0) + 1
            fs.set(statePath, JSONText.text(raised.json))
            _ = await b.refresh()
        }
        // Stamped by the guarded clock, B's answer still reads as the later one.
        #expect(saved(fs).refused == .revoked && saved(fs).verdictAt == NOW + 2_000)
        #expect(saved(fs).lease == nil)
    }

    @Test func keepsARefusalAskedForLaterOverAReactivationOfTheSameSeatThatSavesAfterIt() async throws {
        let fs = oneFile(held)
        let w1 = try instance(fs, now: NOW, answers: ["activate": lease(signer.lease())])
        let w2 = try instance(fs, now: NOW + 1_000, answers: ["validate": revoked])
        let activated = await interleave(fs, { await w1.activate(KEY) }) {
            #expect(await w2.refresh() == LicenseStatus(state: .invalid, reason: .revoked, key: KEY))
        }
        #expect(activated == .activated)
        let state = saved(fs)
        #expect(state.key == KEY && state.activationId == "act_1" && state.refused == .revoked && state.verdictAt == NOW + 1_000)
        #expect(state.lease == nil)
        // So the revoked device does not license offline.
        #expect(await w1.status().reason == .revoked)
    }

    @Test(arguments: ["deactivate", "activate"])
    func aRenewalThatLandsAfterTheActivationItRenewedIsGoneWritesNothingOfIt(action: String) async throws {
        // W2's licence: an open lease inside its upgrade window, so a check-in notes the major it ran.
        let window = (NOW + 10 * DAY) / 1000
        var state = held
        state.lease = signer.lease(major: openMajor, upgradeUntil: window, at: NOW - DAY)
        let fs = oneFile(state)
        let leaseB = signer.lease(sub: "SLUICE-BBBB-BBBB-BBBB-BBBB", aid: "act_2")
        let w1 = try instance(fs, now: NOW, answers: [
            "deactivate": LicenseHTTPResponse(status: 200, json: ["ok": true]), "activate": lease(leaseB, aid: "act_2"),
        ])
        let machine = IdentifyingFingerprinter { DeviceIdentity(fingerprint: "fp-machine", kind: .machine) }
        let w2 = try instance(
            fs, now: NOW, answers: ["validate": lease(signer.lease(major: openMajor, upgradeUntil: window))], fingerprinter: machine
        )
        _ = try await interleave(fs, { await w2.refresh() }) {
            if action == "deactivate" {
                try await w1.deactivate()
            } else {
                #expect(await w1.activate("SLUICE-BBBB-BBBB-BBBB-BBBB") == .activated)
            }
        }
        let stored = saved(fs)
        #expect(stored.keptMajor == nil && stored.deviceKind == nil)
        if action == "deactivate" {
            #expect(stored.key == nil)
        } else {
            #expect(stored.key == "SLUICE-BBBB-BBBB-BBBB-BBBB" && stored.activationId == "act_2" && stored.lease == leaseB)
        }
    }
}
