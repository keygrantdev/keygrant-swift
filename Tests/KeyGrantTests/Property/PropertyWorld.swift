import Foundation

@testable import KeyGrant

/// The world a property test of `use(_:_:)` runs the real `License` in (`PropertyNet.swift` is the machine;
/// `UsePropertyTests.swift` the test): the steps of a case, and the oracle that judges every answer and what
/// must hold between steps and at the end.
///
/// The oracle is written from the contract and takes nothing from the code it judges but the `License` itself
/// and the shape of a stored state: its constants, its figures and its waits are written again below, so a
/// change to the code cannot move the code and what judges it together. Test support only.

private let minute = 60_000
private let hour = 3_600_000
private let day = 24 * hour

// MARK: - the oracle's own reading of the contract

private func entriesOf(_ state: StoredState) -> [SpendEntry] {
    state.spends ?? []
}

/// The unsynced spends of a meter, its `offline` and `unanswered` entries, never a void.
private func unsyncedIn(_ spends: [SpendEntry], _ meter: String) -> Int {
    spends.filter { $0.meter == meter && $0.kind != .void }.map(\.n).reduce(0, +)
}

/// A JSON number as the oracle reads it, from Foundation's reader and not the SDK's.
private func whole(_ value: Any?) -> Int? {
    (value as? NSNumber)?.intValue
}

/// The payload of a lease, read here and not by the SDK: base64url, then JSON (by Foundation's reader).
private func payloadOf(_ lease: String) -> [String: Any] {
    let parts = lease.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count > 1 else { return [:] }
    var text = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while text.count % 4 != 0 { text += "=" }
    guard let data = Data(base64Encoded: text), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return [:]
    }
    return object
}

/// A meter's base figure (left, offline): the stored one when its time is at or after the lease's second, else
/// the lease's own.
private func baseFigure(_ state: StoredState, _ meter: String) -> (left: Int, offline: Int)? {
    guard state.key != nil, let lease = state.lease else { return nil }
    let claims = payloadOf(lease)
    let iat = whole(claims["iat"]) ?? 0
    if let stored = state.meterFigures?[meter], stored.at >= iat * 1000 { return (stored.left, stored.offline) }
    guard let met = (claims["met"] as? [String: Any])?[meter] as? [String: Any], let left = whole(met["left"]),
        let offline = whole(met["offline"])
    else { return nil }
    return (left, offline)
}

/// The journal's wait: k unanswered or void entries (none ahead of `now`), a minute doubling to an hour after the newest.
private func journalWait(_ spends: [SpendEntry], _ now: Int) -> Bool {
    let opened = spends.filter { $0.kind != .offline && $0.at <= now }
    guard let newest = opened.map(\.at).max() else { return false }
    return now < newest + min(hour, minute * (1 << min(opened.count - 1, 6)))
}

/// The wait of a spend the allowance refuses: a void under a minute old, by the guarded clock and the device clock.
private func voidWait(_ spends: [SpendEntry], _ now: Int, _ clockNow: Int) -> Bool {
    spends.contains { $0.kind == .void && $0.at <= now && $0.at <= clockNow && now < $0.at + minute }
}

/// The wait an unanswered ask leaves, by the device clock.
private func askWait(_ state: StoredState, _ clockNow: Int) -> Bool {
    guard let since = state.backoffSince else { return false }
    return state.backoffMs == minute && clockNow >= since && clockNow < since + minute
}

/// What the state said of a spend before the call.
private struct Pre {
    var licensed: Bool
    var covered: Bool
    /// What `use` must answer as `left` for a spend made offline: the figure less the unsynced, less the spend.
    var leftAfter: Int
    var entryCount: Int
    var openOffline: Bool
    /// A wait of the covered spends runs: the no-answer wait (device clock) or the journal's (guarded clock).
    var waiting: Bool
    /// The wait of a spend the allowance refuses runs.
    var voidWaiting: Bool
}

/// A spend refused after the server recorded it: the take-back is the void's. `full`: the journal was full
/// when the spend was made, so the void may have found no room.
private struct Phantom {
    var id: String
    var meter: String
    var n: Int
    var full: Bool
}

final class World {
    private let testCase: Case
    private let shared: PropertyShared
    private var stepNo = 0
    /// Every `use` the customer was told was made, by meter.
    private var acked: [String: Int] = [:]
    /// What the customer was told was made while only memory held it and has not been reported since, by meter:
    /// the overage the allowance may show.
    private var told: [String: Int] = [:]
    private var toldOps = 0
    /// What the contract allows to be lost unreported, by meter.
    private var lossAllowed: [String: Int] = [:]
    private var phantoms: [Phantom] = []
    /// The ids of the voids each process held in memory at the last check.
    private var heldVoids: [Set<String>] = [[], []]

    private let weakening: OracleWeakening

    init(_ testCase: Case, tracing: Bool, weakening: OracleWeakening = []) throws {
        self.testCase = testCase
        self.weakening = weakening
        let signer = Signer()
        let server = PropServer(meters: testCase.meters, signer: signer, now: NOW)
        for meter in testCase.meters.keys {
            acked[meter] = 0
            told[meter] = 0
            lossAllowed[meter] = 0
        }
        func preId(_ i: Int) -> String {
            let name = "pre" + String(repeating: "0", count: max(0, 3 - String(i).count)) + String(i)
            return name + String(repeating: "p", count: 22 - name.count)
        }
        let spends = testCase.preload.enumerated().map { i, e in
            SpendEntry(id: preId(i), meter: e.meter, n: e.n, at: NOW - e.agoMs, kind: e.kind)
        }
        let state = StoredState(key: KEY, activationId: "act_1", lastSeen: NOW, spends: spends.isEmpty ? nil : spends)
        shared = PropertyShared(state: state, server: server, signer: signer, now: NOW, weakening: weakening)
        shared.inner.withValue { inner in
            for (i, e) in testCase.preload.enumerated() {
                inner.preIds.insert(preId(i))
                if e.recorded { inner.server.recorded[preId(i)] = Held(meter: e.meter, n: e.n) }
                if e.kind == .void {
                    phantoms.append(Phantom(id: preId(i), meter: e.meter, n: e.n, full: false))
                } else {
                    acked[e.meter, default: 0] += e.n
                }
            }
            inner.tracing = tracing
        }
        // A journal that begins past the cap is one that spends told to the customer once landed past it.
        toldOps = max(0, spends.count - propertyEntries)
        for e in spends where e.kind != .void { told[e.meter, default: 0] += e.n }
        let procs = [try shared.process(0), try shared.process(1)]
        shared.inner.withValue { inner in
            inner.procs = procs
            inner.state.lease = inner.server.lease("act_1")
        }
    }

    /// What happened, for reading a failing case.
    func trace() -> [String] { shared.inner.current.trace }

    private func proc(_ p: Int) -> License { shared.inner.current.procs[p] }

    private func fail(_ invariant: String, _ message: String) -> PropertyFailure {
        let step = stepNo < testCase.steps.count ? JSONText.text(testCase.steps[stepNo].json) : "end"
        return PropertyFailure(invariant, "\(message) (step \(stepNo): \(step))")
    }

    private var tracing: Bool { shared.inner.current.tracing }

    private func note(_ line: String) { shared.inner.withValue { $0.trace.append(line) } }

    private func lbl(_ id: String) -> String { shared.inner.withValue { label(&$0, id) } }

    private func current() -> StoredState { shared.inner.current.state }

    private func held(_ p: Int) -> [JournalOp] { proc(p).heldChanges }

    private func viewEntries(_ p: Int) async -> [SpendEntry] {
        entriesOf(await view(p))
    }

    private func view(_ p: Int) async -> StoredState {
        (try? await proc(p).load(readOnly: true).state) ?? StoredState()
    }

    // MARK: - the steps

    func run() async throws {
        let watchdog = Task { [shared] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            shared.expire()
        }
        defer { watchdog.cancel() }
        for (i, step) in testCase.steps.enumerated() {
            stepNo = i
            if tracing {
                var shown = step.json
                if case .object(var members) = shown {
                    members["r"] = nil
                    shown = .object(members)
                }
                let (net, disk) = (shared.inner.current.net, shared.diskFailing.on)
                note("step \(i): \(JSONText.text(shown)) net=\(net) disk=\(disk ? "failing" : "ok") clock=\(shared.clockNow() - NOW)")
            }
            try await self.step(step)
            if tracing { describe() }
            try await check()
        }
        stepNo = testCase.steps.count
        try await converge()
    }

    private func setDraws(_ r: [Double]) {
        shared.inner.withValue {
            $0.rs = r.isEmpty ? [0.5] : r
            $0.rk = 0
        }
    }

    private func step(_ s: Step) async throws {
        switch s {
        case .wait(let ms):
            pass(ms)
        case .repeat(let call, let times, let gapMs, let r):
            setDraws(r)
            for _ in 0..<times {
                pass(gapMs)
                try await ensureActive()
                try await useCalls([call], status: nil)
                try await check()
            }
        case .jump(let ms):
            shared.clockOffset = min(max(shared.clockOffset + ms, -3 * day), 3 * day)
        case .net(let mode):
            shared.inner.withValue { $0.net = NetMode(word: mode) }
        case .disk(let failing):
            shared.diskFailing.set(failing)
        case .status(let p, let force, let r):
            setDraws(r)
            try await ensureActive()
            let running = launchStatus(p, force)
            try await shared.settle(stepNo)
            try await shared.drive(stepNo)
            try expectStatus(running)
        case .deactivate(let p, let r):
            setDraws(r)
            try await ensureActive()
            try await deactivate(p)
        case .restart(let p):
            try restart(p)
        case .use(let calls, let status, let r):
            setDraws(r)
            try await ensureActive()
            try await useCalls(calls, status: status)
        }
    }

    private func launchStatus(_ p: Int, _ force: Bool) -> Running {
        shared.launch(p) { license in
            _ = await license.status(forceOnline: force)
            return .status
        }
    }

    private func expectStatus(_ running: Running) throws {
        guard case .status? = running.take() else { throw fail("status-rejected", "a call that was not a status") }
    }

    /// Time passes, for the server and the device alike.
    private func pass(_ ms: Int) {
        let now = shared.advance(ms)
        shared.inner.withValue { $0.server.now = max($0.server.now, now) }
    }

    /// A release drops the journal of the seat. The releasing process lands what it holds first, so the release
    /// carries its journal: the contract lets it drop an entry only when the server got none of it (no 200) or it
    /// is past the 64 a report holds; a void it was meant to carry and did not, in any other case, is a fault.
    /// What another process held only in memory is lost with the seat.
    private func deactivate(_ p: Int) async throws {
        let journal = await viewEntries(p)
        let others = (0..<2).filter { $0 != p }.flatMap { held($0) }
        shared.inner.withValue { $0.releases.removeAll() }
        let running = shared.launch(p) { license in
            do {
                return .deactivate(.success(try await license.deactivate()))
            } catch {
                return .deactivate(.failure(error))
            }
        }
        try await shared.settle(stepNo)
        try await shared.drive(stepNo)
        switch running.take() {
        case .deactivate(.success)?: break
        case .deactivate(.failure(let error))?:
            // It fails, the key kept, when the state cannot be saved; any other reason is a bug.
            if !shared.diskFailing.on { throw fail("deactivate-rejected", "\(error)") }
            return
        default: throw fail("deactivate-rejected", "a call that was not a release")
        }
        let (carried, applied, recorded) = shared.inner.withValue { inner in
            (
                inner.releases.filter { $0.applied }.reduce(into: Set<String>()) { $0.formUnion($1.ids) },
                inner.releases.contains { $0.applied }, inner.server.recorded.mapValues(\.n)
            )
        }
        for (index, e) in journal.enumerated() {
            // The report holds the first 64 of the journal in the order the SDK keeps it: only what the server got none of (no 200) or what is past them may be dropped.
            let mayDrop = !applied || index >= propertyEntries
            if e.kind == .void {
                let voided = shared.inner.current.server.voided.contains(e.id)
                if carried.contains(e.id) || voided { continue }
                if !mayDrop {
                    throw fail(
                        "release-dropped-void",
                        "a release left a void of the journal behind: \(lbl(e.id)) is entry \(index) of \(journal.count) (\(carried.count) carried)"
                    )
                }
                shared.inner.withValue { _ = $0.lostVoids.insert(e.id) }
            } else if mayDrop {
                // What the server holds of it already is not lost; the rest is, and the contract allows it.
                lossAllowed[e.meter, default: 0] += max(0, e.n - (recorded[e.id] ?? 0))
            }
        }
        lose(others)
    }

    /// What a process held only in memory is lost with it: the spends are the customer's to have been told of.
    private func lose(_ ops: [JournalOp]) {
        for op in ops {
            guard case .spend(let spend) = op else { continue }
            if spend.kind == .void {
                shared.inner.withValue { _ = $0.lostVoids.insert(spend.id) }
            } else {
                lossAllowed[spend.meter, default: 0] += spend.n
            }
        }
    }

    /// The app ends and starts again: what its process held only in memory is gone, and the customer was told it was made.
    private func restart(_ p: Int) throws {
        lose(held(p))
        heldVoids[p] = []
        let fresh = try shared.process(p)
        shared.inner.withValue { $0.procs[p] = fresh }
    }

    /// The seat is taken (on a good network and disk) when a release dropped it: the app activates again.
    private func ensureActive() async throws {
        if current().key != nil { return }
        let (net, disk) = (shared.inner.current.net, shared.diskFailing.on)
        shared.inner.withValue { $0.net = .good }
        shared.diskFailing.set(false)
        let running = shared.launch(0) { license in .activate(await license.activate(KEY)) }
        try await shared.settle(stepNo)
        try await shared.drive(stepNo)
        switch running.take() {
        case .activate(.activated)?: break
        case .activate(.failed(let error))?: throw fail("reactivation", error.rawValue)
        default: throw fail("reactivation", "a call that was not an activation")
        }
        shared.inner.withValue { $0.net = net }
        shared.diskFailing.set(disk)
    }

    private func preOf(_ call: Call) async -> Pre {
        let state = await view(call.p)
        let spends = entriesOf(state)
        let figure = baseFigure(state, call.meter)
        let unsynced = unsyncedIn(spends, call.meter)
        let clockNow = shared.clockNow()
        let guarded = max(clockNow, state.lastSeen ?? 0)
        let left = figure.map { max(0, $0.left - unsynced) } ?? 0
        return Pre(
            licensed: state.key != nil && state.lease != nil,
            covered: figure.map { unsynced + call.n <= $0.offline && call.n <= left } ?? false,
            leftAfter: left - call.n,
            entryCount: spends.count,
            openOffline: spends.contains { $0.kind == .offline && $0.meter == call.meter },
            waiting: askWait(state, clockNow) || journalWait(spends, guarded),
            voidWaiting: voidWait(spends, guarded, clockNow)
        )
    }

    private func useCalls(_ calls: [Call], status: Step.StatusCall?) async throws {
        let concurrent = calls.count > 1 || status != nil
        // Only a disk that refuses its writes leaves a spend in memory, told and not saved: a call behind another of
        // its process waits its turn (the grace here is an hour) and saves as any call does.
        let risky = shared.diskFailing.on
        var pres: [Pre] = []
        for call in calls { pres.append(await preOf(call)) }
        shared.inner.withValue { inner in for p in 0..<2 { inner.useReqs[p].removeAll() } }
        var running: [Running] = []
        for call in calls {
            let (meter, n) = (call.meter, call.n)
            running.append(shared.launch(call.p) { license in .use(await license.use(meter, n)) })
            try await shared.settle(stepNo)
        }
        var side: Running?
        if let status {
            side = launchStatus(status.p, status.force)
            try await shared.settle(stepNo)
        }
        try await shared.drive(stepNo)
        // What each process sees now: a spend after the first of two may meet a journal the first filled.
        var views: [[SpendEntry]] = []
        for p in 0..<2 { views.append(await viewEntries(p)) }
        for (i, call) in calls.enumerated() {
            guard case .use(let result)? = running[i].take() else { throw fail("use-rejected", "a call that was not a spend") }
            let requests = shared.inner.current.useReqs[call.p].filter { $0.meter == call.meter }
            if tracing { note("  p\(call.p) use \(call.meter) \(call.n) => \(result)") }
            try judge(call, pres[i], result, requests, concurrent: concurrent, risky: risky, view: views[call.p])
        }
        if let side { try expectStatus(side) }
    }

    /// What the contract says of an answer, and the ledger of what the customer was told.
    private func judge(
        _ call: Call, _ pre: Pre, _ res: UseResult, _ reqs: [Req], concurrent: Bool, risky: Bool, view: [SpendEntry]
    ) throws {
        let asked = !reqs.isEmpty
        let alone = !concurrent && pre.licensed
        let (n, meter) = (call.n, call.meter)
        if alone && !pre.covered && pre.voidWaiting && asked {
            throw fail("uncovered-asked-in-wait", "\(n) of \(meter) asked the server while a void under a minute old stands")
        }
        if alone && pre.covered && asked == pre.waiting {
            let what = asked ? "asked the server while a wait runs" : "did not ask the server though no wait runs"
            throw fail("covered-ask-rule", "\(n) of \(meter) \(what)")
        }
        if res.ok {
            // What is left is never told high. Made offline it is the figure less the unsynced, less the spend; online the server's own is at most what it has.
            let left = res.left ?? 0
            if alone && res.offline && left != pre.leftAfter {
                throw fail("left-wrong", "\(n) of \(meter) made offline answered \(left) left, the figure and the unsynced say \(pre.leftAfter)")
            }
            let serverLeft = shared.inner.current.server.left(meter)
            if alone && !res.offline && left > serverLeft {
                throw fail("left-high", "\(n) of \(meter) answered \(left) left, the server has \(serverLeft)")
            }
            acked[meter, default: 0] += n
            if res.offline && risky {
                told[meter, default: 0] += n
                toldOps += 1
            }
            return
        }
        // A void finds no room when the journal, less the oldest void if sixteen stand and the new one takes its place, still holds the cap; one that landed, or is held, found its room.
        let crowded =
            weakening.contains(.crowdedByEntryCountOnly)
            ? pre.entryCount >= propertyEntries
            : max(pre.entryCount, view.count) - (view.filter { $0.kind == .void }.count >= propertyVoids ? 1 : 0) >= propertyEntries
        let heldOps = (0..<2).flatMap { held($0) }
        func heldVoid(_ id: String) -> Bool {
            heldOps.contains { if case .spend(let s) = $0 { s.kind == .void && s.id == id } else { false } }
        }
        func heldPlain(_ id: String) -> Bool {
            heldOps.contains { if case .spend(let s) = $0 { s.kind != .void && s.id == id } else { false } }
        }
        let placed = { (id: String) in view.contains { $0.id == id } || heldVoid(id) }
        // A process's requests of one meter are not told apart by call, so a spend the customer was told was made (another call of the step, asked and
        // unanswered, then kept as a plain entry or reported as one) is not a refused spend whose void is owed.
        let reported = shared.inner.current.reportedPlain
        let toldId = { (id: String) in
            reported.contains(id) || view.contains { $0.id == id && $0.kind != .void } || heldPlain(id)
        }
        for q in reqs where q.applied && !q.answered && (weakening.contains(.everyUnansweredIsOwed) || !toldId(q.id)) {
            phantoms.append(Phantom(id: q.id, meter: q.meter, n: q.n, full: crowded && !placed(q.id)))
        }
        // The world's disk refuses writes, never reads: a state that cannot be read is no outcome of any step.
        if res.error == .storage { throw fail("use-storage", "\(n) of \(meter) answered storage, though the disk only ever refuses writes") }
        if concurrent || !pre.licensed || (res.error != .offlineLimit && res.error != .noMeter) { return }
        if pre.covered && res.error == .offlineLimit {
            // A covered spend is refused only for the journal's size: it would open a 65th entry.
            let capped = pre.entryCount >= propertyEntries && (asked || !pre.openOffline)
            if !capped {
                throw fail("covered-refused", "\(n) of \(meter) was covered by the allowance and refused (journal of \(pre.entryCount))")
            }
        }
        if !pre.covered && !asked && !pre.voidWaiting {
            throw fail("uncovered-unasked", "\(n) of \(meter) was refused without asking, and no void wait runs")
        }
    }

    private func describe() {
        func show(_ e: SpendEntry) -> String { "\(e.kind.rawValue):\(lbl(e.id)):\(e.meter):\(e.n)" }
        func showOp(_ op: JournalOp) -> String {
            switch op {
            case .confirmed(_, let entries): "confirmed:\(entries.count)"
            case .figures: "figures"
            case .activated: "activated"
            case .deactivated: "deactivated"
            case .spend(let s): "\(s.kind.rawValue)\(s.told ? "!" : ""):\(lbl(s.id)):\(s.meter):\(s.n)"
            }
        }
        note("  stored [\(entriesOf(current()).map(show).joined(separator: " "))]")
        for p in 0..<2 { note("  p\(p) holds [\(held(p).map(showOp).joined(separator: " "))]") }
    }

    // MARK: - what must hold between steps, and at the end

    /// A void held in memory that is gone, though it neither landed nor reached the server: sixteen were held and
    /// the oldest went, or the journal found no room for it.
    private func accountVoids() throws {
        let stored = entriesOf(current())
        for p in 0..<2 {
            let now = Set(
                held(p).compactMap { op -> String? in
                    if case .spend(let s) = op, s.kind == .void { return s.id }
                    return nil
                }
            )
            let before = heldVoids[p]
            for id in before.sorted() {
                let (voided, lost, refused) = shared.inner.withValue {
                    ($0.server.voided.contains(id), $0.lostVoids.contains(id), $0.refusedVoids.contains(id))
                }
                if now.contains(id) || stored.contains(where: { $0.id == id }) || voided || lost { continue }
                if before.count >= propertyVoids || refused {
                    shared.inner.withValue { _ = $0.lostVoids.insert(id) }
                } else {
                    throw fail("void-dropped", "a void held in memory is gone: \(lbl(id)) (\(before.count) held, \(stored.count) stored)")
                }
            }
            heldVoids[p] = now
        }
    }

    /// The phantoms the server recorded and no void has taken back.
    private func outstanding() -> [Phantom] {
        let inner = shared.inner.current
        return phantoms.filter { inner.server.recorded[$0.id] != nil && !inner.server.voided.contains($0.id) }
    }

    private func check() async throws {
        if let violation = shared.inner.current.violation { throw fail("void-replaced", violation) }
        let stored = entriesOf(current())
        if Set(stored.map(\.id)).count != stored.count { throw fail("duplicate-id", "the journal holds one id twice") }
        if stored.count > propertyEntries + toldOps {
            throw fail("journal-size", "\(stored.count) entries stored, past the cap and what was told")
        }
        if stored.filter({ $0.kind == .void }).count > propertyVoids { throw fail("void-cap", "more voids stored than the cap") }
        for (m, spec) in testCase.meters.sorted(by: { $0.key < $1.key }) {
            let unsynced = unsyncedIn(stored, m)
            let toldHere = told[m] ?? 0
            if unsynced > spec.offline + toldHere {
                throw fail("allowance", "\(unsynced) of \(m) unsynced past its allowance \(spec.offline) and the \(toldHere) told")
            }
        }
        var holding = false
        for p in 0..<2 {
            let heldOps = held(p)
            let voids = heldOps.filter { if case .spend(let s) = $0 { s.kind == .void } else { false } }.count
            if voids > propertyVoids { throw fail("unsaved-voids", "a process holds more voids in memory than the cap") }
            if heldOps.contains(where: { if case .spend(let s) = $0 { s.kind == .void && s.told } else { false } }) {
                throw fail("void-told", "a void was marked told")
            }
            if heldOps.count > propertyEntries + propertyVoids + 16 { throw fail("unsaved-size", "\(heldOps.count) changes held in memory") }
            holding = holding || !heldOps.isEmpty
        }
        try accountVoids()
        // The server never holds more than the customer was told and the refusals it recorded: a spend counted twice shows here at once.
        let owing = outstanding()
        for m in testCase.meters.keys.sorted() {
            let phantom = owing.filter { $0.meter == m }.map(\.n).reduce(0, +)
            let used = shared.inner.current.server.used(m)
            if used > acked[m, default: 0] + phantom {
                throw fail(
                    "counted-twice",
                    "\(m): the server holds \(used), the customer was told \(acked[m, default: 0]) (and \(phantom) refused but recorded)"
                )
            }
        }
        // What was told while only memory held it excuses the allowance only while it is unreported: once a meter's journal drains, the loosening ends.
        let heldAll = (0..<2).flatMap { held($0) }
        for m in testCase.meters.keys {
            let heldHere = heldAll.contains { if case .spend(let s) = $0 { s.kind != .void && s.meter == m } else { false } }
            if unsyncedIn(stored, m) == 0 && !heldHere { told[m] = 0 }
        }
        if stored.isEmpty && !holding { toldOps = 0 }
    }

    /// The network and the disk come back, time passes, and every journal is reported: then the books are balanced.
    private func converge() async throws {
        shared.inner.withValue {
            $0.net = .good
            $0.rs = [0.0]
            $0.rk = 0
        }
        shared.diskFailing.set(false)
        let now = shared.advance(3 * hour)
        shared.inner.withValue { $0.server.now = max($0.server.now, now) }
        try await ensureActive()
        // A journal past 64 entries is reported 64 at a time, so more than one check-in each may be needed.
        var round = 0
        while round < 4 && (round == 0 || !entriesOf(current()).isEmpty || (0..<2).contains(where: { !held($0).isEmpty })) {
            for p in 0..<2 {
                let running = launchStatus(p, true)
                try await shared.settle(stepNo)
                try await shared.drive(stepNo)
                try expectStatus(running)
                try accountVoids()
            }
            round += 1
        }
        if let violation = shared.inner.current.violation { throw fail("void-replaced", violation) }
        let leftOver = entriesOf(current())
        if !leftOver.isEmpty {
            let shown = leftOver.map { "\($0.kind.rawValue):\(lbl($0.id))" }.joined(separator: " ")
            throw fail("journal-left", "the journal still holds \(shown) after every process reported")
        }
        if (0..<2).contains(where: { !held($0).isEmpty }) { throw fail("unsaved-left", "a process still holds changes in memory") }
        // A refusal the server recorded is taken back, unless that very void was lost as the contract allows: replaced by a newer one, dropped with a release, held by a process that ended, or never given room.
        for phantom in outstanding() {
            let lost = shared.inner.current.lostVoids.contains(phantom.id)
            if !phantom.full && !lost {
                throw fail(
                    "void-lost",
                    "\(phantom.meter): \(phantom.n) refused after the server recorded it (\(lbl(phantom.id))), and its void did not reach the server though nothing lost it"
                )
            }
        }
        var shown: [LicenseStatus] = []
        for p in 0..<2 { shown.append(await proc(p).status()) }
        let owing = outstanding()
        for (m, spec) in testCase.meters.sorted(by: { $0.key < $1.key }) {
            let used = shared.inner.current.server.used(m)
            let owed = owing.filter { $0.meter == m }.map(\.n).reduce(0, +)
            let (acknowledged, lost) = (acked[m, default: 0], lossAllowed[m, default: 0])
            if used + lost < acknowledged + owed {
                throw fail("lost", "\(m): the server holds \(used), the customer was told \(acknowledged) (and \(owed) refused but recorded)")
            }
            if used > acknowledged + owed {
                throw fail("counted-twice", "\(m): the server holds \(used), the customer was told \(acknowledged) (and \(owed) refused but recorded)")
            }
            let left = max(0, spec.total - used)
            for status in shown {
                let figure = status.meters[m]
                if figure == nil || figure?.left != left || figure?.unsynced != 0 {
                    throw fail("figures", "\(m): status shows \(String(describing: figure)), the server has \(left) left")
                }
            }
        }
    }
}

/// Run a case: none when every property held. With `trace` the trace of what happened is given too.
func runCase(
    _ testCase: Case, trace: Bool, weakening: OracleWeakening = []
) async -> (failure: PropertyFailure?, trace: [String]) {
    let world: World
    do {
        world = try World(testCase, tracing: trace, weakening: weakening)
    } catch {
        return (PropertyFailure("exception", "the world could not begin: (error)"), [])
    }
    do {
        try await world.run()
        return (nil, world.trace())
    } catch let failure as PropertyFailure {
        return (failure, world.trace())
    } catch {
        return (PropertyFailure("exception", "\(error)"), world.trace())
    }
}
