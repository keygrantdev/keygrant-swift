import Foundation

/// Spending a key's meters under `License`: `use(_:_:)` asks the server to spend (exact, atomic,
/// idempotent by the spend's id), and when it gets no answer spends from the device's offline
/// allowance, keeping the spend in the journal (`License+Journal.swift`) to report with the next
/// request.
///
/// A meter never takes a licence away, and licensing fails in favour of the customer: no answer is
/// never a refusal of the licence, only of a spend past the allowance, and the journal never fails a
/// renewal or a release.
extension License {
    /// Spend `n` uses of the key's meter `meter`, before the work they count; do the work only when
    /// the result is `ok`.
    ///
    /// Online it is exact: the server takes `n` only while the meter has room for all of it
    /// (`.usedUp`, with `left`, otherwise). With no answer (no network, a timeout, a 5xx, a 429 or an
    /// answer the SDK cannot use) it spends from this device's offline allowance for the meter, never
    /// past what the device last heard is left (`.offlineLimit`), answers `offline: true`, and
    /// reports the spend with its next request. A spend the allowance would refuse asks the server
    /// first, whatever the last outage left behind, so a customer who is back online is not refused
    /// for it (once a minute while KeyGrant stays out of reach); one the allowance covers is not asked
    /// again for a minute after an outage, growing to an hour.
    ///
    /// Needs a key's lease that licenses this build here (`.notLicensed` otherwise, asking nothing); a
    /// device trial and an offline licence file have no meters. `n` from 1 to `maxMeterUses`
    /// (`.invalidAmount` otherwise) and a meter code of 1 to 32 UTF-16 units, matched exactly
    /// (`.noMeter` otherwise), both without asking anything. Two calls are two spends: the spend's id
    /// covers the SDK's own retries and reports, never an app that calls twice.
    ///
    /// Never throws: every outcome is in the result, behind a call that has not finished too (nothing
    /// is then saved: an offline spend is kept in memory and saved by the next call that can), and a
    /// state that cannot be read just now is `.storage`. A `use` request waits at most 5 seconds, or
    /// `LicenseConfig.httpTimeout` when that is shorter. A call whose task is cancelled still runs to
    /// its bounded answer, as every call on a `License` does: a spend that was made is the customer's.
    /// Calls on one `License` run one at a time, this one among them.
    public func use(_ meter: String, _ n: Int = 1) async -> UseResult {
        let asked: (meter: String, n: Int)
        switch askedFor(meter, n) {
        case .failure(let error): return .refused(error)
        case .success(let given): asked = given
        }
        return await calls.run { readOnly in await self.spend(asked.meter, asked.n, readOnly: readOnly) }
    }
}

/// One call to `use`, as the steps below read it.
private struct Spending: Sendable {
    /// The state the call read, with what this process could not save landed on it.
    var view: LoadedState
    /// The claims of the lease that licenses this build.
    var claims: LeaseClaims
    var meter: String
    var n: Int
    /// The activation the spend is about.
    var about: String
    /// The spend's id.
    var id: String
    /// When (the guarded clock) the spend is made.
    var at: Int
    /// Behind a call that has not finished: nothing is saved.
    var readOnly: Bool
    /// What the offline allowance says of the spend as the call read the state.
    var verdict: OfflineVerdict
}

/// What asking the server came to.
private enum Ask {
    /// The server answered: this is the result.
    case answered(UseResult)
    /// No usable answer: the spend was sent, and the server may hold it.
    case doubt
}

extension License {
    /// The steps of a spend: the state and the licence, then the server when it should be asked, then
    /// the allowance.
    fileprivate func spend(_ meter: String, _ n: Int, readOnly: Bool) async -> UseResult {
        if !readOnly { await saveUnsavedJournal() }
        guard let view = await loadForStatus(readOnly: readOnly) else { return .refused(.storage) }
        guard let claims = await keyClaims(view), let about = view.state.activationId else { return .refused(.notLicensed) }
        let state = view.state
        let at = effectiveNow(state)
        let verdict = offlineSpend(figuresFor(claims, state), state.spends ?? [], meter, n)
        let spending = Spending(
            view: view, claims: claims, meter: meter, n: n, about: about, id: newSpendId(), at: at, readOnly: readOnly,
            verdict: verdict
        )
        var sent = false
        if useAsksNow(state, clockNow: clockNow(), now: at, covered: verdict.isAllowed) {
            switch await askToSpend(spending) {
            case .answered(let result): return result
            case .doubt: sent = true
            }
        }
        return await spendOffline(spending, doubt: sent)
    }

    /// The claims of the key's lease when the state licenses this build here by a key's lease: what
    /// `status()` would give as `.licensed` from what is stored (no ask, no write), and not by a
    /// licence file. Nil otherwise.
    private func keyClaims(_ view: LoadedState) async -> LeaseClaims? {
        let state = view.state
        let status = await statusNow(view, force: false, readOnly: true)
        guard status.state == .licensed, status.source != .file, let lease = nonEmpty(state.lease) else { return nil }
        let checked = await evaluate(lease, now: effectiveNow(state), key: state.key, activationId: state.activationId, deviceKind: state.deviceKind)
        guard case .ok(_, let claims) = checked else { return nil }
        return claims
    }

    /// Ask the server to spend (`use`, bounded by the status check's bound, 5 seconds, or the HTTP
    /// bound when shorter), with the journal's report. Its answer is saved as a validate's is
    /// (`useOutcome`) unless this call is behind one that has not finished; with no usable answer the
    /// spend is in doubt: the server may hold it.
    fileprivate func askToSpend(_ sp: Spending) async -> Ask {
        let state = sp.view.state
        let askedAt = clockNow()
        let asked = Asked(at: sp.at, activationId: state.activationId, seen: state.verdictAt)
        let device = await self.device(timing.machineId, installKind: state.deviceKind)
        var body = deviceBody(state, device)
        body["meter"] = .string(sp.meter)
        body["n"] = .number(Double(sp.n))
        body["id"] = .string(sp.id)
        if let reports = spendsReported(await reportable(sp.view)) { body["spends"] = reports }
        body["kids"] = kidsJSON
        let response = try? await post("use", .object(body), timeout: min(timing.statusCheck, httpTimeout))
        let outcome = useOutcome(UseInput(response: response, askedAt: askedAt, major: major, device: device))
        let ops = journalOps(state, outcome)
        // A verdict or a wait is the answer to an ask, stamped as a validate's is; figures and
        // confirmations are not a verdict, so a spend never makes a validate another process asked
        // for earlier look out of date.
        let answer = !outcome.patch.changes.isEmpty
        if !sp.readOnly && (!ops.isEmpty || answer) {
            await saveOps(state, outcome.patch, answer ? Basis(answer: asked) : Basis(), ops)
        }
        if outcome.kind == .unanswered { return .doubt }
        return .answered(answered(outcome, sp, landJournal(state, ops, now: sp.at).state))
    }

    /// With no answer (or none asked): spend from the allowance (`offlineSpend`). Allowed, the spend is
    /// journaled, `.offline` when it was never sent and `.unanswered` when it was in doubt, with the
    /// most the meter's unsynced spends may come to (`limit`), which the landing judges again on the
    /// state as stored then, so two processes never pass the allowance together. Refused, a spend in
    /// doubt is journaled as a `.void`, for the server to take it back off if it recorded it, and so is
    /// one the landing refuses (the journal full, or the allowance taken by another process meanwhile,
    /// answered with what is left as the landing found it): the customer is told `.offlineLimit`, the
    /// server is told the spend is taken back. Voids are kept to `maxPendingVoids`, a new one taking the
    /// place of the oldest, and a void a full journal cannot take is lost.
    fileprivate func spendOffline(_ sp: Spending, doubt: Bool) async -> UseResult {
        func op(_ kind: SpendKind, limit: Int? = nil) -> JournalOp {
            .spend(SpendOp(kind: kind, about: sp.about, id: sp.id, meter: sp.meter, n: sp.n, at: sp.at, limit: limit))
        }
        switch sp.verdict {
        case .noMeter:
            if doubt { await journal(sp, [op(.void)]) }
            return .refused(.noMeter)
        case .offlineLimit(let left):
            if doubt { await journal(sp, [op(.void)]) }
            return .refused(.offlineLimit, left: left)
        case .allowed(let left, let limit):
            if await journal(sp, [op(doubt ? .unanswered : .offline, limit: limit)]).first == true {
                if doubt { await journal(sp, [op(.void)]) }
                return .refused(.offlineLimit, left: await landedLeft(sp))
            }
            return .spent(left: left, offline: true)
        }
    }

    /// What is left of the meter by the state as a refused landing found it (another process had
    /// spent meanwhile): the figure less the unsynced spends there then, never below 0, and 0 when the
    /// state cannot be read just now.
    private func landedLeft(_ sp: Spending) async -> Int {
        guard let fresh = await loadForStatus(readOnly: sp.readOnly) else { return 0 }
        return leftOf(sp.claims, fresh.state, sp.meter)
    }

    /// `ops` saved, or kept in memory when this call may save nothing or the disk refuses. Whether each
    /// was refused.
    @discardableResult
    private func journal(_ sp: Spending, _ ops: [JournalOp]) async -> [Bool] {
        if sp.readOnly { return keepUnsaved(sp.view.state, ops) }
        return await saveOps(sp.view.state, StatePatch(), Basis(), ops)
    }
}

/// The journal changes an answer makes: the reports it confirms and the figures it gives, about the
/// activation asked for.
private func journalOps(_ state: StoredState, _ outcome: UseOutcome) -> [JournalOp] {
    guard let about = state.activationId else { return [] }
    var ops: [JournalOp] = []
    if !outcome.confirmed.isEmpty { ops.append(.confirmed(about: about, entries: outcome.confirmed)) }
    if !outcome.figures.isEmpty { ops.append(.figures(about: about, figures: outcome.figures)) }
    return ops
}

/// What `use` answers for an answer the server gave. A spend: what is left of the meter by the
/// figures as the answer left them (`after`: the base figure, its own from the answer when it gave
/// one, less what this device has not reported). `used-up`: the answer's `left`. A verdict: the
/// refusal, as `status()` will say it.
private func answered(_ outcome: UseOutcome, _ sp: Spending, _ after: StoredState) -> UseResult {
    switch outcome.kind {
    case .spent: .spent(left: leftOf(sp.claims, after, sp.meter))
    case .usedUp: .refused(.usedUp, left: outcome.left)
    case .noMeter: .refused(.noMeter)
    case .refused, .unanswered: .refused(outcome.refusal.map(UseError.init) ?? .notLicensed)
    }
}

extension UseError {
    /// The error a server verdict is answered as.
    init(_ refusal: Refusal) {
        switch refusal {
        case .revoked: self = .revoked
        case .upgrade: self = .upgrade
        case .outdated: self = .outdated
        case .device: self = .device
        }
    }
}
