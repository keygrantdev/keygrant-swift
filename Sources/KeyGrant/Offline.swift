import Foundation

/// What the SDK decides from what the device holds, without asking the server: whether a lease
/// licenses this build, what a trial shows, which refusal still stands, when to ask the server
/// again, and how a save lands on a state another process changed.
enum Waits {
    /// How long after the server answered without a lease before the SDK asks again on its own.
    static let askAgainMs = 60 * 60_000
    /// How long after an ask that got no answer at all (no network, a timeout).
    static let retryUnansweredMs = 60_000
    /// A valid lease is renewed early once less than this is left of it (or less than half its life).
    static let renewWithinMs = 7 * 24 * 60 * 60_000
    /// How far the clock guard may run ahead of a fresh lease's signing time before it is brought back.
    static let clockToleranceMs = 60 * 60_000
    static let dayMs = 86_400_000
}

/// The major a build runs as: the configured one, read as the server reads a version (0.x as 1, and
/// majors from 1 up). So a build configured as major 0 is major 1 everywhere the SDK uses the major
/// (sent with an activation and a validate, and judged by `checkLease`, `keptWith`,
/// `standingRefusal` and the renewal decisions), rather than refused offline as `outdated` by every
/// lease. None configured is 1.
func majorOf(_ configured: Int?) -> Int {
    max(1, configured ?? 1)
}

/// What a licence lease says about this build, offline.
enum LeaseCheck: Sendable, Hashable {
    case ok(test: Bool, claims: LeaseClaims)
    case refused(Reason)

    enum Reason: String, Sendable, Hashable {
        case expired, upgrade, outdated, tampered, device
        case unknownKey = "unknown-key"
    }
}

/// Whose a licence lease must be: the key and activation stored, and this device.
struct LeaseHolder: Sendable, Hashable {
    var key: String
    var activationId: String
    /// Every `fp` claim this device answers to: its own, and the host-name one it may have been activated under.
    var claims: [String]
    /// Whether this run could tell who the device is.
    var canTell: Bool
}

/// Whether two strings are the same text unit for unit, as JavaScript's `===` compares them
/// (Swift's `==` also equates canonically equivalent ones).
func sameText(_ a: String, _ b: String) -> Bool {
    a.unicodeScalars.elementsEqual(b.unicodeScalars)
}

func sameText(_ a: String?, _ b: String?) -> Bool {
    switch (a, b) {
    case (nil, nil): true
    case (let a?, let b?): sameText(a, b)
    default: false
    }
}

/// Whether two licence keys are the same key: the server matches them without regard to case.
func sameKey(_ a: String, _ b: String) -> Bool {
    sameText(a.uppercased(), b.uppercased())
}

/// A verified licence lease held to this product, this holder and this build's major
/// (`checkLease`): another product, key or activation is `tampered`; a seat keyed by a machine id
/// for another device is `device`, unless this run cannot tell who the device is; a build below
/// `minMajor` (absent: 1) is `outdated`, one above `major` `upgrade`.
func checkLease(_ verified: VerifyResult, product: String, major: Int, holder: LeaseHolder) -> LeaseCheck {
    guard case .valid(let claims) = verified else {
        switch verified.failure {
        case .expired?: return .refused(.expired)
        case .unknownKey?: return .refused(.unknownKey)
        default: return .refused(.tampered)
        }
    }
    if !sameText(claims.product, product) { return .refused(.tampered) }
    if !sameKey(claims.sub, holder.key) || !sameText(claims.aid, holder.activationId) { return .refused(.tampered) }
    // Held to its device only when its seat is keyed by a machine id: a host name changes with a
    // rename or an architecture switch.
    let held = claims.fp != nil && claims.fpk == .machine
    if held && holder.canTell && !holder.claims.contains(where: { sameText($0, claims.fp ?? "") }) {
        return .refused(.device)
    }
    if Double(major) < (claims.minMajor ?? 1) { return .refused(.outdated) }
    if Double(major) > claims.major { return .refused(.upgrade) }
    return .ok(test: claims.test == true, claims: claims)
}

/// The status a stored licence lease gives, judged offline (`checkLease`), when the server gives no
/// verdict on it: licensed, with the check's test flag (its one source) and the lease's
/// entitlements (empty when it grants none); `.expired`/`.offline` once it has run out; `.invalid`
/// with the reason, and the key, when it is not for this build or this device, or is signed by a
/// key the build does not carry (`.unknownKey`); `.invalid`/`.tampered`, with no key, when it is not this licence's at all. Only a lease that
/// licenses carries entitlements. Test licences verify like any other (they are signed with the
/// product's real key); the flag is how an app tells them apart.
func leaseStatus(_ check: LeaseCheck, key: String?) -> LicenseStatus {
    switch check {
    case .ok(let test, let claims): LicenseStatus(state: .licensed, key: key, isTest: test, entitlements: claims.ent)
    case .refused(.expired): LicenseStatus(state: .expired, reason: .offline, key: key)
    case .refused(.tampered): LicenseStatus(state: .invalid, reason: .tampered)
    case .refused(let reason): LicenseStatus(state: .invalid, reason: LicenseReason(reason), key: key)
    }
}

/// Whether a licence lease is held to a machine that is not this device (the reference's
/// `heldElsewhere`): its seat keyed by a machine id (`fp`, `fpk` machine) that this run can tell
/// is not one of its own. Read from the claims of a lease whose signature holds, expired or not:
/// a seat does not change hands when its lease runs out. A lease held to no machine (no `fp`, or a
/// host name's) is never elsewhere. A seat that is another device's is not this device's to
/// release (`deactivate()`).
func heldElsewhere(_ verified: VerifyResult, claims deviceClaims: [String], canTell: Bool) -> Bool {
    let claims: LeaseClaims?
    switch verified {
    case .valid(let valid): claims = valid
    case .invalid(.expired, let expired): claims = expired
    case .invalid: claims = nil
    }
    guard let claims, let fp = claims.fp, claims.fpk == .machine, canTell else { return false }
    return !deviceClaims.contains { sameText($0, fp) }
}

/// `kept` after running `major` on a lease with these claims at `now`: raised to it while the
/// lease carries an open upgrade window (`upgradeUntil`, seconds) and `now` is before its end.
func keptWith(_ kept: Int?, claims: LeaseClaims, now: Int, major: Int) -> Int? {
    guard let until = claims.upgradeUntil, Double(now) < until * 1000 else { return kept }
    return max(kept ?? 0, major)
}

/// A trial lease, verified: a trial's (`model`), for this product, and for this device, judged
/// only when the trial was started under a machine id (`fpk`) and this run can tell who the device
/// is. A licence's lease in the trial's place is not a trial: the server signs a trial's as `trial`.
func trialLeaseValid(_ verified: VerifyResult, product: String, claims deviceClaims: [String], canTell: Bool) -> Bool {
    guard case .valid(let claims) = verified, claims.model == "trial", sameText(claims.product, product) else {
        return false
    }
    return claims.fpk != .machine || !canTell || deviceClaims.contains(where: { sameText($0, claims.aid) })
}

/// What a trial's status reads of its trial lease (`trialLeaseOf`).
struct TrialLease: Sendable, Hashable {
    /// Whether it is valid here (`trialLeaseValid`).
    var valid: Bool
    /// The end it was signed to (its `exp`, in ms), when it is valid.
    var endsAt: Int?
    /// What it grants (its `ent`), when it is valid; empty otherwise.
    var entitlements: [String: Entitlement] = [:]

    /// A trial lease that is not valid here: it says nothing of an end or of entitlements.
    static let invalid = TrialLease(valid: false)
}

/// A trial lease, verified, as a trial's status reads it: whether it is valid here
/// (`trialLeaseValid`), and, when it is, the end it was signed to and its entitlements. A lease
/// that is not valid here says nothing of either.
func trialLeaseOf(_ verified: VerifyResult, product: String, claims deviceClaims: [String], canTell: Bool) -> TrialLease {
    guard case .valid(let claims) = verified,
        trialLeaseValid(verified, product: product, claims: deviceClaims, canTell: canTell)
    else { return .invalid }
    // A whole number of seconds, at least 0 (the claims hold no other): as ms, within what a
    // JavaScript number holds exactly.
    let endsAt = Int(min(claims.exp * 1000, Double(maxSafeInteger)))
    return TrialLease(valid: true, endsAt: endsAt, entitlements: claims.ent)
}

/// A trial's status from what the device holds: `leaseValid` is its trial lease, checked
/// (`trialLeaseValid`), `leaseEndsAt` the end that lease was signed to (its `exp`, in ms), and
/// `leaseEntitlements` what it grants (its `ent`), which a running trial carries. Every other
/// answer carries none.
///
/// A trial runs only while its trial lease is valid. The `trialEndsAt` stored beside it is the
/// server's word too, but UNSIGNED: trusted on its own, an edit to it in the state file was a
/// trial that never ended, offline or not. KeyGrant signs a trial lease to the trial's own end, so
/// an honest trial holds a valid one for every day it runs, and the signed end is the one shown.
/// The stored end is shown only when the lease's is not known.
func trialStatusOf(
    _ state: StoredState, now: Int, leaseValid: Bool, leaseEndsAt: Int? = nil, leaseEntitlements: [String: Entitlement] = [:]
) -> LicenseStatus {
    // No trial evidence at all: the trial was never started, not expired.
    if state.trialStart == nil && state.trialEndsAt == nil && state.trialLease == nil {
        return LicenseStatus(state: .unlicensed)
    }
    guard leaseValid else { return LicenseStatus(state: .expired, reason: .trial) }
    let trialEndsAt = leaseEndsAt ?? state.trialEndsAt
    let daysLeft = trialEndsAt.map { max(0, ceilingDivision(difference($0, now), Waits.dayMs)) }
    return LicenseStatus(state: .trial, trialDaysLeft: daysLeft, trialEndsAt: trialEndsAt, entitlements: leaseEntitlements)
}

/// `a - b`, held at the ends of `Int` rather than overflowing: a state a custom storage adapter
/// built in code may hold any value, and no value it holds may crash the app.
func difference(_ a: Int, _ b: Int) -> Int {
    let (result, overflow) = a.subtractingReportingOverflow(b)
    guard overflow else { return result }
    return a > b ? Int.max : Int.min
}

/// `ceil(a / b)` for a positive `b`.
func ceilingDivision(_ a: Int, _ b: Int) -> Int {
    let quotient = a / b
    return a % b > 0 ? quotient + 1 : quotient
}

/// What storing the server's refusal changes: `revoked` drops the lease; `upgrade` and `outdated`
/// keep it, with the major refused; `device` keeps it, with this device's own claim (empty when it
/// has none).
func refusalPatch(_ refused: Refusal, major: Int, ownClaim: String?) -> StatePatch {
    switch refused {
    case .revoked:
        return [.lease: .clear, .refused: .refusal(.revoked), .refusedMajor: .clear, .refusedFor: .clear]
    case .device:
        return [.refused: .refusal(.device), .refusedMajor: .clear, .refusedFor: .strings(ownClaim.map { [$0] } ?? [])]
    case .upgrade, .outdated:
        return [.refused: .refusal(refused), .refusedMajor: .int(major), .refusedFor: .clear]
    }
}

/// What a check-in with this device writes of the install's key: a machine id read here keys it.
func keyedBy(_ device: Device) -> StatePatch {
    device.kind == .machine ? [.deviceKind: .deviceKind(.machine)] : StatePatch()
}

/// When something was asked of the server (guarded device clock, ms), and the stored stamp of that
/// kind the asker saw.
struct Stamp: Sendable, Hashable {
    var at: Int
    var seen: Int?
}

/// An ask of the server about an activation, as a save of its answer sees it.
struct Asked: Sendable, Hashable {
    var at: Int
    /// The activation it asked about.
    var activationId: String?
    var seen: Int?

    var stamp: Stamp { Stamp(at: at, seen: seen) }
}

/// A save about an activation that is not an answer (what a check-in noted it ran).
struct About: Sendable, Hashable {
    var activationId: String?
}

/// What a save is based on.
struct Basis: Sendable, Hashable {
    /// The answer to an ask about an activation: stamped `verdictAt`.
    var answer: Asked?
    /// An activation's answer, about the activation it names: stamped `verdictAt`.
    var activation: Asked?
    /// A save about an activation that is not an answer.
    var about: About?
    /// The server's answer to a trial ask: stamped `trialAt`.
    var trial: Stamp?
}

/// What the answer to an ask writes: what the server said, and the wait before asking again.
let verdictFields: Set<StateField> = [
    .lease, .refused, .refusedMajor, .refusedFor, .backoffSince, .backoffMs, .checkedMajor, .verdictAt,
]

/// A server trial answer, taken whole from the newest one: the end and the lease that says it.
let trialAnswerFields: Set<StateField> = [.trialEndsAt, .trialLease, .trialAt]

/// The trial evidence, which belongs to the device, not to any activation.
let trialFields: Set<StateField> = trialAnswerFields.union([.trialStart])

/// What a new lease from the server clears: any refusal, and the wait before asking again.
let leased: StatePatch = [.refused: .clear, .refusedMajor: .clear, .refusedFor: .clear, .backoffSince: .clear, .backoffMs: .clear]

/// What a deactivated device keeps of its licence: nothing but its trial evidence and clock guard.
let unkeyed: StatePatch = [
    .key: .clear, .activationId: .clear, .lease: .clear, .checkedMajor: .clear, .keptMajor: .clear, .deviceKind: .clear,
] + leased

/// Whether a stored stamp is a NEWER answer than `stamp`'s: saved since that asker read the state
/// (another stamp than the one it saw), and asked for later than it.
func outdated(_ stored: Int?, _ stamp: Stamp) -> Bool {
    stored != stamp.seen && (stored ?? Int.min) > stamp.at
}

/// How an ask's answer is out of date by the time it is saved.
enum Superseded: Sendable, Hashable {
    /// The state now names another activation, or none: nothing of it but trial evidence may land.
    case activation
    /// A newer answer about the same activation has been saved: its verdict fields may not land.
    case answer
}

func superseded(_ latest: StoredState, _ asked: Asked) -> Superseded? {
    if !sameText(latest.activationId, asked.activationId) { return .activation }
    return outdated(latest.verdictAt, asked.stamp) ? .answer : nil
}

/// A patch without the verdict fields: what of an out-of-date answer is still saved.
func withoutVerdict(_ patch: StatePatch) -> StatePatch {
    patch.omitting(verdictFields)
}

/// Only the trial evidence of a patch: what lands on another activation.
func trialOnly(_ patch: StatePatch) -> StatePatch {
    patch.keepingOnly(trialFields)
}

/// How out of date a save is by what it is based on.
private func outOfDate(_ latest: StoredState, _ basis: Basis) -> Superseded? {
    if let answer = basis.answer { return superseded(latest, answer) }
    // An activation's answer on the same seat, activated again: an answer like any.
    if let activation = basis.activation {
        let same = sameText(latest.activationId, activation.activationId)
        return same && outdated(latest.verdictAt, activation.stamp) ? .answer : nil
    }
    if let about = basis.about, !sameText(latest.activationId, about.activationId) { return .activation }
    return nil
}

/// A patch merged onto the state as stored now, by what it is based on (the reference's
/// `merged`). Stamped: an answer or an activation with `verdictAt`, a trial answer with `trialAt`.
/// A save about an activation no longer stored keeps only its trial evidence; an answer older than
/// the stored one loses its verdict fields, as does an activation of the same seat; a trial answer
/// older than the stored one loses its end and lease, taken together from the newest. The trial
/// start only ever moves earlier, whoever saved it; the kept major of the stored activation only ever up (a
/// deactivation, based on nothing, still clears it).
func merged(_ latest: StoredState, _ patch: StatePatch, _ basis: Basis = Basis()) -> StoredState {
    let stamp = basis.answer ?? basis.activation
    var applied = patch
    if let stamp { applied[.verdictAt] = .int(stamp.at) }
    if let trial = basis.trial { applied[.trialAt] = .int(trial.at) }
    switch outOfDate(latest, basis) {
    case .activation?: applied = trialOnly(applied)
    case .answer?: applied = withoutVerdict(applied)
    case nil: break
    }
    if let trial = basis.trial, outdated(latest.trialAt, trial) { applied = applied.omitting(trialAnswerFields) }
    let trialStart = earliest(latest.trialStart, applied.int(.trialStart))
    var result = applied.applied(to: latest)
    if let trialStart { result.trialStart = trialStart }
    // About the stored activation: its kept major only goes up, a renewal's none included.
    // Unbased (a deactivation) or a fresh activation: as patched.
    let about: String?? = stamp.map { $0.activationId } ?? basis.about.map { $0.activationId }
    if let about, sameText(latest.activationId, about) {
        let kept = [latest.keptMajor, applied.int(.keptMajor)].compactMap { $0 }
        if let highest = kept.max() { result.keptMajor = highest }
    }
    return result
}

/// The stored refusal that still stands for a build running `major`, or nil. A key-level one
/// always does; a build-level one for the build refused and any further the same way (`upgrade`
/// newer, `outdated` older); one stored with no `refusedMajor` for every build. A `device` one
/// with `refusedFor` only while this run can tell it is still the device it was given for.
func standingRefusal(_ state: StoredState, major: Int, device: (ownClaim: String?, canTell: Bool)?) -> Refusal? {
    guard let refused = state.refused else { return nil }
    if refused == .device, let refusedFor = state.refusedFor {
        let own = device?.canTell == true ? device?.ownClaim : nil
        guard let own else { return nil }
        return refusedFor.contains(where: { sameText($0, own) }) ? refused : nil
    }
    guard let refusedMajor = state.refusedMajor, refused == .upgrade || refused == .outdated else { return refused }
    return (refused == .upgrade ? major >= refusedMajor : major <= refusedMajor) ? refused : nil
}

/// Whether to ask the server now: forced; no wait recorded; the device clock before the recorded
/// ask (it was set back); or the wait (`backoffMs`, default an hour) over.
func askDue(_ state: StoredState, clockNow: Int, force: Bool) -> Bool {
    guard !force, let since = state.backoffSince, clockNow >= since else { return true }
    return difference(clockNow, since) >= (state.backoffMs ?? Waits.askAgainMs)
}

/// Whether a valid lease is near enough its end at `now` to renew it early: less than
/// `renewWithinMs` left, or less than half its life if that is shorter.
func renewsEarly(_ claims: LeaseClaims, now: Int) -> Bool {
    let left = claims.exp * 1000 - Double(now)
    let life = (claims.exp - claims.iat) * 1000
    return left < min(Double(Waits.renewWithinMs), life / 2)
}
