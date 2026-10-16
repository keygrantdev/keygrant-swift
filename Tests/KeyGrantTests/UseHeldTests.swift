import Foundation
import Testing

@testable import KeyGrant

/// `use(_:_:)` beside a disk that refuses and a call that has not finished: a spend the customer was
/// told was made is kept in memory and counted everywhere, a request reports the journal as stored, and
/// the allowance is judged again where a spend lands.
@Suite("metered uses: a spend held in memory", suiteTimeLimit)
struct UseHeldTests {
    func offlineLimit(_ left: Int) -> UseResult { .refused(.offlineLimit, left: left) }

    /// A key holding `met`, its no-answer wait running (so a spend the allowance covers asks nothing).
    func waitingHarness(
        met: LicenseJSON = ["exports": ["left": 90, "total": 100, "offline": 10]], httpTimeout: TimeInterval = 15,
        timing: Timing = .standard
    ) throws -> Harness {
        try Harness.holding(met: met, httpTimeout: httpTimeout, timing: timing) {
            $0.backoffSince = NOW
            $0.backoffMs = Waits.retryUnansweredMs
        }
    }

    // MARK: - a spend held in memory

    @Test func isNotReportedUntilItHasLandedSoTheEntryItJoinsIsReportedWithItOnce() async throws {
        let h = try waitingHarness()
        h.renewing()
        h.storage.failWrites()
        #expect(await h.license.use("exports", 2) == .spent(left: 88, offline: true))
        // Held in memory, it counts toward the status but no request carries it: it has no place in the journal yet.
        let shown = await h.license.refresh().meters["exports"]
        #expect(shown?.left == 88 && shown?.unsynced == 2)
        #expect(h.report(0) == nil)
        // Another process lands an entry, and the disk is back: the spend lands in it, and the entry is what is reported.
        var stored = try #require(h.stored)
        stored.spends = [entry(id: spendId("Y"), .offline, 1, NOW - 5)]
        h.storage.set(stored)
        h.storage.failWrites(false)
        _ = await h.license.refresh()
        #expect(h.report(1) == [["id": .string(spendId("Y")), "meter": "exports", "n": 3, "at": .number(Double(NOW - 5))]])
    }

    @Test func isReportedWithAReleaseOnceItHasLandedAsEverythingTheJournalHolds() async throws {
        let h = try waitingHarness()
        h.http.on("deactivate", status: 200, json: [:])
        h.storage.failWrites()
        _ = await h.license.use("exports", 2)
        h.storage.failWrites(false)
        #expect(try await h.license.deactivate() == DeactivateResult(released: true))
        let body = try #require(h.http.body("deactivate"))
        #expect(body["spends"]?.arrayValue?.first?["meter"] == "exports" && body["spends"]?.arrayValue?.first?["n"] == 2)
    }

    @Test func reportsAnUnansweredSpendAndAVoidWhichOpenOnceByTheirIDsAndWithholdsOnlyTheOfflineSpends() async throws {
        let h = try Harness.holding()
        h.renewing()
        h.storage.failWrites()
        h.http.setFail(true)
        // In doubt, then refused after asking: an unanswered spend, and a void. A third, made while the journal waits, never left the device.
        #expect(await h.license.use("exports", 2) == .spent(left: 88, offline: true))
        #expect(await h.license.use("renders", 1).error == .offlineLimit)
        #expect(await h.license.use("exports", 1) == .spent(left: 87, offline: true))
        h.http.setFail(false)
        _ = await h.license.refresh()
        let report = try #require(h.report(0)?.arrayValue)
        let shown = report.map { "\($0["meter"]?.stringValue ?? "") \($0["n"]?.numberValue ?? 0) \($0["void"] == true)" }
        #expect(shown == ["exports 2.0 false", "renders 1.0 true"])
    }

    @Test func judgesAViewThatCarriedHeldSpendsByWhatIsStoredThoughASaveInTheSameCallLandedThem() async throws {
        let h = try Harness()
        let lease = h.signer.meteredLease(
            over: ["model": "perpetual", "major": .number(Double(openMajor)), "upgradeUntil": .number(Double((NOW + 10 * DAY) / 1000))]
        )
        var held = licensedState(with: lease)
        held.backoffSince = NOW
        held.backoffMs = Waits.retryUnansweredMs
        h.storage.set(held)
        let flaky = Flaky(over: h, injectAt: 2)
        let app = try h.app(storage: flaky)
        h.renewing(lease)
        #expect(await app.use("exports", 2) == .spent(left: 88, offline: true))
        flaky.diskBack()
        _ = await app.refresh()
        // The spend landed in that entry before the request was made; the request reports the entry, not the spend under an id of its own.
        #expect(h.report(0) == [["id": .string(spendId("Y")), "meter": "exports", "n": 3, "at": .number(Double(NOW - 5))]])
    }

    @Test func doesNotMakeStatusAskAtEveryCallForSpendsHeldInMemoryThatNoRequestCarries() async throws {
        let h = try waitingHarness()
        h.renewing()
        h.storage.failWrites()
        _ = await h.license.use("exports", 2)
        h.clock.set(NOW + 2 * MINUTE)
        for _ in 0..<3 { _ = await h.license.status() }
        #expect(h.http.count("validate") == 0)
        // Landed, the journal asks as it does, once.
        h.storage.failWrites(false)
        _ = await h.license.status()
        #expect(h.http.count("validate") == 1)
    }

    @Test func isNotReportedWithAUseEitherWhoseOwnSpendIsTheReportIsWhatIsStored() async throws {
        let h = try waitingHarness(met: meters())
        h.storage.failWrites()
        _ = await h.license.use("exports", 2)
        h.http.on(
            "use", status: 200,
            json: ["spent": true, "at": .number(Double(NOW)), "meters": ["renders": ["left": 4, "total": 5, "offline": 0, "resets": true]]]
        )
        #expect(await h.license.use("renders", 1) == .spent(left: 4))
        let body = h.useBody()
        #expect(body["meter"] == "renders" && body["n"] == 1)
        #expect(!body.has("spends"))
    }

    @Test func startsTheHoursWaitAfterAnAnswerOnlyWhenTheRequestCarriedAReport() async throws {
        let h = try waitingHarness()
        h.renewing()
        let flaky = Flaky(over: h)
        let app = try h.app(storage: flaky)
        #expect(await app.use("exports", 2) == .spent(left: 88, offline: true))
        // The next call's first save fails and its answer's save lands the spend: it read a journal, and sent none of it.
        flaky.diskBack()
        _ = await app.refresh()
        #expect(h.report(0) == nil)
        #expect(h.journal.count == 1)
        #expect(h.stored?.backoffMs != Waits.askAgainMs)
        // So the journal that has landed is offered at the next status() once the minute's wait is over, not an hour on.
        h.clock.set(NOW + 2 * MINUTE)
        _ = await app.status()
        #expect(h.http.count("validate") == 2)
        #expect(h.report(1)?.arrayValue?.first?["n"] == 2)
    }

    @Test func startsTheHoursWaitWhenAnAnswerConfirmsNoneOfTheReportItCarried() async throws {
        let h = try Harness.holdingJournal([entry(.offline, 2, LONG_AGO)])
        // A lease, and no word of the reports: the server could not record them.
        h.renewing()
        _ = await h.license.refresh()
        #expect(h.report(0)?.arrayValue?.count == 1)
        #expect(h.stored?.backoffSince == NOW && h.stored?.backoffMs == Waits.askAgainMs)
        #expect(h.journal.count == 1)
        // So it is not offered again at every status().
        _ = await h.license.status()
        _ = await h.license.status()
        #expect(h.http.count("validate") == 1)
    }

    // MARK: - calls one at a time

    @Test func runsTwoCallsMadeTogetherOneAfterTheOtherEachASpendOfItsOwn() async throws {
        let h = try Harness.holding()
        h.http.setFail(true)
        async let first = h.license.use("exports", 3)
        async let second = h.license.use("exports", 4)
        let (a, b) = await (first, second)
        #expect(a.ok && a.offline && b.ok && b.offline)
        // Whichever ran first, the second saw what it left.
        #expect([a.left, b.left].compactMap { $0 }.sorted() == [83, 86] || [a.left, b.left].compactMap { $0 }.sorted() == [83, 87])
        #expect(h.journal.map(\.n).reduce(0, +) == 7)
    }

    @Test func waitsBehindAStatusAlreadyRunningAndSeesWhatItSaved() async throws {
        let ticker = ManualTicker()
        let h = try Harness.holding(timing: Timing(ticker: ticker))
        let renewed = h.signer.meteredLease(met: ["exports": ["left": 60, "total": 100, "offline": 10]], at: NOW + 1000)
        h.clock.set(NOW + 1000)
        let gate = Gate()
        let reached = Flag(), validated = Flag()
        defer { gate.open() }
        h.http.on("validate") { _ in
            reached.set(true)
            await gate.wait()
            validated.set(true)
            return LicenseHTTPResponse(status: 200, json: ["lease": .string(renewed)])
        }
        // The spend's answer gives no figure: what is left can only come from the lease the status saved.
        let asked = Shared<[Bool]>([])
        h.http.on("use") { _ in
            asked.set(asked.current + [validated.on])
            return LicenseHTTPResponse(status: 200, json: ["spent": true])
        }
        let refreshing = Task { await h.license.refresh() }
        await eventually { reached.on }
        let spending = Task { await h.license.use("exports", 1) }
        // The spend is queued behind the status (it waits for its turn, to the end of the status's grace, 30 s):
        // it has asked nothing yet.
        await eventually { ticker.deadlinesMs.contains(30_000) }
        #expect(h.http.count("use") == 0)
        gate.open()
        _ = await refreshing.value
        #expect(await spending.value == .spent(left: 60))
        // It asked once, and after the status had its answer.
        #expect(asked.current == [true])
    }

    // MARK: - a disk that keeps refusing

    @Test func costsTheProcessAShortListOfChangesHoweverManySpendsOfOneMeterItHoldsAndNoneIsLost() async throws {
        let h = try Harness.holding(met: ["exports": ["left": 1_000_000, "total": 1_000_000, "offline": 1_000_000]])
        h.http.setFail(true)
        h.storage.failWrites()
        for _ in 0..<400 { #expect(await h.license.use("exports", 1).ok) }
        let shown = await h.license.status().meters["exports"]
        #expect(shown?.left == 1_000_000 - 400 && shown?.unsynced == 400)
        // However many spends of one meter it holds, a run of them is folded into one change.
        #expect(h.license.heldChanges.count < 10, "\(h.license.heldChanges.count)")
        h.storage.failWrites(false)
        _ = await h.license.status()
        #expect(h.journal.map(\.n).reduce(0, +) == 400)
    }

    @Test func keepsEverySpendOfTwoMetersThatTakeTurnsAndLandsEachMetersTotalWhenTheDiskIsBack() async throws {
        // Only a run of one meter is folded into one change (a spend of the other between two is not
        // folded across), so this list grows with the spends; what must hold is that none is lost or counted twice.
        let h = try Harness.holding(
            met: [
                "exports": ["left": 1_000, "total": 1_000, "offline": 1_000], "renders": ["left": 1_000, "total": 1_000, "offline": 1_000],
            ]
        )
        h.http.setFail(true)
        h.storage.failWrites()
        for turn in 0..<100 {
            #expect(await h.license.use("exports", 1).ok, "turn \(turn)")
            #expect(await h.license.use("renders", 2).ok, "turn \(turn)")
        }
        let shown = await h.license.status().meters
        #expect(shown["exports"]?.unsynced == 100 && shown["renders"]?.unsynced == 200)
        h.storage.failWrites(false)
        _ = await h.license.status()
        var totals: [String: Int] = [:]
        for entry in h.journal { totals[entry.meter, default: 0] += entry.n }
        #expect(totals == ["exports": 100, "renders": 200])
        #expect(h.license.heldChanges.isEmpty)
    }

    @Test func keepsTheNewestVoidsInMemoryNoneOfThemToldAndRefusesNoCoveredSpendForThem() async throws {
        let h = try Harness.holding()
        h.http.setFail(true)
        h.storage.failWrites()
        for minute in 0..<20 {
            h.clock.set(NOW + minute * MINUTE)
            #expect(await h.license.use("renders", 1) == offlineLimit(5), "minute \(minute)")
        }
        let voids = h.license.heldChanges.compactMap { op -> SpendOp? in
            if case .spend(let spend) = op, spend.kind == .void { return spend }
            return nil
        }
        #expect(voids.count == maxPendingVoids)
        #expect(voids.allSatisfy { !$0.told }, "a void is no spend told")
        // A spend the allowance covers is made, whatever the uncovered ones did to what this process holds.
        #expect(await h.license.use("exports", 3) == .spent(left: 87, offline: true))
        h.storage.failWrites(false)
        _ = await h.license.status()
        // A void is no spend told: it lands under the journal's rules, the newest sixteen of the twenty.
        #expect(h.journal.filter { $0.kind == .void }.map(\.at) == (0..<maxPendingVoids).map { NOW + (4 + $0) * MINUTE })
        #expect(h.journal.filter { $0.kind != .void }.map { "\($0.meter) \($0.n)" } == ["exports 3"])
    }

    // MARK: - the allowance, judged where the spend lands

    @Test func refusesASpendThatAnotherProcessTookTheAllowanceFromMeanwhileAndKeepsTheirs() async throws {
        let h = try waitingHarness()
        let app = try h.app(storage: Racing(over: h, theirs: [entry(id: spendId("T"), .offline, 8, NOW - 5)]))
        // Read with nothing unsynced, so the allowance covers 5; by the time it lands, 8 are there: 13 would pass 10.
        // What is left is as the landing found it: the 90, less the 8 the other process had spent by then.
        #expect(await app.use("exports", 5) == offlineLimit(82))
        #expect(kindsAndCounts(h.journal) == ["offline 8"])
        // What the allowance still covers lands.
        #expect(await app.use("exports", 2).offline)
        #expect(h.journal.map(\.n) == [10])
    }

    @Test func holdsASpendToWhatIsLeftWhenThatIsBelowTheAllowance() async throws {
        let met: LicenseJSON = ["exports": ["left": 2, "total": 100, "offline": 50]]
        let h = try waitingHarness(met: met)
        let app = try h.app(storage: Racing(over: h, theirs: [entry(id: spendId("T"), .offline, 2, NOW - 5)]))
        // The allowance of 50 would take it; the 2 that are left, and the other process has spent them.
        #expect(await app.use("exports", 2) == offlineLimit(0))
        #expect(kindsAndCounts(h.journal) == ["offline 2"])
        let alone = try waitingHarness(met: met)
        #expect(await alone.license.use("exports", 2) == .spent(left: 0, offline: true))
        #expect(await alone.license.use("exports", 1) == offlineLimit(0))
    }

    @Test func journalsAVoidForASpendThatWasInDoubtAndIsThenRefusedAtLanding() async throws {
        let h = try Harness.holding()
        h.http.setFail(true)
        let app = try h.app(storage: Racing(over: h, theirs: [entry(id: spendId("T"), .offline, 8, NOW - 5)]))
        #expect(await app.use("exports", 5) == offlineLimit(82))
        let sent = try #require(h.useBody()["id"]?.stringValue)
        #expect(kindsAndCounts(h.journal) == ["offline 8", "void 5"])
        #expect(h.journal.dropFirst().first?.id == sent)
    }

    @Test func neverTakesBackASpendTheCustomerWasToldWasMadeItLandsPastTheAllowance() async throws {
        let h = try waitingHarness()
        h.storage.failWrites()
        #expect(await h.license.use("exports", 6) == .spent(left: 84, offline: true))
        h.storage.failWrites(false)
        // Meanwhile another process of the app spent 8, and the journal is full.
        var crowd = (0..<(maxPendingSpends - 1)).map { entry(id: numbered($0, "c"), .unanswered, 1, NOW - 100, meter: "m\($0)") }
        crowd.insert(entry(id: spendId("T"), .offline, 8, NOW), at: 0)
        var stored = try #require(h.stored)
        stored.spends = crowd
        h.storage.set(stored)
        _ = await h.license.status()
        #expect(h.journal.count == maxPendingSpends)
        #expect(h.journal.first?.id == spendId("T") && h.journal.first?.n == 14)
        let shown = await h.license.status().meters["exports"]
        #expect(shown?.unsynced == 14 && shown?.left == 76)
    }

    @Test func landsASpendTheCustomerWasToldWasMadeAsA65thEntryWhenItOpensAnEntryOfItsOwn() async throws {
        let h = try waitingHarness()
        h.storage.failWrites()
        #expect(await h.license.use("exports", 2).ok)
        h.storage.failWrites(false)
        var stored = try #require(h.stored)
        stored.spends = (0..<maxPendingSpends).map { entry(id: numbered($0, "c"), .unanswered, 1, NOW - 100, meter: "m\($0)") }
        h.storage.set(stored)
        _ = await h.license.status()
        #expect(h.journal.count == maxPendingSpends + 1)
        let last = try #require(h.journal.last)
        #expect(last.meter == "exports" && last.n == 2 && last.kind == .offline)
    }

    // MARK: - what is left when a landing refuses a spend and the state cannot say

    @Test func answers0LeftWhenTheStateCannotBeReadAgainJustAfterTheRefusal() async throws {
        let h = try waitingHarness()
        let app = try h.app(storage: Racing(over: h, theirs: [entry(id: spendId("T"), .offline, 8, NOW - 5)], failReadsAfter: true))
        #expect(await app.use("exports", 5) == offlineLimit(0))
        // The refusal stands, and their spend is kept: only the figure was lost to the customer.
        #expect(kindsAndCounts(h.journal) == ["offline 8"])
    }

    @Test func answers0LeftWhenTheStateAsTheLandingFoundItHasNoFigureForTheMeterAnyMore() async throws {
        // The lease names no credits; the figure is a use answer's, stored beside it.
        func withFigure() throws -> Harness {
            try Harness.holding(met: meters()) {
                $0.backoffSince = NOW
                $0.backoffMs = Waits.retryUnansweredMs
                $0.meterFigures = ["credits": MeterFigure(left: 20, total: 20, offline: 10, resets: false, at: NOW)]
            }
        }
        let h = try withFigure()
        let shown = await h.license.status().meters["credits"]
        #expect(shown?.left == 20 && shown?.offline == 10)
        let theirs = [entry(id: spendId("T"), .offline, 8, NOW - 5, meter: "credits")]
        let dropped = try h.app(storage: Racing(over: h, theirs: theirs, dropFigures: true))
        #expect(await dropped.use("credits", 5) == offlineLimit(0))
        #expect(kindsAndCounts(h.journal) == ["offline 8"])
        // With the figure kept, the same refusal says what is left: 20 less their 8.
        let kept = try withFigure()
        let keptApp = try kept.app(storage: Racing(over: kept, theirs: theirs))
        #expect(await keptApp.use("credits", 5) == offlineLimit(12))
    }

    // MARK: - what an answer stamps

    func unconfirmed(_ answer: LicenseHTTPResponse?) async throws -> Harness {
        let h = try Harness.holding { $0.verdictAt = 111 }
        if let answer { h.http.on("use") { _ in answer } } else { h.http.setFail(true) }
        _ = await h.license.use("exports", 1)
        return h
    }

    @Test func leavesVerdictAtAloneForASpendUsedUpAndAnUnknownMeter() async throws {
        let usedUp = LicenseHTTPResponse(
            status: 409, json: ["error": "used-up", "left": 0, "meters": meters(), "at": .number(Double(NOW))]
        )
        let unknown = LicenseHTTPResponse(status: 404, json: ["error": "unknown-meter"])
        for answer in [Harness.spent(89, at: NOW + 5), usedUp, unknown] {
            #expect(try await unconfirmed(answer).stored?.verdictAt == 111, "\(answer)")
        }
    }

    @Test func setsItForAVerdictAndForAWaitAsAValidatesAnswerDoes() async throws {
        #expect(try await unconfirmed(LicenseHTTPResponse(status: 403, json: ["error": "revoked"])).stored?.verdictAt == NOW)
        #expect(try await unconfirmed(nil).stored?.verdictAt == NOW)
    }

    @Test func letsAValidateThatWasInFlightAcrossASpendKeepItsLease() async throws {
        let h = try Harness.holding()
        let other = try h.license(major: 1)
        let renewed = h.signer.meteredLease(at: NOW + 1_000)
        let gate = Gate()
        let reached = Flag()
        defer { gate.open() }
        h.http.on("validate") { _ in
            reached.set(true)
            await gate.wait()
            return LicenseHTTPResponse(status: 200, json: ["lease": .string(renewed)])
        }
        h.http.on("use") { _ in Harness.spent(89, at: NOW + 2_000) }
        let validating = Task { await h.license.refresh() }
        await eventually { reached.on }
        // Another process spends, asked later and answered first.
        h.clock.set(NOW + 2_000)
        #expect(await other.use("exports", 1) == .spent(left: 89))
        #expect(h.stored?.verdictAt == nil)
        gate.open()
        _ = await validating.value
        #expect(h.stored?.lease == renewed)
    }

    // MARK: - a spend kept while a save is in flight

    @Test func aSpendKeptWhileASaveIsInFlightIsCountedOnceBesideTheOneThatSaveCarries() async throws {
        let h = try waitingHarness(
            met: ["exports": ["left": 90, "total": 100, "offline": 50]], httpTimeout: 1.5, timing: behind
        )
        // A: kept in memory because the disk refused it.
        h.storage.failWrites()
        #expect(await h.license.use("exports", 2).offline)
        h.storage.failWrites(false)
        // A save in flight carries A and is held inside the storage.
        h.http.setFail(true)
        h.storage.holdNextWrite()
        let refreshing = Task { await h.license.refresh() }
        await eventually { h.storage.holdingWrite }
        defer { h.storage.releaseAll() }
        // B, of the same meter, is made behind it: kept in memory, beside A.
        let second = await h.license.use("exports", 3)
        #expect(second.ok && second.offline)
        h.storage.releaseWrite()
        _ = await refreshing.value
        _ = await h.license.status()
        #expect(h.journal.map(\.n).reduce(0, +) == 5)
        #expect(await h.license.status().meters["exports"]?.unsynced == 5)
    }

    // MARK: - a spend the allowance cannot cover, while nothing answers

    @Test func asksOnceAMinuteKeepsAtMostTheCapOfVoidsAndLeavesTheJournalItsRoom() async throws {
        let h = try Harness.holding()
        h.http.setFail(true)
        for minute in 0..<30 {
            h.clock.set(NOW + minute * MINUTE)
            #expect(await h.license.use("renders", 1) == offlineLimit(5))
            // The same minute: the void is a wait of its own, and nothing is asked.
            #expect(await h.license.use("renders", 1) == offlineLimit(5))
        }
        #expect(h.http.count("use") == 30)
        // The newest sixteen stay: the first void to go was the oldest.
        #expect(h.journal.filter { $0.kind == .void }.map(\.at) == (0..<maxPendingVoids).map { NOW + (14 + $0) * MINUTE })
        // A spend on another meter that its allowance covers is made, whatever the uncovered ones did to the journal.
        #expect(await h.license.use("exports", 3) == .spent(left: 87, offline: true))
        #expect(h.journal.count == maxPendingVoids + 1)
    }

    @Test func asksAgainWhenTheDeviceClockIsSetBackBelowTheVoid() async throws {
        let h = try Harness.holding()
        h.http.setFail(true)
        h.clock.set(NOW + 10 * MINUTE)
        #expect(await h.license.use("renders", 1).error == .offlineLimit)
        // Inside the void's minute by both clocks: nothing is asked.
        h.clock.set(NOW + 10 * MINUTE + 1000)
        #expect(await h.license.use("renders", 1).error == .offlineLimit)
        #expect(h.http.count("use") == 1)
        // The device clock is set back to before the void while the guard stands at its minute: the wait is none, and a customer who is online is served.
        h.http.setFail(false)
        h.http.on(
            "use", status: 200,
            json: ["spent": true, "at": .number(Double(NOW)), "meters": ["renders": ["left": 4, "total": 5, "offline": 0, "resets": true]]]
        )
        h.clock.set(NOW)
        #expect(await h.license.use("renders", 1) == .spent(left: 4))
        #expect(h.http.count("use") == 2)
    }

    @Test func isServedAtOnceWhenTheServerIsBackAndItsMinuteIsOverNotBefore() async throws {
        let h = try Harness.holding()
        h.http.setFail(true)
        #expect(await h.license.use("renders", 1).error == .offlineLimit)
        h.http.setFail(false)
        h.http.on(
            "use", status: 200,
            json: ["spent": true, "at": .number(Double(NOW + MINUTE)), "meters": ["renders": ["left": 4, "total": 5, "offline": 0, "resets": true]]]
        )
        // Inside the void's minute: refused without asking.
        h.clock.set(NOW + MINUTE - 1)
        #expect(await h.license.use("renders", 1).error == .offlineLimit)
        #expect(h.http.count("use") == 1)
        h.clock.set(NOW + MINUTE)
        #expect(await h.license.use("renders", 1) == .spent(left: 4))
    }

    @Test func asksForItWhateverAnUnansweredSpendOfACoveredMeterWaitsForAndAVoidAheadOfTheClock() async throws {
        let h = try Harness.holdingJournal([
            entry(id: spendId("U"), .unanswered, 1, NOW - 1_000), entry(id: spendId("V"), .void, 1, NOW + DAY),
        ])
        h.http.on(
            "use", status: 200,
            json: ["spent": true, "at": .number(Double(NOW)), "meters": ["renders": ["left": 4, "total": 5, "offline": 0, "resets": true]]]
        )
        #expect(await h.license.use("renders", 1) == .spent(left: 4))
    }

    @Test func aWaitThatCannotBeMeasuredLeavesOutOnlyTheEntriesAheadOfTheGuardedClock() async throws {
        let ahead = entry(id: spendId("Z"), .unanswered, 1, NOW + 5 * DAY)
        let waiting = try Harness.holdingJournal([entry(id: spendId("A"), .unanswered, 1, NOW - 30_000), ahead])
        waiting.http.on("use") { _ in Harness.spent(89, at: NOW) }
        _ = await waiting.license.use("exports", 1)
        #expect(waiting.http.count("use") == 0)
        let over = try Harness.holdingJournal([entry(id: spendId("A"), .unanswered, 1, NOW - 2 * MINUTE), ahead])
        over.http.on("use") { _ in Harness.spent(89, at: NOW) }
        _ = await over.license.use("exports", 1)
        #expect(over.http.count("use") == 1)
    }
}
