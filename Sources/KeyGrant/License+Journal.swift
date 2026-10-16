import Foundation

/// The journal of unsynced spends under `License`: what this process could not save is kept in memory,
/// counts everywhere the stored state is read, and is saved with the next save that can, as a trial the
/// disk refused is kept (`unsavedTrial`). A process that ends first loses the report, never the
/// customer's use.

/// Journal changes this process could not save: the disk refused them, or the call was behind one that
/// has not finished.
struct Held: Sendable {
    /// The changes, in the order they were made.
    var ops: [JournalOp] = []
    /// Saves in flight: while one is, `ops` is only added to, never folded (`License.keepUnsaved`).
    var saving = 0
}

/// The stored state as this process sees it: the stored one with what it could not save landed on it.
struct LoadedState: Sendable, Hashable {
    var state: StoredState
    /// A held spend is in `state.spends`, so a request must not report them as they are
    /// (`License.reportable`).
    var carried = false

    /// The same view of `state`: what it carries is unchanged.
    func with(_ state: StoredState) -> LoadedState {
        LoadedState(state: state, carried: carried)
    }
}

extension License {
    /// The journal changes this process holds because a save failed.
    var heldChanges: [JournalOp] {
        held.current.ops
    }

    /// The stored state, as the storage has it.
    func stored(readOnly: Bool) async throws -> StoredState {
        try await storage.read(readOnly: readOnly) ?? StoredState()
    }

    /// The stored state with the journal changes this process could not save landed on it, as they
    /// will be; `readOnly` behind a call that has not finished, so the read writes nothing either.
    func load(readOnly: Bool = false) async throws -> LoadedState {
        let state = try await stored(readOnly: readOnly)
        let changes = heldChanges
        if changes.isEmpty { return LoadedState(state: state) }
        let landed = landJournal(state, changes, now: guardedNow(clockNow(), state.lastSeen)).state
        return LoadedState(state: landed, carried: landed.spends != nil)
    }

    /// The journal a request reports for `view` (the state a call read): the journal as stored, with
    /// what this process could not save that opens an entry of its own, once, by its id: an
    /// `.unanswered` spend and a `.void`. A spend held in memory that was made `.offline` is withheld:
    /// it joins the entry of another when it lands, so a report of it under its own id would be
    /// counted a second time when the entry it joined is reported. It is reported once it has landed,
    /// which the next call that can save does. The entries the server has since confirmed are left
    /// out: there is no need to say again what it holds. A view that carried held spends is judged the
    /// same, though they may have landed since.
    func reportable(_ view: LoadedState) async -> [SpendEntry] {
        let changes = heldChanges
        if !view.carried && changes.isEmpty { return view.state.spends ?? [] }
        guard let current = try? await stored(readOnly: true), sameText(current.activationId, view.state.activationId) else {
            return []
        }
        let reportable = changes.filter { op in
            switch op {
            case .spend(let spend): spend.kind != .offline
            case .confirmed: true
            default: false
            }
        }
        return landJournal(current, reportable, now: guardedNow(clockNow(), current.lastSeen)).state.spends ?? []
    }

    /// `save` with changes to the journal (`ops`), landed on the state as stored now, after the ones
    /// this process could not save before. Whether each of `ops` was refused, the journal being full
    /// or its limit forbidding it. Throws when the save fails; the changes stay held until one lands.
    @discardableResult
    func saveWith(_ patch: StatePatch, guardTime: Int?, basis: Basis, ops: [JournalOp]) async throws -> [Bool] {
        let (before, all) = held.withValue { held -> (Int, [JournalOp]) in
            held.saving += 1
            return (held.ops.count, held.ops + ops)
        }
        let refused = Locked<[Bool]>([])
        let clock = self.clock
        do {
            try await storage.update { latest in
                let clockNow = clampToSafe(clock.now())
                let landed = landJournal(latest, all, now: guardedNow(clockNow, latest.lastSeen))
                // The last merge is the one that landed, when the storage ran it again on a newer state.
                refused.withValue { $0 = landed.refused }
                var next = merged(landed.state, patch, basis)
                next.lastSeen = savedLastSeen(stored: latest.lastSeen, clockNow: clockNow, guard: guardTime)
                return next
            }
        } catch {
            held.withValue { $0.saving -= 1 }
            throw error
        }
        held.withValue { held in
            held.saving -= 1
            held.ops.removeFirst(min(before, held.ops.count))
        }
        return Array(refused.current.dropFirst(before))
    }

    /// `saveWith`, whose failure fails nothing: the changes it could not save are kept for this process,
    /// those the journal had room for (judged on `view`, the state the call read, when the save
    /// failed). Whether each of `ops` was refused.
    @discardableResult
    func saveOps(_ view: StoredState, _ patch: StatePatch, _ basis: Basis, _ ops: [JournalOp]) async -> [Bool] {
        do {
            return try await saveWith(patch, guardTime: nil, basis: basis, ops: ops)
        } catch {
            return keepUnsaved(view, ops)
        }
    }

    /// Keep `ops` for this process, those the journal has room for on `view`. Whether each was refused.
    func keepUnsaved(_ view: StoredState, _ ops: [JournalOp]) -> [Bool] {
        let refused = landJournal(view, ops, now: guardedNow(clockNow(), view.lastSeen)).refused
        held.withValue { held in
            // A spend is told to the customer from here on: it lands whatever the journal holds by
            // then. A void is no spend told, so it is held to the journal's rules, and to the newest
            // `maxPendingVoids` here.
            for (op, wasRefused) in zip(ops, refused) where !wasRefused { held.ops.append(told(op)) }
            if held.saving == 0 { held.ops = boundedVoids(compacted(held.ops)) }
        }
        return refused
    }

    /// Save what this process could not, best-effort, at the start of a call that may write.
    func saveUnsavedJournal() async {
        if !heldChanges.isEmpty { _ = await saveBestEffort(StatePatch()) }
    }
}

/// `op` as it is kept in memory: a spend marked told.
private func told(_ op: JournalOp) -> JournalOp {
    guard case .spend(var spend) = op, spend.kind != .void else { return op }
    spend.told = true
    return .spend(spend)
}
