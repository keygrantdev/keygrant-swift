import Foundation
import Testing

@testable import KeyGrant

/// What the pickup lets in and what it saves: a bought key's lease verified like any other, the
/// secret sent in no request but the claim, and each save about the secret landing only on it.
@Suite("the pickup's lease and saves", suiteTimeLimit)
struct PickupSaveTests {
    /// A claim's 200 carrying the key, its activation and `lease`.
    func answering(_ h: Harness, lease: String) {
        h.http.on("claim", status: 200, json: ["key": .string(Purchase.boughtKey), "activationId": "act_1", "lease": .string(lease)])
    }

    /// `lease` with one claim of its payload changed (`lim`) and the payload encoded again, under
    /// its original header and signature: well-formed and canonical, so only the signature refuses it.
    func tampered(_ lease: String) throws -> String {
        let parts = lease.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        try #require(parts.count == 3)
        let payload = try #require(base64URLDecode(parts[1]).flatMap(JSONText.parse(decoding:)))
        var claims = try #require(payload.objectValue)
        claims["lim"] = 4
        return [parts[0], base64URLEncode(JSONText.data(.object(claims))), parts[2]].joined(separator: ".")
    }

    /// The two leases a claim may not license by: one signed by another key, and the product's
    /// own with its payload tampered, each refused by its signature.
    func forged(_ h: Harness) throws -> [String] {
        let leases = [Signer().lease(sub: Purchase.boughtKey), try tampered(h.signer.lease(sub: Purchase.boughtKey))]
        let key = try KeySet(publicJWK: h.signer.publicJWK)
        for lease in leases { #expect(verifyLease(lease, keys: key, now: NOW).failure == .badSignature) }
        return leases
    }

    @Test func refusesAtStatusABoughtKeyWhoseLeaseIsSignedByAnotherKeyOrTampered() async throws {
        let h = try Harness()
        for lease in try forged(h) {
            h.storage.set(Purchase.trialState(h))
            answering(h, lease: lease)
            // As with no secret: the trial; the secret let go, and nothing of the key kept.
            #expect(await h.license.status() == Purchase.trial)
            #expect(Purchase.noPurchaseFields(h.stored) && h.stored?.key == nil && h.stored?.lease == nil)
        }
        #expect(h.http.count("claim") == 2)
    }

    @Test func refusesAtStartTrialABoughtKeyWhoseLeaseIsSignedByAnotherKeyOrTamperedAndAsksTheTrial() async throws {
        let h = try Harness()
        let trialLease = h.signer.trialLease(device: "fp-test", kind: nil, ttlSeconds: 5 * 24 * 3600)
        h.http.on(
            "trial", status: 200,
            json: ["trialStart": .number(Double(NOW)), "trialEndsAt": .number(Double(NOW + 5 * DAY)), "lease": .string(trialLease)]
        )
        for lease in try forged(h) {
            h.storage.set(Purchase.held())
            answering(h, lease: lease)
            #expect(await h.license.startTrial() == Purchase.trial)
            #expect(Purchase.noPurchaseFields(h.stored) && h.stored?.key == nil && h.stored?.lease == nil)
        }
        #expect(h.http.actions == ["claim", "trial", "claim", "trial"])
    }

    @Test func sendsTheSecretInNoRequestButTheClaim() async throws {
        let h = try Harness()
        let trialLease = h.signer.trialLease(device: "fp-test", kind: nil, ttlSeconds: 5 * 24 * 3600)
        h.storage.set(Purchase.held {
            $0.trialStart = NOW - 2 * DAY
            $0.trialEndsAt = NOW + 5 * DAY
            $0.trialLease = trialLease
            $0.lastSeen = NOW
        })
        let lease = h.signer.lease(sub: "KEY-1")
        h.http.on("claim", status: 200, json: ["pending": true])
        h.http.on(
            "trial", status: 200,
            json: ["trialStart": .number(Double(NOW - 2 * DAY)), "trialEndsAt": .number(Double(NOW + 5 * DAY)), "lease": .string(trialLease)]
        )
        h.http.on("activate", status: 200, json: ["lease": .string(lease), "activationId": "act_1"])
        h.http.on("validate", status: 200, json: ["lease": .string(lease)])
        _ = await h.license.status()  // a claim, and the launch report
        await h.license.launchReportSettled()
        _ = await h.license.startTrial()  // a claim, and the trial ask
        #expect(await h.license.activate("KEY-1") == .activated)
        _ = await h.license.refresh()
        #expect(h.http.actions == ["claim", "trial", "claim", "trial", "activate", "validate"])
        for call in h.http.calls {
            #expect(JSONText.text(call.body).contains(Purchase.token) == (call.action == "claim"), "\(call.action)")
        }
    }

    @Test func sendsTheSecretNeitherInAValidateNorInADeactivateWhenAKeyIsStoredBesideIt() async throws {
        // A link's save is unbased: it can land beside a key another process activated meanwhile.
        let h = try Harness()
        let lease = h.signer.lease(sub: "KEY-1")
        h.storage.set(Purchase.held {
            $0.key = "KEY-1"
            $0.activationId = "act_1"
            $0.lease = lease
            $0.lastSeen = NOW
        })
        h.http.on("validate", status: 200, json: ["lease": .string(lease)])
        h.http.on("deactivate", status: 200, json: [:])
        #expect(await h.license.refresh() == LicenseStatus(state: .licensed, key: "KEY-1"))
        try await h.license.deactivate()
        #expect(h.http.actions == ["validate", "deactivate"])
        for call in h.http.calls { #expect(!JSONText.text(call.body).contains(Purchase.token), "\(call.action)") }
    }

    @Test func savesTheKindOfTheFingerprintABoughtKeyWasClaimedUnder() async throws {
        let machine = IdentifyingFingerprinter { DeviceIdentity(fingerprint: "fp-machine", kind: .machine) }
        let h = try Harness(Purchase.held(), fingerprinter: machine)
        h.http.on("claim") { _ in Purchase.bought(h) }
        #expect(await h.license.status() == LicenseStatus(state: .licensed, key: Purchase.boughtKey))
        #expect(h.stored?.deviceKind == .machine)
    }

    @Test func savesADropPastTheBoundAboutItsSecretSoOneAnotherProcessMadeMeanwhileStays() async throws {
        let h = try Harness(Purchase.held(Waits.purchaseTokenMs))
        let another = String(repeating: "B", count: 43)
        // The status reads the expired secret; another process saves a new one before the drop lands.
        h.storage.saveBeforeRead(2, StoredState(purchaseToken: another, purchaseTokenAt: NOW))
        #expect(await h.license.status() == LicenseStatus(state: .unlicensed))
        #expect(!h.http.called("claim"))
        #expect(h.stored?.purchaseToken == another && h.stored?.purchaseTokenAt == NOW)
    }

    @Test func dropsASpentSecretEvenWhenItsLinkWasHandedOutAgainMeanwhile() async throws {
        let h = try Harness(Purchase.held(HOUR))
        h.http.on("claim") { _ in
            // The same secret's link handed out again while the claim was out: a drop still lands.
            h.storage.set(Purchase.held(-1000))
            return LicenseHTTPResponse(status: 409, json: ["error": "spent"])
        }
        _ = await h.license.status()
        #expect(Purchase.noPurchaseFields(h.stored))
    }

    @Test(arguments: [LicenseHTTPResponse?.none, LicenseHTTPResponse(status: 409, json: ["error": "spent"])])
    func answersWhenTheDiskRefusesAWaitOrADrop(answer: LicenseHTTPResponse?) async throws {
        let h = try Harness(Purchase.held())
        if let answer { h.http.on("claim") { _ in answer } } else { h.http.setFail(true) }
        h.storage.failWrites()
        #expect(await h.license.status() == LicenseStatus(state: .unlicensed))
        #expect(h.http.count("claim") == 1 && h.stored == Purchase.held())
    }
}
