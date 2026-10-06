import Foundation
import Testing

@testable import KeyGrant

@Suite("the waits, early renewal and the clock guard", suiteTimeLimit)
struct ClockTests {
    @Test func healsALeaseThatRanOutOfflineOnceTheShortWaitIsOver() async throws {
        let h = try Harness()
        h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: h.sign(ttl: 3600, at: NOW - 2 * DAY), lastSeen: NOW))
        h.http.setFail(true)
        #expect(await h.license.status() == LicenseStatus(state: .expired, reason: .offline, key: KEY))
        h.http.setFail(false)
        h.http.on("validate", status: 200, json: ["lease": .string(h.sign()), "activationId": "act_1"])
        h.clock.set(NOW + Waits.retryUnansweredMs - 1)
        #expect(await h.license.status().state == .expired)
        h.clock.set(NOW + Waits.retryUnansweredMs)
        #expect(await h.license.status() == LicenseStatus(state: .licensed, key: KEY))
    }

    @Test func stillWaitsTheHourAfterARefusal() async throws {
        let h = try Harness()
        h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: h.sign(ttl: 3600, at: NOW - 2 * DAY), lastSeen: NOW))
        h.http.on("validate", status: 403, json: ["error": "revoked"])
        #expect(await h.license.status().reason == .revoked)
        h.clock.set(NOW + Waits.retryUnansweredMs)
        _ = await h.license.status()
        #expect(h.http.count("validate") == 1)
        h.clock.set(NOW + Waits.askAgainMs)
        _ = await h.license.status()
        #expect(h.http.count("validate") == 2)
    }

    /// What a device holds that `status()` asks the server about once the wait allows.
    enum Holding: String, Sendable, CaseIterable, CustomTestStringConvertible {
        case refusal = "a stored refusal"
        case expiredLease = "a lease past its end"
        case leaseNearItsEnd = "a valid lease near its end"

        var testDescription: String { rawValue }

        func state(_ h: Harness) -> StoredState {
            switch self {
            case .refusal: StoredState(key: KEY, activationId: "act_1", refused: .revoked)
            case .expiredLease: StoredState(key: KEY, activationId: "act_1", lease: h.sign(ttl: 3600, at: NOW - 2 * DAY), checkedMajor: 1)
            case .leaseNearItsEnd: StoredState(key: KEY, activationId: "act_1", lease: h.sign(at: NOW - 26 * DAY), checkedMajor: 1)
            }
        }
    }

    @Test(arguments: Holding.allCases)
    func timesTheWaitBeforeAskingAgainByTheDeviceClockNotTheGuard(holding: Holding) async throws {
        // The guard (lastSeen) is a day ahead of the device clock, and the last ask was half an
        // hour ago by the device clock: its hour's wait is not over, though by the guard it would be.
        let h = try Harness()
        var state = holding.state(h)
        state.backoffSince = NOW - 30 * 60_000
        state.backoffMs = Waits.askAgainMs
        state.lastSeen = NOW + DAY
        h.storage.set(state)
        h.http.setFail(true)
        _ = await h.license.status()
        #expect(!h.http.called("validate"))
    }

    @Test func startsTheWaitAfterARenewalByTheDeviceClockNotTheGuard() async throws {
        let h = try Harness()
        let expired = h.sign(ttl: 3600, at: NOW - 2 * DAY)
        h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: expired, lastSeen: NOW + DAY, checkedMajor: 1))
        h.http.setFail(true)
        #expect(await h.license.status() == LicenseStatus(state: .expired, reason: .offline, key: KEY))
        #expect(h.stored?.backoffSince == NOW && h.stored?.backoffMs == Waits.retryUnansweredMs)
    }

    @Test func licensesFromARenewalWhoseCheckOfTheServersTimeCannotReadTheStateJustThen() async throws {
        // The renewal reads the state again to bring the clock guard to the server's time
        // (`serverNow`): a read that fails there costs the correction, never the renewal, and
        // status() still answers.
        let h = try Harness()
        let expired = h.sign(ttl: 3600, at: NOW - 2 * DAY)
        h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: expired, lastSeen: NOW, checkedMajor: 1))
        let fresh = h.sign()
        h.http.on("validate", status: 200, json: ["lease": .string(fresh)])
        // The status's own read is the first; the renewal's check of the time, the second.
        h.storage.failRead(2)
        #expect(await h.license.status() == LicenseStatus(state: .licensed, key: KEY))
        #expect(h.stored?.lease == fresh)
    }

    @Test func renewsALeaseEarlyWithinAWeekOfItsEndAndNotBefore() async throws {
        let h = try Harness()
        h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: h.sign(), lastSeen: NOW, checkedMajor: 1))
        let renewed = h.sign(at: NOW + 30 * DAY - Waits.renewWithinMs)
        h.http.on("validate", status: 200, json: ["lease": .string(renewed), "activationId": "act_1"])
        h.clock.set(NOW + 30 * DAY - Waits.renewWithinMs - 1)
        #expect(await h.license.status().state == .licensed)
        #expect(h.http.count("validate") == 0)
        h.clock.set(NOW + 30 * DAY - Waits.renewWithinMs + 1)
        #expect(await h.license.status().state == .licensed)
        #expect(h.http.count("validate") == 1)
        #expect(h.stored?.lease == renewed)
        // The renewed lease is far from its end: no ask on the next status().
        _ = await h.license.status()
        #expect(h.http.count("validate") == 1)
    }

    @Test func renewsAShortLeaseAtHalfItsLifeNotOnEveryStatus() async throws {
        let h = try Harness()
        h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: h.sign(model: "subscription", ttl: 7 * 24 * 3600), lastSeen: NOW, checkedMajor: 1))
        h.http.setFail(true)
        h.clock.set(NOW + 7 * DAY / 2 - 1)
        _ = await h.license.status()
        #expect(h.http.count("validate") == 0)
        h.clock.set(NOW + 7 * DAY / 2 + 1)
        _ = await h.license.status()
        #expect(h.http.count("validate") == 1)
    }

    @Test func keepsTheValidLeaseWhenAnEarlyRenewalGetsNothingAndWaitsBeforeTryingAgain() async throws {
        let h = try Harness()
        let lease = h.sign()
        h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: lease, lastSeen: NOW, checkedMajor: 1))
        h.http.setFail(true)
        h.clock.set(NOW + 25 * DAY)
        #expect(await h.license.status() == LicenseStatus(state: .licensed, key: KEY))
        #expect(h.stored?.lease == lease && h.stored?.backoffSince == NOW + 25 * DAY && h.stored?.backoffMs == Waits.retryUnansweredMs)
        _ = await h.license.status()
        #expect(h.http.count("validate") == 1)
    }

    @Test func answersARefusalToAnEarlyRenewal() async throws {
        let h = try Harness()
        h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: h.sign(model: "subscription", ttl: 7 * 24 * 3600), lastSeen: NOW, checkedMajor: 1))
        h.http.on("validate", status: 403, json: ["error": "expired"])
        h.clock.set(NOW + 5 * DAY)
        #expect(await h.license.status() == LicenseStatus(state: .invalid, reason: .revoked, key: KEY))
    }

    @Test func licensesAgainOnlineAfterAClockThatJumped60DaysAheadIsPutRight() async throws {
        let h = try Harness()
        h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: h.sign(at: NOW - DAY), lastSeen: NOW + 60 * DAY, checkedMajor: 1))
        h.http.on("validate", status: 200, json: ["lease": .string(h.sign()), "activationId": "act_1"])
        #expect(await h.license.status() == LicenseStatus(state: .licensed, key: KEY))
        #expect(h.stored?.lastSeen == NOW)
        h.http.setFail(true)
        #expect(await h.license.status() == LicenseStatus(state: .licensed, key: KEY))
    }

    @Test func licensesFromTheServersLeaseWhenTheGuardItPutsRightCannotBeSaved() async throws {
        let h = try Harness()
        h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: h.sign(at: NOW - DAY), lastSeen: NOW + 60 * DAY, checkedMajor: 1))
        h.http.on("validate", status: 200, json: ["lease": .string(h.sign()), "activationId": "act_1"])
        h.storage.failWrites()
        #expect(await h.license.status() == LicenseStatus(state: .licensed, key: KEY))
        #expect(h.stored?.lastSeen == NOW + 60 * DAY)
    }

    /// The guard after a refresh() answered with a fresh lease signed at NOW, the clock at `clock`.
    func guardAfterRefresh(guard lastSeen: Int, clock: Int = NOW) async throws -> Int? {
        let h = try Harness()
        let lease = h.sign()
        h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: lease, lastSeen: lastSeen, checkedMajor: 1))
        h.clock.set(clock)
        h.http.on("validate", status: 200, json: ["lease": .string(lease), "activationId": "act_1"])
        #expect(await h.license.refresh().state == .licensed)
        return h.stored?.lastSeen
    }

    @Test func leavesTheGuardWithinTheToleranceAndBringsItBackPastIt() async throws {
        #expect(try await guardAfterRefresh(guard: NOW + 30 * 60_000) == NOW + 30 * 60_000)
        #expect(try await guardAfterRefresh(guard: NOW + Waits.clockToleranceMs) == NOW + Waits.clockToleranceMs)
        #expect(try await guardAfterRefresh(guard: NOW + Waits.clockToleranceMs + 1) == NOW)
        // Back to the lease's signing time, not to a device clock behind it.
        #expect(try await guardAfterRefresh(guard: NOW + 60 * DAY, clock: NOW - 2 * HOUR) == NOW)
    }

    @Test func bringsTheGuardBackForALeaseNamingTheKeyInAnotherCase() async throws {
        let h = try Harness()
        h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: h.sign(), lastSeen: NOW + 60 * DAY, checkedMajor: 1))
        h.http.on("validate", status: 200, json: ["lease": .string(h.sign("Sluice-aaaa-BBBB-CCCC-DDDD")), "activationId": "act_1"])
        _ = await h.license.refresh()
        #expect(h.stored?.lastSeen == NOW)
    }

    @Test(arguments: [("SLUICE-OTHR-OTHR-OTHR-OTHR", "act_1", NOW), (KEY, "act_2", NOW), (KEY, "act_1", NOW - DAY)])
    func movesNoGuardForALeaseSignedForAnotherKeyActivationOrOlder(sub: String, aid: String, at: Int) async throws {
        let h = try Harness()
        h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: h.sign(), lastSeen: NOW + 60 * DAY, checkedMajor: 1))
        h.http.on("validate", status: 200, json: ["lease": .string(h.signer.lease(sub: sub, aid: aid, at: at)), "activationId": .string(aid)])
        _ = await h.license.refresh()
        #expect(h.stored?.lastSeen == NOW + 60 * DAY)
    }

    @Test func stampsByTheGuardedClockNeverEarlierThanTheLastTimeSeen() async throws {
        let h = try Harness(StoredState(lastSeen: NOW + 5 * 60_000))
        h.http.on("activate", status: 200, json: ["lease": .string(h.sign()), "activationId": "act_1"])
        h.http.on("deactivate", status: 200, json: ["ok": true])
        _ = await h.license.activate(KEY)
        #expect(h.stored?.verdictAt == NOW + 5 * 60_000)
        h.clock.set(NOW - DAY)
        try await h.license.deactivate()
        #expect(h.stored?.verdictAt == NOW + 5 * 60_000)
    }

    @Test func savesItsOwnAnswersAfterTheClockIsPutBack() async throws {
        let h = try Harness()
        // The last answer was stamped by a clock 60 days ahead, since put right.
        h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: h.sign(at: NOW - DAY), lastSeen: NOW, checkedMajor: 1, verdictAt: NOW + 60 * DAY))
        h.http.on("validate", status: 403, json: ["error": "revoked"])
        #expect(await h.license.refresh() == LicenseStatus(state: .invalid, reason: .revoked, key: KEY))
        #expect(h.stored?.refused == .revoked && h.stored?.verdictAt == NOW && h.stored?.lease == nil)
    }

    @Test func advancesTheGuardOnEverySave() async throws {
        let h = try Harness(StoredState(lastSeen: NOW - DAY))
        h.http.on("activate", status: 200, json: ["lease": .string(h.sign()), "activationId": "act_1"])
        _ = await h.license.activate(KEY)
        #expect(h.stored?.lastSeen == NOW)
    }
}
