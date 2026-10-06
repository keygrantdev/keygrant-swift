import Dispatch
import Foundation

/// A value behind a lock, for the little mutable state a `Sendable` type keeps.
final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    /// Runs `body` with the value, holding the lock. Never `await`s, so never holds it across a suspension.
    func withValue<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }

    var current: Value {
        withValue { $0 }
    }
}

/// `seconds` as nanoseconds for `Task.sleep`, never negative and never past what `UInt64` holds.
func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
    guard seconds > 0 else { return 0 }
    guard seconds < 1e9 else { return 1_000_000_000 * 1_000_000_000 }
    return UInt64(seconds * 1e9)
}

/// Sleeps for `seconds`, or less when the task is cancelled.
func pause(_ seconds: TimeInterval) async {
    try? await Task.sleep(nanoseconds: nanoseconds(seconds))
}

/// Monotonic time, and waiting on it: what the SDK's own bounds (`withTimeout`, the grace of
/// `CallQueue`) are kept by. The system's (`SystemTicker`), or one a test moves by hand, so the
/// edge of a bound is pinned to the nanosecond instead of raced against a real clock.
protocol Ticker: Sendable {
    /// A monotonic instant, in nanoseconds.
    func now() -> UInt64
    /// Returns once `now()` has reached `deadline`, or sooner when the task is cancelled.
    func sleep(until deadline: UInt64) async
}

/// The system's monotonic clock.
struct SystemTicker: Ticker {
    func now() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    func sleep(until deadline: UInt64) async {
        let now = self.now()
        guard deadline > now else { return }
        try? await Task.sleep(nanoseconds: deadline - now)
    }
}

/// `seconds` after `start`, as a deadline on a ticker: never past the end of time.
func deadline(_ start: UInt64, after seconds: TimeInterval) -> UInt64 {
    let (end, overflow) = start.addingReportingOverflow(nanoseconds(seconds))
    return overflow ? UInt64.max : end
}

/// The wall clock in whole milliseconds since 1970, as JavaScript's `Date.now()`.
func wallClockMs() -> Int {
    wholeNumber((Date().timeIntervalSince1970 * 1000).rounded(.down)) ?? 0
}

/// The SDK's own bound on a call was reached.
struct TimeoutError: Error, Sendable {}

/// `work`, or `TimeoutError` once `seconds` have passed on `ticker` (counted from this call),
/// whichever comes first: JavaScript's `Promise.race` against a timer. The work is cancelled at
/// the timeout but not waited for, so work that does not heed cancellation (a blocked read, an
/// adapter that ignores it) can never hold the caller past the bound.
func withTimeout<T: Sendable>(
    _ seconds: TimeInterval,
    on ticker: any Ticker = SystemTicker(),
    _ work: @escaping @Sendable () async throws -> T
) async throws -> T {
    let end = deadline(ticker.now(), after: seconds)
    let race = Race<T>()
    return try await withCheckedThrowingContinuation { continuation in
        race.begin(continuation)
        let worker = Task {
            do {
                race.finish(.success(try await work()))
            } catch {
                race.finish(.failure(error))
            }
        }
        let timer = Task {
            await ticker.sleep(until: end)
            // Cancelled: the work finished first, and the race is over.
            if Task.isCancelled { return }
            if race.finish(.failure(TimeoutError())) { worker.cancel() }
        }
        race.whenFinished { timer.cancel() }
    }
}

/// The one result of a `withTimeout`: the first to finish resumes the caller, the other is ignored.
private final class Race<T: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<T, Error>?
        var finished = false
        var onFinish: (@Sendable () -> Void)?
    }

    private let state = Locked(State())

    func begin(_ continuation: CheckedContinuation<T, Error>) {
        state.withValue { $0.continuation = continuation }
    }

    /// Resumes the caller with `result` when nothing has yet; whether this was the first.
    @discardableResult
    func finish(_ result: Result<T, Error>) -> Bool {
        let taken = state.withValue { state -> (CheckedContinuation<T, Error>?, (@Sendable () -> Void)?)? in
            guard !state.finished else { return nil }
            state.finished = true
            defer {
                state.continuation = nil
                state.onFinish = nil
            }
            return (state.continuation, state.onFinish)
        }
        guard let taken else { return false }
        taken.0?.resume(with: result)
        taken.1?()
        return true
    }

    func whenFinished(_ action: @escaping @Sendable () -> Void) {
        let now = state.withValue { state -> Bool in
            if state.finished { return true }
            state.onFinish = action
            return false
        }
        if now { action() }
    }
}

/// `body`, run on a thread of its own rather than the task's: for blocking file system calls
/// (an `F_FULLFSYNC` can take a while), and so a bound can abandon one that hangs. Handed to
/// `dispatch` with the quality of service `ioQoS` gives the task waiting on it: run on the
/// system's global queue of that class, unless a test dispatches it itself.
func blocking<T: Sendable>(
    _ body: @escaping @Sendable () throws -> T,
    dispatch: (DispatchQoS.QoSClass, @escaping @Sendable () -> Void) -> Void = { qos, work in
        DispatchQueue.global(qos: qos).async { work() }
    }
) async throws -> T {
    let qos = ioQoS(Task.currentPriority)
    return try await withCheckedThrowingContinuation { continuation in
        dispatch(qos) {
            continuation.resume(with: Result { try body() })
        }
    }
}

/// The quality of service the file reads and writes of a task of `priority` run at: its own
/// class (a task priority is the value of the class it runs at) when that is above
/// user-initiated, else user-initiated. Never lower: the calls on a `License` run one at a time,
/// so a check made at a low priority holds up every call behind it (an activation the customer
/// is waiting on) for as long as its I/O takes, and on macOS a background class's I/O is throttled.
func ioQoS(_ priority: TaskPriority) -> DispatchQoS.QoSClass {
    priority.rawValue > TaskPriority.userInitiated.rawValue ? .userInteractive : .userInitiated
}

// MARK: - one call at a time

/// Runs a `License`'s calls one after another (the reference's `serial`).
///
/// A call waits for the one before it to settle, but not past that call's HTTP bound plus the
/// lock grace from when that one STARTED running. Every request is bounded, but the storage,
/// fingerprint and registry adapters are not (cutting a storage write short could leave it
/// half-written), so a call stuck on one is left to finish on its own, and the calls behind it go
/// ahead READ-ONLY for as long as any call before them is unsettled: a write of theirs could be
/// reverted by the stuck call's late one, which carries a whole state taken before them.
///
/// Each call runs in a task of its own, so cancelling the task that awaits it does not cut a
/// licence check (and its save) short; the caller still waits for its bounded answer.
final class CallQueue: Sendable {
    private struct State {
        var last: CallTicket
        /// Calls running with writes allowed that have not settled yet.
        var writing = 0
    }

    private let state: Locked<State>
    /// The HTTP bound plus the lock grace.
    private let grace: TimeInterval
    /// What the grace is kept by.
    private let ticker: any Ticker

    init(grace: TimeInterval, ticker: any Ticker = SystemTicker()) {
        state = Locked(State(last: CallTicket(finished: true)))
        self.grace = grace
        self.ticker = ticker
    }

    /// `work` once every call queued before it has settled (or overrun its grace), told whether it
    /// must run read-only.
    func run<T: Sendable>(_ work: @escaping @Sendable (_ readOnly: Bool) async -> T) async -> T {
        let ticket = CallTicket(finished: false)
        let previous = state.withValue { state -> CallTicket in
            defer { state.last = ticket }
            return state.last
        }
        let call = Task { () async -> T in
            // The grace runs from when the call before started, however late this one was queued.
            let graceEnds = await previous.graceDeadline()
            await previous.settled(orUntil: graceEnds, on: self.ticker)
            let readOnly = self.state.withValue { state -> Bool in
                if state.writing > 0 { return true }
                state.writing += 1
                return false
            }
            ticket.start(graceEndsAt: deadline(self.ticker.now(), after: self.grace))
            let result = await work(readOnly)
            if !readOnly { self.state.withValue { $0.writing -= 1 } }
            ticket.settle()
            return result
        }
        return await call.value
    }

    /// `run`, for work that may throw.
    func runThrowing<T: Sendable>(_ work: @escaping @Sendable (_ readOnly: Bool) async throws -> T) async throws -> T {
        let result: Result<T, Error> = await run { readOnly in
            do {
                return .success(try await work(readOnly))
            } catch {
                return .failure(error)
            }
        }
        return try result.get()
    }
}

/// One call's place in the queue: when it started (and so when its grace ends), and when it settled.
final class CallTicket: Sendable {
    private struct State {
        var graceEndsAt: UInt64?
        var startWaiters: [CheckedContinuation<UInt64, Never>] = []
        var settled = false
        var settleWaiters: [SettleWaiter] = []
    }

    private let state: Locked<State>

    /// A ticket for a call not yet started, or (`finished`) for none at all: started long ago, settled.
    init(finished: Bool) {
        state = Locked(State(graceEndsAt: finished ? 0 : nil, settled: finished))
    }

    /// When this call's grace ends, once it has started.
    func graceDeadline() async -> UInt64 {
        await withCheckedContinuation { (continuation: CheckedContinuation<UInt64, Never>) in
            let ready = state.withValue { state -> UInt64? in
                if let deadline = state.graceEndsAt { return deadline }
                state.startWaiters.append(continuation)
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    func start(graceEndsAt deadline: UInt64) {
        let waiters = state.withValue { state -> [CheckedContinuation<UInt64, Never>] in
            state.graceEndsAt = deadline
            defer { state.startWaiters = [] }
            return state.startWaiters
        }
        for waiter in waiters { waiter.resume(returning: deadline) }
    }

    /// Returns once this call has settled, or at `deadline` on `ticker`, whichever comes first.
    func settled(orUntil deadline: UInt64, on ticker: any Ticker) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let waiter = SettleWaiter(continuation)
            let settled = state.withValue { state -> Bool in
                if state.settled { return true }
                state.settleWaiters.append(waiter)
                return false
            }
            if settled {
                waiter.resume()
                return
            }
            waiter.keep(timer: Task {
                await ticker.sleep(until: deadline)
                waiter.resume()
            })
        }
    }

    func settle() {
        let waiters = state.withValue { state -> [SettleWaiter] in
            state.settled = true
            defer { state.settleWaiters = [] }
            return state.settleWaiters
        }
        for waiter in waiters { waiter.resume() }
    }
}

/// A call waiting on the one before it: resumed once, by its settling or by the grace timer,
/// whichever comes first; the timer is cancelled when the settling wins.
private final class SettleWaiter: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Void, Never>?
        var timer: Task<Void, Never>?
    }

    private let state: Locked<State>

    init(_ continuation: CheckedContinuation<Void, Never>) {
        state = Locked(State(continuation: continuation))
    }

    func keep(timer: Task<Void, Never>) {
        let resumed = state.withValue { state -> Bool in
            if state.continuation == nil { return true }
            state.timer = timer
            return false
        }
        if resumed { timer.cancel() }
    }

    func resume() {
        let taken = state.withValue { state -> (CheckedContinuation<Void, Never>?, Task<Void, Never>?) in
            defer {
                state.continuation = nil
                state.timer = nil
            }
            return (state.continuation, state.timer)
        }
        taken.1?.cancel()
        taken.0?.resume()
    }
}
