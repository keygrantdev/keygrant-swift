import Foundation
import Testing

@testable import KeyGrant

/// `status()` heals a trial whose lease does not verify while its stored end is still ahead: it
/// asks for the trial again (the reference's `healTrial`).
@Suite("a trial whose lease does not verify while its stored end is ahead", suiteTimeLimit)
struct TrialHealTests {
    /// A trial stored with a lease signed by another key: one the product signed before a rotation.
    func rotated(
        fingerprinter: (any Fingerprinter)? = nil, timing: Timing = .standard, _ edit: (inout StoredState) -> Void = { _ in }
    ) throws -> Harness {
        let h = try Harness(fingerprinter: fingerprinter, timing: timing)
        let stale = Signer().trialLease(device: "fp-test", ttlSeconds: 5 * 24 * 3600)
        var state = StoredState(trialStart: NOW - 2 * DAY, trialEndsAt: NOW + 5 * DAY, trialLease: stale, lastSeen: NOW)
        edit(&state)
        h.storage.set(state)
        return h
    }

    /// The server's trial: its start, its end, and the lease it signed (none when nil).
    func answering(_ h: Harness, start: Int, end: Int, lease: String?) {
        var json: [String: LicenseJSON] = ["trialStart": .number(Double(start)), "trialEndsAt": .number(Double(end))]
        if let lease { json["lease"] = .string(lease) }
        h.http.on("trial", status: 200, json: .object(json))
    }

    @Test func asksForTheTrialAgainAndTheServersFreshLeaseRunsIt() async throws {
        let h = try rotated()
        let fresh = h.signer.trialLease(device: "fp-test", ttlSeconds: 5 * 24 * 3600)
        answering(h, start: NOW - 2 * DAY, end: NOW + 5 * DAY, lease: fresh)
        #expect(await h.license.status() == LicenseStatus(state: .trial, trialDaysLeft: 5, trialEndsAt: NOW + 5 * DAY))
        #expect(h.http.count("trial") == 1)
        #expect(h.stored?.trialLease == fresh)
        // Healed: no wait before asking again is recorded.
        #expect(h.stored?.backoffSince == nil && h.stored?.backoffMs == nil)
        // Asked as startTrial() asks: the device's own fingerprint, and the earliest start it holds.
        #expect(h.http.body("trial") == ["fingerprint": "fp-test", "clientStart": .number(Double(NOW - 2 * DAY))])
        // Healed: the next status() needs no ask.
        _ = await h.license.status()
        #expect(h.http.count("trial") == 1)
    }

    @Test func startsTheWaitByTheDeviceClockNotTheGuard() async throws {
        // The guard is a day ahead of the device clock (the clock was put back).
        let h = try rotated { $0.lastSeen = NOW + DAY }
        h.http.setFail(true)
        #expect(await h.license.status() == LicenseStatus(state: .expired, reason: .trial))
        #expect(h.stored?.backoffSince == NOW && h.stored?.backoffMs == Waits.retryUnansweredMs)
        // Within the wait by the device clock: no request.
        h.clock.set(NOW + Waits.retryUnansweredMs - 1)
        _ = await h.license.status()
        #expect(h.http.count("trial") == 1)
    }

    @Test func savesItsAnswerOverTheTrialAnswerItSawEvenOneStampedLater() async throws {
        // A trial answer stored while the clock ran ahead: stamped later than the guard is now
        // (it was brought back since). The asker saw it, so its own answer saves over it.
        let h = try Harness(StoredState(
            trialStart: NOW - 2 * DAY, trialEndsAt: NOW + DAY, trialLease: "OLD", trialAt: NOW + 2 * HOUR, lastSeen: NOW
        ))
        let lease = h.signer.trialLease(device: "fp-test", kind: nil, ttlSeconds: 5 * 24 * 3600)
        answering(h, start: NOW - 2 * DAY, end: NOW + 5 * DAY, lease: lease)
        #expect(await h.license.startTrial() == LicenseStatus(state: .trial, trialDaysLeft: 5, trialEndsAt: NOW + 5 * DAY))
        #expect(h.stored?.trialEndsAt == NOW + 5 * DAY && h.stored?.trialLease == lease && h.stored?.trialAt == NOW)
    }

    @Test func healsALeaseFromBeforeTrialLeasesRanToTheTrialsEnd() async throws {
        let h = try Harness()
        // Seven days on a fourteen-day trial, as KeyGrant once signed them.
        let capped = h.signer.trialLease(device: "fp-test", ttlSeconds: 7 * 24 * 3600)
        h.storage.set(StoredState(trialStart: NOW, trialEndsAt: NOW + 14 * DAY, trialLease: capped, lastSeen: NOW))
        h.clock.set(NOW + 8 * DAY)
        let fresh = h.signer.trialLease(device: "fp-test", ttlSeconds: 6 * 24 * 3600, at: NOW + 8 * DAY)
        answering(h, start: NOW, end: NOW + 14 * DAY, lease: fresh)
        #expect(await h.license.status() == LicenseStatus(state: .trial, trialDaysLeft: 6, trialEndsAt: NOW + 14 * DAY))
    }

    @Test func answersExpiredAndWaitsAMinuteWhenTheServerCannotBeReached() async throws {
        let h = try rotated()
        h.http.setFail(true)
        #expect(await h.license.status() == LicenseStatus(state: .expired, reason: .trial))
        #expect(h.stored?.backoffSince == NOW && h.stored?.backoffMs == Waits.retryUnansweredMs)
        // Within the wait, no ask: a status() offline does not pay a timeout each time.
        _ = await h.license.status()
        #expect(h.http.count("trial") == 1)
        h.clock.set(NOW + Waits.retryUnansweredMs)
        _ = await h.license.status()
        #expect(h.http.count("trial") == 2)
    }

    @Test func waitsAnHourWhenTheServerAnswersWithNothingThisBuildCanVerify() async throws {
        let h = try rotated()
        let stale = try #require(h.stored?.trialLease)
        // A build carrying a key the product no longer signs with: the answer cannot verify either.
        // Signed with another foreign key than the stored lease, so the two differ.
        let stillStale = Signer().trialLease(device: "fp-test", ttlSeconds: 5 * 24 * 3600)
        #expect(stillStale != stale)
        answering(h, start: NOW - 2 * DAY, end: NOW + 5 * DAY, lease: stillStale)
        #expect(await h.license.status() == LicenseStatus(state: .expired, reason: .trial))
        #expect(h.stored?.backoffSince == NOW && h.stored?.backoffMs == Waits.askAgainMs)
        // Neither verifies, so nothing is kept over the server's: its lease is the one stored.
        #expect(h.stored?.trialLease == stillStale)
    }

    @Test(arguments: [503, 429, 400])
    func waitsAnHourWhenTheServerAnswersWithoutATrial(status: Int) async throws {
        let h = try rotated()
        h.http.on("trial", status: status, json: ["error": "unavailable"])
        #expect(await h.license.status() == LicenseStatus(state: .expired, reason: .trial))
        #expect(h.stored?.backoffSince == NOW && h.stored?.backoffMs == Waits.askAgainMs)
    }

    @Test func takesTheServersWordThatTheTrialIsOver() async throws {
        let h = try rotated()
        answering(h, start: NOW - 9 * DAY, end: NOW - 2 * DAY, lease: nil)
        #expect(await h.license.status() == LicenseStatus(state: .expired, reason: .trial))
        #expect(h.stored?.trialEndsAt == NOW - 2 * DAY && h.stored?.trialStart == NOW - 9 * DAY)
        #expect(h.stored?.backoffMs == Waits.askAgainMs)
    }

    @Test func asksNothingOnceTheStoredEndHasPassedOrWhenTheLeaseVerifies() async throws {
        let over = try rotated { state in
            state.trialStart = NOW - 9 * DAY
            state.trialEndsAt = NOW - 1
        }
        #expect(await over.license.status() == LicenseStatus(state: .expired, reason: .trial))
        let valid = try Harness()
        let lease = valid.signer.trialLease(device: "fp-test", ttlSeconds: 5 * 24 * 3600)
        valid.storage.set(StoredState(trialStart: NOW - 2 * DAY, trialEndsAt: NOW + 5 * DAY, trialLease: lease, lastSeen: NOW))
        #expect(await valid.license.status().state == .trial)
        #expect(!over.http.called("trial") && !valid.http.called("trial"))
    }

    @Test func asksNothingWhenTheStoredEndIsExactlyNow() async throws {
        let h = try rotated { $0.trialEndsAt = NOW }
        #expect(await h.license.status() == LicenseStatus(state: .expired, reason: .trial))
        #expect(!h.http.called("trial"))
    }

    @Test func asksAgainWithinTheWaitWhenForced() async throws {
        let h = try rotated()
        h.http.setFail(true)
        _ = await h.license.status()
        _ = await h.license.status()
        #expect(h.http.count("trial") == 1)
        #expect(await h.license.refresh() == LicenseStatus(state: .expired, reason: .trial))
        #expect(h.http.count("trial") == 2)
    }

    @Test func doesNotAskAgainAfterTheAnswerStartTrialGot() async throws {
        let h = try Harness()
        answering(h, start: NOW - 2 * DAY, end: NOW + 5 * DAY, lease: Signer().trialLease(device: "fp-test", ttlSeconds: 5 * 24 * 3600))
        #expect(await h.license.startTrial() == LicenseStatus(state: .expired, reason: .trial))
        #expect(h.http.count("trial") == 1)
        #expect(h.stored?.backoffSince == nil)
    }

    @Test func neitherAsksNorWritesBehindACallThatHasNotFinished() async throws {
        let ticker = ManualTicker()
        let h = try rotated(timing: Timing(ticker: ticker))
        h.storage.hangNextRead()
        let stuck = Task { await h.license.status() }
        await eventually { h.storage.hungReads == 1 }
        let later = Task { await h.license.status() }
        await eventually { ticker.deadlinesMs == [30_000] }
        ticker.advance(ms: 30_000)
        #expect(await answer { await later.value } == LicenseStatus(state: .expired, reason: .trial, isStalled: true))
        #expect(!h.http.called("trial"))
        // The call stuck on its read has written nothing yet, and the one behind it writes nothing.
        #expect(h.storage.writes == 0)
        h.storage.releaseAll()
        _ = await answer { await stuck.value }
    }

    @Test func boundsTheAskAsAStatusCheckIsBounded() async throws {
        let ticker = ManualTicker()
        let h = try rotated(timing: Timing(ticker: ticker))
        h.http.setHang(true)
        let answered = Flag()
        let status = Task { () -> LicenseStatus in
            let status = await h.license.status()
            answered.set(true)
            return status
        }
        // A status check's 5 s, not a request's 15 s.
        await eventually { ticker.deadlinesMs == [5_000] }
        #expect(ticker.deadlinesMs == [5_000])
        ticker.advance(ms: 4_999)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(!answered.on, "answered before its bound")
        ticker.advance(ms: 1)
        #expect(await answer { await status.value } == LicenseStatus(state: .expired, reason: .trial))
        #expect(h.stored?.backoffSince == NOW && h.stored?.backoffMs == Waits.retryUnansweredMs)
    }

    @Test func readsTheDeviceForItWithTheStatusBoundNotAnActivations() async throws {
        let ticker = ManualTicker()
        let never = GetFingerprinter {
            try? await Task.sleep(nanoseconds: hangNanoseconds)
            throw CancellationError()
        }
        let h = try rotated(fingerprinter: never, timing: Timing(ticker: ticker))
        let status = Task { await h.license.status() }
        // The lease's check reads the device for at most 2 s...
        await eventually { ticker.deadlinesMs == [2_000] }
        ticker.advance(ms: 2_000)
        // ...and the ask for the trial for 2 s more, as a status() reads it: not an activation's 10 s.
        await eventually { ticker.deadlinesMs == [4_000] }
        #expect(ticker.deadlinesMs == [4_000])
        ticker.advance(ms: 2_000)
        // A device that cannot be told asks nothing: as offline.
        #expect(await answer { await status.value } == LicenseStatus(state: .expired, reason: .trial))
        #expect(!h.http.called("trial"))
        #expect(h.stored?.backoffSince == NOW && h.stored?.backoffMs == Waits.retryUnansweredMs)
    }
}
