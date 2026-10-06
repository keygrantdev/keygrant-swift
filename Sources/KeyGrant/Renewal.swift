import Foundation

/// The online validate (a renewal), decided without I/O (the reference's `renewal.ts`): when
/// `status()` asks the server while it holds a lease that licenses this build
/// (`asksOnValidLease`), and what an ask's answer saves and says (`renewalOutcome`). The engine
/// makes the request, judges the lease a 200 carried, and saves the patch as the answer to its ask.
///
/// Licensing fails in favour of the paying customer: only an explicit verdict (a lease, or a
/// refusal `refusalOf` names) gives a status. No answer at all, a 5xx, a 429, any other error, and
/// a 200 without a lease that can be used give none, and the caller's own answer (a valid lease, a
/// stored refusal, the lease's own end) stands.

/// What an ask's answer is judged from.
struct RenewalInput: Sendable {
    /// The answer; nil when there was none at all (the request threw or timed out).
    var response: LicenseHTTPResponse?
    /// The offline check (`checkLease`) of the lease the 200 carried, made as of `now` on this
    /// device; nil when it carried none.
    var check: LeaseCheck?
    /// When the ask was made, by the device clock (ms): where the wait before asking again starts.
    var askedAt: Int
    /// The time the lease was judged at (ms): the guarded clock, reconciled to the server's (`serverNow`).
    var now: Int
    /// This build's major, sent with the ask.
    var major: Int
    /// The stored key, which a status names.
    var key: String?
    /// The stored kept major (`keptWith`).
    var keptMajor: Int?
    /// Who this device is, as the ask read it: a machine id read keys the install (`keyedBy`), and
    /// a device refusal is held to its own claim (`refusalPatch`).
    var device: Device
}

/// What an ask's answer does.
struct RenewalOutcome: Sendable, Hashable {
    /// Whether the server answered at all: false for no answer, a 5xx or a 429.
    var answered: Bool
    /// The status the answer gives; nil when it gives none, and the caller's own answer stands.
    var status: LicenseStatus?
    /// What is saved, as the answer to the ask (`merged`, basis `answer`).
    var patch: StatePatch
}

/// What a validate's answer saves and says. Every patch carries `deviceKind: machine` when this
/// run read a machine id (`keyedBy`): the seat is re-keyed by it whatever the answer, so the
/// install is keyed by it from now on.
///
///  - no answer at all: wait `retryUnansweredMs`, no status;
///  - a 5xx or a 429: wait `askAgainMs`, no status;
///  - a 200 with a lease that licenses this build: the lease, the major heard (`checkedMajor`),
///    the kept major (`keptWith`, cleared when it keeps none), any refusal and wait cleared
///    (`leased`): licensed, with the lease's test flag and entitlements (`leaseStatus`);
///  - a 200 with a lease the server stands behind that does not license this build or this device
///    (`upgrade`, `outdated`, `device`): kept as above, with no kept major, so every later status
///    says the same offline: invalid, with no entitlements (`leaseStatus`);
///  - any other 200 (no lease, or one expired or not this licence's): the major heard and a wait
///    of `askAgainMs`, no status; never a lockout on a bad body;
///  - a refusal (`refusalOf` of the body's error word, on any status but a 200, a 5xx or a 429):
///    the major heard, the wait, and the refusal (`refusalPatch`): invalid with it;
///  - any other answer (a proxy's 4xx, an unknown product, a body that is not an object): the
///    major heard and the wait, no status.
func renewalOutcome(_ input: RenewalInput) -> RenewalOutcome {
    let keyed = keyedBy(input.device)
    guard let response = input.response else {
        let patch: StatePatch = [.backoffSince: .int(input.askedAt), .backoffMs: .int(Waits.retryUnansweredMs)]
        return RenewalOutcome(answered: false, status: nil, patch: patch + keyed)
    }
    let backoff: StatePatch = [.backoffSince: .int(input.askedAt), .backoffMs: .int(Waits.askAgainMs)] + keyed
    if noAnswer(response.status) { return RenewalOutcome(answered: false, status: nil, patch: backoff) }
    if response.status == 200 { return leaseOutcome(input, response, backoff: backoff) }
    // Locked out ONLY on an explicit verdict. Anything else (a proxy's or a WAF's 4xx, an
    // unknown-product 404, a malformed-body 400, an answer not recognised) is taken as no network,
    // so a still-valid lease is never revoked by an ambiguous answer.
    let refused = refusalOf(errorOf(response.json))
    // On a verdict, the next status() must not license offline what the server has just refused.
    let verdict = refused.map { refusalPatch($0, major: input.major, ownClaim: input.device.ownClaim) } ?? StatePatch()
    return RenewalOutcome(
        answered: true,
        status: refused.map { LicenseStatus(state: .invalid, reason: LicenseReason($0), key: input.key) },
        patch: [.checkedMajor: .int(input.major)] + backoff + verdict
    )
}

/// A 200's answer (`renewalOutcome`): by the lease it carried, as checked here.
private func leaseOutcome(_ input: RenewalInput, _ response: LicenseHTTPResponse, backoff: StatePatch) -> RenewalOutcome {
    if let lease = nonEmpty(parseLeaseBody(response.json).lease), let check = input.check {
        let kept: StatePatch = [.lease: .string(lease), .checkedMajor: .int(input.major)]
        switch check {
        case .ok(_, let claims):
            let keptMajor = keptWith(input.keptMajor, claims: claims, now: input.now, major: input.major)
            let patch = kept + [.keptMajor: .int(orClear: keptMajor)] + leased + keyedBy(input.device)
            return RenewalOutcome(answered: true, status: leaseStatus(check, key: input.key), patch: patch)
        case .refused(let reason) where reason == .upgrade || reason == .outdated || reason == .device:
            // A lease the server stands behind that does not license this build, or this device:
            // kept, so every later status() says the same offline.
            let patch = kept + leased + keyedBy(input.device)
            return RenewalOutcome(answered: true, status: leaseStatus(check, key: input.key), patch: patch)
        case .refused:
            break
        }
    }
    // A 200 with no lease that can be used: nothing to heal with, and whatever the caller has is
    // kept (in favour of the customer) rather than locked out on a bad body.
    return RenewalOutcome(answered: true, status: nil, patch: [.checkedMajor: .int(input.major)] + backoff)
}

/// Whether `status()`, holding a lease that licenses this build, asks the server now (unforced;
/// `refresh()` always asks): when the server should hear from this device before the lease runs
/// out. A newer major than the server last heard, on an open lease (`major >= openMajor`; else it
/// might not hear of it until the key's upgrade window has closed), or a lease nearing its end
/// (`renewsEarly`, by the guarded clock `now`), renewed early so it rarely runs out while the
/// device is offline. And only once the wait after the last ask is over (`askDue`, by the device
/// clock `clockNow`). The ask is bounded (`statusCheckTimeout`) and the valid lease is the answer
/// when it gets no verdict.
func asksOnValidLease(claims: LeaseClaims, state: StoredState, major: Int, now: Int, clockNow: Int) -> Bool {
    let newMajor = claims.major >= Double(openMajor) && major > (state.checkedMajor ?? 0)
    let due = newMajor || renewsEarly(claims, now: now)
    return due && askDue(state, clockNow: clockNow, force: false)
}

/// The outcome of an online validate: the server's verdict (a status, or none it would stand
/// by), or no answer at all.
enum Renewal: Sendable {
    case answered(LicenseStatus?)
    case unanswered
}
