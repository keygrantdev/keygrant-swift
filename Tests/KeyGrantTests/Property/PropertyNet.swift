import Foundation

@testable import KeyGrant

/// The machine a property test of `use(_:_:)` runs the real `License` on: two processes of the app over one
/// state file and one device clock, a KeyGrant server whose every answer a step may lose, delay or refuse, a
/// disk that may refuse its writes, and a device clock that jumps forward and back.
///
/// Concurrency is deterministic. A request of a process is PARKED at the world, which decides when and how it
/// is answered, and a call is started only once every call running before it is parked at a request or done,
/// so one task moves at a time and a case replays the same way on any machine. The races that matter (a
/// process's whole call between another's request and its answer) are the order the world answers its parked
/// requests in. A request nobody answers is timed out one at a time, as an adapter's is at its bound: no
/// answer, to the SDK; no clock is raced against a timer. Test support only.

/// A property that did not hold: which, and where.
struct PropertyFailure: Error, Sendable {
    var invariant: String
    var message: String

    init(_ invariant: String, _ message: String) {
        self.invariant = invariant
        self.message = "\(invariant): \(message)"
    }
}

enum NetMode: String, Sendable {
    case good, down, flaky

    init(word: String) {
        self = NetMode(rawValue: word) ?? .flaky
    }
}

enum Fate: Sendable {
    case ok, lost, lostAfter, hang, hangAfter, fail, failAfter, limited
}

func fateOf(_ net: NetMode, _ r: Double) -> Fate {
    let thresholds: [(Double, Fate)]
    switch net {
    case .good: return .ok
    case .down: thresholds = [(0.45, .lost), (0.75, .lostAfter), (0.88, .hang)]
    case .flaky:
        thresholds = [(0.35, .ok), (0.45, .lost), (0.55, .lostAfter), (0.65, .fail), (0.75, .failAfter), (0.82, .limited), (0.9, .hang)]
    }
    return thresholds.first { r < $0.0 }?.1 ?? .hangAfter
}

/// A request a process made for one of its `use` calls.
struct Req: Sendable {
    var meter: String
    var n: Int
    var id: String
    /// The server recorded the spend.
    var applied: Bool
    /// The SDK got a usable answer.
    var answered: Bool
}

struct NetworkDown: Error {}

/// A request parked at the world: it is answered, lost or left to time out when the world says.
struct Parked: Sendable {
    var index: Int
    var action: String
    var body: LicenseJSON
    var fate: Fate
    var hung = false
    var delivery: CheckedContinuation<LicenseHTTPResponse, Error>
}

/// What a call came to.
enum CallValue: Sendable {
    case use(UseResult)
    case status
    case deactivate(Result<DeactivateResult, any Error>)
    case activate(ActivateResult)
}

/// A call under way: the process it is made on, and whether it is done.
final class Running: Sendable {
    let p: Int
    private let state = Locked<(done: Bool, value: CallValue?)>((false, nil))

    init(p: Int) {
        self.p = p
    }

    var isDone: Bool { state.current.done }

    func finish(_ value: CallValue) {
        state.withValue { $0 = (true, value) }
    }

    /// What the call came to.
    func take() -> CallValue? {
        state.withValue { state in
            defer { state.value = nil }
            return state.value
        }
    }
}

/// A resumption the world makes of a parked request, after it has let go of its lock.
typealias Resume = (CheckedContinuation<LicenseHTTPResponse, Error>, Result<LicenseHTTPResponse, Error>)

/// Everything the adapters and the world share.
struct Inner: Sendable {
    var state: StoredState
    var server: PropServer
    var net = NetMode.good
    var rs: [Double] = [0.5]
    var rk = 0
    var parked: [Parked?] = [nil, nil]
    var active: [Running] = []
    var procs: [License] = []
    var useReqs: [[Req]] = [[], []]
    /// The releases a step made: whether the server recorded each, and the entries it carried.
    var releases: [(applied: Bool, ids: Set<String>)] = []
    /// The ids of spends a request reported as plain spends (not as voids): spends the customer was told were made.
    var reportedPlain: Set<String> = []
    /// The voids the contract let be lost before the server heard them.
    var lostVoids: Set<String> = []
    /// The voids held in memory when a save left the journal at its size: one that did not land may have found no room.
    var refusedVoids: Set<String> = []
    /// A save that dropped a void with nothing to replace it, found inside the SDK's save and reported by the next check.
    var violation: String?
    var tracing = false
    var trace: [String] = []
    var labels: [String: String] = [:]
    var preIds: Set<String> = []
    /// Tasks waiting for something to change (`PropertyShared.until`).
    var waiters: [CheckedContinuation<Void, Never>] = []
    /// The run has taken too long: whatever waits gives up.
    var expired = false
}

/// A term of the oracle that a test may take away, to show that a case needs it. The terms are listed once: each bit of
/// an `OracleWeakening` is a term's place here, and `OracleWeakening.named` is every one of them, so a term added is
/// held by the oracle test to a kept case.
enum OracleTerm: Int, CaseIterable, Sendable {
    /// A void held in memory that lands in a save is not counted among the voids that land.
    case ignoreHeldVoids
    /// A save that opens several voids replaces at most one of the oldest.
    case oneVoidPerLanding
    /// A void held in memory that found no room in a journal at its size is not excused.
    case noRoomNotExcused
    /// A void owed to a spend is judged to find no room by the journal before the call alone.
    case crowdedByEntryCountOnly
    /// Every spend whose request the server recorded and the SDK got no answer to is owed a void, a spend the customer was told was made included.
    case everyUnansweredIsOwed
    /// A void held in memory that lands in a save which confirms it away at once (the journal not at its size) is not counted among the voids that land.
    case confirmedHeldVoidsNotCounted
}

/// Terms of the oracle taken away: a case kept for a blind spot of the oracle fails against the oracle without the term
/// that was added for it. Never used by the property test itself.
struct OracleWeakening: OptionSet, Sendable {
    let rawValue: Int

    init(rawValue: Int) { self.rawValue = rawValue }

    init(_ term: OracleTerm) { rawValue = 1 << term.rawValue }

    static let ignoreHeldVoids = OracleWeakening(.ignoreHeldVoids)
    static let oneVoidPerLanding = OracleWeakening(.oneVoidPerLanding)
    static let noRoomNotExcused = OracleWeakening(.noRoomNotExcused)
    static let crowdedByEntryCountOnly = OracleWeakening(.crowdedByEntryCountOnly)
    static let everyUnansweredIsOwed = OracleWeakening(.everyUnansweredIsOwed)
    static let confirmedHeldVoidsNotCounted = OracleWeakening(.confirmedHeldVoidsNotCounted)

    /// Every term, by name.
    static let named: [(name: String, term: OracleWeakening)] = OracleTerm.allCases.map { (String(describing: $0), OracleWeakening($0)) }
}

let propertyEntries = 64
let propertyVoids = 16

final class PropertyShared: Sendable {
    let inner: Locked<Inner>
    let signer: Signer
    private let trueNow: Locked<Int>
    private let offset = Locked(0)
    let diskFailing = Flag()

    let weakening: OracleWeakening

    init(state: StoredState, server: PropServer, signer: Signer, now: Int, weakening: OracleWeakening = []) {
        self.weakening = weakening
        inner = Locked(Inner(state: state, server: server))
        self.signer = signer
        trueNow = Locked(now)
    }

    /// The device clock.
    func clockNow() -> Int { trueNow.current + offset.current }

    func advance(_ ms: Int) -> Int { trueNow.withValue { $0 += ms; return $0 } }

    var clockOffset: Int {
        get { offset.current }
        set { offset.withValue { $0 = newValue } }
    }

    var trueTime: Int { trueNow.current }

    /// Something changed that the world may be waiting for. The waiters are taken under the lock, so one
    /// that has checked and not yet slept cannot miss it.
    func signal() {
        let waiters = inner.withValue { inner -> [CheckedContinuation<Void, Never>] in
            defer { inner.waiters = [] }
            return inner.waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    /// Wait until `condition` holds of the shared state.
    func until(_ what: String, _ condition: @Sendable (Inner) -> Bool) async throws {
        enum Check { case holds, expired(String), wait }
        while true {
            // Registered as a waiter in the same hold of the lock that finds the condition false, so a
            // change cannot slip between the check and the wait.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let proceed = inner.withValue { inner -> Bool in
                    if condition(inner) || inner.expired { return true }
                    inner.waiters.append(continuation)
                    return false
                }
                if proceed { continuation.resume() }
            }
            let check = inner.withValue { inner -> Check in
                if condition(inner) { return .holds }
                return inner.expired ? .expired(whereabouts(inner)) : .wait
            }
            switch check {
            case .holds: return
            case .expired(let whereabouts): throw PropertyFailure("stuck", "a call never settled (\(what)): \(whereabouts)")
            case .wait: continue
            }
        }
    }

    /// A process of the app: the real `License`, over the world's adapters.
    func process(_ index: Int) throws -> License {
        let patient: TimeInterval = 3600
        let timing = Timing(lockGrace: patient, statusCheck: patient, machineId: patient, activateMachineId: patient, identifySlack: patient)
        let config = LicenseConfig(
            product: PRODUCT, apiBaseURL: apiBase, publicJWK: signer.publicJWK, httpTimeout: patient,
            adapters: LicenseAdapters(
                storage: WorldStorage(shared: self), clock: WorldClock(shared: self), fingerprinter: GetFingerprinter("fp-test"),
                http: WorldHttp(shared: self, index: index)
            )
        )
        return try License(config, timing: timing)
    }

    /// Start a call on process `p` in a task of its own.
    func launch(_ p: Int, _ work: @escaping @Sendable (License) async -> CallValue) -> Running {
        let running = Running(p: p)
        let license = inner.withValue { inner -> License in
            inner.active.append(running)
            return inner.procs[p]
        }
        Task {
            running.finish(await work(license))
            self.signal()
        }
        return running
    }

    /// Every call running is parked at a request or done: nothing moves until the world moves it.
    private static func quiescent(_ inner: Inner) -> Bool {
        (0..<2).allSatisfy { p in
            // The first call of a process not done runs (the others wait their turn); it is moving unless it is parked.
            let running = inner.active.contains { $0.p == p && !$0.isDone }
            return !running || inner.parked[p] != nil
        }
    }

    /// Wait for a call just started to park at a request or be done.
    func settle(_ step: Int) async throws {
        try await until("step \(step)", PropertyShared.quiescent)
    }

    /// Answer the requests parked, one at a time in an order the case fixes, until every call started is
    /// done. Requests left to time out (hung) are timed out last.
    func drive(_ step: Int) async throws {
        enum Next { case finished, deliver([Resume]), stuck(String) }
        var rounds = 0
        while true {
            try await settle(step)
            rounds += 1
            let next = inner.withValue { inner -> Next in
                if inner.active.allSatisfy(\.isDone) {
                    inner.active.removeAll()
                    return .finished
                }
                if rounds > 400 { return .stuck("a call never settled (step \(step))") }
                let last = inner.rs.last ?? 0.5
                // Two requests parked: the case says whose is answered first.
                let waiting = (0..<2).filter { inner.parked[$0].map { !$0.hung } ?? false }
                if !waiting.isEmpty {
                    let pick = waiting.count == 1 || last < 0.5 ? waiting[0] : waiting[waiting.count - 1]
                    guard let request = inner.parked[pick] else { return .stuck("a parked request went") }
                    inner.parked[pick] = nil
                    return .deliver(release(&inner, request))
                }
                // Two left that nobody answers: one at a time, in the order the case fixes, so a case replays the same way.
                let hung = (0..<2).filter { inner.parked[$0] != nil }
                if hung.isEmpty { return .stuck("a call never settled (step \(step)): \(whereabouts(inner))") }
                let pick = hung.count == 1 || last < 0.5 ? hung[0] : hung[hung.count - 1]
                guard let silent = inner.parked[pick] else { return .stuck("a parked request went") }
                inner.parked[pick] = nil
                // A request nobody answers times out, as an adapter's does at its bound (no answer, to the SDK).
                return .deliver([(silent.delivery, .failure(NetworkDown()))])
            }
            switch next {
            case .finished: return
            case .stuck(let why): throw PropertyFailure("stuck", why)
            case .deliver(let resumes):
                for (continuation, result) in resumes { continuation.resume(with: result) }
            }
        }
    }

    /// Give up whatever waits: the run took too long.
    func expire() {
        inner.withValue { $0.expired = true }
        signal()
    }
}

/// Where every call is, for a failure that says a call never settled.
func whereabouts(_ inner: Inner) -> String {
    let calls = inner.active.enumerated().map { "call \($0.offset) on p\($0.element.p): \($0.element.isDone ? "done" : "running")" }
    let parked = inner.parked.enumerated().map { index, request -> String in
        guard let request else { return "p\(index): nothing parked" }
        return "p\(index): \(request.action) \(request.fate)\(request.hung ? " hung" : "")"
    }
    return (calls + parked).joined(separator: "; ")
}

/// An id as the trace shows it: the order it was first seen in, so a case reads the same every time.
func label(_ inner: inout Inner, _ id: String) -> String {
    if id.isEmpty { return "" }
    if let known = inner.labels[id] { return known }
    let next = inner.labels.count
    let shown = inner.preIds.contains(id) ? String(id.prefix(6)) : "s\(next)"
    inner.labels[id] = shown
    return shown
}

/// What a request comes to over a network that may lose it, or its answer, or both.
func release(_ inner: inout Inner, _ given: Parked) -> [Resume] {
    var request = given
    var resumes: [Resume] = []
    func respond(_ response: LicenseHTTPResponse) { resumes.append((request.delivery, .success(response))) }
    func fail() { resumes.append((request.delivery, .failure(NetworkDown()))) }
    func answer(_ inner: inout Inner, answered: Bool) -> Served {
        let served = inner.server.handle(request.action, request.body)
        noted(&inner, request, served, answered)
        return served
    }
    switch request.fate {
    case .ok:
        let served = answer(&inner, answered: true)
        respond(LicenseHTTPResponse(status: served.status, json: served.json))
    case .lostAfter:
        _ = answer(&inner, answered: false)
        fail()
    case .hangAfter:
        _ = answer(&inner, answered: false)
        request.hung = true
        inner.parked[request.index] = request
    case .failAfter:
        let served = answer(&inner, answered: false)
        respond(LicenseHTTPResponse(status: 500, json: served.json))
    case .lost:
        noted(&inner, request, nil, false)
        fail()
    case .hang:
        noted(&inner, request, nil, false)
        request.hung = true
        inner.parked[request.index] = request
    case .fail:
        noted(&inner, request, nil, false)
        respond(LicenseHTTPResponse(status: 503, json: ["error": "unavailable"]))
    case .limited:
        noted(&inner, request, nil, false)
        respond(LicenseHTTPResponse(status: 429, json: ["error": "rate-limited"]))
    }
    return resumes
}

private func noted(_ inner: inout Inner, _ request: Parked, _ served: Served?, _ answered: Bool) {
    let body = request.body
    if inner.tracing {
        let reports = (body["spends"]?.arrayValue ?? []).map { entry -> String in
            let who = label(&inner, entry["id"]?.stringValue ?? "")
            return "\(who):\(entry["meter"]?.stringValue ?? ""):\(entry["n"]?.intValue ?? 0)\(entry.has("void") ? "v" : "")"
        }
        let id = label(&inner, body["id"]?.stringValue ?? "")
        inner.trace.append(
            "  p\(request.index) \(request.action) {meter:\(body["meter"]?.stringValue ?? ""),n:\(body["n"]?.intValue.map(String.init) ?? "null"),id:\(id),spends:[\(reports.joined(separator: ","))]} -> \(served.map { String($0.status) } ?? "lost") \(answered ? "answered" : "unanswered")"
        )
    }
    for entry in body["spends"]?.arrayValue ?? [] where !entry.has("void") {
        if let plain = entry["id"]?.stringValue { inner.reportedPlain.insert(plain) }
    }
    if request.action == "deactivate" {
        let ids = Set((body["spends"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue })
        inner.releases.append((served != nil, ids))
    }
    if request.action == "use" {
        inner.useReqs[request.index].append(
            Req(
                meter: body["meter"]?.stringValue ?? "", n: body["n"]?.intValue ?? 0, id: body["id"]?.stringValue ?? "",
                applied: served?.spent != nil, answered: answered
            )
        )
    }
}

// MARK: - the adapters

private struct WorldClock: LicenseClock {
    let shared: PropertyShared

    func now() -> Int { shared.clockNow() }
}

private struct WorldHttp: HTTPAdapter {
    let shared: PropertyShared
    let index: Int

    func post(_ url: URL, body: LicenseJSON, timeout: TimeInterval) async throws -> LicenseHTTPResponse {
        let action = url.lastPathComponent
        let response = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<LicenseHTTPResponse, Error>) in
            shared.inner.withValue { inner in
                let r = inner.rs.isEmpty ? 0.5 : inner.rs[inner.rk % inner.rs.count]
                inner.rk += 1
                inner.parked[index] = Parked(index: index, action: action, body: body, fate: fateOf(inner.net, r), delivery: continuation)
            }
            shared.signal()
        }
        return response
    }
}

private struct WorldStorage: StorageAdapter {
    let shared: PropertyShared

    func read(readOnly: Bool) async throws -> StoredState? {
        shared.inner.withValue { $0.state }
    }

    func write(_ state: StoredState) async throws {
        try shared.inner.withValue { inner in
            if shared.diskFailing.on { throw StorageError(code: "EBUSY", operation: "write", path: "world") }
            landed(&inner, state, shared.weakening)
            inner.state = state
        }
    }

    func update(_ merge: @escaping @Sendable (StoredState) -> StoredState) async throws {
        try shared.inner.withValue { inner in
            let next = merge(inner.state)
            if shared.diskFailing.on { throw StorageError(code: "EBUSY", operation: "update", path: "world") }
            landed(&inner, next, shared.weakening)
            inner.state = next
        }
    }
}

/// A save that landed. A void that left the journal and that the server did not confirm was replaced, and a
/// replacement happens only when a void lands with sixteen standing: for each void that lands (one now in the
/// journal that was not, or one held that is in neither, whether refused or confirmed in the same save) the
/// oldest may go. A void dropped otherwise is a fault, kept for the next check to report. A seat taken or
/// dropped is the release's and the restart's to account for.
private func landed(_ inner: inout Inner, _ after: StoredState, _ weakening: OracleWeakening) {
    let before = inner.state
    if before.activationId != after.activationId || after.key == nil { return }
    let was = before.spends ?? []
    let now = after.spends ?? []
    let kept = Set(now.map(\.id)), had = Set(was.map(\.id))
    let dropped = was.filter { $0.kind == .void && !kept.contains($0.id) && !inner.server.voided.contains($0.id) }.map(\.id)
    let heldVoids = inner.procs.flatMap(\.heldChanges).compactMap { op -> String? in
        if case .spend(let spend) = op, spend.kind == .void { return spend.id }
        return nil
    }
    var landing = Set(now.filter { $0.kind == .void && !had.contains($0.id) }.map(\.id))
    let standing = was.filter { $0.kind == .void }.count
    let nowVoids = now.filter { $0.kind == .void }.count
    let full = now.count - (nowVoids >= propertyVoids ? 1 : 0) >= propertyEntries
    if !weakening.contains(.ignoreHeldVoids) && !(weakening.contains(.confirmedHeldVoidsNotCounted) && !full) {
        landing.formUnion(heldVoids.filter { !had.contains($0) && !kept.contains($0) })
    }
    let unplaced = heldVoids.filter { !kept.contains($0) }
    if !dropped.isEmpty {
        let landingCount = weakening.contains(.oneVoidPerLanding) ? min(landing.count, 1) : landing.count
        if dropped.count <= landingCount && standing + landingCount > propertyVoids {
            inner.lostVoids.formUnion(dropped)
        } else if inner.violation == nil {
            inner.violation = "\(dropped.count) void(s) left the journal of \(standing) voids with \(landing.count) landing, and nothing was to replace them"
        }
    }
    // Left at its size, with sixteen voids' oldest not yet replaced, the journal took no more: a void that was held and did not land found no room.
    if full && !weakening.contains(.noRoomNotExcused) { inner.refusedVoids.formUnion(unplaced) }
}
