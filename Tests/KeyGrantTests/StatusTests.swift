import Foundation
import Testing

@testable import KeyGrant

@Suite("status, offline first", suiteTimeLimit)
struct StatusTests {
    @Test func isUnlicensedWithNoState() async throws {
        let h = try Harness()
        #expect(await h.license.status() == LicenseStatus(state: .unlicensed))
        #expect(h.http.calls.isEmpty)
    }

    @Test func isLicensedFromAValidLeaseWithoutAskingTheServer() async throws {
        let h = try Harness(StoredState(key: KEY, activationId: "act_1", lastSeen: NOW))
        h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: h.sign(), lastSeen: NOW))
        #expect(await h.license.status() == LicenseStatus(state: .licensed, key: KEY))
        #expect(h.http.calls.isEmpty)
    }

    /// A harness holding a lease that ran out two days ago.
    func expiredLease() throws -> Harness {
        let h = try Harness()
        h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: h.sign(ttl: 3600, at: NOW - 2 * DAY), lastSeen: NOW))
        return h
    }

    @Test func healsAnExpiredLeaseOnline() async throws {
        let h = try expiredLease()
        let fresh = h.sign()
        h.http.on("validate", status: 200, json: ["lease": .string(fresh), "activationId": "act_1"])
        #expect(await h.license.status() == LicenseStatus(state: .licensed, key: KEY))
        #expect(h.stored?.lease == fresh)
        #expect(h.stored?.checkedMajor == 1)
        #expect(h.stored?.verdictAt == NOW)
    }

    @Test func staysExpiredOfflineWhenAnExpiredLeaseCannotBeRenewed() async throws {
        let h = try expiredLease()
        h.http.setFail(true)
        #expect(await h.license.status() == LicenseStatus(state: .expired, reason: .offline, key: KEY))
        #expect(h.stored?.backoffSince == NOW && h.stored?.backoffMs == Waits.retryUnansweredMs)
    }

    @Test(arguments: ["revoked", "expired", "deactivated"])
    func locksOutWhenTheRenewalSaysSoDefinitively(word: String) async throws {
        let h = try expiredLease()
        h.http.on("validate", status: 403, json: ["error": .string(word)])
        #expect(await h.license.status() == LicenseStatus(state: .invalid, reason: .revoked, key: KEY))
        #expect(h.stored?.refused == .revoked)
        #expect(h.stored?.lease == nil)
    }

    @Test(arguments: [("upgrade-required", LicenseReason.upgrade), ("update-required", .outdated)])
    func reportsABuildRefusalFromTheRenewal(word: String, reason: LicenseReason) async throws {
        let h = try expiredLease()
        h.http.on("validate", status: 403, json: ["error": .string(word)])
        #expect(await h.license.status() == LicenseStatus(state: .invalid, reason: reason, key: KEY))
        #expect(h.stored?.lease != nil)
        #expect(h.stored?.refusedMajor == 1)
    }

    /// Never a lockout: an answer the SDK cannot use, a 5xx, a 429, a 4xx it does not know, no answer.
    @Test(arguments: [
        LicenseHTTPResponse(status: 200, json: ["lease": "garbage.lease.value"]),
        LicenseHTTPResponse(status: 200, json: [:]),
        LicenseHTTPResponse(status: 200, json: nil),
        LicenseHTTPResponse(status: 503, json: ["error": "unavailable"]),
        LicenseHTTPResponse(status: 500, json: ["error": "revoked"]),
        LicenseHTTPResponse(status: 429, json: ["error": "rate-limited"]),
        LicenseHTTPResponse(status: 404, json: ["error": "unknown-product"]),
        LicenseHTTPResponse(status: 400, json: ["error": "limit"]),
        LicenseHTTPResponse(status: 401, json: nil),
    ])
    func neverLocksOutOnAnAmbiguousAnswer(response: LicenseHTTPResponse) async throws {
        // An expired lease stays expired/offline (not revoked) ...
        let expired = try expiredLease()
        expired.http.on("validate") { _ in response }
        #expect(await expired.license.status() == LicenseStatus(state: .expired, reason: .offline, key: KEY))
        #expect(expired.stored?.refused == nil)
        // ... and a valid lease stays licensed, through a forced renewal.
        let valid = try Harness()
        let lease = valid.sign()
        valid.storage.set(StoredState(key: KEY, activationId: "act_1", lease: lease, lastSeen: NOW))
        valid.http.on("validate") { _ in response }
        #expect(await valid.license.refresh() == LicenseStatus(state: .licensed, key: KEY))
        #expect(valid.stored?.lease == lease)
        #expect(valid.stored?.refused == nil)
    }

    @Test func keepsALicenseThroughARefreshThatCannotReachTheServer() async throws {
        let h = try Harness()
        h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: h.sign(), lastSeen: NOW))
        h.http.setFail(true)
        #expect(await h.license.refresh() == LicenseStatus(state: .licensed, key: KEY))
        #expect(h.http.count("validate") == 1)
    }

    @Test func refreshRenewsAStillValidLease() async throws {
        let h = try Harness()
        h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: h.sign(), lastSeen: NOW))
        let fresh = h.sign(at: NOW + 1000)
        h.http.on("validate", status: 200, json: ["lease": .string(fresh), "activationId": "act_1"])
        #expect(await h.license.refresh() == LicenseStatus(state: .licensed, key: KEY))
        #expect(h.stored?.lease == fresh)
    }

    @Test func keepsARenewedLeaseThatCoversALowerMajorAndReportsUpgrade() async throws {
        let h = try Harness(major: 2)
        h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: h.sign(ttl: 3600, at: NOW - 2 * DAY), lastSeen: NOW))
        let majorOne = h.sign()
        h.http.on("validate", status: 200, json: ["lease": .string(majorOne), "activationId": "act_1"])
        #expect(await h.license.status() == LicenseStatus(state: .invalid, reason: .upgrade, key: KEY))
        #expect(h.stored?.lease == majorOne)
    }

    @Test func reportsTamperedForALeaseNotSignedByTheProductKeyAndLetsTheServerHealIt() async throws {
        let h = try Harness()
        h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: Signer().lease(), lastSeen: NOW))
        h.http.setFail(true)
        // Not a lease for this licence at all: no key in the answer.
        #expect(await h.license.status() == LicenseStatus(state: .invalid, reason: .tampered))
        h.http.setFail(false)
        let fresh = h.sign()
        h.http.on("validate", status: 200, json: ["lease": .string(fresh), "activationId": "act_1"])
        #expect(await h.license.refresh() == LicenseStatus(state: .licensed, key: KEY))
        #expect(h.stored?.lease == fresh)
    }

    @Test func rejectsAValidlySignedLeaseForAnotherProduct() async throws {
        let h = try Harness()
        h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: h.signer.lease(product: "other-app"), lastSeen: NOW))
        h.http.setFail(true)
        #expect(await h.license.status() == LicenseStatus(state: .invalid, reason: .tampered))
    }

    @Test func reportsUpgradeOfflineWhenTheBuildIsNewerThanTheLeaseCovers() async throws {
        let h = try Harness(major: 2)
        h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: h.sign(), lastSeen: NOW))
        h.http.setFail(true)
        #expect(await h.license.status() == LicenseStatus(state: .invalid, reason: .upgrade, key: KEY))
    }

    @Test func ignoresAClockPutBackSoAnExpiredLeaseStaysExpired() async throws {
        let h = try Harness()
        h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: h.sign(ttl: 3600, at: NOW - 2 * DAY), lastSeen: NOW + 10 * DAY))
        h.clock.set(NOW - 5 * DAY)
        h.http.setFail(true)
        #expect(await h.license.status() == LicenseStatus(state: .expired, reason: .offline, key: KEY))
    }

    @Test func treatsAnEmptyKeyOrLeaseAsNone() async throws {
        let h = try Harness()
        let trial = h.signer.trialLease(device: "fp-test", ttlSeconds: 24 * 3600)
        // Synced within the day, so no launch report is due either.
        h.storage.set(StoredState(
            key: "", activationId: "act_1", lease: "", trialStart: NOW - DAY, trialEndsAt: NOW + DAY, trialLease: trial, trialAt: NOW - DAY / 2
        ))
        #expect(await h.license.status() == LicenseStatus(state: .trial, trialDaysLeft: 1, trialEndsAt: NOW + DAY))
        await h.license.launchReportSettled()
        #expect(h.http.calls.isEmpty)
    }
}

@Suite("the default adapters", suiteTimeLimit)
struct DefaultAdapterTests {
    @Test func buildsWithNoAdapterGivenAndReadsUnlicensedForAFreshProduct() async throws {
        // A product of its own, so no state of it exists in this user's folder; nothing is written.
        let product = "covtest-unlicensed-\(UInt64.random(in: 0...UInt64.max))"
        let license = try License(LicenseConfig(product: product, apiBaseURL: apiBase, publicJWK: Signer().publicJWK))
        #expect(await license.status() == LicenseStatus(state: .unlicensed))
        #expect(!FileManager.default.fileExists(atPath: FileStorage.defaultPath(product: product)))
    }

    @Test func theSystemClockReadsMillisecondsAndTheDefaultStashKeepsNothing() async throws {
        let before = Int(Date().timeIntervalSince1970 * 1000)
        let now = SystemClock().now()
        #expect(abs(now - before) < 5_000)
        let stash = NoRegistryStash()
        try await stash.writeTrialStart(123)
        #expect(try await stash.readTrialStart() == nil)
    }
}

@Suite("a key for a range of versions", suiteTimeLimit)
struct VersionRangeTests {
    @Test func reportsOutdatedOfflineForABuildOlderThanTheKeyCovers() async throws {
        let h = try Harness(major: 1)
        h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: h.signer.lease(major: 3, minMajor: 2), lastSeen: NOW))
        h.http.setFail(true)
        #expect(await h.license.status() == LicenseStatus(state: .invalid, reason: .outdated, key: KEY))
    }

    @Test(arguments: [2, 3])
    func licensesEveryBuildInsideTheRange(major: Int) async throws {
        let h = try Harness(major: major)
        h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: h.signer.lease(major: 3, minMajor: 2), lastSeen: NOW))
        #expect(await h.license.status().state == .licensed)
    }

    @Test func runsAnyLaterBuildOnAnOpenEndedKey() async throws {
        let h = try Harness(major: 41)
        h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: h.signer.lease(major: openMajor, minMajor: 2), lastSeen: NOW, checkedMajor: 41))
        #expect(await h.license.status().state == .licensed)
    }

    @Test func keepsARenewedLeaseThatStartsAboveThisBuildAndReportsOutdated() async throws {
        let h = try Harness(major: 1)
        h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: h.sign(ttl: 3600, at: NOW - 2 * DAY), lastSeen: NOW))
        let fresh = h.signer.lease(major: 2, minMajor: 2)
        h.http.on("validate", status: 200, json: ["lease": .string(fresh), "activationId": "act_1"])
        #expect(await h.license.status() == LicenseStatus(state: .invalid, reason: .outdated, key: KEY))
        #expect(h.stored?.lease == fresh)
    }
}

@Suite("upgradeURL", suiteTimeLimit)
struct UpgradeURLTests {
    @Test func namesThisDevicesActivationOnAPaymentLink() async throws {
        let h = try Harness(StoredState(key: KEY, activationId: "act_device1"))
        let url = await h.license.upgradeURL(paymentLink: try #require(URL(string: "https://buy.stripe.com/test_abc")))
        #expect(url?.absoluteString == "https://buy.stripe.com/test_abc?client_reference_id=act_device1")
        #expect(h.http.calls.isEmpty)
    }

    @Test func neverPutsTheKeyInTheURLAndReplacesAClientReferenceAlreadyOnIt() async throws {
        let h = try Harness(StoredState(key: KEY, activationId: "act_1"))
        let link = try #require(URL(string: "https://buy.stripe.com/x?prefilled_email=jo%40example.com&client_reference_id=old&client_reference_id=older#top"))
        let url = try #require(await h.license.upgradeURL(paymentLink: link))
        #expect(url.absoluteString.range(of: "SLUICE") == nil)
        #expect(url.absoluteString == "https://buy.stripe.com/x?prefilled_email=jo%40example.com&client_reference_id=act_1#top")
    }

    @Test(arguments: [
        ("https://buy.test/u", "https://buy.test/u?client_reference_id=act_1"),
        ("https://buy.test/u#pay", "https://buy.test/u?client_reference_id=act_1#pay"),
        ("https://buy.test/u?", "https://buy.test/u?client_reference_id=act_1"),
        ("https://buy.test/u?a=1&&b=x%20y+z", "https://buy.test/u?a=1&b=x%20y+z&client_reference_id=act_1"),
        // One link rule with `purchaseURL` (`referencedLink`): only a name that is exactly
        // client_reference_id as written is replaced, and the reference always goes last.
        ("https://buy.test/u?client%5Freference%5Fid=old&a=1", "https://buy.test/u?client%5Freference%5Fid=old&a=1&client_reference_id=act_1"),
        ("https://buy.test/u?client_reference_id=old&a=1", "https://buy.test/u?a=1&client_reference_id=act_1"),
        ("https://buy.test/u?flag&client_reference_id", "https://buy.test/u?flag&client_reference_id=act_1"),
    ])
    func setsTheReferenceOnALinkOfAnyShape(link: String, expected: String) async throws {
        let h = try Harness(StoredState(key: KEY, activationId: "act_1"))
        #expect(await h.license.upgradeURL(paymentLink: try #require(URL(string: link)))?.absoluteString == expected)
    }

    @Test(arguments: ["/buy", "buy.stripe.com/test_abc"])
    func isNilForALinkThatIsNotAnAbsoluteURL(link: String) async throws {
        let h = try Harness(StoredState(key: KEY, activationId: "act_1"))
        #expect(await h.license.upgradeURL(paymentLink: try #require(URL(string: link))) == nil)
    }

    @Test func encodesAnActivationIdThatIsNotPlainText() async throws {
        let h = try Harness(StoredState(key: KEY, activationId: "act 1&x=é"))
        let url = await h.license.upgradeURL(paymentLink: try #require(URL(string: "https://buy.test/u")))
        #expect(url?.absoluteString == "https://buy.test/u?client_reference_id=act%201%26x%3D%C3%A9")
    }

    @Test func makesTheLinkFromAStateKeptElsewhereBeforeWithoutCopyingIt() async throws {
        let legacy = "/memory/legacy/sluice.json"
        let fs = MemoryFileSystem([legacy: saved])
        let license = try License(LicenseConfig(
            product: PRODUCT, apiBaseURL: apiBase, publicJWK: Signer().publicJWK,
            adapters: LicenseAdapters(storage: storage(fs, migrateFrom: legacy), http: FakeHTTP())
        ))
        let url = await license.upgradeURL(paymentLink: try #require(URL(string: "https://buy.test/upgrade")))
        #expect(url?.absoluteString == "https://buy.test/upgrade?client_reference_id=act_1")
        #expect(fs.changes.isEmpty)
    }

    @Test(arguments: [StoredState(trialStart: NOW), StoredState(key: "KEY-1"), StoredState(key: "", activationId: "act_1"), StoredState()])
    func isNilOnADeviceHoldingNoActivatedLicence(state: StoredState) async throws {
        let h = try Harness(state)
        #expect(await h.license.upgradeURL(paymentLink: try #require(URL(string: "https://buy.stripe.com/test_abc"))) == nil)
    }

    @Test func isNilWhenTheStateCannotBeReadAndWritesNothing() async throws {
        let fs = MemoryFileSystem(["/state/sluice.json": #"{"key":"K","activationId":"act_1"}"#])
        fs.failAlways(.readFile, "EBUSY")
        let storage = FileStorage(path: "/state/sluice.json", fs: fs, migrateFrom: nil, sleep: NoSleep().sleep)
        let h = try Harness()
        let license = try License(
            LicenseConfig(product: PRODUCT, apiBaseURL: apiBase, publicJWK: h.signer.publicJWK, adapters: LicenseAdapters(storage: storage, http: h.http)),
            timing: quick
        )
        #expect(await license.upgradeURL(paymentLink: try #require(URL(string: "https://buy.test/u"))) == nil)
        #expect(fs.changes.isEmpty)
    }
}

@Suite("deactivate", suiteTimeLimit)
struct DeactivateTests {
    @Test func releasesTheActivationAndClearsAllButTheTrialEvidenceAndTheClockGuard() async throws {
        let h = try Harness()
        h.storage.set(StoredState(
            key: KEY, activationId: "act_1", lease: h.sign(), trialStart: NOW - 9 * DAY, trialEndsAt: NOW - 2 * DAY, trialLease: "T",
            trialAt: NOW - 9 * DAY, lastSeen: NOW + 1000, checkedMajor: 1, keptMajor: 1, backoffSince: NOW, backoffMs: 60_000,
            refused: .device, refusedFor: ["c"], deviceKind: .machine, verdictAt: NOW - DAY
        ))
        h.http.on("deactivate", status: 200, json: ["ok": true])
        // A 200: KeyGrant says the seat is free.
        #expect(try await h.license.deactivate() == DeactivateResult(released: true))
        #expect(h.http.body("deactivate") == ["key": .string(KEY), "activationId": "act_1"])
        let expected = StoredState(
            trialStart: NOW - 9 * DAY, trialEndsAt: NOW - 2 * DAY, trialLease: "T", trialAt: NOW - 9 * DAY, lastSeen: NOW + 1000,
            verdictAt: NOW + 1000
        )
        #expect(h.stored == expected)
        #expect(await h.license.status() == LicenseStatus(state: .expired, reason: .trial))
    }

    @Test func clearsTheLocalLicenceEvenWhenTheServerIsUnreachableAndSaysTheSeatMayStillBeHeld() async throws {
        let h = try Harness()
        h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: h.sign(), lastSeen: NOW))
        h.http.setFail(true)
        #expect(try await h.license.deactivate() == DeactivateResult(released: false))
        #expect(h.http.called("deactivate"))
        #expect(h.stored?.key == nil)
        #expect(await h.license.status() == LicenseStatus(state: .unlicensed))
    }

    @Test(arguments: [
        LicenseHTTPResponse(status: 503, json: ["error": "unavailable"]),
        LicenseHTTPResponse(status: 500, json: nil),
        LicenseHTTPResponse(status: 429, json: ["error": "rate-limited"]),
        // A proxy's page: an answer, but not KeyGrant's.
        LicenseHTTPResponse(status: 403, json: nil),
        LicenseHTTPResponse(status: 404, json: ["error": "not-found"]),
        LicenseHTTPResponse(status: 201, json: ["ok": true]),
    ])
    func saysTheSeatMayStillBeHeldWhenTheAnswerIsAnythingButA200(answer: LicenseHTTPResponse) async throws {
        let h = try Harness()
        h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: h.sign(), lastSeen: NOW))
        h.http.on("deactivate") { _ in answer }
        #expect(try await h.license.deactivate() == DeactivateResult(released: false))
        // The local licence is dropped either way.
        #expect(h.stored?.key == nil && h.stored?.lease == nil)
    }

    @Test(arguments: [StoredState(), StoredState(key: KEY, lease: "L"), StoredState(activationId: "act_1"), StoredState(key: "", activationId: "act_1")])
    func saysTheSeatIsFreeWhenNoKeyAndActivationWereHeldAskingNothing(held: StoredState) async throws {
        let h = try Harness(held)
        h.http.setFail(true)
        #expect(try await h.license.deactivate() == DeactivateResult(released: true))
        #expect(!h.http.called("deactivate"))
        #expect(h.stored?.key == nil && h.stored?.activationId == nil)
    }

    @Test func asksNothingWhenThereIsNoActivationToRelease() async throws {
        let h = try Harness()
        try await h.license.deactivate()
        #expect(!h.http.called("deactivate"))
        #expect(await h.license.status() == LicenseStatus(state: .unlicensed))
    }

    @Test func throwsWhenTheStateCannotBeSavedAndKeepsTheKeyToTryAgain() async throws {
        let h = try Harness()
        let lease = h.sign()
        h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: lease, lastSeen: NOW, checkedMajor: 1))
        h.http.on("deactivate", status: 200, json: ["ok": true])
        h.storage.failWrites()
        await #expect(throws: StorageError.self) { try await h.license.deactivate() }
        #expect(h.stored?.key == KEY && h.stored?.lease == lease)
    }

    @Test func stampsAnActivationAndADeactivationWithTheirTime() async throws {
        let h = try Harness()
        h.http.on("activate", status: 200, json: ["lease": .string(h.sign()), "activationId": "act_1"])
        h.http.on("deactivate", status: 200, json: ["ok": true])
        _ = await h.license.activate(KEY)
        #expect(h.stored?.verdictAt == NOW)
        h.clock.set(NOW + DAY)
        try await h.license.deactivate()
        #expect(h.stored?.verdictAt == NOW + DAY)
    }
}
