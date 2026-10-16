import Foundation

/// How the journal of unsynced spends (`StoredState.spends`) and the figures beside it
/// (`StoredState.meterFigures`) land on the stored state: on the state as stored at that moment, as
/// `merged` lands the rest, so that two processes of one app never lose each other's spends. Both
/// fields are about the stored activation: a save made for another activation, or on a state with
/// none, writes neither.

/// A spend made with no request sent (`.offline`), or whose own request got no answer
/// (`.unanswered`), or one refused after that (`.void`).
///
/// A spend carries the most its meter's unsynced spends may come to with it (`limit`, the smaller of
/// the device's allowance and what is left), judged again where it lands. `told`: the customer was told
/// the spend was made while a failed save kept it in memory, so it lands whatever the limit and the
/// cap say: a spend is never taken back. Not read on a void, which is the take-back of a spend the
/// customer was refused, never one told: a void is always held to the void cap and to the journal's.
struct SpendOp: Sendable, Hashable {
    /// Which kind of entry it opens or grows.
    var kind: SpendKind
    /// The activation it is about.
    var about: String
    /// The spend's id.
    var id: String
    /// The meter's code.
    var meter: String
    /// How many uses.
    var n: Int
    /// When (the guarded clock) the spend was made.
    var at: Int
    /// The most the meter's unsynced spends may come to with it.
    var limit: Int?
    /// Whether the customer was told it was made while only memory could hold it.
    var told = false
}

/// One change to the journal or its figures.
enum JournalOp: Sendable, Hashable {
    /// A spend: opens or grows an entry.
    case spend(SpendOp)
    /// An answer's `spends`: the entries the server recorded.
    case confirmed(about: String, entries: [Confirmed])
    /// The figures a `use` answer gave, by code.
    case figures(about: String, figures: [String: MeterFigure])
    /// An activation, saved: another seat's journal is dropped, the same seat's is kept.
    case activated(about: String)
    /// A deactivation: the journal goes with the rest of the licence.
    case deactivated
}

/// The fields after an op; `refused` is true when it was a spend the full journal could not take, or
/// whose limit forbids.
struct Journaled: Sendable, Hashable {
    var spends: [SpendEntry]
    var meterFigures: [String: MeterFigure]
    var refused = false

    static let cleared = Journaled(spends: [], meterFigures: [:])
}

/// Whether an answer's confirmation names a stored entry as recorded. A void is named by `void`, any
/// other by how many the server holds.
private func confirms(_ entry: SpendEntry, _ confirmed: [Confirmed]) -> Bool {
    confirmed.contains { confirmation in
        switch confirmation {
        case .void(let id): sameText(id, entry.id) && entry.kind == .void
        case .count(let id, let n): sameText(id, entry.id) && entry.kind != .void && entry.n <= n
        }
    }
}

/// `stored` with the incoming figures, for each meter the newer by `at` kept (the stored one on a tie).
private func newest(_ stored: [String: MeterFigure], _ incoming: [String: MeterFigure]) -> [String: MeterFigure] {
    var merged = stored
    for (code, figure) in incoming where merged[code].map({ figure.at > $0.at }) ?? true {
        merged[code] = figure
    }
    return merged
}

/// Whether a spend was told to the customer: so it lands whatever the limit and the cap say. A void
/// never is.
private func toldOf(_ op: SpendOp) -> Bool {
    op.kind != .void && op.told
}

/// The index of the void a new void takes the place of: the oldest, when the journal already holds
/// `maxPendingVoids`.
private func voidToReplace(_ journal: [SpendEntry]) -> Int? {
    let voids = journal.indices.filter { journal[$0].kind == .void }
    return voids.count >= maxPendingVoids ? voids.first : nil
}

/// The journal an entry is opened in: for a void, without the oldest void when `maxPendingVoids` are
/// held (the new one takes its place), so the attempts of a device out of reach never fill the journal
/// the spends it can make need. Whether it has room: a new entry past the cap is refused, unless it
/// was told.
private func opened(_ journal: [SpendEntry], _ op: SpendOp) -> (spends: [SpendEntry], refused: Bool) {
    var room = journal
    if op.kind == .void, let oldest = voidToReplace(journal) { room.remove(at: oldest) }
    if room.count >= maxPendingSpends && !toldOf(op) { return (journal, true) }
    room.append(SpendEntry(id: op.id, meter: op.meter, n: op.n, at: op.at, kind: op.kind))
    return (room, false)
}

/// The journal with an append applied: an `.offline` entry grows or is opened, the others are opened
/// once by id; none that would take the meter's unsynced spends past the op's limit (a void is no
/// spend, and a told one lands whatever it says), nor a new entry past the cap (`opened`). An
/// `.offline` spend that joins an entry loses its id, which is why no request reports a spend still
/// held in memory (`License.reportable`).
private func appended(_ journal: [SpendEntry], _ op: SpendOp) -> (spends: [SpendEntry], refused: Bool) {
    // A spend whose id the journal holds is the one it is: left as it is, whatever the limit now says.
    if op.kind != .offline && journal.contains(where: { sameText($0.id, op.id) }) { return (journal, false) }
    if op.kind != .void, !toldOf(op), let limit = op.limit, saturatingSum(unsyncedOf(journal, op.meter), op.n) > limit {
        return (journal, true)
    }
    if op.kind == .offline, let open = journal.firstIndex(where: { $0.kind == .offline && $0.meter == op.meter }) {
        var grown = journal
        grown[open].n = saturatingSum(grown[open].n, op.n)
        return (grown, false)
    }
    return opened(journal, op)
}

/// The journal and the figures after `op`, landed on `latest` at `now` (the guarded clock). An op about
/// another activation than the one stored, or about none, changes nothing; a deactivation clears both,
/// and an activation of another seat does (the same seat activated again keeps them). Every op that
/// lands drops the entries opened more than `pendingMaxMs` before `now`, unreported. An append the
/// journal has no room for is `refused`.
func journaled(_ latest: StoredState, _ op: JournalOp, now: Int) -> Journaled {
    let about: String
    switch op {
    case .deactivated: return .cleared
    case .spend(let spend): about = spend.about
    case .confirmed(let given, _), .figures(let given, _), .activated(let given): about = given
    }
    let spends = latest.spends ?? []
    let figures = latest.meterFigures ?? [:]
    guard let stored = latest.activationId, sameText(stored, about) else {
        if case .activated = op { return .cleared }
        return Journaled(spends: spends, meterFigures: figures)
    }
    let live = spends.filter { difference(now, $0.at) <= pendingMaxMs }
    switch op {
    case .confirmed(_, let entries):
        return Journaled(spends: live.filter { !confirms($0, entries) }, meterFigures: figures)
    case .figures(_, let given):
        return Journaled(spends: live, meterFigures: newest(figures, given))
    case .spend(let spend):
        let landed = appended(live, spend)
        return Journaled(spends: landed.spends, meterFigures: figures, refused: landed.refused)
    case .activated, .deactivated:
        return Journaled(spends: live, meterFigures: figures)
    }
}

/// Confirmations with each id once as a count and once as a void, the larger count kept: the entries
/// any of them would have dropped.
private func foldedConfirmations(_ entries: [Confirmed]) -> [Confirmed] {
    var folded: [Confirmed] = []
    for entry in entries {
        let held = folded.firstIndex { held in
            switch (entry, held) {
            case (.void(let id), .void(let other)): sameText(id, other)
            case (.count(let id, _), .count(let other, _)): sameText(id, other)
            default: false
            }
        }
        guard let held else {
            folded.append(entry)
            continue
        }
        if case .count(_, let n) = entry, case .count(let id, let heldN) = folded[held], n > heldN {
            folded[held] = .count(id: id, n: n)
        }
    }
    return folded
}

/// `ops` with neighbours folded together where landing them one after the other lands what landing the
/// fold does: offline spends of one meter (their counts added, the first's id and time kept), figures
/// (the newer of each meter) and confirmations (each id once, the larger count). A disk that keeps
/// refusing the journal then costs the process one change for a run of spends of one meter, not one for
/// each; spends of meters that take turns are not folded across one another.
func compacted(_ ops: [JournalOp]) -> [JournalOp] {
    var out: [JournalOp] = []
    for op in ops {
        switch (out.last, op) {
        case (.spend(var last)?, .spend(let next))
        where last.kind == .offline && next.kind == .offline && sameText(last.about, next.about) && last.meter == next.meter:
            last.n = saturatingSum(last.n, next.n)
            out[out.count - 1] = .spend(last)
        case (.figures(let about, let figures)?, .figures(let nextAbout, let next)) where sameText(about, nextAbout):
            out[out.count - 1] = .figures(about: about, figures: newest(figures, next))
        case (.confirmed(let about, let entries)?, .confirmed(let nextAbout, let next)) where sameText(about, nextAbout):
            out[out.count - 1] = .confirmed(about: about, entries: foldedConfirmations(entries + next))
        default:
            out.append(op)
        }
    }
    return out
}

/// `ops` with all but the newest `maxPendingVoids` void ops dropped: a process that cannot save keeps
/// no more voids than the journal would.
func boundedVoids(_ ops: [JournalOp]) -> [JournalOp] {
    func isVoid(_ op: JournalOp) -> Bool {
        if case .spend(let spend) = op { return spend.kind == .void }
        return false
    }
    var surplus = max(0, ops.filter(isVoid).count - maxPendingVoids)
    return ops.filter { op in
        guard surplus > 0, isVoid(op) else { return true }
        surplus -= 1
        return false
    }
}

/// `ops` landed in order on `state` at `now`, and whether each was refused; the state itself when
/// there are none. An empty journal, or no figures, is the field absent.
func landJournal(_ state: StoredState, _ ops: [JournalOp], now: Int) -> (state: StoredState, refused: [Bool]) {
    var current = state
    var refused: [Bool] = []
    for op in ops {
        let landed = journaled(current, op, now: now)
        refused.append(landed.refused)
        current.spends = landed.spends.isEmpty ? nil : landed.spends
        current.meterFigures = landed.meterFigures.isEmpty ? nil : landed.meterFigures
    }
    return (current, refused)
}
