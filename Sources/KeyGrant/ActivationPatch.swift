import Foundation

/// An activation the server answered with a lease that licenses this build (`activationPatch`).
struct Activation: Sendable {
    var key: String
    var activationId: String
    var lease: String
    /// The lease's claims.
    var claims: LeaseClaims
    /// The time the lease was judged at.
    var now: Int
    /// This build's major.
    var major: Int
    /// What the activation's fingerprint hashes: none for one of unknown kind.
    var kind: DeviceKind?
}

/// What an activation saves (`activate(_:)`), stamped as an activation: the key, the activation,
/// the lease, the major heard, the kept major (`keptWith`, cleared when it keeps none), any refusal
/// and wait cleared (`leased`), and what the install is keyed by (cleared for a fingerprint of
/// unknown kind).
func activationPatch(_ a: Activation) -> StatePatch {
    let patch: StatePatch = [
        .key: .string(a.key),
        .activationId: .string(a.activationId),
        .lease: .string(a.lease),
        .checkedMajor: .int(a.major),
        .keptMajor: .int(orClear: keptWith(nil, claims: a.claims, now: a.now, major: a.major)),
    ]
    return patch + leased + [.deviceKind: .deviceKind(orClear: a.kind)]
}
