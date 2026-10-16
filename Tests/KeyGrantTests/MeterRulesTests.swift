import Foundation
import Testing

@testable import KeyGrant

/// The decisions under `use(_:_:)` and `status().meters`, by the rule each states, straight through
/// the functions the engine decides with. The conformance vectors pin the same decisions for every
/// port; these hold this port to the contract itself, and cover what vectors cannot say.
@Suite("metered uses: the decisions", suiteTimeLimit)
struct MeterRulesTests {
    func asked(_ meter: String, _ n: Int) -> String {
        switch askedFor(meter, n) {
        case .success(let value): "\(value.meter) \(value.n)"
        case .failure(let error): error.rawValue
        }
    }

    // MARK: - what is asked

    @Test func takesAWholeNumberFrom1ToTheBoundAndJudgesTheAmountBeforeTheCode() {
        #expect(asked("exports", 1) == "exports 1")
        #expect(asked("exports", maxMeterUses) == "exports \(maxMeterUses)")
        for n in [0, -1, maxMeterUses + 1, Int.max, Int.min, 1 << 53] {
            #expect(asked("exports", n) == "invalid-amount", "\(n)")
        }
        #expect(asked("", 0) == "invalid-amount")
        #expect(asked("", 1) == "no-meter")
    }

    @Test func countsACodeInUTF16Units32AreACode33AreNotASurrogatePairIsTwo() {
        #expect(asked(String(repeating: "x", count: 32), 1).hasSuffix(" 1"))
        #expect(asked(String(repeating: "x", count: 33), 1) == "no-meter")
        #expect(asked(String(repeating: "x", count: 30) + "\u{1F600}", 1).hasSuffix(" 1"))
        #expect(asked(String(repeating: "x", count: 31) + "\u{1F600}", 1) == "no-meter")
        // Characters beyond the BMP count two each.
        #expect(asked(String(repeating: "\u{1F600}", count: 16), 1).hasSuffix(" 1"))
        #expect(asked(String(repeating: "\u{1F600}", count: 17), 1) == "no-meter")
    }

    @Test func makesAnIdOf22CharactersOfBase64URLThatIsNeverTheSameTwice() {
        let ids = (0..<500).map { _ in newSpendId() }
        #expect(Set(ids).count == ids.count)
        for id in ids {
            #expect(id.utf8.count == 22)
            #expect(id.utf8.allSatisfy { byte in
                (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) || (0x30...0x39).contains(byte) || byte == 0x2D || byte == 0x5F
            })
        }
        // 16 bytes: it decodes back to as many.
        #expect(ids.allSatisfy { base64URLDecode($0)?.count == 16 })
    }

    // MARK: - the base figures

    @Test func baseFiguresAreTheLeasesWhenNothingIsStoredAndAStoredFigureFromTheLeasesOwnSecondOn() {
        let met = ["exports": figure(90, 100, 10), "renders": figure(5, 5, 0, true)]
        let iat = 1_790_000_000.0
        let at = Int(iat) * 1000
        #expect(figuresOf(met: met, iat: iat, stored: nil) == met)
        func stored(_ when: Int) -> [String: MeterFigure] {
            ["exports": MeterFigure(left: 40, total: 100, offline: 10, resets: false, at: when)]
        }
        for (when, left) in [(at, 40), (at + 999, 40), (at - 1, 90)] {
            #expect(figuresOf(met: met, iat: iat, stored: stored(when))["exports"]?.left == left, "\(when)")
        }
    }

    @Test func aStoredFigureReplacesTheLeasesWholeMember() {
        let stored = ["exports": MeterFigure(left: 7, total: 50, offline: 3, resets: true, at: 2_000_000_000_000)]
        #expect(figuresOf(met: ["exports": figure(90, 100, 10)], iat: 1, stored: stored)["exports"] == figure(7, 50, 3, true))
    }

    @Test func namesAMeterOnlyANewerStoredFigureNamesAndDropsOneTheNewestLeaseNoLongerNames() {
        let iat = 1_790_000_000.0
        let stored = [
            "added": MeterFigure(left: 7, total: 7, offline: 1, resets: false, at: Int(iat) * 1000 + 1),
            "gone": MeterFigure(left: 7, total: 7, offline: 1, resets: false, at: Int(iat) * 1000 - 1),
        ]
        let names = figuresOf(met: ["exports": figure(90, 100, 10)], iat: iat, stored: stored).keys.sorted()
        #expect(names == ["added", "exports"])
        #expect(figuresOf(met: nil, iat: iat, stored: nil).isEmpty)
    }

    // MARK: - the status's meters

    var journalOfEveryKind: [SpendEntry] {
        [
            entry(.offline, 4, NOW), entry(id: spendId("B"), .unanswered, 3, NOW), entry(id: spendId("C"), .void, 50, NOW),
            entry(id: spendId("D"), .offline, 9, NOW, meter: "renders"),
        ]
    }

    @Test func theStatusTakesTheUnsyncedSpendsOffLeftCountsNoVoidAndNeverGoesBelow0() {
        let figures = ["exports": figure(90, 100, 10), "renders": figure(5, 5, 0, true)]
        #expect(
            meterStatusOf(figures, journalOfEveryKind) == [
                "exports": MeterStatus(left: 83, total: 100, offline: 10, unsynced: 7, resets: false),
                "renders": MeterStatus(left: 0, total: 5, offline: 0, unsynced: 9, resets: true),
            ]
        )
    }

    // MARK: - a spend with no answer

    @Test func aSpendIsAllowedUpToTheAllowanceAndUpToWhatIsLeftAndAnswersWhatIsLeftAfterIt() {
        #expect(offlineSpend(usual(), [], "exports", 10) == .allowed(left: 80, limit: 10))
        #expect(offlineSpend(usual(), [entry(.offline, 4, NOW)], "exports", 6) == .allowed(left: 80, limit: 10))
        #expect(offlineSpend(["exports": figure(4, 100, 10)], [], "exports", 4) == .allowed(left: 0, limit: 4))
    }

    @Test func aSpendIsRefusedPastEitherWithWhatIsLeftAndAlwaysForAnAllowanceOf0() {
        #expect(offlineSpend(usual(), [], "exports", 11) == .offlineLimit(left: 90))
        #expect(offlineSpend(["exports": figure(4, 100, 10)], [], "exports", 5) == .offlineLimit(left: 4))
        #expect(offlineSpend(["exports": figure(90, 100, 0)], [], "exports", 1) == .offlineLimit(left: 90))
        #expect(offlineSpend(["exports": figure(5, 100, 50)], [entry(.offline, 12, NOW)], "exports", 1) == .offlineLimit(left: 0))
    }

    @Test func countsTheUnsyncedOfItsOwnMeterAndOfBothKindsNeverAVoidAndKnowsNoMeterWithoutAFigure() {
        #expect(offlineSpend(usual(), journalOfEveryKind, "exports", 3) == .allowed(left: 80, limit: 10))
        #expect(offlineSpend(usual(), journalOfEveryKind, "exports", 4) == .offlineLimit(left: 83))
        #expect(offlineSpend(usual(), [], "credits", 1) == .noMeter)
        #expect(offlineSpend(usual(), [], "constructor", 1) == .noMeter)
    }

    @Test func holdsTheSumsToTheTopOfIntNotPastItAndTheLeftToZero() {
        let spends = [entry(.offline, Int.max, NOW), entry(id: spendId("B"), .unanswered, Int.max, NOW)]
        #expect(unsyncedOf(spends, "exports") == Int.max)
        #expect(offlineSpend(usual(), spends, "exports", 1) == .offlineLimit(left: 0))
        #expect(meterStatusOf(usual(), spends)["exports"]?.left == 0)
    }

    /// A state an adapter built in code may hold any figure: none at the ends of `Int` traps a decision.
    @Test func decidesOnFiguresAtTheEndsOfIntWithoutTrapping() {
        let spends = [entry(.offline, Int.max, NOW)]
        for left in [Int.min, -1, 0, Int.max] {
            let figures = ["exports": figure(left, Int.max, Int.min)]
            #expect(meterStatusOf(figures, spends)["exports"]?.left == 0, "\(left)")
            #expect(meterStatusOf(figures, [])["exports"]?.left == max(0, left), "\(left)")
            #expect(offlineSpend(figures, spends, "exports", 1) == .offlineLimit(left: 0), "\(left)")
        }
        let wide = ["exports": figure(Int.max, Int.max, Int.max)]
        #expect(offlineSpend(wide, [], "exports", maxMeterUses) == .allowed(left: Int.max - maxMeterUses, limit: Int.max))
        #expect(meterStatusOf(wide, [entry(.offline, 1, NOW)])["exports"]?.left == Int.max - 1)
    }

    // MARK: - when use asks

    func unanswered(_ k: Int, ago: Int) -> [SpendEntry] {
        (0..<k).map { i in
            entry(id: numbered(i), .unanswered, 1, NOW - (i == k - 1 ? ago : ago + HOUR))
        }
    }

    func asks(_ state: StoredState, clockNow: Int = NOW, now: Int = NOW, covered: Bool) -> Bool {
        useAsksNow(state, clockNow: clockNow, now: now, covered: covered)
    }

    func waiting(since: Int, ms: Int) -> StoredState {
        StoredState(backoffSince: since, backoffMs: ms)
    }

    @Test func asksEveryTimeButWhileANoAnswerWaitRunsOnTheDeviceClock() {
        #expect(asks(StoredState(), covered: true))
        #expect(!asks(waiting(since: NOW - 1000, ms: Waits.retryUnansweredMs), covered: true))
        #expect(asks(waiting(since: NOW - Waits.retryUnansweredMs, ms: Waits.retryUnansweredMs), covered: true))
        #expect(asks(waiting(since: NOW + 1000, ms: Waits.retryUnansweredMs), covered: true))
        #expect(asks(waiting(since: NOW - 1000, ms: Waits.askAgainMs), covered: true))
    }

    @Test func waitsAMinuteAfterOneUnansweredSpendDoublingWithEachToAnHourFromTheSeventhOn() {
        for (i, minutes) in [1, 2, 4, 8, 16, 32, 60, 60, 60].enumerated() {
            let k = i + 1
            #expect(journalWaiting(unanswered(k, ago: minutes * MINUTE - 1), now: NOW), "\(k) unanswered")
            #expect(!journalWaiting(unanswered(k, ago: minutes * MINUTE), now: NOW), "\(k) unanswered, over")
        }
        #expect(!journalWaiting(unanswered(64, ago: HOUR), now: NOW))
        // The cap is applied first: a journal of any length waits the hour and overflows nothing.
        #expect(journalWaiting(unanswered(maxPendingSpends, ago: HOUR - 1), now: NOW))
        let many = (0..<10_000).map { entry(id: numbered($0), .unanswered, 1, NOW - HOUR + 1) }
        #expect(journalWaiting(many, now: NOW))
    }

    @Test func countsAVoidTowardTheWaitAnOfflineSpendNotAndGoesByTheNewestEntryWhateverTheOrder() {
        #expect(journalWaiting([entry(.void, 1, NOW - 1000)], now: NOW))
        #expect(!journalWaiting([entry(.offline, 1, NOW)], now: NOW))
        let olderLast = [entry(id: spendId("a"), .unanswered, 1, NOW - 1000), entry(id: spendId("b"), .unanswered, 1, NOW - 3 * HOUR)]
        #expect(journalWaiting(olderLast, now: NOW))
    }

    @Test func judgesTheJournalsWaitByTheGuardedClockAndTheOtherByTheDeviceClock() {
        let tenDays = 10 * DAY
        let withSpends = StoredState(spends: unanswered(1, ago: 2 * MINUTE))
        #expect(asks(withSpends, clockNow: NOW - tenDays, covered: true))
        let both = StoredState(backoffSince: NOW - tenDays - 1000, backoffMs: Waits.retryUnansweredMs, spends: unanswered(1, ago: 2 * MINUTE))
        #expect(!asks(both, clockNow: NOW - tenDays, covered: true))
    }

    @Test func asksWhateverTheWaitsASpendTheAllowanceWouldRefuseAndOneItCoversOnlyWhenNoWaitRuns() {
        let state = StoredState(backoffSince: NOW - 1000, backoffMs: Waits.retryUnansweredMs, spends: unanswered(1, ago: 1000))
        #expect(!asks(state, covered: true))
        #expect(asks(state, covered: false))
        #expect(asks(StoredState(), covered: false))
    }

    @Test func givesTheUncoveredSpendAWaitOfItsOwnAVoidOpenedLessThanAMinuteAgoNoneAheadOfEitherClock() {
        func voided(_ at: Int) -> [SpendEntry] { [entry(.void, 1, at)] }
        #expect(voidWaiting(voided(NOW - Waits.retryUnansweredMs + 1), now: NOW, clockNow: NOW))
        #expect(!voidWaiting(voided(NOW - Waits.retryUnansweredMs), now: NOW, clockNow: NOW))
        #expect(!voidWaiting(voided(NOW + 1), now: NOW, clockNow: NOW))
        #expect(!voidWaiting([entry(.unanswered, 1, NOW), entry(.offline, 1, NOW)], now: NOW, clockNow: NOW))
        var state = waiting(since: NOW - 1000, ms: Waits.retryUnansweredMs)
        state.spends = voided(NOW - 1000)
        #expect(!asks(state, covered: false))
        #expect(asks(StoredState(spends: unanswered(1, ago: 1000)), covered: false))
    }

    @Test func needsTheDeviceClockAtOrAfterTheVoidToo() {
        let voided = [entry(.void, 1, NOW - 1000)]
        #expect(voidWaiting(voided, now: NOW, clockNow: NOW - 1000))
        #expect(!voidWaiting(voided, now: NOW, clockNow: NOW - 1001))
        #expect(!voidWaiting(voided, now: NOW, clockNow: NOW - 10 * DAY))
        // A device clock far ahead does not stretch the wait: the guarded clock measures the minute.
        #expect(voidWaiting(voided, now: NOW, clockNow: NOW + 10 * DAY))
        #expect(!voidWaiting(voided, now: NOW + Waits.retryUnansweredMs, clockNow: NOW + 10 * DAY))
        // One void at the device clock is enough, whatever a newer void ahead of it says.
        let two = [entry(id: spendId("a"), .void, 1, NOW - 30_000), entry(id: spendId("b"), .void, 1, NOW - 1000)]
        #expect(voidWaiting(two, now: NOW, clockNow: NOW - 20_000))
        #expect(!voidWaiting(two, now: NOW, clockNow: NOW - 40_000))
    }

    @Test func leavesOutOfAWaitOnlyTheEntriesAheadOfTheClockNotTheirCountNotTheirTime() {
        func behind(_ who: String, _ at: Int) -> SpendEntry { entry(id: spendId(who), .unanswered, 1, at) }
        let ahead = behind("z", NOW + DAY)
        #expect(journalWaiting([behind("a", NOW - 30_000), ahead], now: NOW))
        #expect(!journalWaiting([behind("a", NOW - 2 * MINUTE), ahead], now: NOW))
        // Two behind wait two minutes; counted with the one ahead they would wait four.
        #expect(!journalWaiting([behind("a", NOW - 2 * MINUTE), behind("b", NOW - 3 * HOUR), ahead], now: NOW))
        #expect(journalWaiting([behind("a", NOW - 2 * MINUTE + 1), behind("b", NOW - 3 * HOUR), ahead], now: NOW))
    }

    @Test func hasNoWaitToMeasureFromAnEntryOpenedAfterTheGuardedClockAndWaitsFromOneOpenedAtIt() {
        #expect(journalWaiting([entry(.unanswered, 1, NOW)], now: NOW))
        #expect(!journalWaiting([entry(.unanswered, 1, NOW + 1)], now: NOW))
        #expect(!journalWaiting([entry(.void, 1, NOW + 10 * DAY)], now: NOW))
        #expect(journalAsks([entry(.unanswered, 1, NOW + 1)], now: NOW))
    }

    @Test func hasStatusOfferAJournalThatHoldsAnEntryWhileItsWaitIsNotRunning() {
        #expect(!journalAsks([], now: NOW))
        #expect(journalAsks([entry(.offline, 1, NOW)], now: NOW))
        #expect(!journalAsks(unanswered(1, ago: 30_000), now: NOW))
        #expect(journalAsks(unanswered(1, ago: MINUTE), now: NOW))
    }

    // MARK: - what a use answer does

    func outcome(_ response: LicenseHTTPResponse?) -> UseOutcome {
        useOutcome(UseInput(response: response, askedAt: NOW, major: 3, device: deviceOf(kind: .machine, ownClaim: "c")))
    }

    func answer(_ status: Int, _ json: LicenseJSON?) -> LicenseHTTPResponse {
        LicenseHTTPResponse(status: status, json: json)
    }

    @Test func aSpentAnswerIsASpendWithTheFiguresStampedByTheServersTime() {
        let meters: LicenseJSON = ["exports": ["left": 89, "total": 100, "offline": 10]]
        let spent = outcome(answer(200, ["spent": true, "meters": meters, "at": .number(Double(NOW + 1)), "spends": [["id": .string(spendId("A")), "n": 2]]]))
        #expect(spent.kind == .spent)
        #expect(spent.patch.changes.isEmpty)
        #expect(spent.figures == ["exports": MeterFigure(left: 89, total: 100, offline: 10, resets: false, at: NOW + 1)])
        #expect(spent.confirmed == [.count(id: spendId("A"), n: 2)])
        #expect(outcome(answer(200, ["spent": true, "meters": meters, "at": 1.5])).figures.isEmpty)
        #expect(outcome(answer(200, ["spent": "true", "meters": meters, "at": .number(Double(NOW))])).kind == .unanswered)
    }

    @Test func usedUpCarriesWhatTheAnswerSaysIsLeftOnAnyStatusButA200A5xxAnd429() {
        func usedUp(_ status: Int, _ left: LicenseJSON) -> UseOutcome { outcome(answer(status, ["error": "used-up", "left": left])) }
        #expect(usedUp(409, 3).kind == .usedUp && usedUp(409, 3).left == 3)
        #expect(usedUp(400, 0).left == 0)
        #expect(usedUp(409, -1).left == nil)
        #expect(usedUp(409, 1.5).left == nil)
        #expect(usedUp(503, 3).kind == .unanswered)
        #expect(usedUp(429, 3).kind == .unanswered)
    }

    @Test func storesAVerdictAsAValidateDoesAndAMissingAnswerAsTheWaitOfAnUnansweredRequest() {
        let revoked = outcome(answer(403, ["error": "revoked", "spends": [["id": .string(spendId("A")), "n": 1]]]))
        #expect(revoked.kind == .refused && revoked.refusal == .revoked)
        #expect(revoked.confirmed == [.count(id: spendId("A"), n: 1)])
        #expect(
            revoked.patch.json == [
                "checkedMajor": 3, "backoffSince": .number(Double(NOW)), "backoffMs": .number(Double(Waits.askAgainMs)),
                "deviceKind": "machine", "refused": "revoked", "refusedMajor": .null, "refusedFor": .null, "lease": .null,
            ]
        )
        #expect(
            outcome(nil).patch.json == [
                "backoffSince": .number(Double(NOW)), "backoffMs": .number(Double(Waits.retryUnansweredMs)), "deviceKind": "machine",
            ]
        )
        #expect(outcome(answer(500, nil)).patch.changes.isEmpty)
    }

    // MARK: - the reports

    @Test func reportsAreTheJournalOldestFirstWithAVoidMarkedNoneForNoneAndAtMost64() {
        #expect(spendsReported([]) == nil)
        let report = spendsReported([entry(.void, 1, NOW), entry(id: spendId("B"), .unanswered, 1, NOW)])
        #expect(
            report == [
                ["id": "AAAAAAAAAAAAAAAAAAAAAA", "meter": "exports", "n": 1, "at": .number(Double(NOW)), "void": true],
                ["id": .string(spendId("B")), "meter": "exports", "n": 1, "at": .number(Double(NOW))],
            ]
        )
        let many = (0..<(maxPendingSpends + 3)).map { entry(id: numbered($0), .offline, 1, NOW) }
        #expect(spendsReported(many)?.arrayValue?.count == maxPendingSpends)
    }

    @Test func reportsAreConfirmedByAnAnswerThatIsNotA5xxA429OrNoneReadLeniently() {
        let body: LicenseJSON = [
            "spends": [
                ["id": "a", "n": 2], ["id": "b", "void": true], ["id": "c", "n": 0], ["n": 1], "x", ["id": "d", "n": 1.5],
                ["id": "e", "void": "true"], ["id": "f", "n": 9_007_199_254_740_992.0],
            ]
        ]
        #expect(spendsConfirmed(answer(200, body)) == [.count(id: "a", n: 2), .void(id: "b")])
        #expect(spendsConfirmed(answer(403, body)).count == 2)
        for status in [500, 503, 429] { #expect(spendsConfirmed(answer(status, body)).isEmpty) }
        #expect(spendsConfirmed(nil).isEmpty)
        #expect(spendsConfirmed(answer(200, ["spends": "x"])).isEmpty)
    }
}
