import Foundation
import Testing

@testable import KeyGrant

/// Each purchase and launch-report stamp is taken and judged on its own clock: the link's
/// (`purchaseTokenAt`), its 30 days, its day of unforced asks and the report's (`trialReportedAt`)
/// on the guarded clock, the wait after an ask (`claimAskedAt`) on the device clock. Every state
/// here keeps the guarded clock a day ahead of the device clock (`lastSeen`), so a swap fails.
@Suite("the purchase stamps, each on its own clock", suiteTimeLimit)
struct PurchaseClockTests {
    /// The guarded clock: a day ahead of the device clock, which stands at NOW.
    static let guarded = NOW + DAY

    @Test func judgesTheLinksDayByTheGuardedClockAndTheWaitByTheDeviceClock() async throws {
        // A link an hour old by the device clock is a day and an hour old by the guarded one: stale.
        let stale = try Harness(Purchase.held(HOUR) { $0.lastSeen = Self.guarded })
        _ = await stale.license.status()
        #expect(!stale.http.called("claim"))
        // Fresh by the guarded clock, but asked a second ago by the device clock: the wait still runs.
        let waiting = try Harness(Purchase.held(-(DAY - HOUR)) {
            $0.lastSeen = Self.guarded
            $0.claimAskedAt = NOW - 1000
        })
        _ = await waiting.license.status()
        #expect(!waiting.http.called("claim"))
        // Neither was dropped: refresh() asks.
        stale.http.on("claim", status: 200, json: ["pending": true])
        _ = await stale.license.refresh()
        #expect(stale.http.count("claim") == 1)
    }

    @Test func stampsTheLinkByTheGuardedClockAndTheWaitAfterAnAskByTheDeviceClock() async throws {
        let h = try Harness(StoredState(lastSeen: Self.guarded))
        _ = try await h.license.purchaseURL(paymentLink: try #require(URL(string: Purchase.link)))
        #expect(h.stored?.purchaseTokenAt == Self.guarded)
        h.http.on("claim", status: 200, json: ["pending": true])
        _ = await h.license.status()
        #expect(h.http.count("claim") == 1 && h.stored?.claimAskedAt == NOW)
    }

    @Test func dropsASecretThirtyDaysOldByTheGuardedClockUnsent() async throws {
        // 29 days old by the device clock, 30 by the guarded one.
        let h = try Harness(Purchase.held(Waits.purchaseTokenMs - DAY) { $0.lastSeen = Self.guarded })
        _ = await h.license.refresh()
        #expect(!h.http.called("claim") && Purchase.noPurchaseFields(h.stored))
    }

    @Test func handsOutANewSecretForOneThirtyDaysOldByTheGuardedClock() async throws {
        // 29 days old by the device clock, 30 by the guarded one: not held, so a new secret is made.
        let h = try Harness(Purchase.held(Waits.purchaseTokenMs - DAY) { $0.lastSeen = Self.guarded })
        let link = try #require(URL(string: Purchase.link))
        let url = try #require(try await h.license.purchaseURL(paymentLink: link))
        let secret = try #require(h.stored?.purchaseToken)
        #expect(secret != Purchase.token && h.stored?.purchaseTokenAt == Self.guarded)
        #expect(url.absoluteString.hasSuffix("client_reference_id=\(Purchase.reference(secret))"))
    }

    @Test func judgesAndStampsTheLaunchReportByTheGuardedClock() async throws {
        let h = try Harness()
        let lease = h.signer.trialLease(device: "fp-test", kind: nil, ttlSeconds: 5 * 24 * 3600)
        // Its last trial answer half a day ago by the device clock, a day and a half by the guarded one: due.
        h.storage.set(StoredState(
            trialStart: NOW - 2 * DAY, trialEndsAt: NOW + 5 * DAY, trialLease: lease, trialAt: NOW - DAY / 2, lastSeen: Self.guarded
        ))
        #expect(await h.license.status().state == .trial)
        await h.license.launchReportSettled()
        #expect(h.http.count("trial") == 1 && h.stored?.trialReportedAt == Self.guarded)
    }

    @Test func judgesABoughtKeysLeaseAtTheServersTimeTheClockGuardBroughtBack() async throws {
        // A clock that once ran two months ahead: the guard is there, the lease signed now (30 days).
        let ahead = NOW + 60 * DAY
        let h = try Harness(Purchase.held(-60 * DAY) { $0.lastSeen = ahead })
        h.http.on("claim") { _ in Purchase.bought(h) }
        #expect(await h.license.refresh() == LicenseStatus(state: .licensed, key: Purchase.boughtKey))
        #expect(h.stored?.key == Purchase.boughtKey && h.stored?.lastSeen == NOW)
    }
}
