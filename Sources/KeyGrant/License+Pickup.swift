import Foundation

/// Key pickup under `License` (`Pickup.swift` holds the pure pieces): a code mailed to the address a
/// key was sold to (`pickUp(email:)`), that address's keys of the product for the code
/// (`pickUp(email:code:)`), and a restore that confirms and activates the key that fits this build
/// (`restoreByEmail(email:code:)`), so an App Store build licenses itself with no key typed.
///
/// The two `pickUp` calls store nothing and run beside any call; a restore runs in the one-at-a-time
/// order as `activate` does, and what it activates is stored as any activation is. Nothing here takes
/// a licence away.
extension License {
    /// Ask KeyGrant to mail a code to `email`, the address a key was sold to. For a build that may not
    /// take a typed key (an App Store build): the customer types the code, then `pickUp(email:code:)`
    /// hands back that address's keys, or `restoreByEmail(email:code:)` activates the one that fits.
    /// `.sent` means the code is on its way when the address holds a key: the answer is the same when
    /// it holds none.
    ///
    /// The product's Key pickup must be on (`.pickupDisabled` otherwise). A blank address, or one
    /// longer than any, is `.invalidEmail`, asking nothing. Stores nothing, runs beside any call, and
    /// never throws: no answer at all is `.network`.
    public func pickUp(email: String) async -> PickUpResult {
        guard case .send(let address, _) = pickupAsk(email: email, code: nil) else {
            return .failed(PickupRefusal(error: .invalidEmail))
        }
        let response: LicenseHTTPResponse
        do {
            response = try await post("pickup", .object(["email": .string(address)]))
        } catch {
            return .failed(PickupRefusal(error: .network))
        }
        return response.status == 200 ? .sent : .failed(pickupRefusal(response.json))
    }

    /// The keys of the product that `email` was sold, for the `code` mailed to it: each with what the
    /// app may show (its `modelName`) and `held` when this device already holds a seat on it (the
    /// fingerprints a validate sends go with the code, when the device can tell who it is). An address
    /// with no key answers an empty list. Activate one with
    /// `activate(picked.key, email: address, code: picked.activationCode)`, or let
    /// `restoreByEmail(email:code:)` choose.
    ///
    /// The address is judged first (`.invalidEmail`), then the code: the ends trimmed, the spaces
    /// dropped, exactly six ASCII digits or `.wrongCode`, at once and asking nothing, so the address
    /// loses none of its wrong tries. The first confirm spends the code, so the keys it answered are
    /// kept in memory for 10 minutes by the address and code as sent: the same pair answers from them
    /// and asks nothing. Stores nothing (not the address, the code, the keys or a refusal), runs
    /// beside any call, never throws, and a 200 that holds no list of keys is `.network`.
    public func pickUp(email: String, code: String) async -> PickUpKeysResult {
        let address: String
        let digits: String
        switch pickupAsk(email: email, code: code) {
        case .refused(let error): return .failed(PickupRefusal(error: error))
        case .send(let sentEmail, let sentCode):
            address = sentEmail
            digits = sentCode ?? ""
        }
        if let kept = keptKeys(email: address, code: digits) { return .keys(kept) }
        // Read-only: this runs outside the one-at-a-time order, beside any call.
        let stored = (try? await load(readOnly: true))?.state
        let device = await self.device(timing.machineId, installKind: installKind(stored?.deviceKind))
        var body: [String: LicenseJSON] = ["email": .string(address), "code": .string(digits)]
        if device.canTell { body["fingerprints"] = .array(device.fingerprints.map(LicenseJSON.string)) }
        let response: LicenseHTTPResponse
        do {
            response = try await post("pickup/confirm", .object(body))
        } catch {
            return .failed(PickupRefusal(error: .network))
        }
        guard response.status == 200 else { return .failed(pickupRefusal(response.json)) }
        guard let keys = pickedKeysOf(response.json) else { return .failed(PickupRefusal(error: .network)) }
        let kept = KeptKeys(email: address, code: digits, keys: keys, at: clockNow())
        keptPickup.withValue { $0 = kept }
        return .keys(keys)
    }

    /// Confirm a pickup's code and activate, on this device, the key of the address that fits this
    /// build: the one this device already holds a seat on, else one with a free seat, else the first.
    /// It activates as `activate(_:email:code:)` would, with the address as the pickup sent it and, for
    /// a code-locked key, the code the pickup handed back, so nothing more is asked of the customer.
    /// The key is stored as an activation's is and never handed to the app; nothing else is stored.
    /// The keys the confirm answered are kept in memory for 10 minutes (see `pickUp(email:code:)`), so
    /// a restore whose activation got no answer can be retried with the same code; a restore that
    /// activates drops them.
    ///
    /// Answers the confirm's errors (`.pickup`); then `.noKey` for an address with no key, and
    /// `.license(.upgrade)` or `.license(.outdated)` when none of its keys covers this build
    /// (`.upgrade`: they are for an older major, buy an upgrade; `.outdated`: update the app),
    /// activating nothing; then the activation's own errors, as they come. Behind a call that has not
    /// finished it answers `.license(.network)`, to retry, as `activate` does. Never throws.
    public func restoreByEmail(email: String, code: String) async -> RestoreResult {
        await calls.run { readOnly in
            if readOnly { return .failed(.license(.network)) }
            return await self.restoreNow(email: email, code: code)
        }
    }

    /// The keys a confirm with this address and code answered, while they are kept.
    private func keptKeys(email: String, code: String) -> [PickedKey]? {
        let now = clockNow()
        return keptPickup.withValue { $0?.keys(email: email, code: code, now: now) }
    }

    /// The confirm, the choice, and the activation of the key chosen.
    private func restoreNow(email: String, code: String) async -> RestoreResult {
        let keys: [PickedKey]
        switch await pickUp(email: email, code: code) {
        case .failed(let refusal): return .failed(.pickup(refusal))
        case .keys(let picked): keys = picked
        }
        let index: Int
        switch chosenKey(keys, major: major, now: clockNow()) {
        case .success(let chosen): index = chosen
        case .failure(.noKey): return .failed(.noKey)
        case .failure(.upgrade): return .failed(.license(.upgrade))
        case .failure(.outdated): return .failed(.license(.outdated))
        }
        let picked = keys[index]
        // The address as the pickup sent it (the confirm just accepted it).
        var address = email
        if case .send(let sent, _) = pickupAsk(email: email, code: nil) { address = sent }
        let activated: ActivateResult
        do {
            activated = try await activateNow(picked.key, email: address, code: picked.activationCode)
        } catch {
            // The state could not be read or saved, as `activate` answers it.
            return .failed(.license(.storage))
        }
        if case .failed(let error) = activated { return .failed(.license(error)) }
        // Activated: the keys (and a lock's single-use code among them) are done with.
        keptPickup.withValue { $0 = nil }
        return .restored
    }
}
