import Foundation

/// Buying from the app with no key typed, under `License`: the purchase link (`purchaseURLNow`,
/// which keeps this install's one-time secret and hands out the reference to it) and the pickup
/// (`pickUp`): while no key is held and a secret is, asking the server for the key bought with it
/// (`claim`) and saving it exactly as `activate(_:)` saves one. What each answer does is
/// Pickup.swift; the public calls decide when to ask.
extension License {
    /// `purchaseURL(paymentLink:)`'s answer: nil while a key is held; else the link carrying the
    /// reference to the held secret, or to a new one, saved with when its link was handed out (the
    /// claim's wait cleared, so the next `status()` asks). Read-only (behind a call that has not
    /// settled), a held secret's link is answered as it is and none held throws: a secret that is
    /// not saved could never be picked up.
    func purchaseURLNow(_ link: URL, readOnly: Bool) async throws -> URL? {
        let state = try await load(readOnly: readOnly)
        if nonEmpty(state.key) != nil { return nil }
        let now = effectiveNow(state)
        let held = purchaseTokenKept(state, now: now) ? state.purchaseToken : nil
        if readOnly {
            guard let held else { throw LicenseCallError.previousCallUnfinished }
            return try linked(link, held)
        }
        let secret = held ?? newPurchaseSecret()
        // Built before the save: a link that cannot carry the reference saves nothing.
        let url = try linked(link, secret)
        try await save([.purchaseToken: .string(secret), .purchaseTokenAt: .int(now), .claimAskedAt: .clear])
        return url
    }

    /// `link` carrying the reference to `secret` (`purchaseLink`), or `InvalidPaymentLink` when it
    /// cannot.
    private func linked(_ link: URL, _ secret: String) throws -> URL {
        guard let url = purchaseLink(link, secret) else { throw InvalidPaymentLink(link: link.absoluteString) }
        return url
    }

    /// The key bought through `purchaseURL(paymentLink:)`, picked up: with no key held and a
    /// secret held, the secret is dropped once past its bound (`purchaseTokenKept`), and otherwise
    /// the claim is asked as `ask` says. Never called behind a call that has not settled.
    func pickUp(_ state: StoredState, ask: PickupAsk) async -> Pickup {
        guard nonEmpty(state.key) == nil, let secret = state.purchaseToken else { return .state(state) }
        let now = effectiveNow(state)
        if !purchaseTokenKept(state, now: now) { return .state(await dropSecret(state, secret)) }
        if !ask.start && !ask.force && !claimDue(state, clockNow: clockNow(), now: now) { return .state(state) }
        return await claim(state, secret: secret, ask: ask)
    }

    /// The secret dropped (saved about it, best-effort): the state without it.
    private func dropSecret(_ state: StoredState, _ secret: String) async -> StoredState {
        let basis = Basis(purchase: PurchaseBasis(token: secret))
        _ = await saveBestEffort(noPurchase, basis: basis)
        return merged(state, noPurchase, basis)
    }

    /// Asks for the key bought with `secret` (`claim`) and saves what the answer does
    /// (`claimOutcome`): a bought key as an activation, a wait or a drop about the secret. The body
    /// is `claimRequest`'s: from `status()`, a device whose own fingerprint did not read is not
    /// asked at all, and nothing is saved, so the next status asks again; at `startTrial()`, a
    /// device with no fingerprint at all is no answer. Saved best-effort: a bought key the disk
    /// refused is answered all the same, and the next claim answers it again (the server knows
    /// this device by any of the fingerprints it sends).
    private func claim(_ state: StoredState, secret: String, ask: PickupAsk) async -> Pickup {
        let askedClock = clockNow()
        let askedAt = effectiveNow(state)
        let device: Device
        if let known = ask.device { device = known } else { device = await self.device(timing.machineId, installKind: state.deviceKind) }
        let body = claimRequest(secret: secret, device: device, name: deviceName, major: major, start: ask.start)
        if body == nil && !ask.start { return .state(state) }
        let timeout = ask.force && !ask.start ? nil : timing.statusCheck
        var response: LicenseHTTPResponse?
        // Nil when it threw or timed out: no answer.
        if let body, case .object(var sent) = body.json {
            sent["kids"] = kidsJSON
            response = try? await post("claim", .object(sent), timeout: timeout)
        }
        let kind = body?.fingerprintKind
        let judged = await judgeClaim(response, kind: kind, askedAt: askedAt)
        let outcome = claimOutcome(
            ClaimInput(response: response, check: judged.check, clockNow: askedClock, now: judged.now, major: major, kind: kind)
        )
        if outcome.result == .bought, let status = outcome.status {
            let activationId = parseClaimBody(response?.json).activationId
            let activation = Asked(at: askedAt, activationId: activationId, seen: state.verdictAt)
            _ = await saveBestEffort(outcome.patch, basis: Basis(activation: activation))
            return .licensed(status)
        }
        // A wait is about the secret as its link was handed out when asked; a drop about the secret alone.
        let about = PurchaseBasis(token: secret, at: outcome.result == .kept ? state.purchaseTokenAt : nil)
        _ = await saveBestEffort(outcome.patch, basis: Basis(purchase: about))
        return .state(merged(state, outcome.patch, Basis(purchase: about)))
    }

    /// The lease a claim's 200 carried with a key and an activation id, checked for them on this
    /// device as of the server's time (`judged`); no check for any other answer. With the time it
    /// was judged at.
    private func judgeClaim(_ response: LicenseHTTPResponse?, kind: DeviceKind?, askedAt: Int) async -> (check: LeaseCheck?, now: Int) {
        guard let response, response.status == 200 else { return (nil, askedAt) }
        let body = parseClaimBody(response.json)
        guard let key = body.key, let activationId = body.activationId, let lease = body.lease else { return (nil, askedAt) }
        let judged = await judged(lease, for: LeaseOwner(key: key, activationId: activationId, deviceKind: kind), fallbackNow: askedAt)
        return (judged.check, judged.now)
    }
}

/// How a pickup asks: for `startTrial()` (`start`: always, under the device `startTrial()` read
/// once for both its asks, `device`, bounded as a status check is, a host-name fallback allowed),
/// or for `status()` (when `force`d, under the HTTP bound, or when `claimDue`, bounded as a status
/// check is), reading the device as a status does and asking only under its own fingerprint.
struct PickupAsk: Sendable {
    var start: Bool
    var force: Bool
    /// The device `startTrial()` read; nil for a `status()`, which reads it here.
    var device: Device?
}

/// What a pickup did: the licensed status when a bought key licensed this device, else the state
/// to answer from.
enum Pickup: Sendable {
    case licensed(LicenseStatus)
    case state(StoredState)
}
