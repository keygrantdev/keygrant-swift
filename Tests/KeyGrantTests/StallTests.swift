import Foundation
import Testing

@testable import KeyGrant

/// One call at a time, every request bounded, and READ-ONLY behind a call that has not finished.
/// The edges of the bounds on a clock the test moves by hand (`ManualTicker`), with the SDK's own
/// bounds: a 15 s HTTP bound and a 15 s lock grace. The rest in real time, cut short: an HTTP
/// bound of 0.2 s and a lock grace of 0.3 s, so a call waits at most 0.5 s for the one before it.
@Suite("one call at a time", .serialized, suiteTimeLimit)
struct StallTests {
    static let httpTimeout: TimeInterval = 0.2
    static let grace = httpTimeout + quick.lockGrace

    func licensed(_ h: Harness) {
        h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: h.sign(), lastSeen: NOW, checkedMajor: 1))
    }

    func harness(_ initial: StoredState? = nil, httpTimeout: TimeInterval = httpTimeout) throws -> Harness {
        try Harness(initial, httpTimeout: httpTimeout, timing: quick)
    }

    /// `call` started in a task of its own, and whether it has answered yet.
    func started<T: Sendable>(_ call: @escaping @Sendable () async -> T) -> (task: Task<T, Never>, answered: Flag) {
        let answered = Flag()
        let task = Task { () -> T in
            let answer = await call()
            answered.set(true)
            return answer
        }
        return (task, answered)
    }

    /// Moves `ticker` to 1 ms before `deadlineMs` and checks `answered` is still unset; then onto it.
    func edge(_ ticker: ManualTicker, _ deadlineMs: Double, _ answered: Flag) async throws {
        await eventually { ticker.deadlinesMs == [deadlineMs] }
        #expect(ticker.deadlinesMs == [deadlineMs])
        ticker.advance(ms: Int(deadlineMs - Double(ticker.now()) / 1_000_000) - 1)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(!answered.on, "answered 1 ms before \(deadlineMs) ms")
        ticker.advance(ms: 1)
    }

    @Test func boundsACallWhoseHTTPAdapterNeverAnswersSoTheCallsBehindItStillAnswer() async throws {
        let ticker = ManualTicker()
        let h = try Harness(timing: Timing(ticker: ticker))
        licensed(h)
        h.http.setHang(true)
        let (refreshed, _) = started { await h.license.refresh() }
        await eventually { h.http.count("validate") == 1 }
        let (later, _) = started { await h.license.status() }
        // The refresh's request is bounded at 15 s; the status behind it waits at most to the end
        // of the refresh's grace, 30 s.
        await eventually { ticker.deadlinesMs == [15_000, 30_000] }
        #expect(ticker.deadlinesMs == [15_000, 30_000])
        ticker.advance(ms: 15_000)
        #expect(await answer { await refreshed.value } == LicenseStatus(state: .licensed, key: KEY))
        // The refresh settled at its bound: the status went ahead then, writing as it may.
        #expect(await answer { await later.value } == LicenseStatus(state: .licensed, key: KEY))
        #expect(ticker.deadlinesMs.isEmpty)
        // The request the bound gave up on is cancelled, not left running.
        await eventually { h.http.hangsCancelled == 1 }
        #expect(h.http.hangsCancelled == 1)
    }

    @Test func boundsEveryRequestByTheConfiguredTimeoutWhenTheCallNamesNone() async throws {
        let ticker = ManualTicker()
        let h = try Harness(timing: Timing(ticker: ticker))
        h.http.setHang(true)
        let (activating, answered) = started { await h.license.activate(KEY) }
        try await edge(ticker, 15_000, answered)
        #expect(await answer { await activating.value } == .failed(.network))
        await eventually { h.http.hangsCancelled == 1 }
        #expect(h.http.hangsCancelled == 1)
    }

    @Test func letsALaterCallGoAheadReadOnlyWhenOneIsStuckOnStorage() async throws {
        let ticker = ManualTicker()
        let h = try Harness(timing: Timing(ticker: ticker))
        licensed(h)
        h.storage.hangNextRead()
        let stuck = Task { await h.license.status() }
        await eventually { h.storage.hungReads == 1 }
        // The stuck call started at 0: its grace, its HTTP bound and the lock grace, ends at 30 s.
        let (later, answered) = started { await h.license.status() }
        try await edge(ticker, 30_000, answered)
        // Answered from storage behind the stuck call, and saying so.
        #expect(await answer { await later.value } == LicenseStatus(state: .licensed, key: KEY, isStalled: true))
        h.storage.releaseAll()
        _ = await answer { await stuck.value }
    }

    /// A refresh() whose refusal write is held inside the adapter, then time past its grace:
    /// whatever is called next runs read-only behind it.
    func behindAStuckWrite(_ stored: (Harness) -> StoredState) async throws -> (Harness, Task<LicenseStatus, Never>) {
        let h = try harness()
        h.storage.set(stored(h))
        h.http.on("validate", status: 403, json: ["error": "revoked"])
        h.storage.holdNextWrite()
        let stuck = Task { await h.license.refresh() }
        await eventually { h.storage.writes == 1 }
        #expect(h.storage.writes == 1)
        try await Task.sleep(nanoseconds: nanoseconds(Self.grace + 0.05))
        return (h, stuck)
    }

    func licensedState(_ h: Harness) -> StoredState {
        StoredState(key: KEY, activationId: "act_1", lease: h.sign(), lastSeen: NOW, checkedMajor: 1)
    }

    @Test func letsNoCallBehindAStuckOneWriteWhatItsLateWriteCouldRevert() async throws {
        let (h, stuck) = try await behindAStuckWrite(licensedState)
        let lease = h.stored?.lease
        let renewed = h.sign()
        h.http.on("validate", status: 200, json: ["lease": .string(renewed), "activationId": "act_1"])
        // Read-only: the lease still stored, licensed; not asked, nothing written.
        #expect(await h.license.refresh() == LicenseStatus(state: .licensed, key: KEY, isStalled: true))
        #expect(h.http.count("validate") == 1)
        #expect(h.storage.writes == 1)
        #expect(h.stored?.lease == lease)
        h.storage.releaseWrite()
        #expect(await answer { await stuck.value } == LicenseStatus(state: .invalid, reason: .revoked, key: KEY))
        #expect(h.stored?.refused == .revoked)
        // The stuck call settled: the next call writes again, and heals.
        #expect(await h.license.refresh() == LicenseStatus(state: .licensed, key: KEY))
        #expect(h.http.count("validate") == 2)
    }

    @Test func timesTheGraceFromWhenTheStuckCallStartedHoweverLateTheNextIsQueued() async throws {
        let ticker = ManualTicker()
        let h = try Harness(timing: Timing(ticker: ticker))
        licensed(h)
        h.http.on("validate", status: 403, json: ["error": "revoked"])
        h.storage.holdNextWrite()
        let stuck = Task { await h.license.refresh() }
        await eventually { h.storage.writes == 1 && ticker.deadlinesMs.isEmpty }
        #expect(h.storage.writes == 1)
        // Well into the stuck call's grace (from 0 to 30 s), the next is queued: it goes ahead when
        // that grace is up, not a whole grace after it was queued.
        ticker.advance(ms: 18_000)
        let (next, answered) = started { await h.license.status() }
        try await edge(ticker, 30_000, answered)
        #expect(await answer { await next.value } == LicenseStatus(state: .licensed, key: KEY, isStalled: true))
        h.storage.releaseWrite()
        _ = await answer { await stuck.value }
    }

    @Test func answersActivateNetworkBehindAStuckCallNoRequestNoWrite() async throws {
        let (h, stuck) = try await behindAStuckWrite(licensedState)
        #expect(await h.license.activate(KEY) == .failed(.network))
        #expect(!h.http.called("activate"))
        #expect(h.storage.writes == 1)
        h.storage.releaseWrite()
        _ = await answer { await stuck.value }
    }

    @Test func refusesToDeactivateBehindAStuckCallReleasingNothing() async throws {
        let (h, stuck) = try await behindAStuckWrite(licensedState)
        await #expect(throws: LicenseCallError.previousCallUnfinished) { try await h.license.deactivate() }
        #expect(!h.http.called("deactivate"))
        #expect(h.stored?.key == KEY)
        #expect(h.storage.writes == 1)
        h.storage.releaseWrite()
        _ = await answer { await stuck.value }
    }

    @Test func answersStartTrialWithTheStoredTrialBehindAStuckCall() async throws {
        let (h, stuck) = try await behindAStuckWrite { h in
            var state = licensedState(h)
            state.trialStart = NOW
            state.trialEndsAt = NOW + 5 * DAY
            state.trialLease = h.signer.trialLease(device: "fp-test", ttlSeconds: 5 * 24 * 3600)
            return state
        }
        #expect(await h.license.startTrial() == LicenseStatus(state: .trial, trialDaysLeft: 5, trialEndsAt: NOW + 5 * DAY, isStalled: true))
        #expect(!h.http.called("trial"))
        #expect(h.storage.writes == 1)
        h.storage.releaseWrite()
        _ = await answer { await stuck.value }
    }

    @Test func answersAStoredRefusalBehindAStuckCallWithoutAsking() async throws {
        let (h, stuck) = try await behindAStuckWrite { _ in StoredState(key: KEY, activationId: "act_1", lastSeen: NOW, refused: .revoked) }
        #expect(await h.license.status() == LicenseStatus(state: .invalid, reason: .revoked, key: KEY, isStalled: true))
        #expect(h.http.count("validate") == 1)
        h.storage.releaseWrite()
        _ = await answer { await stuck.value }
    }

    @Test func answersAnExpiredStoredLeaseAsExpiredOfflineBehindAStuckCallWithoutAsking() async throws {
        let (h, stuck) = try await behindAStuckWrite { h in
            StoredState(key: KEY, activationId: "act_1", lease: h.sign(ttl: 3600, at: NOW - 2 * DAY), lastSeen: NOW)
        }
        #expect(await h.license.status() == LicenseStatus(state: .expired, reason: .offline, key: KEY, isStalled: true))
        #expect(h.http.count("validate") == 1)
        h.storage.releaseWrite()
        _ = await answer { await stuck.value }
    }

    @Test func runsThreeCallsQueuedAtOnceOnASlowNetworkOneAfterAnotherEachAsking() async throws {
        // Each answer takes 0.3 s, well inside the bounds (kept on a clock that does not move
        // here): none goes ahead of the one before it.
        let h = try Harness(timing: Timing(ticker: ManualTicker()))
        let lease = h.sign()
        h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: lease, lastSeen: NOW, checkedMajor: 1))
        let inFlight = Counter()
        let most = Shared(0)
        let finished = Counter()
        h.http.on("validate") { _ in
            let now = inFlight.next() - finished.count
            if now > most.current { most.set(now) }
            try? await Task.sleep(nanoseconds: 300_000_000)
            finished.next()
            return LicenseHTTPResponse(status: 200, json: ["lease": .string(lease), "activationId": "act_1"])
        }
        let answers = try #require(await answer { () -> [LicenseStatus] in
            async let first = h.license.refresh()
            async let second = h.license.refresh()
            async let third = h.license.refresh()
            return await [first, second, third]
        })
        #expect(answers.allSatisfy { $0 == LicenseStatus(state: .licensed, key: KEY) })
        #expect(h.http.count("validate") == 3)
        #expect(most.current == 1)
    }

    @Test func finishesACallWhoseCallerWasCancelled() async throws {
        // Its bounds on a clock that does not move: only a cancellation could cut the call short.
        let h = try Harness(timing: Timing(ticker: ManualTicker()))
        h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: h.sign(ttl: 3600, at: NOW - 2 * DAY), lastSeen: NOW))
        let fresh = h.sign()
        h.http.on("validate") { _ in
            try? await Task.sleep(nanoseconds: 50_000_000)
            return LicenseHTTPResponse(status: 200, json: ["lease": .string(fresh), "activationId": "act_1"])
        }
        // The caller is cancelled before it calls: the call starts in a cancelled task.
        let gate = Gate()
        let caller = Task { () -> LicenseStatus in
            await gate.wait()
            return await h.license.status()
        }
        caller.cancel()
        gate.open()
        // A licence check is not cut short half-done: the server is asked and answers (a request
        // made from the cancelled task would throw), and the renewal lands, saved (as would a
        // write made from it).
        #expect(await answer { await caller.value } == LicenseStatus(state: .licensed, key: KEY))
        #expect(h.http.count("validate") == 1)
        #expect(h.stored?.lease == fresh)
    }

    @Test func hasTheFakesRefuseARequestAndAWriteFromACancelledTask() async throws {
        // What makes the test above worth its name: run in the caller's task, the call would fail.
        let h = try harness()
        let attempt = Task { () -> (request: Bool, write: Bool) in
            withUnsafeCurrentTask { $0?.cancel() }
            let request = (try? await h.http.post(apiBase, body: .null, timeout: 1)) == nil
            let write = (try? await h.storage.write(StoredState(key: KEY))) == nil
            return (request, write)
        }
        let refused = try #require(await answer { await attempt.value })
        #expect(refused.request && refused.write)
        #expect(h.stored == nil)
    }
}
