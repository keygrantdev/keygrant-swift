import Foundation

/// Who this device is, for holding a lease to it and telling the server (a validate's
/// `fingerprints`): as far as can be told this call, and never guessed.
struct Device: Sendable, Hashable {
    /// This run's own fingerprint, or nil when it cannot be told this time.
    var own: String?
    /// What `own` hashes; nil when the fingerprinter does not say, or with no `own`.
    var kind: DeviceKind?
    var canTell: Bool
    /// Every fingerprint this device answers to: its own first, then its alternates.
    var fingerprints: [String]
    /// Their `fp` claims.
    var claims: [String]
    /// The claim of `own` alone, when there is one: what a `device` refusal is held to.
    var ownClaim: String?
    /// The host-name fingerprint to activate under when the machine id cannot be read even in an
    /// activation's time, or nil when there is none.
    var hostname: String?
}

/// Who this device is (`Device`), from what its fingerprinter said this time (`identity`), on an
/// install keyed as `installKind` (`StoredState.deviceKind`), held to its device or not
/// (`LicenseConfig.deviceHold`). `claimOf` is `fingerprintClaim`, which a reader may remember.
///
/// Install memory: once a machine id has keyed this install, a host-name answer is not this
/// device either. The id being unreadable now says nothing about whether the machine changed, so
/// it is "cannot tell", never the host name. A fingerprint of no kind (a custom `get()`) is not
/// judged by it.
///
/// Install memory applies only to a held device: not held, a host name is as good an answer as
/// any, and an install once keyed by a machine id must not leave an unreadable id with no
/// fingerprint to activate under. Not held, a device has no kind, so no seat is keyed to it, and
/// is judged as a run that cannot tell, so no lease is refused for its device and the server is
/// told no fingerprints. Its own still activates.
func deviceFrom(
    _ identity: DeviceIdentity,
    installKind: DeviceKind?,
    deviceHold: Bool,
    claimOf: (String) -> String = fingerprintClaim
) -> Device {
    let keyedAs = deviceHold ? installKind : nil
    // A kind with no fingerprint says nothing.
    let read = identity.fingerprint == nil ? nil : identity.kind
    let own = read == .hostname && keyedAs == .machine ? nil : identity.fingerprint
    let fingerprints = (own.map { [$0] } ?? []) + identity.alternates.filter { !sameText($0, own) }
    let hostname = read == .hostname ? identity.fingerprint : identity.alternates.first
    let claims = fingerprints.map(claimOf)
    var device = Device(own: own, canTell: own != nil, fingerprints: fingerprints, claims: claims, hostname: hostname)
    if !deviceHold {
        device.canTell = false
        return device
    }
    if own != nil {
        device.ownClaim = claims.first
        device.kind = read
    }
    return device
}

/// Reads, and once settled keeps, who this device is.
final class DeviceIdentityReader: Sendable {
    let fingerprinter: any Fingerprinter
    /// How much longer than its own bound a fingerprinter's `identify` is given.
    private let slack: TimeInterval
    /// What the bounds are kept by.
    private let ticker: any Ticker
    private let known = Locked<DeviceIdentity?>(nil)
    private let claimCache = Locked<[String: String]>([:])

    init(_ fingerprinter: any Fingerprinter, slack: TimeInterval, ticker: any Ticker = SystemTicker()) {
        self.fingerprinter = fingerprinter
        self.slack = slack
        self.ticker = ticker
    }

    /// Who this device is (`deviceFrom`), reading for at most about `timeout`, on an install keyed
    /// as `installKind`, held to its device unless `deviceHold` is false. A fingerprinter that
    /// throws, or does not answer in time, gives "cannot tell", not kept: a failed read must
    /// neither stand in for the device nor stick.
    func read(timeout: TimeInterval, installKind: DeviceKind?, deviceHold: Bool = true) async -> Device {
        let identity: DeviceIdentity
        if let settled = known.current {
            identity = settled
        } else {
            identity = await self.identity(timeout)
        }
        if identity.fingerprint != nil { known.withValue { $0 = identity } }
        return deviceFrom(identity, installKind: installKind, deviceHold: deviceHold, claimOf: claimOf)
    }

    /// A fingerprint's claim (`fingerprintClaim`), remembered.
    private func claimOf(_ fingerprint: String) -> String {
        if let known = claimCache.withValue({ $0[fingerprint] }) { return known }
        let claim = fingerprintClaim(fingerprint)
        claimCache.withValue { $0[fingerprint] = claim }
        return claim
    }

    /// The fingerprinter's answer, bounded; one with only `get()` says nothing of what it hashes,
    /// and has the bound itself, with no slack.
    private func identity(_ timeout: TimeInterval) async -> DeviceIdentity {
        let fingerprinter = self.fingerprinter
        do {
            return try await withTimeout(timeout + slack, on: ticker) { try await fingerprinter.identify(timeout: timeout) }
        } catch is IdentifyNotImplemented {
            do {
                return DeviceIdentity(fingerprint: try await withTimeout(timeout, on: ticker) { try await fingerprinter.get() })
            } catch {
                return DeviceIdentity(fingerprint: nil)
            }
        } catch {
            return DeviceIdentity(fingerprint: nil)
        }
    }
}
