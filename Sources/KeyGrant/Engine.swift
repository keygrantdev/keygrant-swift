import Foundation

/// The machinery under `License`: every request bounded, the stored state and its clock guard, and
/// the online validate with what its answer does to the stored state.
extension License {
    /// The device clock, kept within what a JavaScript number holds exactly, so no sum on it overflows.
    func clockNow() -> Int {
        clampToSafe(clock.now())
    }

    /// POST to the product's endpoint, ALWAYS bounded: by `timeout`, else by `httpTimeout`. The
    /// bound is passed to the adapter and also kept here, so an adapter that ignores it cannot
    /// hold a call, and every call queued behind it, open.
    func post(_ action: String, _ body: LicenseJSON, timeout: TimeInterval? = nil) async throws -> LicenseHTTPResponse {
        let bound = timeout ?? httpTimeout
        guard let url = endpoint(action) else { throw InvalidEndpoint() }
        let http = self.http
        return try await withTimeout(bound, on: timing.ticker) { try await http.post(url, body: body, timeout: bound) }
    }

    /// `<apiBaseURL>/v1/products/<product>/<action>`: the product one path segment whatever it
    /// holds (all but RFC 3986's unreserved characters percent-encoded).
    func endpoint(_ action: String) -> URL? {
        let segment = product.addingPercentEncoding(withAllowedCharacters: pathSegmentCharacters) ?? product
        return URL(string: "\(base)/v1/products/\(segment)/\(action)")
    }

    func verify(_ lease: String, now: Int) -> VerifyResult {
        verifyLease(lease, publicKey: publicKey, now: now)
    }

    /// A licence lease verified offline and held to this product and build, and to the key and
    /// activation it is for, on this device (`checkLease`).
    func evaluate(_ lease: String, now: Int, key: String?, activationId: String?, deviceKind: DeviceKind?) async -> LeaseCheck {
        let device = await self.device(timing.machineId, installKind: deviceKind)
        let holder = LeaseHolder(key: key ?? "", activationId: activationId ?? "", claims: device.claims, canTell: device.canTell)
        return checkLease(verify(lease, now: now), product: product, major: major, holder: holder)
    }

    /// A trial lease verified offline, for this product and this device, with the end it was
    /// signed to (ms) and its entitlements when it is valid (`trialLeaseOf`).
    func trialLease(_ lease: String, now: Int, installKind: DeviceKind?) async -> TrialLease {
        let device = await self.device(timing.machineId, installKind: installKind)
        return trialLeaseOf(verify(lease, now: now), product: product, claims: device.claims, canTell: device.canTell)
    }

    /// Who this device is, read for at most about `timeout`, on an install keyed as `installKind`,
    /// held to its device as configured (`deviceHold`): `deviceFrom`.
    func device(_ timeout: TimeInterval, installKind: DeviceKind?) async -> Device {
        await reader.read(timeout: timeout, installKind: installKind, deviceHold: deviceHold)
    }

    /// The install's kind as it bears on this device: none when nothing is held.
    func installKind(_ stored: DeviceKind?) -> DeviceKind? {
        deviceHold ? stored : nil
    }

    /// The stored state; `readOnly` behind a call that has not finished, so the read writes nothing either.
    func load(readOnly: Bool = false) async throws -> StoredState {
        try await storage.read(readOnly: readOnly) ?? StoredState()
    }

    /// Persist a patch onto the state as it is stored NOW, through the storage's `update`, which
    /// merges it again onto a state another process saved meanwhile; with the latest time seen
    /// (`savedLastSeen`): the guard advanced, or brought back on the server's evidence
    /// (`guardTime`). What the patch is (`basis`) decides what of it lands on a state another
    /// process changed (`merged`).
    func save(_ patch: StatePatch, guardTime: Int? = nil, basis: Basis = Basis()) async throws {
        let clock = self.clock
        try await storage.update { latest in
            var next = merged(latest, patch, basis)
            next.lastSeen = savedLastSeen(stored: latest.lastSeen, clockNow: clampToSafe(clock.now()), guard: guardTime)
            return next
        }
    }

    /// A save for `status()` and `startTrial()`, whose failure fails nothing: the answer stands.
    /// The write is atomic, so a failed one left the state as it was. Whether it was saved.
    func saveBestEffort(_ patch: StatePatch, guardTime: Int? = nil, basis: Basis = Basis()) async -> Bool {
        do {
            try await save(patch, guardTime: guardTime, basis: basis)
            return true
        } catch {
            return false
        }
    }

    /// Never earlier than the highest wall-clock time ever seen (anti clock-rollback).
    func effectiveNow(_ state: StoredState) -> Int {
        guardedNow(clockNow(), state.lastSeen)
    }

    /// `now` for judging a lease the server has just signed, with the clock guard reconciled to it
    /// (`clockCorrection`): a guard more than the tolerance past the lease's signing time comes
    /// back. `save` saves the correction; throws when the state cannot be read.
    func serverNow(
        _ lease: String, key: String, activationId: String, save: (StatePatch, Int) async throws -> Void
    ) async throws -> Int {
        let stored = try await load()
        let now = effectiveNow(stored)
        let signed = verify(lease, now: now).claims.map { SignedAt(sub: $0.sub, aid: $0.aid, iat: $0.iat) }
        let heldIat = nonEmpty(stored.lease).flatMap { verify($0, now: now).claims?.iat }
        let corrected = clockCorrection(
            clockNow: clockNow(), lastSeen: stored.lastSeen, claims: signed, heldIat: heldIat, key: key, activationId: activationId
        )
        guard let corrected else { return now }
        try await save(StatePatch(), corrected)
        return corrected
    }

    /// An online validate: a status on a definitive answer, else nil.
    func tryRenew(_ state: StoredState, timeout: TimeInterval? = nil) async -> LicenseStatus? {
        if case .answered(let status) = await renew(state, timeout: timeout) { return status }
        return nil
    }

    /// An online validate, and whether the server gave a verdict. What its answer saves and says is
    /// `renewalOutcome`: any verdict records the major it was sent as heard (`checkedMajor`); an
    /// ask that came back without a lease starts the wait before the SDK asks again on its own: a
    /// minute when nothing answered at all, an hour when the server did (a refusal, a 5xx, a 429,
    /// an answer it could not use).
    func renew(_ state: StoredState, timeout: TimeInterval? = nil) async -> Renewal {
        // The wait runs on the device clock; the answer is stamped by the guarded one.
        let askedAt = clockNow()
        let asked = Asked(at: effectiveNow(state), activationId: state.activationId, seen: state.verdictAt)
        // A machine id read here keys this install from now on, written with whatever this ask writes.
        let device = await self.device(timing.machineId, installKind: state.deviceKind)
        let response: LicenseHTTPResponse?
        do {
            response = try await post("validate", validateBody(state, device), timeout: timeout)
        } catch {
            response = nil
        }
        let judged = await judgeFresh(state, response)
        let outcome = renewalOutcome(
            RenewalInput(
                response: response, check: judged.check, askedAt: askedAt, now: judged.now, major: major,
                key: state.key, keptMajor: state.keptMajor, device: device
            )
        )
        // Saved as the answer to its ask; a save that fails leaves the answer standing.
        _ = await saveBestEffort(outcome.patch, basis: Basis(answer: asked))
        return outcome.answered ? .answered(outcome.status) : .unanswered
    }

    /// The lease a validate's 200 carried, checked on this device (`evaluate`) as of the server's
    /// time (`serverNow`, the clock guard brought back best-effort: the server's time even when the
    /// state cannot be read or saved just now); no check for any other answer. With the time it
    /// was judged at.
    private func judgeFresh(_ state: StoredState, _ response: LicenseHTTPResponse?) async -> (check: LeaseCheck?, now: Int) {
        guard let response, response.status == 200, let lease = nonEmpty(parseLeaseBody(response.json).lease) else {
            return (nil, effectiveNow(state))
        }
        let holder = LeaseOwner(key: state.key ?? "", activationId: state.activationId ?? "", deviceKind: state.deviceKind)
        let judged = await judged(lease, for: holder, fallbackNow: effectiveNow(state))
        return (judged.check, judged.now)
    }

    /// A lease the server just answered, checked for `owner` on this device (`evaluate`) as of the
    /// server's time (`serverNow`, the clock guard brought back best-effort: `fallbackNow` when
    /// the state cannot be read just now). With the time it was judged at.
    func judged(_ lease: String, for owner: LeaseOwner, fallbackNow: Int) async -> (check: LeaseCheck, now: Int) {
        let now: Int
        do {
            now = try await serverNow(lease, key: owner.key, activationId: owner.activationId) { patch, guardTime in
                _ = await self.saveBestEffort(patch, guardTime: guardTime)
            }
        } catch {
            now = fallbackNow
        }
        let check = await evaluate(lease, now: now, key: owner.key, activationId: owner.activationId, deviceKind: owner.deviceKind)
        return (check, now)
    }

    /// A validate's body: with every fingerprint this device answers to when it can tell, so the
    /// server refuses a licence file copied from another machine; with none when it cannot.
    func validateBody(_ state: StoredState, _ device: Device) -> LicenseJSON {
        var body: [String: LicenseJSON] = ["major": .number(Double(major))]
        if let key = state.key { body["key"] = .string(key) }
        if let activationId = state.activationId { body["activationId"] = .string(activationId) }
        if let kept = state.keptMajor { body["keptMajor"] = .number(Double(kept)) }
        if device.canTell { body["fingerprints"] = .array(device.fingerprints.map(LicenseJSON.string)) }
        if device.canTell, let kind = device.kind { body["fingerprintKind"] = .string(kind.rawValue) }
        return .object(body)
    }
}

/// What a path segment may hold as it is: RFC 3986's unreserved characters.
private let pathSegmentCharacters = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
)

/// The API base and product do not make a URL.
private struct InvalidEndpoint: Error {}

/// Whose a lease the server just answered is meant to be (`judged`): the key and activation it
/// came for, and what the install is keyed by (none for a fingerprint of unknown kind).
struct LeaseOwner: Sendable, Hashable {
    var key: String
    var activationId: String
    var deviceKind: DeviceKind?
}

extension LicenseReason {
    init(_ reason: LeaseCheck.Reason) {
        switch reason {
        case .expired: self = .offline
        case .upgrade: self = .upgrade
        case .outdated: self = .outdated
        case .tampered: self = .tampered
        case .device: self = .device
        }
    }

    init(_ refusal: Refusal) {
        switch refusal {
        case .revoked: self = .revoked
        case .upgrade: self = .upgrade
        case .outdated: self = .outdated
        case .device: self = .device
        }
    }
}
