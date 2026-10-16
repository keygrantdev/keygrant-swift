import Foundation
import Testing

@testable import KeyGrant

/// The journal of unsynced spends is reported with the next validate, `use` and `deactivate`, dropped
/// only when the server confirms it, and never costs a customer a renewal or a release; and
/// `status().meters` shows each meter of the lease that licenses the device, net of the journal.
@Suite("metered uses: reports and statuses", suiteTimeLimit)
struct MeterReportTests {
    func state(_ raw: LicenseJSON) -> StoredState { StoredState(json: raw) }

    func reportedCount(_ h: Harness, _ nth: Int = 0) -> Int? { h.report(nth)?.arrayValue?.count }

    func longJournal(_ count: Int) -> [SpendEntry] {
        (0..<count).map { entry(id: numbered($0, "q"), .unanswered, 1, LONG_AGO, meter: "m\($0)") }
    }

    // MARK: - what a validate reports

    @Test func carriesTheJournalOldestFirstAVoidMarkedAndNoSpendsAtAllWhenThereIsNone() async throws {
        let h = try Harness.holdingJournal([
            entry(id: spendId("A"), .offline, 3, NOW - 3000), entry(id: spendId("B"), .unanswered, 1, NOW - 2000),
            entry(id: spendId("C"), .void, 2, NOW - 1000),
        ])
        h.renewing()
        _ = await h.license.refresh()
        #expect(
            h.report(0) == [
                ["id": .string(spendId("A")), "meter": "exports", "n": 3, "at": .number(Double(NOW - 3000))],
                ["id": .string(spendId("B")), "meter": "exports", "n": 1, "at": .number(Double(NOW - 2000))],
                ["id": .string(spendId("C")), "meter": "exports", "n": 2, "at": .number(Double(NOW - 1000)), "void": true],
            ]
        )
        let bare = try Harness.holding()
        bare.renewing()
        _ = await bare.license.refresh()
        #expect(!(try #require(bare.http.body("validate"))).has("spends"))
    }

    @Test func reportsOnlyWhatIsValidOfAStoredJournalAndRenewsAllTheSame() async throws {
        let h = try Harness()
        let stored: [String: LicenseJSON] = [
            "key": .string(KEY), "activationId": "act_1", "lastSeen": .number(Double(NOW)), "lease": .string(h.signer.meteredLease()),
            "spends": [
                ["id": "AAAAAAAAAAAAAAAAAAAAAA", "meter": "exports", "n": 2, "at": .number(Double(NOW)), "kind": "offline"],
                ["id": 4], .null, "x", ["id": .string(spendId("Z")), "meter": "exports", "n": 0, "at": .number(Double(NOW)), "kind": "offline"],
            ],
        ]
        h.storage.set(state(.object(stored)))
        h.renewing()
        #expect(await h.license.refresh().state == .licensed)
        #expect(reportedCount(h) == 1)

        let junk = try Harness()
        var raw = stored
        raw["lease"] = .string(junk.signer.meteredLease())
        raw["spends"] = ["not": "a list"]
        junk.storage.set(state(.object(raw)))
        junk.renewing()
        #expect(await junk.license.refresh().state == .licensed)
        #expect(!(try #require(junk.http.body("validate"))).has("spends"))
    }

    @Test func renewsWithAJournalThatIsFull() async throws {
        let h = try Harness.holdingJournal(longJournal(maxPendingSpends))
        h.renewing()
        #expect(await h.license.refresh().state == .licensed)
        #expect(reportedCount(h) == maxPendingSpends)
    }

    @Test func reportsTheFirst64OfALongerJournal() async throws {
        // 70 entries is a journal the cap let a told spend past; a report carries the first 64.
        let h = try Harness.holdingJournal(longJournal(70))
        h.renewing()
        _ = await h.license.refresh()
        #expect(reportedCount(h) == 64)
    }

    @Test func dropsExactlyTheEntriesTheAnswerNamesAsRecorded() async throws {
        let h = try Harness.holdingJournal([
            entry(id: spendId("A"), .unanswered, 3, LONG_AGO), entry(id: spendId("B"), .offline, 5, LONG_AGO, meter: "renders"),
            entry(id: spendId("C"), .void, 1, LONG_AGO), entry(id: spendId("D"), .void, 1, LONG_AGO, meter: "renders"),
            entry(id: spendId("F"), .unanswered, 2, LONG_AGO),
        ])
        h.http.on(
            "validate", status: 200,
            json: [
                "lease": "not a lease",
                "spends": [
                    // As many as held, or more recorded than ever held: dropped. Fewer than held: kept.
                    ["id": .string(spendId("A")), "n": 3], ["id": .string(spendId("F")), "n": 7],
                    ["id": .string(spendId("B")), "n": 4],
                    // A void is named void; a count for a void entry does not name it.
                    ["id": .string(spendId("C")), "void": true], ["id": .string(spendId("D")), "n": 1],
                    // Another shape confirms nothing, and an id the journal has not is nothing.
                    ["id": .string(spendId("E")), "n": 1], ["n": 2], "x", .null,
                ],
            ]
        )
        _ = await h.license.refresh()
        #expect(h.journal.map(\.id) == [spendId("B"), spendId("D")])
    }

    @Test func keepsAnOfflineEntryAnotherProcessGrewMeanwhileWithItsCount() async throws {
        let h = try Harness.holdingJournal([entry(id: spendId("A"), .offline, 3, LONG_AGO)])
        let storage = h.storage
        h.http.on("validate") { _ in
            // Another process spent two more while this request was out.
            var state = storage.stored ?? StoredState()
            state.spends = [entry(id: spendId("A"), .offline, 5, LONG_AGO)]
            storage.set(state)
            return LicenseHTTPResponse(status: 200, json: ["lease": "no lease", "spends": [["id": .string(spendId("A")), "n": 3]]])
        }
        _ = await h.license.refresh()
        #expect(h.journal == [entry(id: spendId("A"), .offline, 5, LONG_AGO)])
    }

    @Test func dropsNothingWhenTheAnswerNamesNothingAndWaitsAnHourBeforeStatusOffersItAgain() async throws {
        let h = try Harness.holdingJournal([entry(.offline, 1, LONG_AGO)])
        h.renewing()
        _ = await h.license.refresh()
        #expect(h.journal.count == 1)
        #expect(h.stored?.backoffMs == Waits.askAgainMs)
        // A valid, far lease with a journal asks only once the wait is over.
        _ = await h.license.status()
        #expect(h.http.count("validate") == 1)
        h.clock.set(NOW + HOUR)
        _ = await h.license.status()
        #expect(h.http.count("validate") == 2)
    }

    @Test(arguments: [503, 429, 0])
    func dropsNothingOnA5xxOr429WhateverTheirBodySaysAndNothingOnNoAnswer(status: Int) async throws {
        let named: LicenseJSON = ["spends": [["id": .string(spendId("A")), "n": 3]]]
        let h = try Harness.holdingJournal([entry(id: spendId("A"), .unanswered, 3, LONG_AGO)])
        if status == 0 { h.http.setFail(true) } else { h.http.on("validate", status: status, json: named) }
        _ = await h.license.refresh()
        #expect(h.http.count("validate") == 1, "\(status)")
        #expect(h.journal.count == 1, "\(status)")
    }

    @Test func dropsWhatARefusalConfirmsAndWhatAnAnswerWithNoLeaseConfirms() async throws {
        func held() -> [SpendEntry] { [entry(id: spendId("A"), .unanswered, 3, LONG_AGO)] }
        let h = try Harness.holdingJournal(held())
        h.http.on("validate", status: 403, json: ["error": "revoked", "spends": [["id": .string(spendId("A")), "n": 3]]])
        let status = await h.license.refresh()
        #expect(status.state == .invalid && status.reason == .revoked)
        #expect(h.journal.isEmpty)
        // A 200 without a lease is an answer too.
        let g = try Harness.holdingJournal(held())
        g.http.on("validate", status: 200, json: ["spends": [["id": .string(spendId("A")), "n": 3]]])
        _ = await g.license.refresh()
        #expect(g.journal.isEmpty)
    }

    func renewal(confirming id: String, _ n: Int, _ h: Harness) -> LicenseHTTPResponse {
        LicenseHTTPResponse(status: 200, json: ["lease": .string(h.signer.meteredLease()), "spends": [["id": .string(id), "n": .number(Double(n))]]])
    }

    @Test func keepsTheConfirmationInMemoryWhenItCannotBeSavedSoTheEntryIsNotReportedAgain() async throws {
        let h = try Harness.holdingJournal([entry(id: spendId("A"), .unanswered, 3, LONG_AGO)])
        let answer = renewal(confirming: spendId("A"), 3, h)
        h.http.on("validate") { _ in answer }
        h.storage.failWrites()
        _ = await h.license.refresh()
        #expect(h.journal.count == 1)
        #expect(await h.license.status().meters["exports"]?.unsynced == 0)
        _ = await h.license.refresh()
        #expect(h.http.count("validate") == 2)
        #expect(h.report(1) == nil)
        h.storage.failWrites(false)
        _ = await h.license.status()
        #expect(h.journal.isEmpty)
    }

    @Test func reportsToAValidLeaseAtTheNextStatusOnceItsOwnWaitIsNotRunningAndNotBefore() async throws {
        let h = try Harness.holdingJournal([entry(id: spendId("A"), .unanswered, 1, NOW - 30_000)])
        let answer = renewal(confirming: spendId("A"), 1, h)
        h.http.on("validate") { _ in answer }
        // The journal's wait: a minute after one unanswered spend.
        _ = await h.license.status()
        #expect(h.http.count("validate") == 0)
        h.clock.set(NOW - 30_000 + MINUTE)
        _ = await h.license.status()
        #expect(h.http.count("validate") == 1)
        #expect(h.journal.isEmpty)
        // Nothing left to report: a valid, far lease asks nothing.
        _ = await h.license.status()
        #expect(h.http.count("validate") == 1)
    }

    @Test func reportsAnOfflineOnlyJournalAtOnceAndWaitsForTheAsksOwnWaitAfterNoAnswer() async throws {
        let h = try Harness.holdingJournal([entry(.offline, 2, NOW)])
        h.http.setFail(true)
        _ = await h.license.status()
        #expect(h.http.count("validate") == 1)
        #expect(h.stored?.backoffMs == Waits.retryUnansweredMs)
        _ = await h.license.status()
        #expect(h.http.count("validate") == 1)
        h.http.setFail(false)
        let answer = renewal(confirming: "AAAAAAAAAAAAAAAAAAAAAA", 2, h)
        h.http.on("validate") { _ in answer }
        h.clock.set(NOW + MINUTE)
        _ = await h.license.status()
        #expect(h.journal.isEmpty)
    }

    @Test func asksOfALeasePastItsEndToHealItWithTheJournal() async throws {
        let h = try Harness.holdingJournal([entry(.offline, 1, NOW - 40 * DAY)])
        h.clock.set(NOW + 40 * DAY)
        h.http.on("validate", status: 200, json: [:])
        _ = await h.license.status()
        #expect(reportedCount(h) == 1)
    }

    @Test func ridesAUseRequestTooAndIsDroppedByWhatThatRequestConfirms() async throws {
        let h = try Harness.holdingJournal([entry(id: spendId("A"), .unanswered, 2, LONG_AGO)])
        h.http.on(
            "use", status: 200,
            json: [
                "spent": true, "at": .number(Double(NOW)), "meters": ["exports": ["left": 87, "total": 100, "offline": 10]],
                "spends": [["id": .string(spendId("A")), "n": 2]],
            ]
        )
        #expect(await h.license.use("exports", 1) == .spent(left: 87))
        #expect(h.useBody()["spends"] == [["id": .string(spendId("A")), "meter": "exports", "n": 2, "at": .number(Double(LONG_AGO))]])
        #expect(h.journal.isEmpty)
    }

    // MARK: - what a deactivate reports

    @Test func aDeactivateCarriesTheJournalWithTheDevicesFingerprintsThenClearsItWithTheLicence() async throws {
        let h = try Harness.holdingJournal([entry(.offline, 2, NOW), entry(id: spendId("B"), .void, 1, NOW)])
        h.http.on("deactivate", status: 200, json: ["ok": true])
        #expect(try await h.license.deactivate().released)
        let body = try #require(h.http.body("deactivate"))
        #expect(body["key"] == .string(KEY) && body["activationId"] == "act_1")
        #expect(body["spends"]?.arrayValue?.count == 2 && body["fingerprints"]?.arrayValue?.count == 1)
        #expect(!body.has("fingerprintKind"))
        let stored = try #require(h.stored)
        #expect(stored.spends == nil && stored.meterFigures == nil && stored.key == nil && stored.activationId == nil)
    }

    @Test func aDeactivateSendsExactlyTheKeyAndTheActivationWhenThereIsNothingToReport() async throws {
        let figures = ["exports": MeterFigure(left: 5, total: 100, offline: 10, resets: false, at: NOW)]
        let h = try Harness.holding { $0.meterFigures = figures }
        h.http.on("deactivate", status: 200, json: [:])
        _ = try await h.license.deactivate()
        #expect(h.http.body("deactivate") == ["key": .string(KEY), "activationId": "act_1"])
        #expect(h.stored?.meterFigures == nil)
    }

    @Test func aDeactivateNamesNoFingerprintsWhenItCannotTellWhoTheDeviceIs() async throws {
        let h = try Harness.holding(fingerprinter: GetFingerprinter { throw FakeHTTP.NetworkDown() }) {
            $0.spends = [entry(.offline, 1, NOW)]
        }
        h.http.on("deactivate", status: 200, json: [:])
        _ = try await h.license.deactivate()
        let body = try #require(h.http.body("deactivate"))
        #expect(body["spends"]?.arrayValue?.count == 1 && !body.has("fingerprints"))
    }

    @Test(arguments: [true, false])
    func aDeactivateClearsTheJournalLocallyAndSaysTheSeatMayBeHeldWhenTheReleaseGotNo200(fail: Bool) async throws {
        let h = try Harness.holdingJournal([entry(.offline, 1, NOW)])
        if fail { h.http.setFail(true) } else { h.http.on("deactivate", status: 503, json: [:]) }
        #expect(try await h.license.deactivate().released == false)
        #expect(h.stored?.spends == nil)
    }

    @Test func aDeactivateReportsWhatThisProcessCouldNotSaveAndForgetsItWithTheRest() async throws {
        let h = try Harness.holding()
        h.http.setFail(true)
        h.storage.failWrites()
        _ = await h.license.use("exports", 1)
        h.storage.failWrites(false)
        h.http.setFail(false)
        h.http.on("deactivate", status: 200, json: [:])
        _ = try await h.license.deactivate()
        #expect(h.http.body("deactivate")?["spends"]?.arrayValue?.count == 1)
        // Nothing of it comes back with the next licence.
        h.http.on("activate", status: 200, json: ["lease": .string(h.signer.meteredLease()), "activationId": "act_1"])
        #expect(await h.license.activate(KEY) == .activated)
        #expect(await h.license.status().meters["exports"]?.unsynced == 0)
        #expect(h.journal.isEmpty)
        #expect(h.license.heldChanges.isEmpty)
    }

    @Test func aDeactivateWhoseStateCannotBeSavedFailsKeepingTheKeyAndReportsTheJournalAgain() async throws {
        let h = try Harness.holdingJournal([entry(.offline, 2, NOW)])
        h.http.on("deactivate", status: 200, json: [:])
        h.storage.failWrites()
        await #expect(throws: (any Error).self) { try await h.license.deactivate() }
        #expect(h.stored?.key == KEY)
        // The release is idempotent: the retry reports the journal still stored and drops the key.
        h.storage.failWrites(false)
        #expect(try await h.license.deactivate().released)
        #expect(h.http.count("deactivate") == 2)
        #expect(h.http.calls.filter { $0.action == "deactivate" }.last?.body["spends"]?.arrayValue?.count == 1)
        #expect(h.stored?.key == nil)
    }

    @Test func aDeactivateReportsTheFirst64OfALongerJournalAndClearsEveryEntryWithTheLicence() async throws {
        let h = try Harness.holdingJournal(longJournal(maxPendingSpends + 6))
        h.http.on("deactivate", status: 200, json: [:])
        #expect(try await h.license.deactivate().released)
        let sent = try #require(h.http.body("deactivate")?["spends"]?.arrayValue)
        let names = sent.compactMap { $0["meter"]?.stringValue }
        #expect(names.count == maxPendingSpends && names.first == "m0" && names.last == "m63")
        #expect(h.stored?.spends == nil)
    }

    @Test func aDeactivateThatCannotLandWhatItHoldsGoesWithWhatIsStoredAndTheCallThenFailsWithTheKeyKept() async throws {
        let h = try Harness.holdingJournal([entry(id: spendId("S"), .offline, 4, LONG_AGO)])
        h.http.setFail(true)
        // A spend in doubt, a void and, while the journal waits, a spend made offline, held in memory: the disk refuses.
        h.storage.failWrites()
        #expect(await h.license.use("exports", 2).offline)
        #expect(await h.license.use("renders", 1) == .refused(.offlineLimit, left: 5))
        #expect(await h.license.use("exports", 3).offline)
        #expect(h.license.heldChanges.count == 3)
        #expect(h.http.count("use") == 2)
        h.http.setFail(false)
        h.http.on("deactivate", status: 200, json: [:])
        await #expect(throws: (any Error).self) { try await h.license.deactivate() }
        // The release went out with the stored journal and the held spend in doubt and void, and the key is kept.
        // The spend made offline joins the entry it was made beside when it lands, so it is not reported under an id
        // of its own.
        let sent = try #require(h.http.body("deactivate")?["spends"]?.arrayValue)
        #expect(sent.map { "\($0["meter"]?.stringValue ?? "") \($0["n"]?.numberValue ?? 0) \($0.has("void"))" } == [
            "exports 4.0 false", "exports 2.0 false", "renders 1.0 true",
        ])
        // And those two are the ids the server was asked about.
        #expect(sent.dropFirst().first?["id"] == h.useBody(0)["id"] && sent.dropFirst(2).first?["id"] == h.useBody(1)["id"])
        #expect(h.stored?.key == KEY)
    }

    @Test func reportsNothingForASeatThatIsAnotherDevicesTheReleaseIsNotItsToMake() async throws {
        let h = try Harness.holdingJournal([entry(.offline, 1, NOW)])
        // Its lease is held to a machine this one is not: a state file copied from another PC.
        var stored = try #require(h.stored)
        stored.lease = h.signer.meteredLease(over: ["fp": .string(String(repeating: "f", count: 64)), "fpk": "machine"])
        h.storage.set(stored)
        // A device that can tell who it is, and is not that machine.
        let licence = try h.license(
            major: 1, fingerprinter: IdentifyingFingerprinter { DeviceIdentity(fingerprint: "fp-machine", kind: .machine) }
        )
        #expect(try await licence.deactivate().released)
        #expect(h.http.count("deactivate") == 0)
    }

    // MARK: - status().meters

    func shown(_ left: Int, _ total: Int, _ offline: Int, _ unsynced: Int, _ resets: Bool) -> MeterStatus {
        MeterStatus(left: left, total: total, offline: offline, unsynced: unsynced, resets: resets)
    }

    @Test func showsEachMeterOfTheLeaseWithItsFiguresAndNothingWhenTheLeaseHasNone() async throws {
        let h = try Harness.holding()
        let status = await h.license.status()
        #expect(status.state == .licensed && status.key == KEY)
        #expect(status.meters == ["exports": shown(90, 100, 10, 0, false), "renders": shown(5, 5, 0, 0, true)])
        #expect(h.http.count("validate") == 0)
        let bare = try Harness.holding(met: nil)
        let none = await bare.license.status()
        #expect(none.meters.isEmpty)
        #expect(none == LicenseStatus(state: .licensed, key: KEY))
    }

    @Test func isNetOfTheUnsyncedSpendsOfEachKindNeverBelow0AndCountsNoVoid() async throws {
        let h = try Harness.holding {
            $0.spends = [
                entry(.offline, 4, NOW), entry(id: spendId("B"), .unanswered, 3, NOW), entry(id: spendId("C"), .void, 50, NOW),
                entry(id: spendId("D"), .offline, 9, NOW, meter: "renders"),
            ]
            $0.backoffSince = NOW
            $0.backoffMs = Waits.retryUnansweredMs
        }
        let meters = await h.license.status().meters
        #expect(meters["exports"] == shown(83, 100, 10, 7, false))
        #expect(meters["renders"] == shown(0, 5, 0, 9, true))
    }

    @Test func worksBehindACallThatHasNotFinishedSayingSo() async throws {
        let h = try Harness.holding(httpTimeout: 1.5, timing: behind) { $0.spends = [entry(.offline, 2, NOW)] }
        h.http.on("validate", status: 403, json: ["error": "revoked"])
        h.storage.holdNextWrite()
        defer { h.storage.releaseAll() }
        let refreshing = Task { await h.license.refresh() }
        await eventually { h.storage.holdingWrite }
        let later = await h.license.status()
        h.storage.releaseWrite()
        _ = await refreshing.value
        #expect(later.state == .licensed && later.isStalled)
        #expect(later.meters["exports"]?.left == 88 && later.meters["exports"]?.unsynced == 2)
    }

    @Test func spendsBehindACallThatHasNotFinishedAsksSavesNothingOfTheAnswerAndKeepsTheSpend() async throws {
        let h = try Harness.holding(httpTimeout: 1.5, timing: behind)
        h.http.on("validate", status: 403, json: ["error": "revoked"])
        h.storage.holdNextWrite()
        defer { h.storage.releaseAll() }
        h.http.on("use") { _ in Harness.spent(89, at: NOW) }
        let refreshing = Task { await h.license.refresh() }
        await eventually { h.storage.holdingWrite }
        let writes = h.storage.writes
        let first = await h.license.use("exports", 1)
        #expect(first == .spent(left: 89))
        #expect(h.http.count("use") == 1)
        // Offline now: the spend is kept in memory and counts.
        h.http.setFail(true)
        let second = await h.license.use("exports", 2)
        // The answer the first call was given was not saved either, so the lease's own figure is the base.
        #expect(second == .spent(left: 88, offline: true))
        #expect(h.storage.writes == writes)
        h.storage.releaseWrite()
        // The call that was stuck finishes with its verdict, and the spend kept in memory lands beside it.
        _ = await refreshing.value
        #expect(h.stored?.refused == .revoked)
        _ = await h.license.status()
        // The second call was asked (no wait ran) and got no answer: its spend is in doubt, and kept.
        #expect(kindsAndCounts(h.journal) == ["unanswered 2"])
    }

    @Test func isAbsentOnEveryStatusButAKeysLicensedOne() async throws {
        let expired = try Harness.holding()
        expired.clock.set(NOW + 40 * DAY)
        expired.http.setFail(true)
        let status = await expired.license.status()
        #expect(status.state == .expired && status.meters.isEmpty)
        let revoked = try Harness.holding { $0.refused = .revoked }
        let refused = await revoked.license.status()
        #expect(refused.state == .invalid && refused.meters.isEmpty)
        let empty = try Harness()
        #expect(await empty.license.status().meters.isEmpty)
    }

    @Test func isAbsentOnATrialWhoseLeaseCarriesMetersAndOnAnOfflineLicenceFileThatDoes() async throws {
        let trial = try Harness()
        let lease = trial.signer.trialLease(device: "fp-test", kind: nil, ttlSeconds: 5 * 86_400, met: meters())
        trial.http.on(
            "trial", status: 200,
            json: ["trialStart": .number(Double(NOW)), "trialEndsAt": .number(Double(NOW + 5 * DAY)), "lease": .string(lease)]
        )
        let started = await trial.license.startTrial()
        #expect(started.state == .trial && started.meters.isEmpty)
        #expect(await trial.license.status().meters.isEmpty)

        let file = try Harness.holding()
        _ = try await file.license.importLicenseFile(licenseFileText(file.signer.offlineFile(["met": meters()])))
        // The file answers before the key beside it, and a file has no meters, so neither has the status or a spend.
        #expect(await file.license.status() == fileLicensed)
        #expect(await file.license.use("exports", 1) == .refused(.notLicensed))
    }

    @Test func showsAMeterNamedProtoOrLikeAnObjectsMemberAsAMeterLikeAnyOther() async throws {
        let h = try Harness()
        let lease = h.signer.rawLease(
            met: #"{"__proto__":{"left":1,"total":2,"offline":0},"constructor":{"left":3,"total":3,"offline":1}}"#
        )
        h.storage.set(licensedState(with: lease))
        let meters = await h.license.status().meters
        #expect(meters.keys.sorted() == ["__proto__", "constructor"])
        #expect(meters["__proto__"] == shown(1, 2, 0, 0, false))
    }

    @Test func takesAFigureAUseAnswerGaveInPlaceOfTheLeasesUntilTheLeaseIsRenewed() async throws {
        func withFigure(_ at: Int) throws -> Harness {
            try Harness.holding { $0.meterFigures = ["exports": MeterFigure(left: 40, total: 100, offline: 10, resets: false, at: at)] }
        }
        let newer = try withFigure(NOW + 1000), older = try withFigure(NOW - 1000), same = try withFigure(NOW)
        #expect(await newer.license.status().meters["exports"]?.left == 40)
        // A figure from before the lease's own second is older than it; from the same second, newer.
        #expect(await older.license.status().meters["exports"]?.left == 90)
        #expect(await same.license.status().meters["exports"]?.left == 40)
    }

    @Test func showsARenewalsMetersNetOfTheJournalAfterWhatTheAnswerConfirmed() async throws {
        let h = try Harness.holdingJournal([entry(id: spendId("A"), .offline, 2, LONG_AGO), entry(id: spendId("B"), .void, 1, LONG_AGO)])
        let lease = h.signer.meteredLease(met: ["exports": ["left": 70, "total": 100, "offline": 10]], at: NOW + 5000)
        h.http.on("validate", status: 200, json: ["lease": .string(lease), "spends": [["id": .string(spendId("A")), "n": 2]]])
        h.clock.set(NOW + 5000)
        #expect(await h.license.refresh().meters == ["exports": shown(70, 100, 10, 0, false)])
    }

    @Test func stopsShowingAMeterTheNewestLeaseNoLongerNames() async throws {
        let figure = MeterFigure(left: 1, total: 5, offline: 0, resets: true, at: NOW - 5000)
        let h = try Harness.holding { $0.meterFigures = ["renders": figure] }
        var stored = try #require(h.stored)
        stored.lease = h.signer.meteredLease(met: ["exports": ["left": 70, "total": 100, "offline": 10]])
        h.storage.set(stored)
        #expect(await h.license.status().meters.keys.sorted() == ["exports"])
    }

    @Test func spendsOnAnOpenEndedLeaseAsOnAnyOther() async throws {
        let h = try Harness()
        h.storage.set(licensedState(with: h.signer.meteredLease(over: ["model": "perpetual", "major": .number(Double(openMajor))])))
        h.http.on("use") { _ in Harness.spent(89, at: NOW) }
        #expect(await h.license.use("exports", 1) == .spent(left: 89))
    }

    // MARK: - an entry the server did not confirm

    @Test(arguments: ["a lease naming nothing", "a 503", "a 429", "no answer at all", "a count lower than the entry holds"])
    func anEntryTheServerDidNotConfirmIsReportedAgainWithTheSameIDMeterCountAndTime(name: String) async throws {
        let held = entry(id: spendId("A"), .offline, 3, LONG_AGO)
        let report: LicenseJSON = ["id": .string(held.id), "meter": "exports", "n": 3, "at": .number(Double(LONG_AGO))]
        let h = try Harness.holdingJournal([held])
        switch name {
        case "a lease naming nothing": h.renewing()
        case "a 503": h.http.on("validate", status: 503, json: ["error": "down"])
        case "a 429": h.http.on("validate", status: 429, json: ["error": "rate-limited"])
        case "no answer at all": h.http.setFail(true)
        default:
            h.http.on("validate", status: 200, json: ["lease": .string(h.signer.meteredLease()), "spends": [["id": .string(spendId("A")), "n": 2]]])
        }
        _ = await h.license.refresh()
        #expect(h.journal == [held], "\(name)")
        // Past every wait, the next validate and the next use carry it as it was.
        h.http.setFail(false)
        h.clock.set(NOW + 2 * HOUR)
        h.renewing()
        _ = await h.license.refresh()
        #expect(h.report(h.http.count("validate") - 1) == [report], "\(name)")
        h.http.on("use") { _ in Harness.spent(89, at: NOW) }
        _ = await h.license.use("exports", 1)
        #expect(h.useBody(0)["spends"] == [report], "\(name)")
    }

    @Test func carriesTheIDAFailedUseSentIntoTheNextRequestsReport() async throws {
        let h = try Harness.holding()
        h.http.setFail(true)
        _ = await h.license.use("exports", 2)
        let sent = try #require(h.useBody(0)["id"]?.stringValue)
        h.http.setFail(false)
        h.clock.set(NOW + 2 * MINUTE)
        h.renewing()
        _ = await h.license.refresh()
        #expect(h.report(0) == [["id": .string(sent), "meter": "exports", "n": 2, "at": .number(Double(NOW))]])
        h.http.on("use") { _ in Harness.spent(89, at: NOW) }
        _ = await h.license.use("exports", 1)
        #expect(h.useBody(1)["spends"]?.arrayValue?.first?["id"] == .string(sent))
    }

    @Test func sendsNoSpendsWithAnActivationOrATrialThoughTheJournalHoldsSome() async throws {
        let h = try Harness.holdingJournal([entry(.offline, 1, LONG_AGO)])
        h.http.on("activate", status: 200, json: ["lease": .string(h.signer.meteredLease()), "activationId": "act_1"])
        #expect(await h.license.activate(KEY) == .activated)
        _ = await h.license.startTrial()
        #expect(h.http.count("trial") == 1)
        #expect(!(try #require(h.http.body("activate"))).has("spends"))
        #expect(!(try #require(h.http.body("trial"))).has("spends"))
    }

    // MARK: - a full journal

    @Test func aFullJournalRefusesASpendTheAllowanceCoversThoughTheRequestWasSentAndAppendsNoVoid() async throws {
        let h = try Harness.holdingJournal(longJournal(maxPendingSpends))
        h.http.setFail(true)
        #expect(await h.license.use("exports", 1) == .refused(.offlineLimit, left: 90))
        #expect(h.http.count("use") == 1)
        #expect(h.journal.count == maxPendingSpends)
        #expect(h.journal.allSatisfy { $0.kind != .void })
    }

    // MARK: - the bodies the reference's own worker parses

    @Test(MeterVectors.wireBodiesEnabled)
    func theRequestsThatCarryAReportAreTheBodiesTheReferenceSends() async throws {
        let captured = try #require(MeterVectors.wireBodies, "conformance/wire-bodies.json was not found above the tests: this repository makes it")
        let h = try Harness(major: 3)
        let met = meters()
        h.storage.set(
            {
                var stored = licensedState(with: h.signer.meteredLease(met: met))
                stored.spends = [
                    entry(id: "offlineoffline0000001", .offline, 3, NOW - 2 * HOUR),
                    entry(id: "unansweredunanswered2", .unanswered, 1, NOW - 2 * HOUR + 1, meter: "renders"),
                    entry(id: "voidvoidvoidvoid00003", .void, 2, NOW - 2 * HOUR + 2),
                ]
                return stored
            }()
        )
        // Answers that confirm nothing, so the journal is still there for the next request.
        h.http.on("use", status: 200, json: ["spent": true, "meters": met, "at": .number(Double(NOW))])
        h.http.on("validate", status: 200, json: [:])
        h.http.on("deactivate", status: 200, json: [:])
        _ = await h.license.use("exports", 2)
        _ = await h.license.refresh()
        _ = try await h.license.deactivate()

        // The spend's id is random, and the key ids are this suite's own key's.
        var sent = try #require(h.http.body("use")?.objectValue)
        #expect(sent["id"]?.stringValue?.utf8.count == 22)
        sent["id"] = captured["use"]?["id"]
        let validate = try #require(h.http.body("validate")?.objectValue)
        for (name, body) in [("use", sent), ("validate", validate)] {
            var given = body
            #expect(given["kids"] == [.string(h.signer.kid)], "\(name)")
            given["kids"] = nil
            var expected = try #require(captured[name]?.objectValue)
            expected["kids"] = nil
            #expect(LicenseJSON.object(given) == .object(expected), "\(name)")
        }
        #expect(h.http.body("deactivate") == captured["deactivate"])
    }
}
