import Foundation
import Testing

@testable import KeyGrant

/// A running trial reports its launch from `status()`, at most once a day, in the background.
@Suite("a running trial reports its launch", suiteTimeLimit)
struct LaunchReportTests {
    static let trial = LicenseStatus(state: .trial, trialDaysLeft: 5, trialEndsAt: NOW + 5 * DAY)

    /// A running trial (its lease valid), with `edit` on top: no trial answer or report stamped
    /// unless given.
    func running(_ h: Harness, _ edit: (inout StoredState) -> Void = { _ in }) -> StoredState {
        let lease = h.signer.trialLease(device: "fp-test", kind: nil, ttlSeconds: 5 * 24 * 3600)
        var state = StoredState(trialStart: NOW - 2 * DAY, trialEndsAt: NOW + 5 * DAY, trialLease: lease, lastSeen: NOW)
        edit(&state)
        return state
    }

    /// Beyond the `trialReportDue` vectors (ConformancePurchaseTests): a stamp no clock could reach
    /// does not overflow the difference.
    @Test func isDueOnAStampNoClockCouldReachWithoutOverflowing() {
        #expect(trialReportDue(StoredState(trialReportedAt: Int.min), now: NOW))
        #expect(trialReportDue(StoredState(trialAt: Int.min, trialReportedAt: Int.min), now: Int.max))
    }

    @Test func fromStatusStampedFirstThenPostedInTheBackgroundAsStartTrialWouldItsAnswerNotRead() async throws {
        let h = try Harness()
        h.storage.set(running(h))
        h.http.on("trial", status: 200, json: ["trialStart": .number(Double(NOW - 9 * DAY)), "trialEndsAt": .number(Double(NOW + 30 * DAY))])
        #expect(await h.license.status() == Self.trial)
        #expect(h.stored?.trialReportedAt == NOW)
        await h.license.launchReportSettled()
        #expect(h.http.actions == ["trial"])
        #expect(h.http.body("trial") == ["fingerprint": "fp-test", "clientStart": .number(Double(NOW - 2 * DAY))])
        // The answer is not read: the stored trial is as it was.
        #expect(h.stored?.trialStart == NOW - 2 * DAY && h.stored?.trialEndsAt == NOW + 5 * DAY)
    }

    @Test func sendsTheFingerprintsKindAndReadsNoStash() async throws {
        let h = try Harness(fingerprinter: IdentifyingFingerprinter { DeviceIdentity(fingerprint: "fp-test", kind: .machine) })
        h.registry.set(NOW - 9 * DAY)
        h.storage.set(running(h))
        _ = await h.license.status()
        await h.license.launchReportSettled()
        #expect(h.http.body("trial") == ["fingerprint": "fp-test", "fingerprintKind": "machine", "clientStart": .number(Double(NOW - 2 * DAY))])
    }

    @Test func atMostOnceADayAStartTrialAnswerCountingAsAReport() async throws {
        let h = try Harness()
        h.storage.set(running(h))
        _ = await h.license.status()
        await h.license.launchReportSettled()
        h.clock.set(NOW + Waits.trialReportMs - 1)
        _ = await h.license.status()
        await h.license.launchReportSettled()
        #expect(h.http.count("trial") == 1)
        h.clock.set(NOW + Waits.trialReportMs)
        _ = await h.license.status()
        await h.license.launchReportSettled()
        #expect(h.http.count("trial") == 2)

        let synced = try Harness()
        synced.storage.set(running(synced) { $0.trialAt = NOW - DAY / 2 })
        _ = await synced.license.status()
        await synced.license.launchReportSettled()
        #expect(!synced.http.called("trial"))
    }

    @Test func neverHoldsUpTheLaunchStatusAnswersWhileTheReportWaits() async throws {
        // On a clock nobody moves, a report that were awaited would never end at its bound.
        let h = try Harness(timing: Timing(ticker: ManualTicker()))
        h.storage.set(running(h))
        let gate = Gate()
        h.http.on("trial") { _ in
            await gate.wait()
            return LicenseHTTPResponse(status: 200, json: [:])
        }
        #expect(await answer(within: 5) { await h.license.status() } == Self.trial)
        await eventually { h.http.called("trial") }
        #expect(h.http.called("trial"))
        gate.open()
        await h.license.launchReportSettled()
    }

    @Test func readsTheDeviceInTheBackgroundToo() async throws {
        // The first read cannot tell (so nothing is kept of it); the report's own read then waits.
        let reads = Counter()
        let gate = Gate()
        let fingerprinter = GetFingerprinter {
            if reads.next() == 1 { throw FakeHTTP.NetworkDown() }
            await gate.wait()
            return "fp-test"
        }
        // On a clock nobody moves: the report's read waits at the gate, never at its bound.
        let h = try Harness(fingerprinter: fingerprinter, timing: Timing(ticker: ManualTicker()))
        h.storage.set(running(h))
        #expect(await answer(within: 5) { await h.license.status() } == Self.trial)
        await eventually { reads.count == 2 }
        #expect(reads.count == 2 && !h.http.called("trial"))
        gate.open()
        await h.license.launchReportSettled()
        #expect(h.http.body("trial")?["fingerprint"] == "fp-test")
    }

    @Test func readsTheDeviceWithTheStatusBoundAndSendsNothingWhenItCannotTell() async throws {
        // The trial lease names no machine, so it runs on a device that cannot be told.
        let timed = TimedFingerprinter()
        let h = try Harness(fingerprinter: timed)
        h.storage.set(running(h))
        #expect(await h.license.status() == Self.trial)
        await h.license.launchReportSettled()
        // The status's own read, then the report's: each given a status's 2 s, never an activation's 10.
        #expect(timed.bounds == [Timing.standard.machineId, Timing.standard.machineId] && Timing.standard.machineId == 2)
        #expect(!h.http.called("trial") && h.stored?.trialReportedAt == NOW)
    }

    @Test func isBoundedAsAStatusCheckIs() async throws {
        let ticker = ManualTicker()
        let h = try Harness(timing: Timing(ticker: ticker))
        h.storage.set(running(h))
        h.http.setHang(true)
        #expect(await h.license.status() == Self.trial)
        let settled = Flag()
        let waiting = Task {
            await h.license.launchReportSettled()
            settled.set(true)
        }
        await eventually { h.http.called("trial") && ticker.deadlinesMs == [5_000] }
        #expect(ticker.deadlinesMs == [5_000])
        ticker.advance(ms: 4_999)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(!settled.on, "settled before its bound")
        ticker.advance(ms: 1)
        _ = await answer { await waiting.value }
        #expect(settled.on)
    }

    @Test func neverFailsOffline() async throws {
        let h = try Harness()
        h.storage.set(running(h))
        h.http.setFail(true)
        #expect(await h.license.status() == Self.trial)
        await h.license.launchReportSettled()
        #expect(h.http.called("trial"))
    }

    @Test func sendsNothingWhenItsStampCannotBeSavedSoItIsNeverSentTwiceInADay() async throws {
        let h = try Harness()
        h.storage.set(running(h))
        h.storage.failWrites()
        #expect(await h.license.status() == Self.trial)
        await h.license.launchReportSettled()
        #expect(!h.http.called("trial"))
    }

    @Test func isNotMadeByAnExpiredTrialWithAKeyHeldOrBehindACallThatHasNotFinished() async throws {
        let expired = try Harness()
        expired.storage.set(running(expired) {
            $0.trialLease = nil
            $0.trialEndsAt = NOW - 1
        })
        _ = await expired.license.status()
        await expired.license.launchReportSettled()
        #expect(!expired.http.called("trial"))

        let keyed = try Harness()
        keyed.storage.set(running(keyed) { $0.key = "KEY-1" })
        _ = await keyed.license.status()
        await keyed.license.launchReportSettled()
        #expect(!keyed.http.called("trial"))

        let stalled = try Harness(httpTimeout: 0.2, timing: quick)
        stalled.storage.set(running(stalled))
        stalled.storage.hangNextRead()
        let stuck = Task { await stalled.license.status() }
        await eventually { stalled.storage.hungReads == 1 }
        #expect(await answer { await stalled.license.status() } == Self.trial.stalled())
        await stalled.license.launchReportSettled()
        #expect(!stalled.http.called("trial"))
        #expect(stalled.storage.writes == 0)
        stalled.storage.releaseAll()
        _ = await answer { await stuck.value }
    }
}

@Suite("every answer parser ignores members it does not know", suiteTimeLimit)
struct UnknownMembersTests {
    static let extra: [String: LicenseJSON] = ["future": ["nested": [1, 2]], "note": "added by a later server"]

    func with(_ members: [String: LicenseJSON]) -> LicenseJSON {
        .object(members.merging(Self.extra) { given, _ in given })
    }

    @Test func activateValidateTrialAndClaim() async throws {
        let h = try Harness(StoredState(purchaseToken: Purchase.token, purchaseTokenAt: NOW))
        let lease = h.signer.lease(sub: "KEY-1")
        h.http.on("claim", status: 200, json: with(["key": "KEY-1", "activationId": "act_1", "lease": .string(lease)]))
        h.http.on("validate", status: 200, json: with(["lease": .string(lease)]))
        h.http.on("activate", status: 200, json: with(["lease": .string(lease), "activationId": "act_1"]))
        #expect(await h.license.status() == LicenseStatus(state: .licensed, key: "KEY-1"))
        #expect(await h.license.refresh() == LicenseStatus(state: .licensed, key: "KEY-1"))
        #expect(await h.license.activate("KEY-1") == .activated)

        let trial = try Harness()
        let trialLease = trial.signer.trialLease(device: "fp-test", kind: nil, ttlSeconds: 5 * 24 * 3600)
        trial.http.on(
            "trial", status: 200,
            json: with(["trialStart": .number(Double(NOW)), "trialEndsAt": .number(Double(NOW + 5 * DAY)), "lease": .string(trialLease)])
        )
        #expect(await trial.license.startTrial() == LaunchReportTests.trial)
    }
}
