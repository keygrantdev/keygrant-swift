import Foundation

/// What each public call does: when to go online, and what to answer.
extension License {
    /// The stored state for a status, with a trial this process could not save, and the journal
    /// changes it could not save; nil when it cannot be read just now (`.unknown`/`.storage`).
    func loadForStatus(readOnly: Bool) async -> LoadedState? {
        guard let loaded = try? await load(readOnly: readOnly) else { return nil }
        guard let pending = unsavedTrial.current else { return loaded }
        // As a save would merge it: a newer trial answer stored since wins.
        return loaded.with(merged(loaded.state, pending.patch, pending.basis))
    }

    /// Saves the trial this process could not, and forgets it once saved. Best-effort.
    func saveUnsavedTrial() async {
        guard let pending = unsavedTrial.current else { return }
        if await saveBestEffort(pending.patch, basis: pending.basis) { unsavedTrial.withValue { $0 = nil } }
    }

    func activateNow(_ key: String, email: String? = nil, code: String? = nil) async throws -> ActivateResult {
        // Normalised, and refused here when it cannot be a key.
        guard let entered = enteredKey(key) else { return .failed(.invalidKey) }
        // What a person typed for a user-locked key: one that can be no address, or no code, is
        // refused here, before anything is asked of the server or its wrong tries are spent.
        let typed = typedFor(email: email, code: code)
        if case .refused(let error) = typed { return .failed(error) }
        // Install memory protects the seat this install holds: re-activating that key keeps to
        // it; a first activation, or another key's, starts afresh.
        let stored = try await load().state
        let sameSeat = stored.key.map { sameKey($0, entered) } ?? false
        let installKind = sameSeat ? self.installKind(stored.deviceKind) : nil
        let device = await self.device(timing.activateMachineId, installKind: installKind)
        guard let identity = activationIdentity(device, installKind: installKind) else { return .failed(.network) }
        // Stamped with when it was asked for (guarded clock): an older ask's answer, from another
        // process, is not saved over it.
        let askedAt = effectiveNow(stored)
        var body: [String: LicenseJSON] = [
            "key": .string(entered), "fingerprint": .string(identity.fingerprint), "major": .number(Double(major)),
        ]
        if let kind = identity.kind { body["fingerprintKind"] = .string(kind.rawValue) }
        if let deviceName { body["name"] = .string(deviceName) }
        body["kids"] = kidsJSON
        if case .send(let typedEmail, let typedCode) = typed {
            if let typedEmail { body["email"] = .string(typedEmail) }
            if let typedCode { body["code"] = .string(typedCode) }
        }
        let response: LicenseHTTPResponse
        do {
            response = try await post("activate", .object(body))
        } catch {
            return .failed(.network)
        }
        guard response.status == 200 else { return .failed(mapServerError(errorOf(response.json))) }
        let answer = parseLeaseBody(response.json)
        guard let lease = nonEmpty(answer.lease), let activationId = nonEmpty(answer.activationId) else {
            return .failed(.network)
        }
        let now = try await serverNow(lease, key: entered, activationId: activationId) { patch, guardTime in
            try await self.save(patch, guardTime: guardTime)
        }
        let evaluated = await evaluate(lease, now: now, key: entered, activationId: activationId, deviceKind: identity.kind)
        guard case .ok(_, let claims) = evaluated else { return .failed(.invalidLease) }
        let patch = activationPatch(
            Activation(key: entered, activationId: activationId, lease: lease, claims: claims, now: now, major: major, kind: identity.kind)
        )
        let activation = Asked(at: askedAt, activationId: activationId, seen: stored.verdictAt)
        // Activating another seat drops the journal of the old one, unreported; the same seat keeps it.
        try await saveWith(patch, guardTime: nil, basis: Basis(activation: activation), ops: [.activated(about: activationId)])
        return .activated
    }

    func deactivateNow() async throws -> DeactivateResult {
        // What this process could not save lands first, so the release reports it: the journal goes
        // with the seat.
        await saveUnsavedJournal()
        let view = try await load()
        let state = view.state
        // Nothing held is nothing to release: the seat is as free as it gets. Nor is a seat another
        // device holds this one's to release (`seatElsewhere`).
        var released = true
        if let key = nonEmpty(state.key), let activationId = nonEmpty(state.activationId) {
            let device = await self.device(timing.machineId, installKind: state.deviceKind)
            if !seatElsewhere(state, device) { released = await release(view, key: key, activationId: activationId, device: device) }
        }
        // Stamped, so that an answer to an older ask is not saved over it. The journal goes with the
        // rest of the licence: what the release carried is all the server will hear of it.
        try await saveWith(
            unkeyed + [.verdictAt: .int(effectiveNow(state))], guardTime: nil, basis: Basis(), ops: [.deactivated]
        )
        return DeactivateResult(released: released)
    }

    /// The release request, carrying the journal of unsynced spends and, with it, the device's
    /// fingerprints as a validate sends them (so the server holds the reports to the seat's device;
    /// none when it cannot tell). Only a 200 is KeyGrant saying the seat is free: a 5xx, a 429 or a
    /// proxy's page is an answer, but not that one, and no answer is none. The local licence is
    /// dropped by the caller whatever it says.
    private func release(_ view: LoadedState, key: String, activationId: String, device: Device) async -> Bool {
        var body: [String: LicenseJSON] = ["key": .string(key), "activationId": .string(activationId)]
        if let reports = spendsReported(await reportable(view)) {
            body["spends"] = reports
            if device.canTell { body["fingerprints"] = .array(device.fingerprints.map(LicenseJSON.string)) }
        }
        return (try? await post("deactivate", .object(body)))?.status == 200
    }

    /// Whether the stored activation is another device's: a device refusal that stands for this
    /// one, or a lease held to a machine id this device does not have, expired or not
    /// (`heldElsewhere`). A state file copied or restored from another PC (a roaming profile, a
    /// backup, a cloned disk) carries that PC's activation; releasing it would lock that PC out at
    /// its next check-in, so `deactivate()` only drops it here, and this device held no seat.
    private func seatElsewhere(_ state: StoredState, _ device: Device) -> Bool {
        let tellable = (ownClaim: device.ownClaim, canTell: device.canTell)
        if standingRefusal(state, major: major, device: tellable) == .device { return true }
        guard let lease = nonEmpty(state.lease) else { return false }
        return heldElsewhere(verify(lease, now: effectiveNow(state)), claims: device.claims, canTell: device.canTell)
    }

    /// The status, asking the server when it should. `readOnly` (behind a call that has not
    /// settled): from what is stored only, with no ask and no write.
    func statusNow(_ view: LoadedState, force: Bool, readOnly: Bool) async -> LicenseStatus {
        let state = view.state
        // A stored offline licence file that licenses this build wins, offline, with no ask and no
        // write; one that does not answers only when no key path and no running trial does.
        let file = fileStatus(state)
        if let file, file.state == .licensed { return file }
        let now = effectiveNow(state)
        // A device refusal stands only for the device it was given for: who this is.
        var device: Device?
        if state.refused == .device { device = await self.device(timing.machineId, installKind: state.deviceKind) }
        let refused = nonEmpty(state.key) == nil
            ? nil : standingRefusal(state, major: major, device: device.map { (ownClaim: $0.ownClaim, canTell: $0.canTell) })
        if let refused {
            if readOnly { return LicenseStatus(state: .invalid, reason: LicenseReason(refused), key: state.key) }
            return await refusedStatus(view, refused, force: force)
        }
        if nonEmpty(state.key) != nil, let lease = nonEmpty(state.lease) {
            return await licenseStatus(view, lease: lease, now: now, force: force, readOnly: readOnly)
        }
        return await trialOrFile(state, now: now, file: file, ask: TrialAsk(force: force, readOnly: readOnly))
    }

    /// With no key to answer: a trial this device started while it runs, else a stored file that
    /// does not license this build (why is the news), else the trial that has ended, else unlicensed.
    private func trialOrFile(_ state: StoredState, now: Int, file: LicenseStatus?, ask: TrialAsk) async -> LicenseStatus {
        let trial = state.trialStart == nil ? nil : await trialStatus(state, now: now, ask: ask)
        if let trial, trial.state == .trial { return trial }
        return file ?? trial ?? LicenseStatus(state: .unlicensed)
    }

    /// `startTrial()`'s trial ask, the device read with an activation's time.
    func startTrialNow(_ state: StoredState) async -> LicenseStatus {
        let latest = await askTrial(state, machineIdTimeout: timing.activateMachineId).latest
        // The server's trial even when it could not be saved: kept for this process until a later
        // call saves it.
        return await trialStatus(latest, now: effectiveNow(state))
    }

    /// Asks the server for this device's trial (`trial`, with the earliest start the device holds
    /// as `clientStart`), under the device already read (`known`), else reading it for at most
    /// `machineIdTimeout`, the request bounded by `timeout` (else the HTTP bound), and saves its
    /// answer: `reached` when the server answered at all, `latest` the state with its trial merged in.
    func askTrial(
        _ state: StoredState, machineIdTimeout: TimeInterval, timeout: TimeInterval? = nil
    ) async -> (reached: Bool, latest: StoredState) {
        let device = await self.device(machineIdTimeout, installKind: state.deviceKind)
        // The stash is the app's own adapter and can cost nothing: one that cannot be read is no
        // evidence, and `startTrial()` still answers.
        let stashed = try? await registry.readTrialStart()
        let clientStart = earliest(state.trialStart, stashed)
        // A device that cannot be told this time starts no trial: as offline.
        guard let own = device.own else { return (false, state) }
        // Stamped with when it was asked for (guarded clock): an older answer, from another process,
        // is not saved over it.
        let asked = Stamp(at: effectiveNow(state), seen: state.trialAt)
        var body: [String: LicenseJSON] = ["fingerprint": .string(own)]
        if let kind = device.kind { body["fingerprintKind"] = .string(kind.rawValue) }
        if let clientStart { body["clientStart"] = .number(Double(clientStart)) }
        guard let response = try? await post("trial", .object(body), timeout: timeout) else { return (false, state) }
        guard response.status == 200, let trial = parseTrialBody(response.json) else { return (true, state) }
        // The earliest start across all evidence: never moved forward.
        let trialStart = earliest(trial.trialStart, state.trialStart, stashed) ?? trial.trialStart
        // Mirrored to the stash before the save; a stash that cannot be written does not throw the
        // server's trial away with it.
        try? await registry.writeTrialStart(trialStart)
        // A trial lease this build cannot verify (signed with a key the product rotated to ahead of
        // this build, say) never replaces one it can: a trial runs only on a valid lease
        // (`trialStatusOf`), so taking it would end a running trial. As a renewal keeps the lease
        // it has when the answer's will not verify. An answer with no lease (the trial is over) is
        // taken as it is.
        let lease = await keepsItsTrialLease(state, answered: trial.lease) ? state.trialLease : trial.lease
        let patch: StatePatch = [
            .trialStart: .int(trialStart), .trialEndsAt: .int(trial.trialEndsAt), .trialLease: .string(orClear: lease),
        ]
        let basis = Basis(trial: asked)
        // The server's trial even when it cannot be saved: kept for this process until a later
        // call saves it.
        let saved = await saveBestEffort(patch, basis: basis)
        unsavedTrial.withValue { $0 = saved ? nil : UnsavedTrial(patch: patch, basis: basis) }
        return (true, merged(state, patch, basis))
    }

    /// Whether a trial answer's lease fails here while the stored one verifies (`askTrial`): only
    /// when the answer has a lease and one is stored.
    private func keepsItsTrialLease(_ state: StoredState, answered: String?) async -> Bool {
        guard let answered, let stored = state.trialLease else { return false }
        let now = effectiveNow(state)
        if await trialLease(answered, now: now, installKind: state.deviceKind).valid { return false }
        return await trialLease(stored, now: now, installKind: state.deviceKind).valid
    }

    /// A refusal that stands for this build: answered as stored, and asked again once the wait
    /// after the last ask is over, or when forced, so a renewed or reinstated key heals.
    private func refusedStatus(_ view: LoadedState, _ refused: Refusal, force: Bool) async -> LicenseStatus {
        let stored = LicenseStatus(state: .invalid, reason: LicenseReason(refused), key: view.state.key)
        if !askDue(view.state, clockNow: clockNow(), force: force) { return stored }
        return await tryRenew(view) ?? stored
    }

    private func licenseStatus(_ view: LoadedState, lease: String, now: Int, force: Bool, readOnly: Bool) async -> LicenseStatus {
        let state = view.state
        let evaluated = await evaluate(lease, now: now, key: state.key, activationId: state.activationId, deviceKind: state.deviceKind)
        // What the lease says offline, entitlements and meters included: the answer whenever the
        // server gives no verdict (`leaseStatus`).
        var offline = leaseStatus(evaluated, key: state.key)
        if case .ok(_, let claims) = evaluated {
            // The key's meters, net of the journal.
            offline = meteredStatus(offline, claims: claims, state: state)
            if readOnly { return offline }
            let noted = await noteKept(view, claims: claims, now: now)
            if force { return await tryRenew(noted) ?? offline }
            // Asked, bounded in time, when the server should hear from this device before the
            // lease runs out and the wait allows (`asksOnValidLease`), or when it holds spends
            // KeyGrant has not heard of and the journal's own wait is not running. The journal that
            // asks is the one a request would report (`reportable`): spends held in memory that no
            // request carries do not make `status()` ask at every call. The valid lease is the
            // answer when the ask gets no verdict.
            var asking = noted.state
            let reportable = await self.reportable(noted)
            asking.spends = reportable.isEmpty ? nil : reportable
            if !asksOnValidLease(claims: claims, state: asking, major: major, now: now, clockNow: clockNow()) { return offline }
            return await tryRenew(noted, timeout: timing.statusCheck) ?? offline
        }
        // Not valid here: give the server a chance to heal it, once the wait is over or when
        // forced. Only when it cannot be reached (or agrees) does the local reason stand.
        if !readOnly, askDue(state, clockNow: clockNow(), force: force), let renewed = await tryRenew(view) {
            return renewed
        }
        return offline
    }

    /// The state with this run noted in `keptMajor`, saved when that changed.
    private func noteKept(_ view: LoadedState, claims: LeaseClaims, now: Int) async -> LoadedState {
        let state = view.state
        let kept = keptWith(state.keptMajor, claims: claims, now: now, major: major)
        if kept == state.keptMajor { return view }
        // About this activation: not saved onto another one stored meanwhile.
        _ = await saveBestEffort([.keptMajor: .int(orClear: kept)], basis: Basis(about: About(activationId: state.activationId)))
        var noted = state
        noted.keptMajor = kept
        return view.with(noted)
    }

    /// The trial's status (`trialStatusOf`): live only on a valid trial lease, which says its end
    /// and its entitlements (`trialLeaseOf`). With `ask` (a `status()`), a trial whose lease does
    /// not verify while its stored end is still ahead is asked for again first (`healTrial`), and a
    /// running one reports its launch when due (`reportLaunch`); neither read-only.
    func trialStatus(_ state: StoredState, now: Int, ask: TrialAsk? = nil) async -> LicenseStatus {
        var lease = TrialLease.invalid
        if let stored = nonEmpty(state.trialLease) {
            lease = await trialLease(stored, now: now, installKind: state.deviceKind)
        }
        let status = trialStatusOf(
            state, now: now, leaseValid: lease.valid, leaseEndsAt: lease.endsAt, leaseEntitlements: lease.entitlements
        )
        guard let ask, !ask.readOnly else { return status }
        if status.state == .trial {
            await reportLaunch(state, now: now)
            return status
        }
        let storedEndAhead = state.trialEndsAt.map { now < $0 } ?? false
        guard !lease.valid, storedEndAhead else { return status }
        return await healTrial(state, force: ask.force) ?? status
    }

    /// A trial whose lease does not verify here while its stored end is still ahead: a lease signed
    /// with the product's key before it was rotated (on a build that ships the new one), one signed
    /// to end short of the trial's end, or one never saved whole. The stored end is unsigned, so it
    /// runs no trial on its own (`trialStatusOf`): the server is asked for the trial again instead,
    /// under the usual waits (`askDue`, or when forced) and bounded as a status check is, and its
    /// answer stands. An ask that brings back no trial this build can verify starts the wait
    /// (`retryUnansweredMs` when nothing answered, `askAgainMs` when the server did), so a device
    /// that is offline, or carries a key the product no longer signs with, is not asked on every
    /// `status()`. Nil when it did not ask, or nothing answered.
    private func healTrial(_ state: StoredState, force: Bool) async -> LicenseStatus? {
        let askedAt = clockNow()
        guard askDue(state, clockNow: askedAt, force: force) else { return nil }
        let (reached, latest) = await askTrial(state, machineIdTimeout: timing.machineId, timeout: timing.statusCheck)
        var after: LicenseStatus?
        if reached { after = await trialStatus(latest, now: effectiveNow(latest)) }
        if after?.state == .trial { return after }
        let wait = reached ? Waits.askAgainMs : Waits.retryUnansweredMs
        _ = await saveBestEffort([.backoffSince: .int(askedAt), .backoffMs: .int(wait)])
        return after
    }
}

/// What a `status()` asking for a trial may do: ask whatever the wait says (`force`), or nothing
/// at all behind a call that has not finished (`readOnly`).
struct TrialAsk: Sendable {
    var force: Bool
    var readOnly: Bool
}

/// The fingerprint an activation is made under, and what it hashes; or nil: an activation answers
/// `.network` for the app to retry. The device's own; when even that cannot be told:
/// on an install already keyed by a machine id, nothing (a seat under the host name would read as
/// another device to every run after it); otherwise the host name. A fingerprinter with no
/// host-name alternate activates nothing.
func activationIdentity(_ device: Device, installKind: DeviceKind?) -> (fingerprint: String, kind: DeviceKind?)? {
    if let own = device.own { return (own, device.kind) }
    guard installKind != .machine, let hostname = device.hostname else { return nil }
    return (hostname, .hostname)
}
