import Foundation
import Testing

@testable import KeyGrant

/// Every suite's time limit, where Swift Testing can keep one (Linux, and macOS 13 or later): a
/// minute, the shortest it keeps. A test past it is failed and its task cancelled, but that ends
/// only what heeds cancellation: an await that does not (a task's `value`, a continuation nobody
/// resumes) still holds the run. So the tests' own waits on the SDK carry a real-time deadline of
/// their own (`answer(within:)`).
let suiteTimeLimit: any SuiteTrait = {
    if #available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *) {
        return TimeLimitTrait.timeLimit(.minutes(1))
    }
    return ConditionTrait.enabled(if: true)
}()

/// What `work` answers, or nil once `seconds` of real time have passed first: an issue is then
/// recorded, and the test fails. A test that keeps the SDK's bounds on a clock nobody moves, or
/// holds a call at a gate, would otherwise wait forever on a build that never answers, since
/// awaiting a task's value does not end when the test is cancelled. The work is abandoned.
func answer<T: Sendable>(
    within seconds: TimeInterval = 20,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ work: @escaping @Sendable () async -> T
) async -> T? {
    let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<Outcome<T>, Never>) in
        let first = FirstOutcome(continuation)
        let timer = Task {
            try? await Task.sleep(nanoseconds: nanoseconds(seconds))
            first.give(.late)
        }
        Task {
            first.give(.answered(await work()))
            timer.cancel()
        }
    }
    switch outcome {
    case .answered(let value):
        return value
    case .late:
        Issue.record("no answer within \(seconds) s of real time", sourceLocation: sourceLocation)
        return nil
    }
}

/// How an `answer` ended.
private enum Outcome<T: Sendable>: Sendable {
    case answered(T)
    case late
}

/// The first outcome given, handed on once.
private final class FirstOutcome<T: Sendable>: Sendable {
    private let continuation: Locked<CheckedContinuation<Outcome<T>, Never>?>

    init(_ continuation: CheckedContinuation<Outcome<T>, Never>) {
        self.continuation = Locked(continuation)
    }

    func give(_ outcome: Outcome<T>) {
        let taken = continuation.withValue { continuation -> CheckedContinuation<Outcome<T>, Never>? in
            defer { continuation = nil }
            return continuation
        }
        taken?.resume(returning: outcome)
    }
}

/// What `body` gives, run on a thread of its own whose stack is `bytes` (64 KB: a few hundred
/// frames), and waited for. Work that recurses with the depth of what it is given overflows it
/// and crashes the run, which a test thread's stack (8 MB on Linux) would hide.
func onSmallStack<T: Sendable>(_ bytes: Int = 64 * 1024, _ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
        let thread = Thread { continuation.resume(returning: body()) }
        thread.stackSize = bytes
        thread.start()
    }
}

/// How long a fake that "never answers" waits: well past every bound the SDK keeps, and short
/// enough that one nothing cancels cannot hold a run for long.
let hangNanoseconds: UInt64 = 20_000_000_000

/// A clock a test sets.
final class FakeClock: LicenseClock {
    private let value: Locked<Int>

    init(_ now: Int = NOW) {
        value = Locked(now)
    }

    func now() -> Int { value.current }
    func set(_ now: Int) { value.withValue { $0 = now } }
}

/// Monotonic time a test moves by hand: it stands still until `advance`, which wakes every sleeper
/// whose deadline it reaches. The SDK's bounds kept by it end exactly where a test says.
final class ManualTicker: Ticker {
    private struct Sleeper {
        let id: Int
        let deadline: UInt64
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State {
        var now: UInt64 = 0
        var sleepers: [Sleeper] = []
        var next = 0
    }

    private let state = Locked(State())

    func now() -> UInt64 { state.current.now }

    func sleep(until deadline: UInt64) async {
        let id = state.withValue { state -> Int in
            state.next += 1
            return state.next
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let wake = state.withValue { state -> Bool in
                    if deadline <= state.now || Task.isCancelled { return true }
                    state.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return false
                }
                if wake { continuation.resume() }
            }
        } onCancel: {
            let sleeper = state.withValue { state -> Sleeper? in
                guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return state.sleepers.remove(at: index)
            }
            sleeper?.continuation.resume()
        }
    }

    /// When each sleeper wakes, in ms from where this ticker started, soonest first.
    var deadlinesMs: [Double] {
        state.current.sleepers.map { Double($0.deadline) / 1_000_000 }.sorted()
    }

    /// Moves time on by `ms`, waking every sleeper whose deadline it reaches.
    func advance(ms: Int) {
        let woken = state.withValue { state -> [Sleeper] in
            state.now += UInt64(ms) * 1_000_000
            let now = state.now
            let due = state.sleepers.filter { $0.deadline <= now }
            state.sleepers.removeAll { $0.deadline <= now }
            return due
        }
        for sleeper in woken { sleeper.continuation.resume() }
    }
}

/// A registry stash in memory.
final class MemoryRegistry: RegistryStash {
    private let value = Locked<Int?>(nil)
    func readTrialStart() async throws -> Int? { value.current }
    func writeTrialStart(_ ms: Int) async throws { value.withValue { $0 = ms } }
    var stashed: Int? { value.current }
    func set(_ ms: Int?) { value.withValue { $0 = ms } }
}

/// A registry stash that can be read and written by nobody.
struct FailingRegistry: RegistryStash {
    struct Failure: Error {}
    func readTrialStart() async throws -> Int? { throw Failure() }
    func writeTrialStart(_ ms: Int) async throws { throw Failure() }
}

/// A stash item in memory (a Keychain item's stand-in): its data, a read that fails when told to,
/// and every add and update made.
final class MemoryStashItem: StashItem {
    struct Unreadable: Error {}

    private struct State {
        var data: Data?
        var unreadable = false
        var writes: [String] = []
    }

    private let state: Locked<State>

    init(_ text: String? = nil) {
        state = Locked(State(data: text.map { Data($0.utf8) }))
    }

    var text: String? { state.current.data.map { String(decoding: $0, as: UTF8.self) } }
    /// Every write, in order: `add <text>` or `update <text>`.
    var writes: [String] { state.current.writes }
    func failReads(_ on: Bool = true) { state.withValue { $0.unreadable = on } }

    func data() async throws -> Data? {
        let (unreadable, data) = state.withValue { ($0.unreadable, $0.data) }
        if unreadable { throw Unreadable() }
        return data
    }

    func add(_ data: Data) async throws {
        state.withValue { state in
            state.writes.append("add \(String(decoding: data, as: UTF8.self))")
            state.data = data
        }
    }

    func update(_ data: Data) async throws {
        state.withValue { state in
            state.writes.append("update \(String(decoding: data, as: UTF8.self))")
            state.data = data
        }
    }
}

/// A storage in memory with no `update` of its own (so the SDK reads, merges and writes): a read
/// that never settles, a read that fails, a write held inside the adapter with the whole state it
/// was handed, and writes that fail. A write from a task that was cancelled throws
/// `CancellationError`, as a real one cut short would: a licence check's save must not be one.
final class MemoryStorage: StorageAdapter {
    private struct State {
        var stored: StoredState?
        var hangNextRead = false
        var hungReads: [CheckedContinuation<StoredState?, Error>] = []
        var holdNextWrite = false
        var heldWrite: (state: StoredState, continuation: CheckedContinuation<Void, Never>)?
        var writes = 0
        var failWrites = false
        var reads = 0
        /// The read, counted from the first, that fails (`failRead`).
        var failReadAt: Int?
        /// The read, counted from the first, before which another process saves a state (`saveBeforeRead`).
        var savedBefore: (read: Int, state: StoredState)?
    }

    private let state: Locked<State>

    init(_ initial: StoredState? = nil) {
        state = Locked(State(stored: initial))
    }

    var stored: StoredState? { state.current.stored }
    var writes: Int { state.current.writes }
    /// Reads waiting on `releaseAll`.
    var hungReads: Int { state.current.hungReads.count }
    /// Whether a write is held inside the adapter (`holdNextWrite`).
    var holdingWrite: Bool { state.current.heldWrite != nil }

    func set(_ stored: StoredState?) { state.withValue { $0.stored = stored } }
    func failWrites(_ on: Bool = true) { state.withValue { $0.failWrites = on } }
    /// The next read never settles (until `releaseAll`): an adapter stuck on a dead disk.
    func hangNextRead() { state.withValue { $0.hangNextRead = true } }
    /// The `nth` read from now fails, as a file an antivirus scan holds does.
    func failRead(_ nth: Int) { state.withValue { $0.failReadAt = $0.reads + nth } }
    /// Just before the `nth` read from now, `stored` is saved, as by another process: that read,
    /// and every one after it, sees it.
    func saveBeforeRead(_ nth: Int, _ stored: StoredState) { state.withValue { $0.savedBefore = ($0.reads + nth, stored) } }
    /// The next write is held inside the adapter; `releaseWrite` lets it land.
    func holdNextWrite() { state.withValue { $0.holdNextWrite = true } }

    func releaseWrite() {
        let held = state.withValue { state -> (state: StoredState, continuation: CheckedContinuation<Void, Never>)? in
            defer { state.heldWrite = nil }
            if let held = state.heldWrite { state.stored = held.state }
            return state.heldWrite
        }
        held?.continuation.resume()
    }

    /// Lets every hung read finish, with what is stored then.
    func releaseAll() {
        let (reads, stored) = state.withValue { state in
            defer { state.hungReads = [] }
            return (state.hungReads, state.stored)
        }
        for read in reads { read.resume(returning: stored) }
        releaseWrite()
    }

    func read(readOnly: Bool) async throws -> StoredState? {
        let (fail, hang) = state.withValue { state -> (Bool, Bool) in
            state.reads += 1
            if let saved = state.savedBefore, saved.read == state.reads { state.stored = saved.state }
            if state.reads == state.failReadAt { return (true, false) }
            defer { state.hangNextRead = false }
            return (false, state.hangNextRead)
        }
        if fail { throw StorageError(code: "EBUSY", operation: "read", path: "memory") }
        if hang {
            return try await withCheckedThrowingContinuation { continuation in
                state.withValue { $0.hungReads.append(continuation) }
            }
        }
        return state.current.stored
    }

    func write(_ next: StoredState) async throws {
        if Task.isCancelled { throw CancellationError() }
        let (fail, hold) = state.withValue { state -> (Bool, Bool) in
            state.writes += 1
            defer { state.holdNextWrite = false }
            return (state.failWrites, state.holdNextWrite && !state.failWrites)
        }
        if fail { throw StorageError(code: "EBUSY", operation: "write", path: "memory") }
        if hold {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                state.withValue { $0.heldWrite = (next, continuation) }
            }
            return
        }
        state.withValue { $0.stored = next }
    }
}

/// A server a test scripts, recording every call: the action, the whole URL it was posted to, and
/// the body. A call from a task that was cancelled throws `CancellationError`, as a real one cut
/// short would.
final class FakeHTTP: HTTPAdapter {
    typealias Handler = @Sendable (LicenseJSON) async -> LicenseHTTPResponse

    struct Call: Sendable {
        var action: String
        var url: URL
        var body: LicenseJSON
    }

    private struct State {
        var handlers: [String: Handler] = [:]
        var calls: [Call] = []
        var fail = false
        var hang = false
        var hangsCancelled = 0
    }

    struct NetworkDown: Error {}

    private let state = Locked(State())

    func on(_ action: String, _ handler: @escaping Handler) {
        state.withValue { $0.handlers[action] = handler }
    }

    func on(_ action: String, status: Int, json: LicenseJSON) {
        on(action) { _ in LicenseHTTPResponse(status: status, json: json) }
    }

    func setFail(_ fail: Bool) { state.withValue { $0.fail = fail } }
    /// Never answer: a network that takes the connection and says nothing.
    func setHang(_ hang: Bool) { state.withValue { $0.hang = hang } }

    var calls: [Call] { state.current.calls }
    var actions: [String] { calls.map(\.action) }
    func count(_ action: String) -> Int { calls.filter { $0.action == action }.count }
    func called(_ action: String) -> Bool { count(action) > 0 }
    /// The body of the first `action` call.
    func body(_ action: String) -> LicenseJSON? { calls.first { $0.action == action }?.body }
    /// The URL the first `action` call was posted to.
    func url(_ action: String) -> URL? { calls.first { $0.action == action }?.url }
    /// How many calls that never answered saw the SDK's own bound cancel them.
    var hangsCancelled: Int { state.current.hangsCancelled }

    func post(_ url: URL, body: LicenseJSON, timeout: TimeInterval) async throws -> LicenseHTTPResponse {
        if Task.isCancelled { throw CancellationError() }
        let action = url.lastPathComponent
        let (fail, hang, handler) = state.withValue { state -> (Bool, Bool, Handler?) in
            state.calls.append(Call(action: action, url: url, body: body))
            return (state.fail, state.hang, state.handlers[action])
        }
        if fail { throw NetworkDown() }
        if hang {
            // Until the SDK's own bound gives up on it, and cancels it.
            try? await Task.sleep(nanoseconds: hangNanoseconds)
            if Task.isCancelled {
                state.withValue { $0.hangsCancelled += 1 }
                throw CancellationError()
            }
            throw NetworkDown()
        }
        guard let handler else { return LicenseHTTPResponse(status: 404, json: ["error": "unknown"]) }
        let response = await handler(body)
        if Task.isCancelled { throw CancellationError() }
        return response
    }
}

/// A fingerprinter with only `get()`: says nothing of what it hashes.
struct GetFingerprinter: Fingerprinter {
    let answer: @Sendable () async throws -> String

    init(_ fingerprint: String = "fp-test") {
        answer = { fingerprint }
    }

    init(answer: @escaping @Sendable () async throws -> String) {
        self.answer = answer
    }

    func get() async throws -> String { try await answer() }
}

/// A fingerprinter that says who the device is, and what its fingerprint hashes.
struct IdentifyingFingerprinter: Fingerprinter {
    let answer: @Sendable () async throws -> DeviceIdentity

    init(answer: @escaping @Sendable () async throws -> DeviceIdentity) {
        self.answer = answer
    }

    func get() async throws -> String {
        guard let fingerprint = try await answer().fingerprint else { throw FakeHTTP.NetworkDown() }
        return fingerprint
    }

    func identify(timeout: TimeInterval) async throws -> DeviceIdentity { try await answer() }
}

/// A fingerprinter that records the bound each read is given (`identify(timeout:)`), and never
/// tells who the device is, so nothing of it is kept and every read asks it again.
final class TimedFingerprinter: Fingerprinter {
    private let given = Locked<[TimeInterval]>([])

    /// The bound of each read, in order (seconds).
    var bounds: [TimeInterval] { given.current }

    func get() async throws -> String { throw FakeHTTP.NetworkDown() }

    func identify(timeout: TimeInterval) async throws -> DeviceIdentity {
        given.withValue { $0.append(timeout) }
        return DeviceIdentity(fingerprint: nil)
    }
}

/// A counter shared with a closure.
final class Counter: Sendable {
    private let value = Locked(0)
    @discardableResult func next() -> Int { value.withValue { $0 += 1; return $0 } }
    var count: Int { value.current }
}

/// A flag shared with a closure.
final class Flag: Sendable {
    private let value: Locked<Bool>
    init(_ on: Bool = false) { value = Locked(on) }
    var on: Bool { value.current }
    func set(_ on: Bool) { value.withValue { $0 = on } }
}

/// A string shared with a closure.
final class Shared<Value: Sendable>: Sendable {
    private let value: Locked<Value>
    init(_ value: Value) { self.value = Locked(value) }
    var current: Value { value.current }
    func set(_ next: Value) { value.withValue { $0 = next } }
}

/// A gate a task waits at until it is opened (whatever happens to the task meanwhile).
final class Gate: Sendable {
    private let state = Locked<(open: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let open = state.withValue { state -> Bool in
                if state.open { return true }
                state.waiters.append(continuation)
                return false
            }
            if open { continuation.resume() }
        }
    }

    func open() {
        let waiters = state.withValue { state -> [CheckedContinuation<Void, Never>] in
            state.open = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }
}

/// Yields until `condition` holds, or about `seconds` have passed, which fails the test: a state a
/// test waits for and never reaches is not left to show only in what it asserts after.
func eventually(
    _ seconds: TimeInterval = 5, sourceLocation: SourceLocation = #_sourceLocation, _ condition: @Sendable () -> Bool
) async {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() && Date() < deadline {
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    if !condition() {
        Issue.record("the state waited for was not reached within \(seconds) s of real time", sourceLocation: sourceLocation)
    }
}

/// Timings short enough for a test to wait them out.
let quick = Timing(lockGrace: 0.3, statusCheck: 0.25, machineId: 0.2, activateMachineId: 0.6, identifySlack: 0.3)
