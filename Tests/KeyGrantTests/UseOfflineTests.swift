import Foundation
import Testing

@testable import KeyGrant

/// `use(_:_:)` when nothing answers: the allowance, the journal and its waits, what is stored of a
/// spend, and the state a licence leaves behind.
@Suite("metered uses: offline", suiteTimeLimit)
struct UseOfflineTests {
    func offlineLimit(_ left: Int) -> UseResult { .refused(.offlineLimit, left: left) }
    let noMeter = UseResult.refused(.noMeter)

    /// A key whose exports have the allowance `offline`.
    func limited(_ offline: Int) throws -> Harness {
        try Harness.holding(met: ["exports": ["left": 90, "total": 100, "offline": .number(Double(offline))]])
    }

    // MARK: - with no answer

    @Test func spendsFromTheAllowanceJournalsTheSpendUnderTheIDItSentAndWaitsAMinute() async throws {
        let h = try Harness.holding()
        h.http.setFail(true)
        #expect(await h.license.use("exports", 1) == .spent(left: 89, offline: true))
        let sent = try #require(h.useBody()["id"]?.stringValue)
        #expect(h.journal == [SpendEntry(id: sent, meter: "exports", n: 1, at: NOW, kind: .unanswered)])
        #expect(h.stored?.backoffSince == NOW && h.stored?.backoffMs == Waits.retryUnansweredMs)
        // Inside the wait it asks nothing: the spend is made with no request, and grows one entry.
        #expect(await h.license.use("exports", 2) == .spent(left: 87, offline: true))
        #expect(h.http.count("use") == 1)
        #expect(kindsAndCounts(h.journal) == ["unanswered 1", "offline 2"])
        #expect(await h.license.use("exports", 1) == .spent(left: 86, offline: true))
        #expect(kindsAndCounts(h.journal) == ["unanswered 1", "offline 3"])
    }

    @Test func refusesASpendPastTheAllowanceAndPastWhatIsLeft() async throws {
        let h = try limited(3)
        h.http.setFail(true)
        #expect(await h.license.use("exports", 2) == .spent(left: 88, offline: true))
        #expect(await h.license.use("exports", 2) == offlineLimit(88))
        #expect(await h.license.use("exports", 1) == .spent(left: 87, offline: true))
        #expect(await h.license.use("exports", 1) == offlineLimit(87))
        let low = try Harness.holding(met: ["exports": ["left": 2, "total": 100, "offline": 50]])
        low.http.setFail(true)
        #expect(await low.license.use("exports", 3) == offlineLimit(2))
        #expect(await low.license.use("exports", 2) == .spent(left: 0, offline: true))
        #expect(await low.license.use("exports", 1) == offlineLimit(0))
    }

    /// A state a storage adapter built in code may hold any time and any count: no value crashes a
    /// call, and a figure out of range is a meter with nothing left.
    @Test func neverTrapsOnAStateWithTimesAndCountsAtTheEndsOfInt() async throws {
        for extreme in [Int.min, Int.max] {
            let h = try Harness.holding { state in
                state.spends = [
                    entry(id: numbered(0), .unanswered, Int.max, Int.min),
                    entry(id: numbered(1), .void, Int.max, Int.max),
                    entry(id: numbered(2), .offline, 1, NOW),
                ]
                state.meterFigures = ["exports": MeterFigure(left: extreme, total: Int.max, offline: Int.max, resets: false, at: Int.max)]
            }
            h.http.setFail(true)
            #expect(await h.license.use("exports", 1) == offlineLimit(0), "\(extreme)")
            // The refused spend's take-back landed, and with it the horizon: the entry from the far
            // past is given up, the one spend of 1 is not.
            let meter = await h.license.status().meters["exports"]
            #expect(meter?.unsynced == 1 && meter?.left == (extreme == .min ? 0 : extreme - 1), "\(extreme) \(String(describing: meter))")
            // A clock at the top of Int (the lease is long over): the calls answer, whatever they answer.
            h.clock.set(Int.max)
            let late = await h.license.use("exports", 1)
            #expect(!late.ok, "\(extreme)")
            _ = await h.license.status()
            _ = try? await h.license.deactivate()
        }
    }

    @Test func refusesEverySpendWithNoAnswerOnAMeterWhoseAllowanceIs0() async throws {
        let h = try Harness.holding()
        h.http.setFail(true)
        #expect(await h.license.use("renders", 1) == offlineLimit(5))
        // Online it spends as any other.
        h.http.setFail(false)
        h.clock.set(NOW + 2 * MINUTE)
        h.http.on(
            "use", status: 200,
            json: [
                "spent": true, "at": .number(Double(NOW + 2 * MINUTE)),
                "meters": ["renders": ["left": 4, "total": 5, "offline": 0, "resets": true]],
            ]
        )
        #expect(await h.license.use("renders", 1) == .spent(left: 4))
    }

    @Test func journalsARefusalOfASpendThatWasSentAsAVoidForTheServerToTakeBack() async throws {
        let h = try limited(1)
        h.http.setFail(true)
        _ = await h.license.use("exports", 1)
        h.clock.set(NOW + 2 * MINUTE)
        #expect(await h.license.use("exports", 1) == offlineLimit(89))
        let journal = h.journal
        #expect(journal.first?.kind == .unanswered && journal.first?.n == 1)
        #expect(journal.dropFirst().first == SpendEntry(id: try #require(h.useBody(1)["id"]?.stringValue), meter: "exports", n: 1, at: NOW + 2 * MINUTE, kind: .void))
    }

    @Test func asksAgainForASpendTheAllowanceRefusesThoughTheMinuteHasNotPassed() async throws {
        let h = try limited(1)
        h.http.setFail(true)
        _ = await h.license.use("exports", 1)
        // Inside the wait, but the allowance cannot cover it: asked all the same, so an online customer is not refused.
        #expect(await h.license.use("exports", 1) == offlineLimit(89))
        #expect(h.http.count("use") == 2)
        #expect(h.journal.map(\.kind) == [.unanswered, .void])
    }

    @Test func servesACustomerWhoIsBackOnlineAtOnceThoughTheLastOutageLeftAWait() async throws {
        let h = try Harness.holding()
        h.http.setFail(true)
        // The outage: a spend the allowance covers is made with no answer, and the minute's wait begins.
        #expect(await h.license.use("exports", 1) == .spent(left: 89, offline: true))
        h.http.setFail(false)
        h.http.on(
            "use", status: 200,
            json: ["spent": true, "at": .number(Double(NOW)), "meters": ["renders": ["left": 4, "total": 5, "offline": 0, "resets": true]]]
        )
        #expect(await h.license.use("renders", 1) == .spent(left: 4))
        h.http.on("use") { _ in Harness.spent(70, at: NOW) }
        // The server's 70 less the one spend not yet reported.
        #expect(await h.license.use("exports", 50) == .spent(left: 69))
        h.http.on(
            "use", status: 200,
            json: ["spent": true, "at": .number(Double(NOW)), "meters": ["credits": ["left": 9, "total": 10, "offline": 0]]]
        )
        // A meter the lease lacks, which the server knows.
        #expect(await h.license.use("credits", 1) == .spent(left: 9))
        // A spend the allowance covers still waits out the minute.
        let asked = h.http.count("use")
        #expect(await h.license.use("exports", 1).offline)
        #expect(h.http.count("use") == asked)
    }

    @Test(arguments: [(500, LicenseJSON.object(["error": "boom"])), (503, .null), (429, .object(["error": "rate-limited"]))])
    func countsA5xxAndA429AsNoAnswerSavesNothingOfThemAndJournalsTheSpendInDoubt(status: Int, body: LicenseJSON) async throws {
        let h = try Harness.holding()
        h.http.on("use") { _ in LicenseHTTPResponse(status: status, json: body.isNull ? nil : body) }
        #expect(await h.license.use("exports", 1) == .spent(left: 89, offline: true), "\(status)")
        #expect(h.journal.first?.kind == .unanswered && h.journal.first?.n == 1, "\(status)")
        #expect(h.stored?.backoffSince == nil, "\(status)")
    }

    @Test(arguments: [
        (200, LicenseJSON.object(["spent": false])), (200, .string("ok")), (200, .null), (400, .object(["error": "invalid-request"])),
        (404, .object(["error": "invalid-key"])), (403, .object(["error": "something-new"])), (401, .string("denied")),
    ])
    func countsAnyAnswerItCannotUseAsNoAnswerTooAndSavesNothingOfIt(status: Int, body: LicenseJSON) async throws {
        let h = try Harness.holding()
        h.http.on("use") { _ in LicenseHTTPResponse(status: status, json: body.isNull ? nil : body) }
        #expect(await h.license.use("exports", 1) == .spent(left: 89, offline: true), "\(status) \(body)")
        #expect(h.journal.first?.kind == .unanswered, "\(status) \(body)")
        #expect(h.stored?.backoffSince == nil && h.stored?.refused == nil, "\(status) \(body)")
    }

    @Test func doesNotTakeTheConfirmationsOfAnAnswerItCannotUse() async throws {
        let h = try Harness.holdingJournal([entry(id: spendId("E"), .unanswered, 1, NOW)])
        h.http.on("use", status: 500, json: ["spends": [["id": .string(spendId("E")), "n": 1]]])
        h.clock.set(NOW + 2 * MINUTE)
        _ = await h.license.use("exports", 1)
        // It asked, and the entry the answer named is still there.
        #expect(h.http.count("use") == 1)
        #expect(h.journal.contains { $0.id == spendId("E") })
    }

    @Test func asksAgainOnceTheMinuteIsOverAndKeepsTheJournalsWaitDoublingToAnHour() async throws {
        let h = try Harness.holding(met: ["exports": ["left": 1_000_000, "total": 1_000_000, "offline": 1_000_000]])
        h.http.setFail(true)
        var at = NOW
        for (i, wait) in [1, 2, 4, 8, 16, 32, 60, 60].enumerated() {
            h.clock.set(at)
            _ = await h.license.use("exports", 1)
            #expect(h.http.count("use") == i + 1, "ask \(i + 1)")
            // One millisecond short of the wait: not asked.
            h.clock.set(at + wait * MINUTE - 1)
            _ = await h.license.use("exports", 1)
            #expect(h.http.count("use") == i + 1, "short of wait \(i + 1)")
            at += wait * MINUTE
        }
    }

    @Test func keepsTheJournalsWaitWhenTheDeviceClockIsSetBack() async throws {
        let h = try Harness.holding()
        h.http.setFail(true)
        h.clock.set(NOW + 10 * MINUTE)
        _ = await h.license.use("exports", 1)
        h.clock.set(NOW)
        _ = await h.license.use("exports", 1)
        #expect(h.http.count("use") == 1)
    }

    @Test func asksAtOnceWhenAStoredNoAnswerWaitBeginsAfterTheDeviceClock() async throws {
        let h = try Harness.holding { $0.backoffSince = NOW + 10 * MINUTE; $0.backoffMs = Waits.retryUnansweredMs }
        h.http.on("use") { _ in Harness.spent(89, at: NOW) }
        #expect(await h.license.use("exports", 1) == .spent(left: 89))
    }

    @Test func asksWhenTheNewestUnansweredSpendWasOpenedAfterTheGuardedClock() async throws {
        // It jumped ahead and was corrected: asked, not stopped for days.
        let ahead = try Harness.holdingJournal([entry(.unanswered, 1, NOW + 5 * DAY)])
        ahead.http.on("use") { _ in Harness.spent(89, at: NOW) }
        #expect(await ahead.license.use("exports", 1) == .spent(left: 88))
        #expect(ahead.http.count("use") == 1)
        // One opened at the guarded clock waits as it would.
        let now = try Harness.holdingJournal([entry(.unanswered, 1, NOW)])
        now.http.on("use") { _ in Harness.spent(89, at: NOW) }
        _ = await now.license.use("exports", 1)
        #expect(now.http.count("use") == 0)
    }

    @Test func doesNotWaitOnALongerWaitAValidateSetTheUseEndpointIsAskedAllTheSame() async throws {
        let h = try Harness.holding { $0.backoffSince = NOW; $0.backoffMs = Waits.askAgainMs }
        h.http.on("use") { _ in Harness.spent(89, at: NOW) }
        #expect(await h.license.use("exports", 1) == .spent(left: 89))
    }

    @Test func refusesAMeterTheKeyHasNoFigureForAsNoMeterAndJournalsAVoidWhenInDoubt() async throws {
        let h = try Harness.holding()
        h.http.setFail(true)
        #expect(await h.license.use("credits", 1) == noMeter)
        #expect(h.journal.first?.kind == .void && h.journal.first?.meter == "credits" && h.journal.first?.n == 1)
        // A wait running does not stop the ask: the server may know a meter the lease does not name.
        let waiting = try Harness.holding { $0.backoffSince = NOW; $0.backoffMs = Waits.retryUnansweredMs }
        waiting.http.setFail(true)
        #expect(await waiting.license.use("credits", 1) == noMeter)
        #expect(waiting.http.count("use") == 1)
        #expect(waiting.journal.first?.kind == .void)
    }

    func fullJournal() -> [SpendEntry] {
        (0..<maxPendingSpends).map { entry(id: numbered($0, "x"), .unanswered, 1, NOW - 1, meter: "m\($0)") }
    }

    @Test func fillsTheJournalTo64AndRefusesThe65thSpendAsPastTheAllowance() async throws {
        let full = fullJournal()
        let h = try Harness.holding { $0.spends = full; $0.backoffSince = NOW; $0.backoffMs = Waits.retryUnansweredMs }
        // A new entry has no room: the spend is refused, though the allowance had it.
        #expect(await h.license.use("exports", 1) == offlineLimit(90))
        #expect(h.journal.count == maxPendingSpends)
    }

    @Test func letsAnOfflineEntryThatIsAlreadyOpenGrowWhenTheJournalIsFull() async throws {
        let full = [entry(id: String(repeating: "x", count: 22), .offline, 2, NOW)] + fullJournal().dropLast()
        let h = try Harness.holding { $0.spends = full; $0.backoffSince = NOW; $0.backoffMs = Waits.retryUnansweredMs }
        #expect(await h.license.use("exports", 1) == .spent(left: 87, offline: true))
        #expect(h.journal.count == maxPendingSpends && h.journal.first?.n == 3)
    }

    @Test func waitsTheHourAfterAJournalOf64UnansweredEntriesWithNothingOverflowing() async throws {
        // 64 entries: 2^63 minutes would overflow; the wait is the hour, computed with its cap first.
        let opened = NOW - 10 * MINUTE
        let spends = (0..<64).map { entry(id: numbered($0, "u"), .unanswered, 1, opened + $0, meter: "credits") }
        let newest = opened + 63
        let h = try Harness.holding { $0.spends = spends }
        h.http.setFail(true)
        h.clock.set(newest + 60 * MINUTE - 1)
        _ = await h.license.use("exports", 1)
        #expect(h.http.count("use") == 0, "an hour has not passed")
        h.clock.set(newest + 60 * MINUTE)
        _ = await h.license.use("exports", 1)
        #expect(h.http.count("use") == 1, "an hour has passed")
    }

    // MARK: - the journal

    @Test func survivesASaveThatFailsItCountsTowardTheAllowanceAndTheStatusAndLandsWithTheNextSave() async throws {
        let h = try limited(2)
        h.http.setFail(true)
        h.storage.failWrites()
        #expect(await h.license.use("exports", 1) == .spent(left: 89, offline: true))
        #expect(await h.license.use("exports", 1) == .spent(left: 88, offline: true))
        #expect(h.journal.isEmpty)
        // It counts: the allowance is spent, and the status shows it.
        #expect(await h.license.use("exports", 1) == offlineLimit(88))
        #expect(await h.license.status().meters["exports"] == MeterStatus(left: 88, total: 100, offline: 2, unsynced: 2, resets: false))
        h.storage.failWrites(false)
        _ = await h.license.status()
        // The third call was asked, and in doubt: the server is told it is taken back.
        let journal = h.journal
        #expect(journal.filter { $0.kind != .void }.map(\.n).reduce(0, +) == 2)
        #expect(journal.filter { $0.kind == .void }.count == 1)
        // Landed once: a failing disk again changes nothing the view shows.
        h.storage.failWrites()
        #expect(await h.license.status().meters["exports"]?.unsynced == 2)
    }

    @Test func landsWithTheNextUseThatCanSaveInOrder() async throws {
        let h = try Harness.holding()
        h.http.setFail(true)
        h.storage.failWrites()
        _ = await h.license.use("exports", 1)
        h.storage.failWrites(false)
        h.http.setFail(false)
        // The server records the report the request carries, and says so.
        h.http.on("use") { body in
            let confirmed = (body["spends"]?.arrayValue ?? []).map { spend -> LicenseJSON in
                ["id": spend["id"] ?? .null, "n": spend["n"] ?? .null]
            }
            return LicenseHTTPResponse(
                status: 200,
                json: ["spent": true, "at": .number(Double(NOW)), "meters": ["exports": ["left": 88, "total": 100, "offline": 10]], "spends": .array(confirmed)]
            )
        }
        h.clock.set(NOW + 2 * MINUTE)
        #expect(await h.license.use("exports", 1) == .spent(left: 88))
        // The earlier spend rode this request as a report, and its confirmation dropped it.
        #expect(h.useBody(1)["spends"]?.arrayValue?.count == 1)
        #expect(h.journal.isEmpty)
    }

    @Test func landsOnTheStateAsStoredNowSoASecondProcesssSpendIsNeverLost() async throws {
        // Through the storage's own merge (`update`): the other process saves between read and save.
        let h = try limited(10)
        h.http.setFail(true)
        let app = try h.app(storage: Racing(over: h, theirs: [entry(id: spendId("O"), .offline, 4, NOW - 5)]))
        // The first no-answer spend is journaled beside theirs; the second (in its wait) grows the offline entry that is there.
        #expect(await app.use("exports", 1).ok)
        #expect(await app.use("exports", 2).ok)
        let shown = h.journal.map { ($0.id == spendId("O") ? "theirs" : $0.kind.rawValue) + " \($0.n)" }
        #expect(shown == ["theirs 6", "unanswered 1"])
    }

    @Test func landsOnTheFileAsItIsAtTheSaveWhenTheStorageHasNoMergeOfItsOwn() async throws {
        // The write-through path reads the file as it is at the save, not as the call found it: the
        // other process saves while this one's request is in flight.
        let h = try limited(10)
        let file = h.storage
        h.http.on("use") { _ in
            var state = file.stored ?? StoredState()
            state.spends = [entry(id: spendId("O"), .offline, 4, NOW - 5)]
            file.set(state)
            return LicenseHTTPResponse(status: 503, json: [:])
        }
        #expect(await h.license.use("exports", 1).ok)
        // Theirs is there as they left it, and this spend, in doubt, beside it.
        #expect(kindsAndCounts(h.journal) == ["offline 4", "unanswered 1"])
        #expect(h.journal.first?.id == spendId("O"))
    }

    @Test func keepsAnEntryInTheJournalOfTheActivationItIsAboutAndNothingOfItOnAnotherSeat() async throws {
        let figures = ["exports": MeterFigure(left: 50, total: 100, offline: 10, resets: false, at: NOW)]
        let h = try Harness.holding { $0.spends = [entry(.offline, 2, NOW)]; $0.meterFigures = figures }
        // The same seat activated again keeps it.
        h.http.on("activate", status: 200, json: ["lease": .string(h.signer.meteredLease()), "activationId": "act_1"])
        #expect(await h.license.activate(KEY) == .activated)
        #expect(h.journal.count == 1)
        #expect(h.stored?.meterFigures != nil)
        // Another seat of the same key starts afresh.
        h.http.on("activate", status: 200, json: ["lease": .string(h.signer.meteredLease(over: ["aid": "act_9"])), "activationId": "act_9"])
        #expect(await h.license.activate(KEY) == .activated)
        #expect(h.stored?.activationId == "act_9" && h.stored?.spends == nil && h.stored?.meterFigures == nil)
    }

    @Test func dropsTheJournalOfAnOldActivationWhenAnotherKeyIsActivatedUnreported() async throws {
        let h = try Harness.holding { $0.spends = [entry(.offline, 2, NOW)] }
        let another = "SLUICE-OTHER-AAAA-BBBB-CCCC"
        let lease = h.signer.meteredLease(over: ["sub": .string(another), "aid": "act_2"])
        h.http.on("activate", status: 200, json: ["lease": .string(lease), "activationId": "act_2"])
        #expect(await h.license.activate(another) == .activated)
        #expect(h.http.count("validate") == 0)
        #expect(h.stored?.key == another && h.stored?.spends == nil)
    }

    @Test func dropsEntriesUnreportedForMoreThan180DaysAtTheNextSaveAndKeepsTheOnesInside() async throws {
        let old = String(repeating: "o", count: 22), recent = String(repeating: "n", count: 22)
        let h = try Harness.holdingJournal([
            entry(id: old, .unanswered, 1, NOW - 181 * DAY), entry(id: recent, .unanswered, 1, NOW - 179 * DAY),
        ])
        h.http.setFail(true)
        _ = await h.license.use("exports", 1)
        let ids = h.journal.map(\.id)
        #expect(!ids.contains(old) && ids.contains(recent))
        #expect(pendingMaxMs == 180 * DAY)
    }

    @Test func keepsAnEntryOpenedExactly180DaysAgo() async throws {
        let boundary = String(repeating: "b", count: 22)
        let h = try Harness.holdingJournal([entry(id: boundary, .unanswered, 1, NOW - pendingMaxMs)])
        h.http.setFail(true)
        _ = await h.license.use("exports", 1)
        #expect(h.journal.contains { $0.id == boundary })
        h.clock.set(NOW + 1)
        _ = await h.license.use("exports", 1)
        #expect(h.journal.allSatisfy { $0.id != boundary })
    }

    func state(_ raw: LicenseJSON) -> StoredState { StoredState(json: raw) }

    @Test func readsAStoredJournalThatIsNotOneAsAnEmptyJournalAndAnEntryOfAnotherShapeAsNone() async throws {
        let h = try Harness()
        let lease = h.signer.meteredLease()
        h.storage.set(state(["key": .string(KEY), "activationId": "act_1", "lastSeen": .number(Double(NOW)), "lease": .string(lease), "spends": "junk"]))
        h.http.setFail(true)
        #expect(await h.license.use("exports", 1) == .spent(left: 89, offline: true))

        let g = try Harness()
        let raw: LicenseJSON = [
            "key": .string(KEY), "activationId": "act_1", "lastSeen": .number(Double(NOW)), "lease": .string(g.signer.meteredLease()),
            "spends": [
                ["id": 3], .null, "x",
                ["id": "AAAAAAAAAAAAAAAAAAAAAA", "meter": "exports", "n": 2, "at": .number(Double(NOW)), "kind": "offline", "extra": true],
                ["id": "x", "meter": "exports", "n": 0, "at": 1, "kind": "offline"],
                ["id": "y", "meter": "exports", "n": 1.5, "at": 1, "kind": "offline"],
                ["id": "z", "meter": "exports", "n": 1, "at": -1, "kind": "offline"],
                ["id": "w", "meter": "exports", "n": 1, "at": 1, "kind": "later"],
            ],
        ]
        g.storage.set(state(raw))
        g.http.setFail(true)
        #expect(await g.license.status().meters["exports"]?.unsynced == 2)
        // The next save that lands the journal writes it without them: the status above asked and got
        // no answer, so the minute's wait is running and the spend grows the entry.
        #expect(await g.license.use("exports", 1) == .spent(left: 87, offline: true))
        #expect(kindsAndCounts(g.journal) == ["offline 3"])
        #expect(g.stored?.json["spends"]?.arrayValue?.first?.has("extra") == false)
    }

    @Test func readsStoredFiguresOfAnotherShapeAsNone() async throws {
        let h = try Harness()
        let raw: LicenseJSON = [
            "key": .string(KEY), "activationId": "act_1", "lastSeen": .number(Double(NOW)), "lease": .string(h.signer.meteredLease()),
            "meterFigures": [
                "exports": ["left": 1, "total": 100, "offline": 10, "at": .number(Double(NOW + 1)), "extra": 1],
                "renders": ["left": -1, "total": 5, "offline": 0, "at": .number(Double(NOW + 1))],
                "credits": 7,
            ],
        ]
        h.storage.set(state(raw))
        let shown = await h.license.status().meters
        #expect(shown["exports"]?.left == 1)
        // A figure of another shape is left out; the lease's own stands for that meter.
        #expect(shown["renders"]?.left == 5)
        #expect(shown["credits"] == nil)
    }

    // MARK: - the device

    @Test func keysTheInstallByTheMachineIDItReadWhenTheRequestGetsNoAnswer() async throws {
        let h = try Harness.holding(fingerprinter: IdentifyingFingerprinter { DeviceIdentity(fingerprint: "fp-machine", kind: .machine) })
        h.http.setFail(true)
        _ = await h.license.use("exports", 1)
        #expect(h.stored?.deviceKind == .machine)
    }

    // MARK: - a meter never takes the licence away

    @Test func aLicenceStaysLicensedWhenAMeterIsUsedUpAbsentOrPastItsOfflineLimit() async throws {
        let h = try limited(1)
        h.http.setFail(true)
        #expect(await h.license.use("exports", 1).ok)
        #expect(await h.license.use("exports", 1) == offlineLimit(89))
        #expect(await h.license.use("credits", 1) == noMeter)
        h.http.setFail(false)
        h.http.on("use", status: 409, json: ["error": "used-up", "left": 0])
        h.clock.set(NOW + HOUR)
        #expect(await h.license.use("exports", 1) == .refused(.usedUp, left: 0))
        #expect(await h.license.status().state == .licensed)
        #expect(await h.license.use("exports", maxMeterUses + 1).error == .invalidAmount)
    }
}
