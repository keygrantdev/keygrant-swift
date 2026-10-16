import Foundation
import Testing

@testable import KeyGrant

/// How the journal lands on the stored state, what a process keeps of what it could not save, and how
/// a lease's `met`, the stored fields, a result and a status are read and written, by the rule each
/// states.
@Suite("metered uses: the journal and what is read", suiteTimeLimit)
struct MeterJournalTests {
    let about = "act_1"

    func journal(_ spends: [SpendEntry]) -> StoredState {
        StoredState(activationId: about, spends: spends.isEmpty ? nil : spends)
    }

    func spend(_ kind: SpendKind, _ id: String, _ n: Int, meter: String = "exports", limit: Int? = nil, told: Bool = false) -> SpendOp {
        SpendOp(kind: kind, about: about, id: id, meter: meter, n: n, at: NOW, limit: limit, told: told)
    }

    func offlineOp(_ n: Int, meter: String = "exports", limit: Int? = nil, told: Bool = false) -> SpendOp {
        spend(.offline, spendId("N"), n, meter: meter, limit: limit, told: told)
    }

    func ids(_ journal: [SpendEntry]) -> [String] { journal.map(\.id) }

    /// A journal of `count` unanswered spends, each of a meter of its own.
    func crowd(_ count: Int) -> [SpendEntry] {
        (0..<count).map { entry(id: numbered($0), .unanswered, 1, NOW, meter: "m\($0)") }
    }

    // MARK: - landing a spend

    @Test func growsOneOfflineEntryForEachMeterAndOpensTheOthersOnceByID() {
        let grown = journaled(journal([entry(.offline, 3, NOW)]), .spend(offlineOp(2)), now: NOW)
        #expect(grown.spends == [entry(.offline, 5, NOW)])
        let held = journal([entry(.unanswered, 1, NOW)])
        let again = journaled(held, .spend(spend(.unanswered, "AAAAAAAAAAAAAAAAAAAAAA", 9)), now: NOW)
        #expect(again.spends == [entry(.unanswered, 1, NOW)])
        // An offline entry is the one entry of its meter; another meter opens its own.
        let two = journaled(journal([entry(.offline, 3, NOW)]), .spend(offlineOp(1, meter: "renders")), now: NOW)
        #expect(two.spends.count == 2)
    }

    @Test func anIDAlreadyInTheJournalIsLeftAsItIsAnOfflineEntrysIncluded() {
        let held = journal([entry(id: spendId("B"), .offline, 4, NOW)])
        for kind in [SpendKind.unanswered, .void] {
            let landed = journaled(held, .spend(spend(kind, spendId("B"), 9)), now: NOW)
            #expect(!landed.refused && landed.spends == held.spends, "\(kind)")
        }
        // Before its limit is judged.
        let landed = journaled(held, .spend(spend(.unanswered, spendId("B"), 9, limit: 1)), now: NOW)
        #expect(!landed.refused && landed.spends == held.spends)
    }

    @Test func refusesASpendThatWouldTakeItsMetersUnsyncedPastItsLimitAndHoldsAVoidToNone() {
        let held = journal([
            entry(.offline, 3, NOW), entry(id: spendId("B"), .unanswered, 2, NOW), entry(id: spendId("C"), .void, 50, NOW),
            entry(id: spendId("D"), .offline, 9, NOW, meter: "renders"),
        ])
        #expect(!journaled(held, .spend(offlineOp(5, limit: 10)), now: NOW).refused)
        let refused = journaled(held, .spend(offlineOp(6, limit: 10)), now: NOW)
        #expect(refused.refused && refused.spends == held.spends)
        #expect(!journaled(held, .spend(spend(.void, spendId("V"), 6, limit: 0)), now: NOW).refused)
    }

    @Test func landsASpendTheCustomerWasToldWasMadePastItsLimitAndTheCapAndNeverRefusesIt() {
        let landed = journaled(journal(crowd(maxPendingSpends)), .spend(offlineOp(1, told: true)), now: NOW)
        #expect(!landed.refused)
        #expect(landed.spends.count == maxPendingSpends + 1)
        let pastLimit = journaled(journal([entry(.offline, 3, NOW)]), .spend(offlineOp(9, limit: 5, told: true)), now: NOW)
        #expect(pastLimit.spends.first?.n == 12)
    }

    @Test func keepsTheCapOfVoidsANewOneTakingThePlaceOfTheOldestAndNeverRefusesForIt() {
        let voids = (0..<maxPendingVoids).map { entry(id: numbered($0, "v"), .void, 1, NOW - 1000 + $0) }
        let next = spend(.void, spendId("N"), 1)
        #expect(journaled(journal(Array(voids.dropFirst())), .spend(next), now: NOW).spends.count == maxPendingVoids)
        let replaced = journaled(journal(voids), .spend(next), now: NOW)
        #expect(!replaced.refused)
        #expect(ids(replaced.spends) == ids(Array(voids.dropFirst())) + [spendId("N")])
        // The same in a journal at its size of 64 (48 spends and the 16 voids): the cap of entries refuses nothing here.
        let full = crowd(maxPendingSpends - maxPendingVoids) + voids
        #expect(full.count == maxPendingSpends)
        let fullReplaced = journaled(journal(full), .spend(next), now: NOW)
        #expect(!fullReplaced.refused && fullReplaced.spends.count == maxPendingSpends)
        #expect(!ids(fullReplaced.spends).contains(voids[0].id) && ids(fullReplaced.spends).last == spendId("N"))
        // A void in a full journal that holds fewer voids than that is refused, as any spend is.
        let crowded = [entry(id: spendId("V"), .void, 1, NOW)] + crowd(maxPendingSpends - 1)
        #expect(journaled(journal(crowded), .spend(next), now: NOW).refused)
        // A void marked told is held to all of it (a void is never told); an unanswered spend is held to no void cap.
        var told = next
        told.told = true
        #expect(journaled(journal(voids), .spend(told), now: NOW).spends == replaced.spends)
        #expect(journaled(journal(crowded), .spend(told), now: NOW).refused)
        var unanswered = next
        unanswered.kind = .unanswered
        #expect(journaled(journal(voids), .spend(unanswered), now: NOW).spends.count == maxPendingVoids + 1)
    }

    @Test func refusesAnAppendPast64EntriesAndLetsAnOpenEntryGrow() {
        let full = crowd(maxPendingSpends)
        #expect(journaled(journal(full), .spend(offlineOp(1)), now: NOW).refused)
        let grown = journaled(journal([entry(.offline, 3, NOW)] + full.dropFirst()), .spend(offlineOp(1)), now: NOW)
        #expect(!grown.refused)
        #expect(grown.spends.first?.n == 4)
    }

    // MARK: - confirming, figures, the seat and the horizon

    func confirm(_ spends: [SpendEntry], _ entries: [Confirmed]) -> [SpendEntry] {
        journaled(journal(spends), .confirmed(about: about, entries: entries), now: NOW).spends
    }

    @Test func dropsAnEntryByTheCountTheServerRecordedAVoidByAVoidAndKeepsWhatGrewMeanwhile() {
        let held = entry(.offline, 3, NOW)
        let who = held.id
        func count(_ n: Int) -> [Confirmed] { [.count(id: who, n: n)] }
        #expect(confirm([held], count(3)).isEmpty)
        #expect(confirm([held], count(9)).isEmpty)
        let grown = entry(.offline, 5, NOW)
        #expect(confirm([grown], count(3)) == [grown])
        let void = entry(.void, 3, NOW)
        #expect(confirm([void], [.void(id: who)]).isEmpty)
        #expect(confirm([void], count(1)) == [void])
        let unanswered = entry(.unanswered, 3, NOW)
        #expect(confirm([unanswered], [.void(id: who)]) == [unanswered])
    }

    @Test func keepsTheNewerFigureOfEachMeterAndNothingAboutAnotherActivation() {
        let stored = ["exports": MeterFigure(left: 70, total: 100, offline: 10, resets: false, at: NOW)]
        func given(_ at: Int) -> JournalOp {
            .figures(about: about, figures: ["exports": MeterFigure(left: 50, total: 100, offline: 10, resets: false, at: at)])
        }
        func held(_ activation: String?) -> StoredState { StoredState(activationId: activation, meterFigures: stored) }
        func left(_ state: StoredState, _ at: Int) -> Int? { journaled(state, given(at), now: NOW).meterFigures["exports"]?.left }
        #expect(left(held(about), NOW + 1) == 50)
        #expect(left(held(about), NOW) == 70)
        #expect(left(held(about), NOW - 1) == 70)
        #expect(left(held("act_2"), NOW + 1) == 70)
        #expect(left(held(nil), NOW + 1) == 70)
    }

    @Test func clearsBothForAnotherSeatOrADeactivationAndKeepsThemForTheSameSeat() {
        let held = StoredState(
            activationId: about, spends: [entry(.offline, 1, NOW)],
            meterFigures: ["exports": MeterFigure(left: 70, total: 100, offline: 10, resets: false, at: NOW)]
        )
        let other = journaled(held, .activated(about: "act_2"), now: NOW)
        #expect(other.spends.isEmpty && other.meterFigures.isEmpty)
        let same = journaled(held, .activated(about: about), now: NOW)
        #expect(same.spends.count == 1 && same.meterFigures.count == 1)
        #expect(journaled(StoredState(), .activated(about: about), now: NOW).spends.isEmpty)
        let gone = journaled(held, .deactivated, now: NOW)
        #expect(gone.spends.isEmpty && gone.meterFigures.isEmpty)
    }

    @Test func dropsEntriesOpenedMoreThan180DaysAgoOnAnyOpThatLandsAndKeepsThoseExactlyThatOld() {
        let old = entry(id: spendId("O"), .unanswered, 1, NOW - pendingMaxMs - 1)
        let edge = entry(id: spendId("E"), .unanswered, 1, NOW - pendingMaxMs)
        let landed = journaled(journal([old, edge]), .spend(offlineOp(1)), now: NOW)
        #expect(ids(landed.spends) == [spendId("E"), spendId("N")])
        #expect(journaled(journal([old]), .confirmed(about: about, entries: []), now: NOW).spends.isEmpty)
        #expect(journaled(journal([old]), .activated(about: about), now: NOW).spends.isEmpty)
        // An op about another activation, or none, changes nothing: the horizon included.
        var other = offlineOp(1)
        other.about = "act_2"
        #expect(journaled(journal([old]), .spend(other), now: NOW).spends == [old])
    }

    /// A state an adapter built in code may hold any time: no time at the ends of `Int` traps a landing.
    @Test func landsOnTimesAtTheEndsOfIntWithoutTrappingAndJudgesTheHorizonByTheirDistance() {
        let early = entry(id: spendId("O"), .unanswered, 1, Int.min)
        let late = entry(id: spendId("E"), .unanswered, 1, Int.max)
        let state = journal([early, late])
        #expect(journaled(state, .confirmed(about: about, entries: []), now: NOW).spends == [late])
        #expect(journaled(state, .figures(about: about, figures: [:]), now: Int.min).spends == [early, late])
        #expect(journaled(state, .figures(about: about, figures: [:]), now: Int.max).spends == [late])
        var farBack = offlineOp(1)
        farBack.at = Int.min
        let landed = journaled(journal([late]), .spend(farBack), now: Int.max)
        #expect(!landed.refused && ids(landed.spends) == [spendId("E"), spendId("N")])
    }

    @Test func landsOpsInOrderOnAStateAndIsThatStateItselfWithNone() {
        let state = journal([])
        #expect(landJournal(state, [], now: NOW).state == state)
        let confirmAll = JournalOp.confirmed(about: about, entries: [.count(id: spendId("N"), n: 2)])
        let landed = landJournal(state, [.spend(offlineOp(2)), confirmAll], now: NOW)
        #expect(landed.state.spends == nil)
        #expect(landed.refused == [false, false])
    }

    // MARK: - what a process keeps

    /// Offline spends a second apart, so the entry a fold keeps can be told by its time.
    func offlineOf(_ n: Int, _ meter: String) -> JournalOp {
        var op = offlineOp(n, meter: meter)
        op.id = numbered(n, "q")
        op.at = NOW + 1000 * n
        return .spend(op)
    }

    func figureOp(_ left: Int, _ at: Int) -> JournalOp {
        .figures(about: about, figures: ["exports": MeterFigure(left: left, total: 100, offline: 10, resets: false, at: at)])
    }

    func confirmedOp(_ n: Int) -> JournalOp {
        .confirmed(about: about, entries: [.count(id: spendId("A"), n: n)])
    }

    @Test func foldsOfflineSpendsOfOneMeterFiguresAndConfirmationsAndNothingAcrossAnotherKindOfChange() {
        var folded = offlineOp(6)
        folded.id = numbered(1, "q")
        folded.at = NOW + 1000
        #expect(compacted([offlineOf(1, "exports"), offlineOf(2, "exports"), offlineOf(3, "exports")]) == [.spend(folded)])
        #expect(compacted([offlineOf(1, "exports"), offlineOf(2, "renders"), offlineOf(3, "exports")]).count == 3)
        #expect(compacted([figureOp(70, NOW), figureOp(50, NOW + 1)]) == [figureOp(50, NOW + 1)])
        #expect(compacted([figureOp(50, NOW + 1), figureOp(70, NOW)]) == [figureOp(50, NOW + 1)])
        #expect(compacted([confirmedOp(2), confirmedOp(3)]) == [confirmedOp(3)])
        #expect(compacted([confirmedOp(3), confirmedOp(2)]) == [confirmedOp(3)])
        // Never across another kind of change, another activation or a deactivation.
        #expect(compacted([offlineOf(1, "exports"), .deactivated, offlineOf(2, "exports")]).count == 3)
        var otherSeat = offlineOp(2)
        otherSeat.about = "act_2"
        #expect(compacted([offlineOf(1, "exports"), .spend(otherSeat)]).count == 2)
        #expect(compacted([offlineOf(1, "exports"), .activated(about: about), offlineOf(2, "exports")]).count == 3)
        let void = JournalOp.spend(spend(.void, spendId("V"), 1))
        #expect(compacted([offlineOf(1, "exports"), void, offlineOf(2, "exports")]).count == 3)
        // A void and a count of one id are two confirmations.
        let both = JournalOp.confirmed(about: about, entries: [.void(id: spendId("A"))])
        #expect(
            compacted([confirmedOp(1), both])
                == [.confirmed(about: about, entries: [.count(id: spendId("A"), n: 1), .void(id: spendId("A"))])]
        )
    }

    @Test func whatIsFoldedLandsAsTheOpsItWasFoldedFromWould() {
        let base = journal([])
        func offline(_ letter: String, _ n: Int, ago: Int) -> JournalOp {
            var op = offlineOp(n)
            op.id = spendId(letter)
            op.at = NOW - ago
            return .spend(op)
        }
        let ops = [offline("a", 1, ago: 3000), offline("b", 2, ago: 2000), offline("c", 4, ago: 1000)]
        let landed = landJournal(base, compacted(ops), now: NOW).state
        #expect(landed == landJournal(base, ops, now: NOW).state)
        // One entry, with the first spend's id and time.
        #expect(landed.spends == [entry(id: spendId("a"), .offline, 7, NOW - 3000)])
    }

    @Test func keepsOnlyTheNewestVoidsInMemoryAndEveryOtherChange() {
        func void(_ i: Int) -> JournalOp { .spend(spend(.void, numbered(i, "v"), 1)) }
        var ops = (0..<20).map(void)
        ops.insert(.spend(offlineOp(1)), at: 5)
        ops.append(.deactivated)
        let kept = boundedVoids(ops)
        let voids = kept.filter { if case .spend(let s) = $0 { s.kind == .void } else { false } }
        #expect(voids.count == maxPendingVoids)
        #expect(voids.first == void(4), "the oldest four went")
        #expect(kept.contains(.spend(offlineOp(1))) && kept.contains(.deactivated))
        #expect(boundedVoids(Array(ops[16...])).count == ops[16...].count)
    }

    // MARK: - a lease's met, read leniently

    func met(_ text: String) throws -> [String: BaseFigure] {
        let json = try #require(JSONText.parse(text), "JSON: \(text)")
        return metersOf(json)
    }

    @Test func readsAMetThatIsNotAnObjectAsNoMeters() throws {
        for text in ["null", "[]", #"[{"left":1,"total":1,"offline":1}]"#, #""exports""#, "7", "true"] {
            #expect(try met(text).isEmpty, "\(text)")
        }
    }

    @Test func dropsAMemberWhoseFiguresAreNotNonNegativeWholeNumbersOfAtMost2To53Minus1() throws {
        func meter(_ left: String) -> String { #"{"exports":{"left":\#(left),"total":10,"offline":1}}"# }
        for kept in ["4", "4.0", "4e0", "0", "-0", "9007199254740991", "9.007199254740991e15"] {
            #expect(try met(meter(kept)).count == 1, "\(kept)")
        }
        for dropped in [
            "-1", "1.5", "0.5", #""4""#, "null", "true", "[4]", "{}", "9007199254740992", "9007199254740993", "1e400", "-1e400", "1e19",
            "18446744073709551615", "123456789012345678901234567890",
        ] {
            #expect(try met(meter(dropped)).isEmpty, "\(dropped)")
        }
        // Only the member that is not a meter goes, never the meters beside it.
        let both = #"{"a":{"left":4,"total":10,"offline":1},"b":{"left":-1,"total":10,"offline":1},"c":{"left":4,"total":10,"offline":1}}"#
        #expect(try met(both).keys.sorted() == ["a", "c"])
    }

    @Test func readsResetsAsTrueOnlyForJSONTrue() throws {
        func resets(_ value: String) throws -> Bool? {
            try met(#"{"m":{"left":1,"total":1,"offline":0,"resets":\#(value)}}"#)["m"]?.resets
        }
        #expect(try resets("true") == true)
        for other in ["false", "null", "1", #""true""#, "[true]", "{}", "0"] { #expect(try resets(other) == false, "\(other)") }
        #expect(try met(#"{"m":{"left":1,"total":1,"offline":0}}"#)["m"]?.resets == false)
    }

    @Test func keepsNamesAsTheyAreTheServersCapsUnenforcedAndAMetersOtherMembersIgnored() throws {
        let nine = (0..<9).map { #""m\#($0)":{"left":20,"total":10,"offline":1,"overage":3,"extra":{"a":1}}"# }.joined(separator: ",")
        #expect(try met("{\(nine)}").count == 9, "more than 8 meters, and left above total")
        let named = try met(
            #"{"__proto__":{"left":4,"total":10,"offline":1},"":{"left":4,"total":10,"offline":1},"éxports":{"left":4,"total":10,"offline":1}}"#
        )
        #expect(named.keys.sorted() == ["", "__proto__", "éxports"])
        // The last of a repeated name is the one read, as JSON.parse reads it.
        #expect(try met(#"{"m":{"left":1,"total":9,"offline":0},"m":{"left":2,"total":9,"offline":0}}"#)["m"]?.left == 2)
    }

    @Test func aFigureOutOfADoublesRangeDropsItsMemberAndNeverTheLease() async throws {
        let h = try Harness()
        let lease = h.signer.rawLease(met: #"{"huge":{"left":1e400,"total":10,"offline":1},"kept":{"left":1,"total":2,"offline":0}}"#)
        let verified = verifyLease(lease, keys: try KeySet(publicJWK: h.signer.publicJWK), now: NOW)
        #expect(verified.failure == nil)
        #expect(verified.claims?.met?.keys.sorted() == ["kept"])
        // And through the SDK: the lease licenses, with the meter that is whole.
        h.storage.set(licensedState(with: lease))
        let status = await h.license.status()
        #expect(status.state == .licensed)
        #expect(status.meters.keys.sorted() == ["kept"])
    }

    @Test func aMetClaimIsAbsentNullOrAnyJSONAndALeaseWithNoneIsUnchanged() throws {
        let signer = Signer()
        let keys = try KeySet(publicJWK: signer.publicJWK)
        func claims(_ text: String) throws -> LeaseClaims {
            try #require(verifyLease(signer.rawLease(met: text), keys: keys, now: NOW).claims)
        }
        for text in ["null", "[]", "7"] { #expect(try claims(text).met == [:], "\(text)") }
        let without = verifyLease(signer.meteredLease(met: nil), keys: keys, now: NOW)
        #expect(without.claims?.met == nil)
        #expect(without.json["claims"]?["met"] == nil)
        // Present, it is written back as the vectors write it.
        let with = verifyLease(signer.meteredLease(), keys: keys, now: NOW)
        #expect(with.json["claims"]?["met"] == metersJSON(metersOf(meters())))
    }

    @Test func readsAnOutOfRangeNumberAsInfinityNeverAsNoJSON() {
        let read = JSONText.parse(#"{"a":1e400,"b":-1e999,"s":"1e400 \" 1e500","n":[2e308,3]}"#)
        #expect(read?["s"] == .string(#"1e400 " 1e500"#))
        #expect(read?["a"]?.numberValue == .infinity)
        #expect(read?["b"]?.numberValue == -.infinity)
        #expect(read?["n"]?.arrayValue?[1] == 3)
        #expect(JSONText.parse("not json") == nil)
        #expect(JSONText.parse(#"{"a":1e400"#) == nil)
        #expect(JSONText.parse("[1e5,1.0e-400]")?.arrayValue?[0] == 100_000)
    }

    // MARK: - the stored state

    @Test func theStoredStateReadsTheJournalLenientlyAndWritesItBackWithoutWhatItDropped() throws {
        let raw = try #require(
            JSONText.parse(
                """
                {"key":"\(KEY)","spends":[
                  {"id":"A","meter":"m","n":2,"at":5,"kind":"offline","extra":1},
                  {"id":"B","meter":"m","n":0,"at":5,"kind":"offline"},
                  {"id":"C","meter":"m","n":1,"at":-5,"kind":"offline"},
                  {"id":"D","meter":"m","n":1,"at":5,"kind":"other"},
                  {"id":"E","meter":3,"n":1,"at":5,"kind":"offline"},
                  {"id":"F","meter":"m","n":1,"at":5.5,"kind":"void"},
                  17],
                "meterFigures":{
                  "m":{"left":1,"total":2,"offline":0,"resets":true,"at":9,"extra":true},
                  "bad":{"left":1,"total":2,"offline":0,"at":-9},
                  "worse":"x"}}
                """
            )
        )
        let read = StoredState(json: raw)
        #expect(read.spends == [SpendEntry(id: "A", meter: "m", n: 2, at: 5, kind: .offline)])
        #expect(read.meterFigures?.count == 1)
        let written = read.json
        #expect(written["spends"] == [["id": "A", "meter": "m", "n": 2, "at": 5, "kind": "offline"]])
        #expect(written["meterFigures"] == ["m": ["left": 1, "total": 2, "offline": 0, "resets": true, "at": 9]])
        // Neither field is an unknown field of a newer SDK, kept as it was.
        #expect(read.otherFields.isEmpty)
        // A journal that is not a list, and one with no valid entry, is the field absent.
        for spends: LicenseJSON in ["junk", [:], 7, [.null, 1], []] {
            let state = StoredState(json: ["spends": spends])
            #expect(state.spends == nil)
            #expect(state.json["spends"] == nil)
        }
    }

    @Test func aJournalAnAppPutInOtherFieldsIsNotWrittenBesideTheStatesOwn() {
        var state = StoredState(spends: [entry(.offline, 1, NOW)])
        state.otherFields["spends"] = "junk"
        state.otherFields["meterFigures"] = "junk"
        #expect(state.json["spends"] == [spendJSON(entry(.offline, 1, NOW))])
        #expect(state.json["meterFigures"] == nil)
    }

    @Test func roundTripsTheStateThroughItsJSONAndCodable() throws {
        let state = StoredState(
            key: KEY, activationId: "act_1", spends: [entry(.unanswered, 2, NOW), entry(id: spendId("V"), .void, 1, NOW)],
            meterFigures: ["exports": MeterFigure(left: 70, total: 100, offline: 10, resets: true, at: NOW)]
        )
        #expect(StoredState(json: state.json) == state)
        let decoded = try JSONDecoder().decode(StoredState.self, from: JSONEncoder().encode(state))
        #expect(decoded == state)
    }

    // MARK: - the words and the status

    @Test func everyErrorIsItsWordAndAResultSaysWhatItIs() {
        let words: [(UseError, String)] = [
            (.invalidAmount, "invalid-amount"), (.noMeter, "no-meter"), (.usedUp, "used-up"), (.offlineLimit, "offline-limit"),
            (.notLicensed, "not-licensed"), (.storage, "storage"), (.revoked, "revoked"), (.upgrade, "upgrade"), (.outdated, "outdated"),
            (.device, "device"),
        ]
        #expect(words.count == UseError.allCases.count)
        for (error, word) in words {
            #expect(error.rawValue == word)
            #expect(UseError(rawValue: word) == error)
        }
        #expect(UseError(.device) == .device && UseError(.revoked) == .revoked)
        #expect(UseError(.upgrade) == .upgrade && UseError(.outdated) == .outdated)
        #expect(UseResult.spent(left: 89) == UseResult(ok: true, left: 89))
        #expect(UseResult.spent(left: 88, offline: true).offline)
        let used = UseResult.refused(.usedUp, left: 1)
        #expect(!used.ok && used.left == 1 && used.error == .usedUp && !used.offline)
        #expect(UseResult.refused(.storage).left == nil)
    }

    @Test func aStatusCountsItsMetersInItsEquality() {
        let plain = LicenseStatus(state: .licensed)
        var metered = plain
        #expect(metered == plain)
        metered.meters["exports"] = MeterStatus(left: 9, total: 10, offline: 1, unsynced: 1, resets: true)
        #expect(metered != plain)
        var other = metered
        other.meters["exports"]?.left = 8
        #expect(metered != other)
    }
}
