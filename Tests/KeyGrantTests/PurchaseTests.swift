import Foundation
import Testing

@testable import KeyGrant

/// Buying from the trial with no key typed: `purchaseURL(paymentLink:)` keeps this install's
/// purchase secret and hands out the reference to it, and the pickup (`status()`, `refresh()`,
/// `startTrial()`) asks for the key bought with it.
enum Purchase {
    static let link = "https://buy.stripe.com/test_abc"
    /// A stored purchase secret (32 zero bytes, as base64url).
    static let token = String(repeating: "A", count: 43)
    static let boughtKey = "SLUICE-BUY1-BUY1-BUY1-BUY1"
    static let trial = LicenseStatus(state: .trial, trialDaysLeft: 5, trialEndsAt: NOW + 5 * DAY)

    /// The client_reference_id a link carries for a stored secret.
    static func reference(_ secret: String) -> String { purchaseReference(secret) }

    /// A purchase secret held, its link handed out `ago` ms before NOW, with `edit` on top.
    static func held(_ ago: Int = 0, _ edit: (inout StoredState) -> Void = { _ in }) -> StoredState {
        var state = StoredState(purchaseToken: token, purchaseTokenAt: NOW - ago)
        edit(&state)
        return state
    }

    /// A running trial, synced within the day (so no launch report is due), and a token held.
    static func trialState(_ h: Harness, _ edit: (inout StoredState) -> Void = { _ in }) -> StoredState {
        var state = held()
        state.trialStart = NOW - 2 * DAY
        state.trialEndsAt = NOW + 5 * DAY
        state.trialLease = h.signer.trialLease(device: "fp-test", kind: nil, ttlSeconds: 5 * 24 * 3600)
        state.trialAt = NOW - DAY / 2
        state.lastSeen = NOW
        edit(&state)
        return state
    }

    /// The server's answer when the key bought with the secret is this device's: as an activation's.
    static func bought(_ h: Harness, model: String = "perpetual") -> LicenseHTTPResponse {
        let lease = h.signer.lease(sub: boughtKey, model: model)
        let json: LicenseJSON = ["key": .string(boughtKey), "activationId": "act_1", "lease": .string(lease), "inGrace": false, "validUntil": .null]
        return LicenseHTTPResponse(status: 200, json: json)
    }

    static func noPurchaseFields(_ state: StoredState?) -> Bool {
        state?.purchaseToken == nil && state?.purchaseTokenAt == nil && state?.claimAskedAt == nil
    }
}

@Suite("purchaseURL", suiteTimeLimit)
struct PurchaseURLTests {
    let link = URL(string: Purchase.link) ?? URL(fileURLWithPath: "/")

    @Test func keepsANewSecretOf256RandomBitsAndHandsOutOnlyItsReference() async throws {
        let h = try Harness()
        let url = try #require(try await h.license.purchaseURL(paymentLink: link))
        let secret = try #require(h.stored?.purchaseToken)
        #expect(secret.count == 43 && base64URLDecode(secret)?.count == 32)
        #expect(secret.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        // The link carries `kgp_` and a hash of the secret, never the secret itself.
        let reference = Purchase.reference(secret)
        #expect(reference.hasPrefix("kgp_") && reference.count == 47)
        #expect(url.absoluteString == "\(Purchase.link)?client_reference_id=\(reference)")
        #expect(url.absoluteString.range(of: secret) == nil)
        #expect(h.stored?.purchaseTokenAt == NOW)
        #expect(h.http.calls.isEmpty)
    }

    @Test func encodesThirtyTwoBytesItsGeneratorDrewAndNothingElse() {
        var generator = RecordingGenerator()
        let secret = newPurchaseSecret(using: &generator)
        // Four 64-bit draws, each as its eight little-endian bytes: 32 bytes, all of them drawn.
        #expect(generator.draws == 4)
        var drawn = Data()
        for value in RecordingGenerator.values { withUnsafeBytes(of: value.littleEndian) { drawn.append(contentsOf: $0) } }
        #expect(secret == base64URLEncode(drawn) && base64URLDecode(secret) == drawn)
    }

    @Test func drawsADifferentSecretEveryTimeByDefault() {
        // The system's generator, never a seeded or constant one: one secret per install.
        let first = newPurchaseSecret()
        let second = newPurchaseSecret()
        #expect(first != second)
        for secret in [first, second] { #expect(secret.count == 43 && base64URLDecode(secret)?.count == 32) }
    }

    @Test func handsTheHeldTokenOutAgainItsBoundCountedFromThisCallAndClearsTheClaimsWait() async throws {
        let h = try Harness(Purchase.held(10 * DAY) { $0.claimAskedAt = NOW - 1000 })
        h.clock.set(NOW + 1000)
        let url = try await h.license.purchaseURL(paymentLink: link)
        #expect(url?.absoluteString == "\(Purchase.link)?client_reference_id=\(Purchase.reference(Purchase.token))")
        #expect(h.stored?.purchaseToken == Purchase.token && h.stored?.purchaseTokenAt == NOW + 1000)
        #expect(h.stored?.claimAskedAt == nil)
    }

    @Test func makesANewTokenOnceTheHeldOneIsPastItsBound() async throws {
        let h = try Harness(Purchase.held(Waits.purchaseTokenMs))
        let url = try #require(try await h.license.purchaseURL(paymentLink: link))
        #expect(url.absoluteString.range(of: Purchase.reference(Purchase.token)) == nil)
        #expect(h.stored?.purchaseToken != Purchase.token && h.stored?.purchaseToken != nil)
    }

    @Test func keepsTheLinksOwnParametersAndFragmentAndReplacesAClientReferenceAlreadyOnIt() async throws {
        let h = try Harness(Purchase.held())
        let given = try #require(URL(string: "https://buy.stripe.com/x?prefilled_email=jo%40example.com&client_reference_id=old#pay"))
        let url = try await h.license.purchaseURL(paymentLink: given)
        let expected = "https://buy.stripe.com/x?prefilled_email=jo%40example.com&client_reference_id=\(Purchase.reference(Purchase.token))#pay"
        #expect(url?.absoluteString == expected)
    }

    @Test(arguments: [
        StoredState(key: "KEY-1", activationId: "act_1", lease: "header.payload.sig"), StoredState(key: "KEY-1", refused: .revoked),
        StoredState(key: "KEY-1"),
    ])
    func isNilWhileAnyKeyIsHeldAndSavesNothing(state: StoredState) async throws {
        let h = try Harness(state)
        #expect(try await h.license.purchaseURL(paymentLink: link) == nil)
        #expect(h.storage.writes == 0)
    }

    @Test(arguments: ["/buy", "buy.stripe.com/test_abc"])
    func rejectsALinkThatIsNotAnAbsoluteURLBeforeReadingAnything(given: String) async throws {
        let h = try Harness()
        // A read would never settle: the call must not get that far.
        h.storage.hangNextRead()
        let relative = try #require(URL(string: given))
        let thrown = await answer(within: 5) { () -> String in
            do {
                _ = try await h.license.purchaseURL(paymentLink: relative)
                return "answered"
            } catch let error as InvalidPaymentLink {
                return error.link
            } catch {
                return "\(error)"
            }
        }
        #expect(thrown == given)
        #expect(h.storage.hungReads == 0)
        h.storage.releaseAll()
    }

    @Test func throwsWhenTheStateCannotBeReadOrTheTokenCannotBeSaved() async throws {
        let unreadable = try Harness()
        unreadable.storage.failRead(1)
        await #expect(throws: StorageError.self) { try await unreadable.license.purchaseURL(paymentLink: link) }
        let unsaved = try Harness()
        unsaved.storage.failWrites()
        await #expect(throws: StorageError.self) { try await unsaved.license.purchaseURL(paymentLink: link) }
        #expect(unsaved.stored?.purchaseToken == nil)
    }

    @Test func behindACallThatHasNotFinishedAnswersTheHeldTokenAsItIsAndThrowsWhenNoneIsHeld() async throws {
        let h = try Harness(Purchase.held(DAY), httpTimeout: 0.2, timing: quick)
        h.storage.hangNextRead()
        let stuck = Task { await h.license.status() }
        await eventually { h.storage.hungReads == 1 }
        let url = await answer { try? await h.license.purchaseURL(paymentLink: link) }
        #expect(url??.absoluteString == "\(Purchase.link)?client_reference_id=\(Purchase.reference(Purchase.token))")
        #expect(h.storage.writes == 0)
        h.storage.releaseAll()
        _ = await answer { await stuck.value }

        // None held, or one past its bound (a link the next status() would drop), the bound judged by
        // the guarded clock (29 days by the device clock, 30 by the guarded one): it throws.
        let pastByTheGuard = Purchase.held(Waits.purchaseTokenMs - DAY) { $0.lastSeen = NOW + DAY }
        for state in [StoredState?.none, Purchase.held(Waits.purchaseTokenMs), pastByTheGuard] {
            let none = try Harness(state, httpTimeout: 0.2, timing: quick)
            none.storage.hangNextRead()
            let blocked = Task { await none.license.status() }
            await eventually { none.storage.hungReads == 1 }
            await #expect(throws: LicenseCallError.previousCallUnfinished) { try await none.license.purchaseURL(paymentLink: link) }
            #expect(none.storage.writes == 0)
            none.storage.releaseAll()
            _ = await answer { await blocked.value }
        }
    }
}

/// A generator that gives `values` in turn (then 5 on every draw), and records how many draws it gave.
struct RecordingGenerator: RandomNumberGenerator {
    static let values: [UInt64] = [0x0102_0304_0506_0708, 2, 0xFFFF_FFFF_FFFF_FFFF, 4]
    private(set) var draws = 0

    mutating func next() -> UInt64 {
        defer { draws += 1 }
        return draws < Self.values.count ? Self.values[draws] : 5
    }
}

@Suite("the pickup at status()", suiteTimeLimit)
struct PickupTests {
    @Test func savesABoughtKeyExactlyAsActivateDoesClearsTheTokenAndAnswersLicensed() async throws {
        let h = try Harness(deviceName: "Rae's laptop")
        h.storage.set(Purchase.trialState(h))
        h.http.on("claim") { _ in Purchase.bought(h) }
        #expect(await h.license.status() == LicenseStatus(state: .licensed, key: Purchase.boughtKey))
        // The secret, the fingerprint, and every fingerprint the device answers to, as a validate sends them.
        let body: LicenseJSON = [
            "token": .string(Purchase.token), "fingerprint": "fp-test", "fingerprints": ["fp-test"], "name": "Rae's laptop", "major": 1,
        ]
        #expect(h.http.body("claim") == body)
        let stored = try #require(h.stored)
        #expect(stored.key == Purchase.boughtKey && stored.activationId == "act_1" && stored.checkedMajor == 1 && stored.verdictAt == NOW)
        #expect(Purchase.noPurchaseFields(stored))
        // Licensed from then on, offline, and never asked again.
        h.http.setFail(true)
        #expect(await h.license.status() == LicenseStatus(state: .licensed, key: Purchase.boughtKey))
        #expect(h.http.count("claim") == 1)
        #expect(!h.http.called("trial"))
    }

    @Test func sendsEveryFingerprintReadHeldOrNotWithinTheServersBounds() async throws {
        let identity = DeviceIdentity(fingerprint: "fp-machine", kind: .machine, alternates: ["fp-host"])
        let held = try Harness(Purchase.held(), fingerprinter: IdentifyingFingerprinter { identity })
        held.http.on("claim", status: 200, json: ["pending": true])
        _ = await held.license.status()
        let body: LicenseJSON = [
            "token": .string(Purchase.token), "fingerprint": "fp-machine", "fingerprintKind": "machine",
            "fingerprints": ["fp-machine", "fp-host"], "major": 1,
        ]
        // No device name configured: none sent.
        #expect(held.http.body("claim") == body)
        // Not held to its device (`deviceHold` false): no kind, but every fingerprint read all the same.
        let pooled = try Harness(Purchase.held(), fingerprinter: IdentifyingFingerprinter { identity }, deviceHold: false)
        pooled.http.on("claim", status: 200, json: ["pending": true])
        _ = await pooled.license.status()
        #expect(pooled.http.body("claim")?["fingerprints"] == ["fp-machine", "fp-host"])
        #expect(pooled.http.body("claim")?.has("fingerprintKind") == false)
        // Within the server's bounds: 1 to 200 UTF-16 units each, never cut, the first 4.
        let long = String(repeating: "x", count: 201)
        let many = DeviceIdentity(fingerprint: "fp-machine", kind: .machine, alternates: [long, "", "fp-a1", "fp-a2", "fp-a3", "fp-a4"])
        let bounded = try Harness(Purchase.held(), fingerprinter: IdentifyingFingerprinter { many })
        bounded.http.on("claim", status: 200, json: ["pending": true])
        _ = await bounded.license.status()
        #expect(bounded.http.body("claim")?["fingerprints"] == ["fp-machine", "fp-a1", "fp-a2", "fp-a3"])
    }

    @Test func neverClaimsUnderTheHostNameFallbackAndSavesNothingWhenItsOwnFingerprintDidNotRead() async throws {
        let hostOnly = IdentifyingFingerprinter { DeviceIdentity(fingerprint: nil, alternates: ["fp-host"]) }
        let h = try Harness(Purchase.held(), fingerprinter: hostOnly)
        h.http.on("claim", status: 200, json: ["pending": true])
        #expect(await h.license.status() == LicenseStatus(state: .unlicensed))
        #expect(await h.license.refresh() == LicenseStatus(state: .unlicensed))
        #expect(!h.http.called("claim"))
        // Nothing saved, not even the wait: the next status() tries again.
        #expect(h.stored == Purchase.held())
        // startTrial() may: under the host name, the one fingerprint it read.
        _ = await h.license.startTrial()
        #expect(h.http.body("claim")?["fingerprint"] == "fp-host" && h.http.body("claim")?["fingerprintKind"] == "hostname")
        #expect(h.http.body("claim")?["fingerprints"] == ["fp-host"])
    }

    @Test func readsTheDeviceForAStatusClaimWithTheStatusBoundAndOnceForAnActivationsAtATrialStart() async throws {
        // A machine id that never reads: only the bound the read is given keeps it off the launch path.
        let timed = TimedFingerprinter()
        let h = try Harness(Purchase.held(), fingerprinter: timed)
        #expect(await h.license.status() == LicenseStatus(state: .unlicensed))
        #expect(timed.bounds == [Timing.standard.machineId] && Timing.standard.machineId == 2)
        #expect(!h.http.called("claim") && h.stored == Purchase.held())
        // startTrial() reads it once, for an activation's 10 s, for both its asks.
        _ = await h.license.startTrial()
        #expect(timed.bounds == [Timing.standard.machineId, Timing.standard.activateMachineId] && Timing.standard.activateMachineId == 10)
    }

    @Test func atStartTrialADeviceWithNoFingerprintAtAllSendsNoClaimAndStartsTheWait() async throws {
        let h = try Harness(Purchase.held(), fingerprinter: GetFingerprinter { throw FakeHTTP.NetworkDown() })
        #expect(await h.license.startTrial() == LicenseStatus(state: .unlicensed))
        #expect(h.http.calls.isEmpty)
        #expect(h.stored?.purchaseToken == Purchase.token && h.stored?.claimAskedAt == NOW)
    }

    @Test func asksUnforcedOnlyForADayAfterTheLinkThenOnlyOnRefreshOrStartTrial() async throws {
        let fresh = try Harness(Purchase.held(Waits.claimEagerMs - 1))
        fresh.http.on("claim", status: 200, json: ["pending": true])
        _ = await fresh.license.status()
        #expect(fresh.http.count("claim") == 1)

        let stale = try Harness(Purchase.held(Waits.claimEagerMs))
        stale.http.on("claim", status: 200, json: ["pending": true])
        #expect(await stale.license.status() == LicenseStatus(state: .unlicensed))
        #expect(!stale.http.called("claim"))
        _ = await stale.license.refresh()
        #expect(stale.http.count("claim") == 1)
    }

    @Test func aLinkHandedOutAgainWhileAClaimWasOutKeepsTheClaimDue() async throws {
        let h = try Harness(Purchase.held(HOUR))
        // Another process hands the link out again while this claim is out: the wait it clears
        // is not started again by the late "not bought yet".
        h.http.on("claim") { _ in
            h.storage.set(Purchase.held(-1000))
            return LicenseHTTPResponse(status: 200, json: ["pending": true])
        }
        _ = await h.license.status()
        #expect(h.stored?.purchaseTokenAt == NOW + 1000 && h.stored?.claimAskedAt == nil)
        _ = await h.license.status()
        #expect(h.http.count("claim") == 2)
    }

    @Test func onNotBoughtYetAnswersTheTrialKeepsTheTokenAndAsksAgainOnlyAfterTheWait() async throws {
        let h = try Harness()
        h.storage.set(Purchase.trialState(h))
        h.http.on("claim", status: 200, json: ["pending": true])
        #expect(await h.license.status() == Purchase.trial)
        #expect(h.stored?.purchaseToken == Purchase.token && h.stored?.claimAskedAt == NOW)
        h.clock.set(NOW + Waits.claimWaitMs - 1)
        _ = await h.license.status()
        #expect(h.http.count("claim") == 1)
        h.clock.set(NOW + Waits.claimWaitMs)
        _ = await h.license.status()
        #expect(h.http.count("claim") == 2)
    }

    @Test func asksAtOnceOnRefreshAndWhenTheClockWasSetBackBeforeTheLastAsk() async throws {
        let h = try Harness()
        h.storage.set(Purchase.trialState(h) { $0.claimAskedAt = NOW - 1000 })
        h.http.on("claim", status: 200, json: ["pending": true])
        _ = await h.license.refresh()
        #expect(h.http.count("claim") == 1)
        var later = try #require(h.stored)
        later.claimAskedAt = NOW + 60_000
        h.storage.set(later)
        _ = await h.license.status()
        #expect(h.http.count("claim") == 2)
    }

    @Test(arguments: [
        LicenseHTTPResponse?.none, LicenseHTTPResponse(status: 503, json: ["error": "internal"]),
        LicenseHTTPResponse(status: 404, json: nil), LicenseHTTPResponse(status: 200, json: "portal"),
        LicenseHTTPResponse(status: 403, json: ["error": ""]),
    ])
    func keepsTheTokenWhenNothingAnswersOrTheAnswerCarriesNoErrorWord(answer: LicenseHTTPResponse?) async throws {
        let h = try Harness(Purchase.held())
        if let answer { h.http.on("claim") { _ in answer } } else { h.http.setFail(true) }
        #expect(await h.license.status() == LicenseStatus(state: .unlicensed))
        #expect(h.stored?.purchaseToken == Purchase.token && h.stored?.claimAskedAt == NOW)
    }

    @Test func dropsTheTokenOnAnErrorWordAndOnAKeyWhoseLeaseDoesNotLicenseThisBuild() async throws {
        let h = try Harness()
        let elsewhere = h.signer.lease(sub: Purchase.boughtKey, product: "another-product", ttlSeconds: 86_400)
        let answers = [
            LicenseHTTPResponse(status: 409, json: ["error": "spent"]),
            LicenseHTTPResponse(status: 403, json: ["error": "pickup-off"]),
            LicenseHTTPResponse(status: 403, json: ["error": "limit"]),
            LicenseHTTPResponse(status: 200, json: ["key": .string(Purchase.boughtKey), "activationId": "act_1", "lease": .string(elsewhere)]),
        ]
        for answer in answers {
            h.storage.set(Purchase.trialState(h))
            h.http.on("claim") { _ in answer }
            #expect(await h.license.status() == Purchase.trial)
            #expect(Purchase.noPurchaseFields(h.stored) && h.stored?.key == nil, "\(answer)")
        }
        _ = await h.license.refresh()
        #expect(h.http.count("claim") == answers.count)
    }

    @Test func dropsATokenPastItsBoundWithoutSendingIt() async throws {
        let h = try Harness(Purchase.held(Waits.purchaseTokenMs))
        #expect(await h.license.refresh() == LicenseStatus(state: .unlicensed))
        #expect(!h.http.called("claim"))
        #expect(h.stored?.purchaseToken == nil)
    }

    @Test func savesADropAboutItsTokenSoATokenAnotherProcessMadeMeanwhileStays() async throws {
        let h = try Harness(Purchase.held())
        let another = "kgp_another-process-made-this-one-meanwhile"
        h.http.on("claim") { _ in
            h.storage.set(StoredState(purchaseToken: another, purchaseTokenAt: NOW))
            return LicenseHTTPResponse(status: 409, json: ["error": "spent"])
        }
        _ = await h.license.status()
        #expect(h.stored?.purchaseToken == another && h.stored?.purchaseTokenAt == NOW)
    }

    @Test func boundsAnUnforcedClaimAsAStatusCheckIsAndAForcedOneByTheHTTPBound() async throws {
        for (forced, bound) in [(false, 5_000.0), (true, 15_000.0)] {
            let ticker = ManualTicker()
            let h = try Harness(Purchase.held(), timing: Timing(ticker: ticker))
            h.http.setHang(true)
            let answered = Flag()
            let call = Task { () -> LicenseStatus in
                let status = await h.license.status(forceOnline: forced)
                answered.set(true)
                return status
            }
            await eventually { h.http.called("claim") && ticker.deadlinesMs == [bound] }
            #expect(ticker.deadlinesMs == [bound])
            ticker.advance(ms: Int(bound) - 1)
            try await Task.sleep(nanoseconds: 50_000_000)
            #expect(!answered.on, "answered before its bound")
            ticker.advance(ms: 1)
            #expect(await answer { await call.value } == LicenseStatus(state: .unlicensed))
            #expect(h.stored?.purchaseToken == Purchase.token && h.stored?.claimAskedAt == NOW)
        }
    }

    @Test func answersABoughtKeyEvenWhenTheDiskRefusesItAndTheNextStatusClaimsItAgainAndSavesIt() async throws {
        let h = try Harness(Purchase.held())
        h.http.on("claim") { _ in Purchase.bought(h) }
        h.storage.failWrites()
        #expect(await h.license.status() == LicenseStatus(state: .licensed, key: Purchase.boughtKey))
        #expect(h.stored == Purchase.held())
        // No copy kept in memory, and the secret not let go: the next status() asks again, the
        // same ask, and the server answers the key again (it is idempotent for this device).
        h.storage.failWrites(false)
        #expect(await h.license.status() == LicenseStatus(state: .licensed, key: Purchase.boughtKey))
        let claims = h.http.calls.filter { $0.action == "claim" }.map(\.body)
        #expect(claims.count == 2 && claims.first == claims.last)
        #expect(h.stored?.key == Purchase.boughtKey && Purchase.noPurchaseFields(h.stored))
    }

    @Test func asksNothingWhileAKeyIsHeldOrBehindACallThatHasNotFinished() async throws {
        let keyed = try Harness(Purchase.held { $0.key = "KEY-1" })
        _ = await keyed.license.refresh()
        #expect(!keyed.http.called("claim"))

        let h = try Harness(Purchase.held(), httpTimeout: 0.2, timing: quick)
        h.storage.hangNextRead()
        let stuck = Task { await h.license.status() }
        await eventually { h.storage.hungReads == 1 }
        #expect(await answer { await h.license.refresh() } == LicenseStatus(state: .unlicensed, isStalled: true))
        #expect(!h.http.called("claim"))
        h.storage.releaseAll()
        _ = await answer { await stuck.value }
    }
}

@Suite("the pickup at startTrial()", suiteTimeLimit)
struct StartTrialPickupTests {
    @Test func asksTheClaimBeforeTheTrialWhateverTheWaitAndABoughtKeyIsTheAnswerWithNoTrialAsked() async throws {
        let h = try Harness(Purchase.held { $0.claimAskedAt = NOW - 1000 })
        h.http.on("claim") { _ in Purchase.bought(h) }
        #expect(await h.license.startTrial() == LicenseStatus(state: .licensed, key: Purchase.boughtKey))
        #expect(h.http.actions == ["claim"])
    }

    @Test func asksForTheTrialAfterAClaimThatBroughtNoKey() async throws {
        let h = try Harness(Purchase.held())
        let lease = h.signer.trialLease(device: "fp-test", kind: nil, ttlSeconds: 5 * 24 * 3600)
        h.http.on("claim", status: 200, json: ["pending": true])
        h.http.on("trial", status: 200, json: ["trialStart": .number(Double(NOW)), "trialEndsAt": .number(Double(NOW + 5 * DAY)), "lease": .string(lease)])
        #expect(await h.license.startTrial() == Purchase.trial)
        #expect(h.http.actions == ["claim", "trial"])
        #expect(h.stored?.purchaseToken == Purchase.token && h.stored?.claimAskedAt == NOW)
    }

    @Test func claimsNothingAndWritesNothingBehindACallThatHasNotFinished() async throws {
        let h = try Harness(Purchase.held(), httpTimeout: 0.2, timing: quick)
        h.storage.hangNextRead()
        let stuck = Task { await h.license.status() }
        await eventually { h.storage.hungReads == 1 }
        #expect(await answer { await h.license.startTrial() } == LicenseStatus(state: .unlicensed, isStalled: true))
        #expect(h.http.calls.isEmpty && h.storage.writes == 0)
        h.storage.releaseAll()
        _ = await answer { await stuck.value }
    }

    @Test func readsTheDeviceOnceForBothItsAsks() async throws {
        // A device that cannot be told is read afresh each time: once here, for the claim and the trial.
        let reads = Counter()
        let h = try Harness(Purchase.held(), fingerprinter: GetFingerprinter {
            reads.next()
            throw FakeHTTP.NetworkDown()
        })
        _ = await h.license.startTrial()
        #expect(reads.count == 1)
    }

    @Test func boundsItsClaimAsAStatusCheckIsAndHoldsTheCallsBehindItFiveSecondsLonger() async throws {
        let ticker = ManualTicker()
        let h = try Harness(Purchase.held(), timing: Timing(ticker: ticker))
        h.http.setHang(true)
        let started = Task { await h.license.startTrial() }
        await eventually { h.http.called("claim") }
        let behind = Task { await h.license.status() }
        // The claim gives up at 5 s; the status behind waits to the HTTP bound + 15 s + 5 s.
        await eventually { ticker.deadlinesMs == [5_000, 35_000] }
        #expect(ticker.deadlinesMs == [5_000, 35_000])
        ticker.advance(ms: 4_999)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(!h.http.called("trial"))
        ticker.advance(ms: 1)
        // Then the trial is asked, under the HTTP bound.
        await eventually { ticker.deadlinesMs == [20_000, 35_000] }
        #expect(ticker.deadlinesMs == [20_000, 35_000] && h.http.called("trial"))
        ticker.advance(ms: 15_000)
        #expect(await answer { await started.value } == LicenseStatus(state: .unlicensed))
        #expect(await answer { await behind.value } == LicenseStatus(state: .unlicensed))
    }
}

@Suite("an activation and a deactivation clear the purchase secret", suiteTimeLimit)
struct PurchaseClearedTests {
    @Test func aTypedKeyClearsItSoALaterDeactivateLeavesNoPickupPending() async throws {
        let h = try Harness(Purchase.held())
        h.http.on("activate", status: 200, json: ["lease": .string(h.signer.lease(sub: "KEY-1")), "activationId": "act_1"])
        #expect(await h.license.activate("KEY-1") == .activated)
        #expect(Purchase.noPurchaseFields(h.stored))
    }

    @Test func deactivateClearsIt() async throws {
        let h = try Harness(Purchase.held { $0.key = "KEY-1"; $0.activationId = "act_1" })
        h.http.on("deactivate", status: 200, json: [:])
        try await h.license.deactivate()
        #expect(Purchase.noPurchaseFields(h.stored))
    }
}

/// A key minted for a sale of a trial model's own price may carry `model: trial` in its licence
/// lease: it licenses like any other, and is never read as a trial.
@Suite("a licence lease whose model is trial", suiteTimeLimit)
struct TrialModelKeyTests {
    @Test func boughtLicensesTheAppAsALicenceAndIsNeverReadAsATrial() async throws {
        let h = try Harness(Purchase.held())
        h.http.on("claim") { _ in Purchase.bought(h, model: "trial") }
        #expect(await h.license.status() == LicenseStatus(state: .licensed, key: Purchase.boughtKey))
        h.http.setFail(true)
        #expect(await h.license.status() == LicenseStatus(state: .licensed, key: Purchase.boughtKey))
        #expect(h.stored?.trialLease == nil && h.stored?.trialStart == nil)
    }

    @Test func typedLicensesOfflineToo() async throws {
        let h = try Harness()
        h.storage.set(StoredState(key: "KEY-1", activationId: "act_1", lease: h.signer.lease(sub: "KEY-1", model: "trial"), lastSeen: NOW, checkedMajor: 1))
        h.http.setFail(true)
        #expect(await h.license.status() == LicenseStatus(state: .licensed, key: "KEY-1"))
        #expect(h.http.calls.isEmpty)
    }
}
