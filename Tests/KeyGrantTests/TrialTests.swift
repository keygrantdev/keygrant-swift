import Foundation
import Testing

@testable import KeyGrant

@Suite("trials", suiteTimeLimit)
struct TrialTests {
    /// A server that starts a trial `start` ago, ending `end` from now, with this device's trial
    /// lease, signed (as KeyGrant signs one) to the trial's own end.
    func trialServer(_ h: Harness, start: Int = NOW - 2 * DAY, end: Int = NOW + 5 * DAY) -> String {
        let lease = h.signer.trialLease(device: "fp-test", kind: nil, ttlSeconds: (end - NOW) / 1000)
        h.http.on("trial", status: 200, json: ["trialStart": .number(Double(start)), "trialEndsAt": .number(Double(end)), "lease": .string(lease)])
        return lease
    }

    @Test func startsATrialVerifiesItsLeaseAndStashesTheStart() async throws {
        let h = try Harness()
        let lease = trialServer(h)
        #expect(await h.license.startTrial() == LicenseStatus(state: .trial, trialDaysLeft: 5, trialEndsAt: NOW + 5 * DAY))
        #expect(h.stored?.trialStart == NOW - 2 * DAY && h.stored?.trialEndsAt == NOW + 5 * DAY && h.stored?.trialLease == lease)
        #expect(h.stored?.trialAt == NOW)
        #expect(h.registry.stashed == NOW - 2 * DAY)
        // The device's own fingerprint; a get()-only fingerprinter claims no kind.
        #expect(h.http.body("trial") == ["fingerprint": "fp-test"])
    }

    @Test func neverMovesTheTrialStartForward() async throws {
        let h = try Harness(StoredState(trialStart: NOW - 10 * DAY))
        h.registry.set(NOW - 8 * DAY)
        _ = trialServer(h, start: NOW - 2 * DAY, end: NOW + 4 * DAY)
        _ = await h.license.startTrial()
        #expect(h.stored?.trialStart == NOW - 10 * DAY)
        // The earliest evidence is what the server is told, too.
        #expect(h.http.body("trial")?["clientStart"] == .number(Double(NOW - 10 * DAY)))
    }

    @Test func restoresTheEarliestStartFromTheStashWhenTheStateWasWiped() async throws {
        let h = try Harness()
        h.registry.set(NOW - 10 * DAY)
        _ = trialServer(h)
        _ = await h.license.startTrial()
        #expect(h.stored?.trialStart == NOW - 10 * DAY)
        #expect(h.http.body("trial")?["clientStart"] == .number(Double(NOW - 10 * DAY)))
    }

    @Test func answersAndSendsNoClientStartWhenTheStashCannotBeRead() async throws {
        let h = try Harness()
        let license = try License(
            LicenseConfig(
                product: PRODUCT, apiBaseURL: apiBase, publicJWK: h.signer.publicJWK,
                adapters: LicenseAdapters(storage: h.storage, registry: FailingRegistry(), clock: h.clock, fingerprinter: h.fingerprinter, http: h.http)
            ),
            timing: .standard
        )
        _ = trialServer(h)
        #expect(await license.startTrial() == LicenseStatus(state: .trial, trialDaysLeft: 5, trialEndsAt: NOW + 5 * DAY))
        #expect(h.http.body("trial")?.has("clientStart") == false)
        // And a stash that cannot be written does not cost the trial: it is saved all the same.
        #expect(h.stored?.trialStart == NOW - 2 * DAY && h.stored?.trialEndsAt == NOW + 5 * DAY)
    }

    @Test func fallsBackOnTheTrialItHoldsWhenOfflineOrRefused() async throws {
        for answer in [LicenseHTTPResponse?.none, LicenseHTTPResponse(status: 400, json: ["error": "bad"]), LicenseHTTPResponse(status: 503, json: nil)] {
            let h = try Harness()
            let lease = h.signer.trialLease(device: "fp-test", ttlSeconds: 6 * 24 * 3600)
            h.storage.set(StoredState(trialStart: NOW - DAY, trialEndsAt: NOW + 6 * DAY, trialLease: lease, lastSeen: NOW))
            if let answer { h.http.on("trial") { _ in answer } } else { h.http.setFail(true) }
            #expect(await h.license.startTrial() == LicenseStatus(state: .trial, trialDaysLeft: 6, trialEndsAt: NOW + 6 * DAY))
        }
    }

    @Test func keepsTheTrialLeaseItCanVerifyWhenTheServerAnswersWithOneItCannot() async throws {
        // The product's key rotated ahead of this build: every answer is signed with a key the
        // build does not carry. Taking it would end the running trial at the next sync.
        let h = try Harness()
        let ours = h.sign("trial:fp-test", model: "trial", ttl: 5 * 24 * 3600)
        h.storage.set(StoredState(trialStart: NOW - 2 * DAY, trialEndsAt: NOW + 5 * DAY, trialLease: ours, lastSeen: NOW))
        let rotated = Signer().lease(sub: "trial:fp-test", model: "trial", ttlSeconds: 5 * 24 * 3600)
        h.http.on(
            "trial", status: 200,
            json: ["trialStart": .number(Double(NOW - 2 * DAY)), "trialEndsAt": .number(Double(NOW + 5 * DAY)), "lease": .string(rotated)]
        )
        #expect(await h.license.startTrial() == LicenseStatus(state: .trial, trialDaysLeft: 5, trialEndsAt: NOW + 5 * DAY))
        #expect(h.stored?.trialLease == ours)
    }

    @Test func takesAValidTrialLeaseTheServerAnswersWithOverTheValidOneStored() async throws {
        // An extension, or a lease carrying new entitlements: the server's word wins whenever its
        // lease verifies here.
        let h = try Harness()
        let ours = h.sign("trial:fp-test", model: "trial", ttl: 3 * 24 * 3600)
        h.storage.set(StoredState(trialStart: NOW - 4 * DAY, trialEndsAt: NOW + 3 * DAY, trialLease: ours, lastSeen: NOW))
        let extended = signedLease(
            h.signer,
            ["sub": "trial:fp-test", "model": "trial", "lim": 1, "ent": ["edition": "pro"], "exp": .number(Double(NOW / 1000 + 6 * 24 * 3600))]
        )
        h.http.on(
            "trial", status: 200,
            json: ["trialStart": .number(Double(NOW - 4 * DAY)), "trialEndsAt": .number(Double(NOW + 6 * DAY)), "lease": .string(extended)]
        )
        let trial = LicenseStatus(state: .trial, trialDaysLeft: 6, trialEndsAt: NOW + 6 * DAY, entitlements: ["edition": "pro"])
        #expect(await h.license.startTrial() == trial)
        #expect(h.stored?.trialLease == extended)
    }

    @Test func takesTheServersWordWhenItSaysTheTrialIsOverWhateverLeaseIsHeld() async throws {
        let h = try Harness()
        let ours = h.sign("trial:fp-test", model: "trial", ttl: 5 * 24 * 3600)
        h.storage.set(StoredState(trialStart: NOW - 2 * DAY, trialEndsAt: NOW + 5 * DAY, trialLease: ours, lastSeen: NOW))
        h.http.on("trial", status: 200, json: ["trialStart": .number(Double(NOW - 9 * DAY)), "trialEndsAt": .number(Double(NOW - 2 * DAY))])
        #expect(await h.license.startTrial() == LicenseStatus(state: .expired, reason: .trial))
        #expect(h.stored?.trialLease == nil)
    }

    @Test func ignoresAMalformedTrialBody() async throws {
        let h = try Harness()
        h.http.on("trial", status: 200, json: ["trialStart": "oops", "lease": "x"])
        #expect(await h.license.startTrial() == LicenseStatus(state: .unlicensed))
        #expect(h.stored?.trialStart == nil)
    }

    @Test func startsNoTrialOnARunThatCannotTellWhoTheDeviceIs() async throws {
        let h = try Harness(fingerprinter: GetFingerprinter { throw FakeHTTP.NetworkDown() })
        #expect(await h.license.startTrial() == LicenseStatus(state: .unlicensed))
        #expect(!h.http.called("trial"))
    }

    @Test func readsTheDeviceForATrialStartWithTheActivationBoundNotTheOneAStatusGets() async throws {
        let ticker = ManualTicker()
        let never = GetFingerprinter {
            try? await Task.sleep(nanoseconds: hangNanoseconds)
            throw CancellationError()
        }
        let h = try Harness(fingerprinter: never, timing: Timing(ticker: ticker))
        let answered = Flag()
        let started = Task { () -> LicenseStatus in
            let status = await h.license.startTrial()
            answered.set(true)
            return status
        }
        // An activation's 10 s, not the 2 s a status() gets.
        await eventually { ticker.deadlinesMs == [10_000] }
        #expect(ticker.deadlinesMs == [10_000])
        ticker.advance(ms: 9_999)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(!answered.on, "answered before its bound")
        ticker.advance(ms: 1)
        // This device could not be told: no trial is asked for, and none is held.
        #expect(await answer { await started.value } == LicenseStatus(state: .unlicensed))
        #expect(!h.http.called("trial"))
    }

    @Test func answersUnlicensedForATrialLeaseStoredWithoutAStartAskingNothing() async throws {
        // Only a stored start is a trial this device began; no save leaves a lease or an end
        // without one.
        let h = try Harness()
        let lease = h.sign("trial:fp-test", model: "trial", ttl: 5 * 24 * 3600)
        h.storage.set(StoredState(trialEndsAt: NOW + 5 * DAY, trialLease: lease, lastSeen: NOW))
        #expect(await h.license.status() == LicenseStatus(state: .unlicensed))
        #expect(h.http.calls.isEmpty)
    }

    @Test func runsNoTrialOnAStoredEndAloneWhichIsUnsignedAndCouldBeEditedIntoAnyTrial() async throws {
        // The stored end is still ahead: once, that alone ran a trial, offline or not.
        let edited = try Harness(StoredState(trialStart: NOW - 2 * DAY, trialEndsAt: NOW + 365 * DAY))
        edited.http.setFail(true)
        #expect(await edited.license.status() == LicenseStatus(state: .expired, reason: .trial))
        let over = try Harness(StoredState(trialStart: NOW - 10 * DAY, trialEndsAt: NOW - DAY))
        #expect(await over.license.status() == LicenseStatus(state: .expired, reason: .trial))
    }

    @Test func endsATrialWhenItsSignedLeaseEndsWhateverEndIsStoredBesideIt() async throws {
        let h = try Harness()
        h.http.setFail(true)
        let lease = h.signer.trialLease(device: "fp-test", ttlSeconds: 2 * 24 * 3600)
        // Someone edited the stored end a year out: the lease's own end is the one shown.
        h.storage.set(StoredState(trialStart: NOW - 5 * DAY, trialEndsAt: NOW + 365 * DAY, trialLease: lease, lastSeen: NOW))
        #expect(await h.license.status() == LicenseStatus(state: .trial, trialDaysLeft: 2, trialEndsAt: NOW + 2 * DAY))
        // And the same file, read once the lease has ended: the edit buys nothing.
        h.clock.set(NOW + 2 * DAY + 1_000)
        #expect(await h.license.status() == LicenseStatus(state: .expired, reason: .trial))
    }

    @Test func keepsAFourteenDayTrialLiveOnItsTenthDayOfflineOnTheLeaseSignedToItsEnd() async throws {
        let h = try Harness()
        _ = trialServer(h, start: NOW, end: NOW + 14 * DAY)
        #expect(await h.license.startTrial() == LicenseStatus(state: .trial, trialDaysLeft: 14, trialEndsAt: NOW + 14 * DAY))
        // Ten days on, offline: no renewal, and none needed. The launch is reported in the
        // background, and its failing offline costs nothing.
        h.http.setFail(true)
        h.clock.set(NOW + 10 * DAY)
        #expect(await h.license.status() == LicenseStatus(state: .trial, trialDaysLeft: 4, trialEndsAt: NOW + 14 * DAY))
        await h.license.launchReportSettled()
        #expect(h.http.actions == ["trial", "trial"])
        #expect(h.stored?.trialEndsAt == NOW + 14 * DAY && h.stored?.trialReportedAt == NOW + 10 * DAY)
    }

    @Test func takesTheTrialsEndFromItsLeaseWhenNoneIsStored() async throws {
        let h = try Harness()
        h.storage.set(StoredState(trialStart: NOW - 2 * DAY, trialLease: h.signer.trialLease(device: "fp-test"), lastSeen: NOW))
        #expect(await h.license.status() == LicenseStatus(state: .trial, trialDaysLeft: 7, trialEndsAt: NOW + 7 * DAY))
    }

    @Test func runsOnThisDevicesTrialLeaseAndNotAnothers() async throws {
        let mine = try Harness()
        mine.storage.set(StoredState(trialStart: NOW, trialLease: mine.signer.trialLease(device: "fp-test"), lastSeen: NOW))
        #expect(await mine.license.status().state == .trial)
        let theirs = try Harness()
        theirs.storage.set(StoredState(trialStart: NOW - 30 * DAY, trialLease: theirs.signer.trialLease(device: "fp-another-machine"), lastSeen: NOW))
        #expect(await theirs.license.status() == LicenseStatus(state: .expired, reason: .trial))
    }

    @Test func runsOnALeaseStartedUnderAHostNameWhateverDeviceItNames() async throws {
        let h = try Harness()
        h.storage.set(StoredState(
            trialStart: NOW - 30 * DAY, trialLease: h.signer.trialLease(device: "fp-another-machine", kind: .hostname), lastSeen: NOW
        ))
        #expect(await h.license.status().state == .trial)
    }

    @Test func doesNotJudgeATrialLeaseOnARunThatCannotTell() async throws {
        let h = try Harness(fingerprinter: GetFingerprinter { throw FakeHTTP.NetworkDown() })
        h.storage.set(StoredState(trialStart: NOW, trialLease: h.signer.trialLease(device: "fp-another-machine"), lastSeen: NOW))
        #expect(await h.license.status().state == .trial)
    }

    @Test func takesNoLicencesLeaseInTheTrialsPlace() async throws {
        let h = try Harness()
        h.storage.set(StoredState(trialStart: NOW - 30 * DAY, trialLease: h.sign(), lastSeen: NOW))
        #expect(await h.license.status() == LicenseStatus(state: .expired, reason: .trial))
    }

    @Test func stampsATrialAnswerByTheGuardedClock() async throws {
        let h = try Harness(StoredState(lastSeen: NOW + 5 * 60_000))
        _ = trialServer(h, start: NOW, end: NOW + 5 * DAY)
        h.clock.set(NOW - DAY)
        _ = await h.license.startTrial()
        #expect(h.stored?.trialAt == NOW + 5 * 60_000)
    }
}

@Suite("a trial the disk refused", suiteTimeLimit)
struct UnsavedTrialTests {
    /// startTrial() asked at NOW, its answer (ending NOW + 5 days, its lease signed to that end) kept unsaved.
    func keptTrial() async throws -> (Harness, String) {
        let h = try Harness()
        let lease = h.signer.trialLease(device: "fp-test", kind: nil, ttlSeconds: 5 * 24 * 3600)
        h.http.on("trial", status: 200, json: ["trialStart": .number(Double(NOW - 2 * DAY)), "trialEndsAt": .number(Double(NOW + 5 * DAY)), "lease": .string(lease)])
        h.storage.failWrites()
        #expect(await h.license.startTrial() == LicenseStatus(state: .trial, trialDaysLeft: 5, trialEndsAt: NOW + 5 * DAY))
        #expect(h.stored == nil)
        return (h, lease)
    }

    @Test func isKeptForTheProcessAnsweredAndSavedOnceItCanBe() async throws {
        let (h, lease) = try await keptTrial()
        // The next status() reads no trial on the disk, and answers the one it holds.
        #expect(await h.license.status().trialDaysLeft == 5)
        #expect(h.stored == nil)
        h.storage.failWrites(false)
        #expect(await h.license.status().trialDaysLeft == 5)
        #expect(h.stored?.trialStart == NOW - 2 * DAY && h.stored?.trialEndsAt == NOW + 5 * DAY && h.stored?.trialLease == lease)
        // Saved once: not written again by every status() after it.
        let writes = h.storage.writes
        _ = await h.license.status()
        #expect(h.storage.writes == writes)
    }

    @Test func neverMovesAStartLaterWhenItSavesTheTrialItKept() async throws {
        let (h, _) = try await keptTrial()
        h.storage.set(StoredState(trialStart: NOW - 9 * DAY))
        h.storage.failWrites(false)
        _ = await h.license.status()
        #expect(h.stored?.trialStart == NOW - 9 * DAY && h.stored?.trialEndsAt == NOW + 5 * DAY)
    }

    @Test func neverMakesTheTrialLongerThanANewerAnswerAnotherInstanceSaved() async throws {
        let (h, _) = try await keptTrial()
        h.storage.set(StoredState(trialStart: NOW - 9 * DAY, trialEndsAt: NOW - 2 * DAY, trialAt: NOW + 1))
        // Still unable to save: the newer answer's end is the answer.
        #expect(await h.license.status() == LicenseStatus(state: .expired, reason: .trial))
        h.storage.failWrites(false)
        #expect(await h.license.status() == LicenseStatus(state: .expired, reason: .trial))
        #expect(h.stored?.trialEndsAt == NOW - 2 * DAY && h.stored?.trialAt == NOW + 1)
    }

    @Test func takesANewerAnswersLaterEndTooATrialTheServerExtended() async throws {
        let (h, _) = try await keptTrial()
        // The answer the other instance had came with a lease signed to the new end.
        let extended = h.signer.trialLease(device: "fp-test", kind: nil, ttlSeconds: 20 * 24 * 3600)
        h.storage.set(StoredState(trialStart: NOW - 9 * DAY, trialEndsAt: NOW + 20 * DAY, trialLease: extended, trialAt: NOW + 1))
        h.storage.failWrites(false)
        #expect(await h.license.status().trialDaysLeft == 20)
        #expect(h.stored?.trialEndsAt == NOW + 20 * DAY)
    }

    @Test func winsOverAStoredTrialWithNoStampFromAnOlderSDK() async throws {
        let (h, _) = try await keptTrial()
        h.storage.set(StoredState(trialStart: NOW - 9 * DAY, trialEndsAt: NOW - 2 * DAY))
        h.storage.failWrites(false)
        #expect(await h.license.status().trialDaysLeft == 5)
        #expect(h.stored?.trialStart == NOW - 9 * DAY && h.stored?.trialEndsAt == NOW + 5 * DAY && h.stored?.trialAt == NOW)
    }

    @Test(arguments: [
        StoredState(trialStart: NOW - 9 * DAY),
        StoredState(key: "SLUICE-BBBB-BBBB-BBBB-BBBB", activationId: "act_2", lease: "LB", checkedMajor: 1),
    ])
    func savesItsTrialAfterADeactivateOrAnotherKeysActivation(theirs: StoredState) async throws {
        let (h, _) = try await keptTrial()
        h.storage.set(theirs)
        h.storage.failWrites(false)
        _ = await h.license.status()
        let stored = try #require(h.stored)
        #expect(stored.key == theirs.key && stored.activationId == theirs.activationId && stored.lease == theirs.lease)
        #expect(stored.trialStart == (theirs.trialStart ?? NOW - 2 * DAY))
        #expect(stored.trialEndsAt == NOW + 5 * DAY && stored.trialAt == NOW)
    }
}

/// The Keychain stash's rules (`StashedTrialStart`), on an item in memory: the Keychain's own calls
/// are macOS's, and these hold whatever the item is kept in.
@Suite("the trial start a stash keeps", suiteTimeLimit)
struct StashedTrialStartTests {
    @Test func addsTheStartWhenNoneIsStashed() async throws {
        let item = MemoryStashItem()
        try await StashedTrialStart.write(1_000, to: item)
        #expect(item.writes == ["add 1000"])
        #expect(try await StashedTrialStart.read(item) == 1_000)
    }

    @Test func movesTheStartEarlierOnly() async throws {
        let item = MemoryStashItem("1000")
        // A later start, and the same one, leave it alone.
        try await StashedTrialStart.write(2_000, to: item)
        try await StashedTrialStart.write(1_000, to: item)
        #expect(item.writes.isEmpty)
        // An earlier one wins.
        try await StashedTrialStart.write(500, to: item)
        #expect(item.writes == ["update 500"])
        #expect(try await StashedTrialStart.read(item) == 500)
    }

    @Test func writesNothingWhenTheItemCannotBeRead() async throws {
        // A locked keychain: what it holds is not known, so nothing is written over it.
        let item = MemoryStashItem("1000")
        item.failReads()
        await #expect(throws: MemoryStashItem.Unreadable.self) { try await StashedTrialStart.write(500, to: item) }
        await #expect(throws: MemoryStashItem.Unreadable.self) { try await StashedTrialStart.read(item) }
        #expect(item.writes.isEmpty)
        #expect(item.text == "1000")
    }

    @Test func replacesAnItemThatHoldsNoStart() async throws {
        let item = MemoryStashItem("not a time")
        #expect(try await StashedTrialStart.read(item) == nil)
        try await StashedTrialStart.write(1_000, to: item)
        #expect(item.writes == ["update 1000"])
    }
}
