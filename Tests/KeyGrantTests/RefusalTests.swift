import Foundation
import Testing

@testable import KeyGrant

/// A device on 3 holding a valid open lease (every version), last heard by the server on 2.
func onNewMajor(timing: Timing = .standard) throws -> Harness {
    let h = try Harness(major: 3, timing: timing)
    h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: h.signer.lease(major: openMajor), lastSeen: NOW, checkedMajor: 2))
    return h
}

@Suite("upgrade protection: telling the server what this device runs", suiteTimeLimit)
struct UpgradeProtectionTests {
    func openLease(_ h: Harness, windowEnds: Int? = nil, at: Int = NOW) -> String {
        h.signer.lease(major: openMajor, upgradeUntil: windowEnds.map { $0 / 1000 }, at: at)
    }

    @Test func reportsANewerMajorOnAnOpenLeaseAtOnceAndNotesItWasHeard() async throws {
        let h = try Harness(major: 3)
        h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: openLease(h, windowEnds: NOW + 10 * DAY), lastSeen: NOW, checkedMajor: 2))
        let fresh = openLease(h, windowEnds: NOW + 10 * DAY)
        h.http.on("validate", status: 200, json: ["lease": .string(fresh), "activationId": "act_1"])
        #expect(await h.license.status().state == .licensed)
        #expect(h.http.body("validate")?["major"] == 3)
        #expect(h.http.body("validate")?["key"]?.stringValue == KEY)
        #expect(h.stored?.lease == fresh && h.stored?.checkedMajor == 3)
    }

    @Test func keepsTheOpenLeaseWhenThatCheckCannotReachTheServer() async throws {
        let h = try Harness(major: 3)
        let lease = openLease(h, windowEnds: NOW + 10 * DAY)
        h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: lease, lastSeen: NOW, checkedMajor: 2))
        h.http.setFail(true)
        #expect(await h.license.status() == LicenseStatus(state: .licensed, key: KEY))
        #expect(h.http.called("validate"))
        #expect(h.stored?.lease == lease && h.stored?.checkedMajor == 2)
    }

    @Test func notesTheRunAllTheSameWhenItCannotBeSaved() async throws {
        let h = try Harness(major: 3)
        let lease = openLease(h, windowEnds: NOW + 10 * DAY)
        h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: lease, lastSeen: NOW, checkedMajor: 2))
        h.http.on("validate", status: 200, json: ["lease": .string(lease), "activationId": "act_1"])
        h.storage.failWrites()
        #expect(await h.license.status() == LicenseStatus(state: .licensed, key: KEY))
        #expect(h.http.body("validate")?["keptMajor"] == 3)
    }

    @Test func doesNotAskWhenTheServerHasAlreadyHeardThisMajor() async throws {
        let h = try Harness(major: 3)
        h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: openLease(h, windowEnds: NOW + 10 * DAY), lastSeen: NOW, checkedMajor: 3))
        _ = await h.license.status()
        #expect(h.http.calls.isEmpty)
    }

    @Test func notesTheMajorWhileTheWindowIsOpenAndSendsItWithTheNextValidate() async throws {
        let h = try Harness(major: 3)
        h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: openLease(h, windowEnds: NOW + 10 * DAY), lastSeen: NOW, checkedMajor: 3))
        _ = await h.license.status()
        #expect(h.stored?.keptMajor == 3)
        h.http.on("validate", status: 503, json: ["error": "unavailable"])
        _ = await h.license.refresh()
        #expect(h.http.body("validate")?["major"] == 3)
        #expect(h.http.body("validate")?["keptMajor"] == 3)
    }

    @Test func neverLandsAKeptMajorNotedForOneActivationOnAnotherSavedMeanwhile() async throws {
        // Another instance activates another key while this one judges its lease: the major this
        // run noted (`keptMajor`) is about the activation it judged.
        let swap = Shared<(@Sendable () -> Void)?>(nil)
        let h = try Harness(major: 5, fingerprinter: GetFingerprinter {
            swap.current?()
            return "fp-test"
        })
        h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: openLease(h, windowEnds: NOW + 10 * DAY), lastSeen: NOW, checkedMajor: 5))
        let other = StoredState(key: "SLUICE-OTHR-OTHR-OTHR-OTHR", activationId: "act_2", lease: "theirs", lastSeen: NOW)
        let storage = h.storage
        swap.set {
            swap.set(nil)
            storage.set(other)
        }
        h.http.setFail(true)
        #expect(await h.license.status().state == .licensed)
        #expect(h.stored?.activationId == "act_2")
        #expect(h.stored?.keptMajor == nil)
    }

    @Test(arguments: [(10 * DAY, 3), (10 * DAY - 1000, 4), (11 * DAY, 3)])
    func countsTheWindowsLastSecondAsClosed(clockOffset: Int, kept: Int) async throws {
        let end = NOW + 10 * DAY
        let h = try Harness(major: 4)
        h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: openLease(h, windowEnds: end), lastSeen: NOW, checkedMajor: 4, keptMajor: 3))
        h.clock.set(NOW + clockOffset)
        #expect(await h.license.status().state == .licensed)
        #expect(h.stored?.keptMajor == kept)
    }

    @Test func notesNothingOnALeaseThatCarriesNoWindow() async throws {
        let h = try Harness(major: 3)
        h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: openLease(h), lastSeen: NOW, checkedMajor: 3))
        _ = await h.license.status()
        #expect(h.stored?.keptMajor == nil)
    }
}

@Suite("the check of a newer major: once, bounded, and backing off", suiteTimeLimit)
struct NewerMajorTests {
    @Test(arguments: [
        ("revoked", Refusal.revoked), ("expired", .revoked), ("deactivated", .revoked), ("upgrade-required", .upgrade), ("update-required", .outdated),
    ])
    func recordsTheMajorAsHeardOnARefusalKeepsTheRefusalAndDoesNotAskAgain(word: String, refusal: Refusal) async throws {
        let h = try onNewMajor()
        h.http.on("validate", status: 403, json: ["error": .string(word)])
        let refused = LicenseStatus(state: .invalid, reason: LicenseReason(refusal), key: KEY)
        #expect(await h.license.status() == refused)
        #expect(h.stored?.checkedMajor == 3 && h.stored?.refused == refusal && h.stored?.key == KEY)
        #expect(await h.license.status() == refused)
        #expect(h.http.count("validate") == 1)
        if refusal == .revoked {
            // About the key: the lease is dropped.
            #expect(h.stored?.lease == nil && h.stored?.refusedMajor == nil)
        } else {
            // About this build: the lease is kept, with the major refused.
            #expect(h.stored?.lease != nil && h.stored?.refusedMajor == 3)
        }
    }

    @Test func letsARollbackToACoveredBuildRunOfflineAfterItsNewerBuildWasRefused() async throws {
        let h = try onNewMajor()
        h.http.on("validate", status: 403, json: ["error": "upgrade-required"])
        #expect(try await h.license(major: 4).status() == LicenseStatus(state: .invalid, reason: .upgrade, key: KEY))
        h.http.setFail(true)
        #expect(try await h.license(major: 3).status().state == .licensed)
        #expect(try await h.license(major: 4).status() == LicenseStatus(state: .invalid, reason: .upgrade, key: KEY))
        #expect(try await h.license(major: 5).status() == LicenseStatus(state: .invalid, reason: .upgrade, key: KEY))
        #expect(h.http.count("validate") == 1)
    }

    @Test func letsAnUpdateToACoveredBuildRunOfflineAfterAnOlderBuildWasRefusedAsOutOfDate() async throws {
        let h = try onNewMajor()
        h.http.on("validate", status: 403, json: ["error": "update-required"])
        #expect(await h.license.status() == LicenseStatus(state: .invalid, reason: .outdated, key: KEY))
        h.http.setFail(true)
        #expect(try await h.license(major: 3).status() == LicenseStatus(state: .invalid, reason: .outdated, key: KEY))
        #expect(try await h.license(major: 4).status().state == .licensed)
        #expect(try await h.license(major: 2).status() == LicenseStatus(state: .invalid, reason: .outdated, key: KEY))
    }

    @Test func keepsACancelledSubscriberRefusedOfflineToo() async throws {
        let h = try Harness(major: 3)
        h.storage.set(StoredState(
            key: KEY, activationId: "act_1", lease: h.signer.lease(model: "subscription", major: openMajor, ttlSeconds: 7 * 24 * 3600),
            lastSeen: NOW, checkedMajor: 2
        ))
        h.http.on("validate", status: 403, json: ["error": "expired"])
        let revoked = LicenseStatus(state: .invalid, reason: .revoked, key: KEY)
        #expect(await h.license.status() == revoked)
        #expect(await h.license.status() == revoked)
        // The lease it held is still within its life, and is not read to license the app again.
        h.http.setFail(true)
        #expect(await h.license.status() == revoked)
        #expect(await h.license.refresh() == revoked)
    }

    @Test func healsARefusedKeyWhenTheServerLicensesItAgain() async throws {
        let h = try onNewMajor()
        h.http.on("validate", status: 403, json: ["error": "expired"])
        #expect(await h.license.status().state == .invalid)
        h.clock.set(NOW + Waits.askAgainMs)
        h.http.on("validate", status: 200, json: ["lease": .string(h.signer.lease(major: openMajor)), "activationId": "act_1"])
        #expect(await h.license.status().state == .licensed)
        #expect(h.stored?.refused == nil)
        h.http.setFail(true)
        #expect(await h.license.status().state == .licensed)
    }

    @Test func startsAfreshOnANewActivationAfterARefusalAndOnADeactivate() async throws {
        let h = try onNewMajor()
        h.http.on("validate", status: 403, json: ["error": "deactivated"])
        #expect(await h.license.status().state == .invalid)
        h.http.on("activate", status: 200, json: ["lease": .string(h.signer.lease(aid: "act_2", major: openMajor)), "activationId": "act_2"])
        #expect(await h.license.activate(KEY) == .activated)
        #expect(h.stored?.refused == nil)
        h.http.setFail(true)
        #expect(await h.license.status().state == .licensed)
        var refused = try #require(h.stored)
        refused.refused = .revoked
        h.storage.set(refused)
        try await h.license.deactivate()
        #expect(h.stored?.refused == nil)
        #expect(await h.license.status() == LicenseStatus(state: .unlicensed))
    }

    @Test func asksARefusedKeyAgainOnlyOnceTheWaitIsOverAndAtOnceOnRefresh() async throws {
        let h = try onNewMajor()
        h.http.on("validate", status: 403, json: ["error": "revoked"])
        #expect(await h.license.status().state == .invalid)
        #expect(h.http.count("validate") == 1)
        h.clock.set(NOW + Waits.askAgainMs - 1)
        #expect(await h.license.status() == LicenseStatus(state: .invalid, reason: .revoked, key: KEY))
        #expect(h.http.count("validate") == 1)
        #expect(await h.license.refresh().state == .invalid)
        #expect(h.http.count("validate") == 2)
        // The refresh's refusal starts the wait afresh.
        h.clock.set(NOW + 2 * Waits.askAgainMs - 2)
        _ = await h.license.status()
        #expect(h.http.count("validate") == 2)
        h.clock.set(NOW + 2 * Waits.askAgainMs - 1)
        _ = await h.license.status()
        #expect(h.http.count("validate") == 3)
    }

    @Test func asksForAnExpiredLeaseAgainOnlyOnceTheWaitIsOverAndAtOnceOnRefresh() async throws {
        let h = try Harness()
        h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: h.sign(ttl: 3600, at: NOW - 2 * DAY), lastSeen: NOW))
        h.http.setFail(true)
        #expect(await h.license.status() == LicenseStatus(state: .expired, reason: .offline, key: KEY))
        #expect(h.stored?.backoffSince == NOW && h.stored?.backoffMs == Waits.retryUnansweredMs)
        h.clock.set(NOW + Waits.retryUnansweredMs - 1)
        #expect(await h.license.status().state == .expired)
        #expect(h.http.count("validate") == 1)
        h.clock.set(NOW + Waits.retryUnansweredMs)
        _ = await h.license.status()
        #expect(h.http.count("validate") == 2)
        _ = await h.license.refresh()
        #expect(h.http.count("validate") == 3)
        // A lease from the server ends the wait.
        h.http.setFail(false)
        h.http.on("validate", status: 200, json: ["lease": .string(h.sign(at: NOW + Waits.retryUnansweredMs)), "activationId": "act_1"])
        #expect(await h.license.refresh().state == .licensed)
        #expect(h.stored?.backoffSince == nil && h.stored?.backoffMs == nil)
    }

    @Test func serialisesOverlappingStatusCallsOneQuestionAndTheRefusalSurvives() async throws {
        let h = try onNewMajor()
        let asked = Counter()
        let answer = Shared<CheckedContinuation<LicenseHTTPResponse, Never>?>(nil)
        h.http.on("validate") { _ in
            if asked.next() > 1 { return LicenseHTTPResponse(status: 503, json: ["error": "busy"]) }
            return await withCheckedContinuation { answer.set($0) }
        }
        async let first = h.license.status()
        async let second = h.license.status()
        await eventually { answer.current != nil }
        answer.current?.resume(returning: LicenseHTTPResponse(status: 403, json: ["error": "revoked"]))
        let refused = LicenseStatus(state: .invalid, reason: .revoked, key: KEY)
        #expect(await first == refused)
        #expect(await second == refused)
        #expect(asked.count == 1)
        #expect(h.stored?.refused == .revoked && h.stored?.checkedMajor == 3 && h.stored?.lease == nil)
    }

    @Test func recordsTheMajorAsHeardOnAnAnswerItCannotUseAndDoesNotAskAgain() async throws {
        let h = try onNewMajor()
        h.http.on("validate", status: 200, json: ["lease": "not.a.lease"])
        #expect(await h.license.status().state == .licensed)
        _ = await h.license.status()
        #expect(h.http.count("validate") == 1)
        #expect(h.stored?.checkedMajor == 3)
    }

    @Test func backsOffAfterNoAnswerAndAsksAgainOnceTheIntervalHasPassed() async throws {
        let h = try onNewMajor()
        h.http.setFail(true)
        #expect(await h.license.status().state == .licensed)
        #expect(h.stored?.checkedMajor == 2 && h.stored?.backoffSince == NOW && h.stored?.backoffMs == Waits.retryUnansweredMs)
        h.clock.set(NOW + Waits.retryUnansweredMs - 1)
        _ = await h.license.status()
        #expect(h.http.count("validate") == 1)
        h.clock.set(NOW + Waits.retryUnansweredMs)
        _ = await h.license.status()
        #expect(h.http.count("validate") == 2)
    }

    @Test(arguments: [503, 429])
    func treatsAnOutageAsNoVerdictKeepsTheLeaseAndWaitsTheHour(status: Int) async throws {
        let h = try onNewMajor()
        h.http.on("validate", status: status, json: ["error": "busy"])
        #expect(await h.license.status().state == .licensed)
        #expect(h.stored?.checkedMajor == 2 && h.stored?.backoffSince == NOW && h.stored?.backoffMs == Waits.askAgainMs)
        h.clock.set(NOW + Waits.retryUnansweredMs)
        _ = await h.license.status()
        #expect(h.http.count("validate") == 1)
        h.clock.set(NOW + Waits.askAgainMs)
        _ = await h.license.status()
        #expect(h.http.count("validate") == 2)
    }

    @Test func judgesTheWaitBeforeItAsksByTheDeviceClockNotTheGuard() async throws {
        let h = try onNewMajor()
        // A wait of an hour began half an hour ago by the device clock; the guard is two hours
        // ahead of that clock (it was put back).
        var state = try #require(h.stored)
        state.backoffSince = NOW - 30 * 60_000
        state.backoffMs = Waits.askAgainMs
        state.lastSeen = NOW + 2 * HOUR
        h.storage.set(state)
        h.http.setFail(true)
        #expect(await h.license.status() == LicenseStatus(state: .licensed, key: KEY))
        #expect(h.http.count("validate") == 0)
        // Once the device clock is past the wait, it asks.
        h.clock.set(NOW + 31 * 60_000)
        #expect(await h.license.status() == LicenseStatus(state: .licensed, key: KEY))
        #expect(h.http.count("validate") == 1)
    }

    @Test func answersTheValidLeaseWhenTheNetworkNeverAnswersWithinTheChecksBound() async throws {
        let ticker = ManualTicker()
        let h = try onNewMajor(timing: Timing(ticker: ticker))
        h.http.setHang(true)
        let answered = Flag()
        let status = Task { () -> LicenseStatus in
            let status = await h.license.status()
            answered.set(true)
            return status
        }
        // The check status() makes on a valid lease is bounded by its own 5 s, not a request's 15 s.
        await eventually { ticker.deadlinesMs == [5_000] }
        #expect(ticker.deadlinesMs == [5_000])
        ticker.advance(ms: 4_999)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(!answered.on, "answered before its bound")
        ticker.advance(ms: 1)
        #expect(await answer { await status.value } == LicenseStatus(state: .licensed, key: KEY))
        #expect(h.stored?.backoffSince == NOW && h.stored?.backoffMs == Waits.retryUnansweredMs)
    }
}

@Suite("a save that fails once the server has answered", suiteTimeLimit)
struct FailedSaveTests {
    @Test func isTheServersRefusalAllTheSameTheStoredLeaseUntouched() async throws {
        let h = try Harness()
        let lease = h.sign()
        h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: lease, lastSeen: NOW, checkedMajor: 1))
        h.http.on("validate", status: 403, json: ["error": "revoked"])
        h.storage.failWrites()
        #expect(await h.license.refresh() == LicenseStatus(state: .invalid, reason: .revoked, key: KEY))
        #expect(h.storage.writes > 0)
        #expect(h.stored?.lease == lease)
    }

    @Test func isTheServersRenewalAllTheSameAndRenewedAgainByTheNextCall() async throws {
        let h = try Harness()
        let old = h.sign(ttl: 3600, at: NOW - 2 * DAY)
        h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: old, lastSeen: NOW, checkedMajor: 1))
        let fresh = h.sign()
        h.http.on("validate", status: 200, json: ["lease": .string(fresh), "activationId": "act_1"])
        h.storage.failWrites()
        #expect(await h.license.status() == LicenseStatus(state: .licensed, key: KEY))
        #expect(h.stored?.lease == old)
        h.storage.failWrites(false)
        #expect(await h.license.refresh() == LicenseStatus(state: .licensed, key: KEY))
        #expect(h.stored?.lease == fresh)
    }

    @Test func isNoAnswerAtAllRatherThanAThrowWhenNothingAnsweredEither() async throws {
        let h = try Harness()
        h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: h.sign(ttl: 3600, at: NOW - 2 * DAY), lastSeen: NOW, checkedMajor: 1))
        h.http.setFail(true)
        h.storage.failWrites()
        #expect(await h.license.status() == LicenseStatus(state: .expired, reason: .offline, key: KEY))
    }
}

/// What `renew` saves of an ask's answer: `renewalOutcome`'s patch (the vectors pin it), with what
/// this call read and held.
@Suite("what a renewal saves", suiteTimeLimit)
struct RenewalSaveTests {
    @Test func keepsTheMajorItRunsInsideTheRenewedLeasesUpgradeWindow() async throws {
        let h = try Harness(major: 2)
        let expired = h.signer.lease(major: 2, ttlSeconds: 3600, at: NOW - 2 * DAY)
        h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: expired, lastSeen: NOW, checkedMajor: 2))
        // The window still open: this build's major is kept, as the server would have it.
        let renewed = h.signer.lease(major: 2, upgradeUntil: NOW / 1000 + 30 * 24 * 3600)
        h.http.on("validate", status: 200, json: ["lease": .string(renewed), "activationId": "act_1"])
        #expect(await h.license.status() == LicenseStatus(state: .licensed, key: KEY))
        #expect(h.stored?.lease == renewed && h.stored?.keptMajor == 2)
        // Sent with the next ask.
        _ = await h.license.refresh()
        #expect(h.http.calls.last?.body["keptMajor"] == 2)
    }

    @Test(arguments: [Int?.none, 503, 429, 403, 400])
    func keysTheInstallByTheMachineIdItReadWhateverTheAskGotBack(status: Int?) async throws {
        let h = try Harness(fingerprinter: IdentifyingFingerprinter { DeviceIdentity(fingerprint: "fp-test", kind: .machine) })
        let expired = h.sign(ttl: 3600, at: NOW - 2 * DAY)
        h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: expired, lastSeen: NOW, checkedMajor: 1))
        if let status {
            h.http.on("validate", status: status, json: ["error": status == 403 ? "revoked" : "unavailable"])
        } else {
            h.http.setFail(true)
        }
        _ = await h.license.refresh()
        #expect(h.stored?.deviceKind == .machine)
        #expect(h.stored?.backoffSince == NOW)
    }
}
