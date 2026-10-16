import Foundation
import Testing

@testable import KeyGrant

/// `use(_:_:)` when the server answers, what a call asks for, and when it is not licensed: exact
/// online, a verdict stored as a validate's is, and a licence that stays licensed whatever a meter says.
@Suite("metered uses: online", suiteTimeLimit)
struct UseOnlineTests {
    // MARK: - online

    @Test func spendsExactlySendingTheKeyTheSeatTheMeterTheAmountAndAFreshID() async throws {
        let h = try Harness.holding()
        h.http.on("use") { _ in Harness.spent(89, at: NOW + 1) }
        #expect(await h.license.use("exports", 1) == .spent(left: 89))
        let body = h.useBody()
        #expect(body["key"] == .string(KEY) && body["activationId"] == "act_1" && body["meter"] == "exports")
        #expect(body["n"] == 1 && body["major"] == 1)
        let id = try #require(body["id"]?.stringValue)
        #expect(id.utf8.count == 22)
        #expect(body["kids"]?.arrayValue?.count == 1 && body["fingerprints"]?.arrayValue?.count == 1)
        #expect(!body.has("spends") && !body.has("keptMajor"))
        #expect(h.stored?.meterFigures?["exports"] == MeterFigure(left: 89, total: 100, offline: 10, resets: false, at: NOW + 1))
        #expect(h.journal.isEmpty)
    }

    @Test func spendsABatchWholeInOneRequest() async throws {
        let h = try Harness.holding()
        h.http.on("use") { _ in Harness.spent(50, at: NOW) }
        #expect(await h.license.use("exports", 40) == .spent(left: 50))
        #expect(h.useBody()["n"] == 40)
        #expect(h.http.count("use") == 1)
    }

    @Test func makesANewIDForEachCallTwoCallsAreTwoSpends() async throws {
        let h = try Harness.holding()
        h.http.on("use") { _ in Harness.spent(89, at: NOW) }
        _ = await h.license.use("exports")
        _ = await h.license.use("exports")
        #expect(h.useBody(0)["id"] != h.useBody(1)["id"])
    }

    @Test func spendsOneUseWhenNoAmountIsGiven() async throws {
        let h = try Harness.holding()
        h.http.on("use") { _ in Harness.spent(89, at: NOW) }
        #expect(await h.license.use("exports") == .spent(left: 89))
        #expect(h.useBody()["n"] == 1)
    }

    @Test func answersFromTheFigureTheServerGaveNetOfWhatThisDeviceHasNotReported() async throws {
        let h = try Harness.holdingJournal([entry(.offline, 3, LONG_AGO)])
        h.http.on("use") { _ in Harness.spent(80, at: NOW) }
        // The server's 80 does not count the 3 unreported, so 77 is what the customer has.
        #expect(await h.license.use("exports", 1) == .spent(left: 77))
    }

    @Test func answersFromTheBaseFiguresAsTheyWereWhenTheServerGaveNoneForTheMeter() async throws {
        let h = try Harness.holding()
        h.http.on("use", status: 200, json: ["spent": true, "meters": [:], "at": .number(Double(NOW))])
        #expect(await h.license.use("exports", 1) == .spent(left: 90))
        h.http.on("use", status: 200, json: ["spent": true])
        #expect(await h.license.use("exports", 1) == .spent(left: 90))
    }

    @Test func answersNothingLeftForASpendOfAMeterNeitherTheLeaseNorTheAnswerNames() async throws {
        let h = try Harness.holding()
        h.http.on("use", status: 200, json: ["spent": true, "meters": [:], "at": .number(Double(NOW))])
        #expect(await h.license.use("credits", 1) == .spent(left: 0))
        #expect(h.stored?.meterFigures == nil)
        #expect(await h.license.status().meters["credits"] == nil)
    }

    @Test func keepsAFigureTheLeaseIsNewerThanOnlyUntilTheLeaseIsRenewed() async throws {
        let h = try Harness.holding()
        h.http.on("use") { _ in Harness.spent(70, at: NOW + 5_000) }
        _ = await h.license.use("exports", 1)
        #expect(await h.license.status().meters["exports"]?.left == 70)
        // A renewal brings a lease signed after that figure, whose own figures win.
        let renewed = h.signer.meteredLease(met: ["exports": ["left": 60, "total": 100, "offline": 10]], at: NOW + 10_000)
        h.http.on("validate", status: 200, json: ["lease": .string(renewed)])
        h.clock.set(NOW + 10_000)
        #expect(await h.license.refresh().meters["exports"]?.left == 60)
        #expect(await h.license.status().meters["exports"]?.left == 60)
    }

    @Test func answersUsedUpWithWhatTheServerSaysIsLeftAndSpendsNothingOfflineAfter() async throws {
        let h = try Harness.holdingJournal([entry(id: spendId("B"), .unanswered, 2, LONG_AGO)])
        h.http.on(
            "use", status: 409,
            json: [
                "error": "used-up", "left": 1, "at": .number(Double(NOW)),
                "meters": ["exports": ["left": 1, "total": 100, "offline": 10]], "spends": [["id": .string(spendId("B")), "n": 2]],
            ]
        )
        #expect(await h.license.use("exports", 5) == .refused(.usedUp, left: 1))
        // The reports it confirmed and the figures it gave are saved.
        #expect(h.journal.isEmpty)
        #expect(h.stored?.meterFigures?["exports"]?.left == 1)
        // The server's word stands offline too: one is left, and a spend of two is past it.
        h.http.setFail(true)
        h.clock.set(NOW + 2 * MINUTE)
        #expect(await h.license.use("exports", 2) == .refused(.offlineLimit, left: 1))
    }

    @Test func answersUsedUpWithNoLeftWhenTheAnswerGaveNone() async throws {
        let h = try Harness.holding()
        h.http.on("use", status: 409, json: ["error": "used-up"])
        #expect(await h.license.use("exports", 1) == .refused(.usedUp))
    }

    @Test func readsTheServersWordsOnAnyStatusButA200A5xxAnd429() async throws {
        let h = try Harness.holding()
        h.http.on("use", status: 400, json: ["error": "used-up", "left": 0])
        #expect(await h.license.use("exports", 1) == .refused(.usedUp, left: 0))
        // A 200 is a spend only with spent: true; anything else is no answer.
        h.http.on("use", status: 200, json: ["error": "used-up", "left": 0])
        let offline = await h.license.use("exports", 1)
        #expect(offline.ok && offline.offline)
        for status in [500, 503, 429] {
            h.http.on("use", status: status, json: ["error": "used-up", "left": 0])
            h.clock.set(h.clock.now() + 2 * HOUR)
            let result = await h.license.use("exports", 1)
            #expect(result.ok && result.offline, "\(status)")
        }
    }

    @Test func answersNoMeterForAMeterTheServerDoesNotKnowAndConfirmsTheReportsItCarried() async throws {
        let h = try Harness.holdingJournal([entry(id: spendId("C"), .unanswered, 1, LONG_AGO)])
        h.http.on("use", status: 404, json: ["error": "unknown-meter", "spends": [["id": .string(spendId("C")), "n": 1]]])
        #expect(await h.license.use("exports", 1) == .refused(.noMeter))
        #expect(h.journal.isEmpty)
    }

    @Test(arguments: [
        ("revoked", UseError.revoked, Refusal.revoked), ("expired", .revoked, .revoked), ("deactivated", .revoked, .revoked),
        ("upgrade-required", .upgrade, .upgrade), ("update-required", .outdated, .outdated), ("device", .device, .device),
    ])
    func storesAVerdictAsAValidatesIsAndAnswersItAsStatusWill(word: String, error: UseError, refusal: Refusal) async throws {
        let h = try Harness.holding()
        h.http.on("use", status: 403, json: ["error": .string(word)])
        #expect(await h.license.use("exports", 1) == .refused(error), "\(word)")
        #expect(h.stored?.refused == refusal, "\(word)")
        let status = await h.license.status()
        #expect(status.state == .invalid && status.reason == LicenseReason(refusal), "\(word)")
        // The refusal stands: the next spend is not licensed, and asks nothing.
        #expect(await h.license.use("exports", 1) == .refused(.notLicensed), "\(word)")
        #expect(h.http.count("use") == 1, "\(word)")
    }

    @Test func recordsTheReportsAVerdictConfirms() async throws {
        let h = try Harness.holdingJournal([entry(id: spendId("D"), .void, 1, LONG_AGO)])
        h.http.on("use", status: 403, json: ["error": "revoked", "spends": [["id": .string(spendId("D")), "void": true]]])
        _ = await h.license.use("exports", 1)
        #expect(h.journal.isEmpty)
    }

    @Test func aUsedUpMeterRefusesSpendsNeverTheLicence() async throws {
        let h = try Harness.holding()
        h.storage.set(licensedState(with: h.signer.meteredLease(over: ["ent": ["edition": "pro"]])))
        h.http.on(
            "use", status: 409,
            json: ["error": "used-up", "left": 0, "at": .number(Double(NOW)), "meters": ["exports": ["left": 0, "total": 100, "offline": 10]]]
        )
        #expect(await h.license.use("exports", 1) == .refused(.usedUp, left: 0))
        let status = await h.license.status()
        #expect(status.state == .licensed)
        #expect(status.meters["exports"]?.left == 0)
        // Nor an entitlement: what the licence grants is granted with the meter used up.
        #expect(await h.license.has("edition"))
        try await h.license.require("edition")
    }

    // MARK: - the bound of the request

    /// An HTTP adapter that notes the bound each request is given, and answers as the harness's fake
    /// server does.
    final class Bounds: HTTPAdapter {
        let inner: FakeHTTP
        private let seen = Locked<[String]>([])

        init(_ inner: FakeHTTP) { self.inner = inner }

        /// `action seconds` of each request, in order.
        var requests: [String] { seen.current }

        func post(_ url: URL, body: LicenseJSON, timeout: TimeInterval) async throws -> LicenseHTTPResponse {
            seen.withValue { $0.append("\(url.lastPathComponent) \(timeout)") }
            return try await inner.post(url, body: body, timeout: timeout)
        }
    }

    /// A licence over the harness's state whose requests are noted, with the SDK's own bounds and the
    /// HTTP bound given.
    func bounded(_ h: Harness, httpTimeout: TimeInterval) throws -> (License, Bounds) {
        let bounds = Bounds(h.http)
        let license = try License(
            LicenseConfig(
                product: PRODUCT, apiBaseURL: apiBase, publicJWK: h.signer.publicJWK, httpTimeout: httpTimeout,
                adapters: LicenseAdapters(storage: h.storage, clock: h.clock, fingerprinter: h.fingerprinter, http: bounds)
            )
        )
        return (license, bounds)
    }

    @Test func aUseRequestWaitsFiveSecondsForTheServer() async throws {
        let h = try Harness.holding()
        h.http.on("use") { _ in Harness.spent(89, at: NOW) }
        let (license, bounds) = try bounded(h, httpTimeout: 15)
        _ = await license.use("exports", 1)
        #expect(bounds.requests == ["use 5.0"])
    }

    @Test func aUseRequestWaitsForTheHTTPBoundInsteadWhenThatIsShorter() async throws {
        let h = try Harness.holding()
        h.http.on("use") { _ in Harness.spent(89, at: NOW) }
        let (license, bounds) = try bounded(h, httpTimeout: 1)
        _ = await license.use("exports", 1)
        #expect(bounds.requests == ["use 1.0"])
    }

    @Test(arguments: [(15.0, 5_000.0), (1.0, 1_000.0)])
    func waitsForTheServerToTheMillisecondAndThenSpendsFromTheAllowance(httpTimeout: TimeInterval, boundMs: Double) async throws {
        // On a clock the test moves by hand: five seconds, or the HTTP bound when that is shorter.
        let ticker = ManualTicker()
        let h = try Harness.holding(httpTimeout: httpTimeout, timing: Timing(ticker: ticker))
        h.http.setHang(true)
        let answered = Flag()
        let task = Task { () -> UseResult in
            let result = await h.license.use("exports", 1)
            answered.set(true)
            return result
        }
        defer { task.cancel() }
        await eventually { ticker.deadlinesMs == [boundMs] }
        #expect(ticker.deadlinesMs == [boundMs])
        ticker.advance(ms: Int(boundMs) - 1)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(!answered.on, "answered 1 ms before the bound")
        ticker.advance(ms: 1)
        #expect(await answer { await task.value } == .spent(left: 89, offline: true))
        // The request is cancelled by the worker that held it, a moment after the answer.
        await eventually { h.http.hangsCancelled == 1 }
        #expect(h.http.hangsCancelled == 1)
    }

    // MARK: - what is asked

    @Test func refusesAnAmountThatIsNotAWholeNumberFrom1ToTheBoundAskingNothing() async throws {
        let h = try Harness.holding()
        for n in [0, -1, 1_000_000_001, Int.max, Int.min] {
            #expect(await h.license.use("exports", n) == .refused(.invalidAmount), "\(n)")
        }
        #expect(h.http.count("use") == 0)
        #expect(h.journal.isEmpty)
    }

    @Test func takesTheBoundItself() async throws {
        let h = try Harness.holding(
            met: ["exports": ["left": 2_000_000_000, "total": 2_000_000_000, "offline": 0]]
        )
        h.http.on("use") { _ in Harness.spent(1_000_000_000, at: NOW) }
        #expect(await h.license.use("exports", 1_000_000_000).ok)
        #expect(h.useBody()["n"] == 1_000_000_000)
    }

    @Test func judgesTheAmountBeforeTheMeterAndRefusesACodeOfNoMeterAskingNothing() async throws {
        let h = try Harness.holding()
        #expect(await h.license.use("", 0) == .refused(.invalidAmount))
        for code in ["", String(repeating: "x", count: 33), String(repeating: "\u{1F600}", count: 17)] {
            #expect(await h.license.use(code, 1) == .refused(.noMeter), "\(code)")
        }
        #expect(h.http.count("use") == 0)
    }

    @Test func takesACodeOf32UTF16UnitsASurrogatePairAtTheEdgeIncludedAndMatchesItExactly() async throws {
        let code = String(repeating: "x", count: 30) + "\u{1F600}"
        #expect(code.utf16.count == 32)
        let figure: LicenseJSON = ["left": 9, "total": 9, "offline": 0]
        let h = try Harness.holding(met: .object([code: figure, "exports": figure]))
        h.http.on("use", status: 200, json: ["spent": true])
        #expect(await h.license.use(code, 1).ok)
        #expect(h.useBody()["meter"] == .string(code))
        // Matched exactly, case included: the key has "exports", and "EXPORTS" is no meter of it.
        h.http.setFail(true)
        h.clock.set(NOW + 5 * MINUTE)
        #expect(await h.license.use("EXPORTS", 1) == .refused(.noMeter))
    }

    @Test func spendsAMeterNamedLikeAnObjectsMemberOnlyWhenTheKeyHasIt() async throws {
        let h = try Harness.holding(met: ["constructor": ["left": 9, "total": 9, "offline": 3]])
        h.http.setFail(true)
        #expect(await h.license.use("constructor", 1).ok)
        #expect(await h.license.use("toString", 1) == .refused(.noMeter))
        #expect(await h.license.use("__proto__", 1) == .refused(.noMeter))
    }

    // MARK: - when it is not licensed

    func expectNotLicensed(_ h: Harness, sourceLocation: SourceLocation = #_sourceLocation) async {
        #expect(await h.license.use("exports", 1) == .refused(.notLicensed), sourceLocation: sourceLocation)
        #expect(h.http.count("use") == 0, "nothing is asked", sourceLocation: sourceLocation)
    }

    @Test func isNotLicensedWithNoLicenceAnExpiredOrTamperedLeaseAndATrialAskingNothing() async throws {
        // No licence at all.
        await expectNotLicensed(try Harness())
        // An expired lease.
        let expired = try Harness.holding()
        expired.clock.set(NOW + 40 * DAY)
        expired.http.setFail(true)
        await expectNotLicensed(expired)
        // A lease for another activation.
        let tampered = try Harness()
        tampered.storage.set(licensedState(with: tampered.signer.meteredLease(over: ["aid": "act_other"])))
        await expectNotLicensed(tampered)
        // A running trial, even one whose lease carries meters.
        let trial = try Harness()
        let lease = trial.signer.trialLease(device: "fp-test", kind: nil, ttlSeconds: 7 * 86_400, met: meters())
        trial.storage.set(StoredState(trialStart: NOW, trialEndsAt: NOW + 7 * DAY, trialLease: lease, lastSeen: NOW))
        #expect(await trial.license.status().state == .trial)
        await expectNotLicensed(trial)
    }

    @Test func isNotLicensedWithAStoredRefusalThatStandsAndForABuildTheLeaseDoesNotCover() async throws {
        await expectNotLicensed(try Harness.holding { $0.refused = .revoked })
        // The lease covers majors 1 to 3: a build at major 4 is not licensed by it.
        let newer = try Harness.holding(major: 4)
        newer.http.setFail(true)
        await expectNotLicensed(newer)
    }

    @Test func isNotLicensedWithAnOfflineLicenceFileWhichHasNoMeters() async throws {
        // Even one that carries a `met` claim, which the signer refuses and a verifier ignores.
        let h = try Harness()
        _ = try await h.license.importLicenseFile(licenseFileText(h.signer.offlineFile(["met": meters()])))
        let status = await h.license.status()
        #expect(status.state == .licensed && status.source == .file)
        #expect(status.meters.isEmpty)
        await expectNotLicensed(h)
    }

    @Test func answersStorageWhenTheStateCannotBeReadJustNowAskingNothing() async throws {
        let h = try Harness.holding()
        h.storage.failRead(1)
        #expect(await h.license.use("exports", 1) == .refused(.storage))
        #expect(h.http.count("use") == 0)
        // And the next call, the disk back, spends.
        h.http.on("use") { _ in Harness.spent(89, at: NOW) }
        #expect(await h.license.use("exports", 1) == .spent(left: 89))
    }

    // MARK: - the device

    @Test func namesTheDeviceAsAValidateDoesItsFingerprints() async throws {
        let h = try Harness.holding()
        h.http.on("use") { _ in Harness.spent(89, at: NOW) }
        _ = await h.license.use("exports", 1)
        let request = h.useBody()
        _ = await h.license.refresh()
        let validate = try #require(h.http.calls.last { $0.action == "validate" }).body
        for name in ["key", "activationId", "major", "fingerprints"] {
            #expect(request[name] == validate[name], "\(name)")
        }
    }

    @Test func sendsNoFingerprintsWhenDevicesAreNotHeld() async throws {
        let h = try Harness.holding(deviceHold: false)
        h.http.on("use") { _ in Harness.spent(89, at: NOW) }
        _ = await h.license.use("exports", 1)
        let body = h.useBody()
        #expect(!body.has("fingerprints") && !body.has("fingerprintKind"))
    }

    @Test func sendsTheMachineKindOfADeviceThatReadsAMachineID() async throws {
        let h = try Harness.holding(fingerprinter: IdentifyingFingerprinter { DeviceIdentity(fingerprint: "fp-machine", kind: .machine) })
        h.http.on("use") { _ in Harness.spent(89, at: NOW) }
        _ = await h.license.use("exports", 1)
        let body = h.useBody()
        #expect(body["fingerprintKind"] == "machine" && body["fingerprints"] == ["fp-machine"])
    }

    @Test func sendsTheAlternatesAFingerprinterGivesBesideTheMachineID() async throws {
        let h = try Harness.holding(
            fingerprinter: IdentifyingFingerprinter { DeviceIdentity(fingerprint: "fp-machine", kind: .machine, alternates: ["fp-host"]) }
        )
        h.http.on("use") { _ in Harness.spent(89, at: NOW) }
        _ = await h.license.use("exports", 1)
        let body = h.useBody()
        #expect(body["fingerprintKind"] == "machine" && body["fingerprints"]?.arrayValue?.count == 2)
    }

    @Test func sendsNoFingerprintsWhenTheDeviceCannotBeTold() async throws {
        let h = try Harness.holding(fingerprinter: GetFingerprinter { throw FakeHTTP.NetworkDown() })
        h.http.on("use") { _ in Harness.spent(89, at: NOW) }
        _ = await h.license.use("exports", 1)
        #expect(h.http.count("use") == 1)
        #expect(!h.useBody().has("fingerprints"))
    }
}
