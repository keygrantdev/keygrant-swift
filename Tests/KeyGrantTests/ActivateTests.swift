import Foundation
import Testing

@testable import KeyGrant

@Suite("activate", suiteTimeLimit)
struct ActivateTests {
    /// A harness whose server activates any key with `lease` as `act_1`.
    func activating(_ h: Harness, lease: String? = nil) {
        let lease = lease ?? h.sign()
        h.http.on("activate", status: 200, json: ["lease": .string(lease), "activationId": "act_1"])
    }

    @Test func storesAVerifiedLeaseAndReportsLicensed() async throws {
        let h = try Harness()
        activating(h)
        #expect(await h.license.activate(KEY) == .activated)
        #expect(h.stored?.key == KEY)
        #expect(h.stored?.activationId == "act_1")
        #expect(h.stored?.checkedMajor == 1)
        let status = await h.license.status()
        #expect(status == LicenseStatus(state: .licensed, key: KEY))
        // Offline-first: no ask for a valid lease.
        #expect(h.http.actions == ["activate"])
    }

    @Test func sendsWhatTheContractSays() async throws {
        let h = try Harness(major: 3, deviceName: "Rae’s MacBook")
        h.http.on("activate", status: 200, json: ["lease": .string(h.signer.lease(major: 3)), "activationId": "act_1"])
        #expect(await h.license.activate(KEY) == .activated)
        let body = try #require(h.http.body("activate"))
        #expect(body == ["key": .string(KEY), "fingerprint": "fp-test", "name": "Rae’s MacBook", "major": 3, "kids": [.string(h.signer.kid)]])
    }

    @Test func refusesAKeyLongerThanTheServerHoldsCountingUTF16Units() async throws {
        let h = try Harness()
        activating(h)
        // 120 characters, but 121 UTF-16 units: the emoji is two.
        let long = String(repeating: "K", count: 119) + "😀"
        #expect(long.count == 120 && long.utf16.count == 121)
        #expect(await h.license.activate(long) == .failed(.invalidKey))
        #expect(!h.http.called("activate"))
        // 120 units is a key it may hold (the lease is for another one: it is asked, then refused).
        #expect(await h.license.activate(String(repeating: "K", count: 120)) == .failed(.invalidLease))
        #expect(h.http.called("activate"))
    }

    @Test func cutsADeviceNameTheServerWouldRefuse() async throws {
        let h = try Harness(deviceName: String(repeating: "D", count: 500))
        activating(h)
        _ = await h.license.activate(KEY)
        #expect(h.http.body("activate")?["name"]?.stringValue?.utf16.count == 120)
    }

    @Test func doesNotCutACharacterInHalf() async throws {
        let h = try Harness(deviceName: String(repeating: "D", count: 119) + "😀")
        activating(h)
        _ = await h.license.activate(KEY)
        #expect(h.http.body("activate")?["name"]?.stringValue == String(repeating: "D", count: 119))
    }

    @Test func leavesANameOfExactlyTheLimitAlone() async throws {
        let h = try Harness(deviceName: String(repeating: "D", count: 120))
        activating(h)
        _ = await h.license.activate(KEY)
        #expect(h.http.body("activate")?["name"]?.stringValue?.count == 120)
    }

    @Test func refusesAKeyLongerThanOneCouldBeWithoutAsking() async throws {
        let h = try Harness()
        #expect(await h.license.activate(String(repeating: "S", count: 200)) == .failed(.invalidKey))
        #expect(!h.http.called("activate"))
    }

    @Test func refusesAnEmptyKeyWithoutAsking() async throws {
        let h = try Harness()
        #expect(await h.license.activate("   ") == .failed(.invalidKey))
        #expect(!h.http.called("activate"))
    }

    @Test func sendsAKeyOfExactlyTheLimit() async throws {
        let key = "SLUICE-" + String(repeating: "A", count: 113)
        let h = try Harness()
        activating(h, lease: h.sign(key))
        #expect(await h.license.activate(key) == .activated)
        #expect(h.http.body("activate")?["key"]?.stringValue == key)
        // Pasted with a newline after it: the whitespace does not count towards its length.
        let pasted = try Harness()
        activating(pasted, lease: pasted.sign(key))
        #expect(await pasted.license.activate(key + "\n") == .activated)
    }

    @Test(arguments: ["  SLUICE-AAAA-BBBB-CCCC-DDDD\n", "sluice-aaaa-bbbb-cccc-dddd", "\u{FEFF}SLUICE-AAAA-BBBB-CCCC-DDDD\u{00A0}"])
    func normalisesTheKeyItSendsAndStores(entered: String) async throws {
        let h = try Harness()
        activating(h)
        #expect(await h.license.activate(entered) == .activated)
        #expect(h.http.body("activate")?["key"]?.stringValue == KEY)
        // And the STORED key is the normalised one, so the deactivate that follows names a key the server can find.
        #expect(h.stored?.key == KEY)
    }

    @Test(arguments: [
        (404, "invalid-key", LicenseError.invalidKey),
        (409, "limit", .limit),
        (403, "revoked", .revoked),
        (403, "expired", .revoked),
        (403, "upgrade-required", .upgrade),
        (403, "update-required", .outdated),
        (403, "device", .network),
        (400, "weird", .network),
        (500, "boom", .network),
    ])
    func mapsTheServersError(status: Int, word: String, error: LicenseError) async throws {
        let h = try Harness()
        h.http.on("activate", status: status, json: ["error": .string(word)])
        #expect(await h.license.activate(KEY) == .failed(error))
        #expect(h.stored == nil)
    }

    @Test func isNetworkOnATransportFailure() async throws {
        let h = try Harness()
        h.http.setFail(true)
        #expect(await h.license.activate(KEY) == .failed(.network))
    }

    @Test(arguments: [["activationId": "act_1"], ["lease": "a.b.c"], ["lease": "", "activationId": "act_1"], "not an object"] as [LicenseJSON])
    func isNetworkWhenTheServerAnswers200WithoutALeaseAndActivation(body: LicenseJSON) async throws {
        let h = try Harness()
        h.http.on("activate", status: 200, json: body)
        #expect(await h.license.activate(KEY) == .failed(.network))
    }

    @Test func isInvalidLeaseWhenTheServersLeaseFailsOfflineVerification() async throws {
        let h = try Harness()
        h.http.on("activate", status: 200, json: ["lease": "not.a.jwt", "activationId": "act_1"])
        #expect(await h.license.activate(KEY) == .failed(.invalidLease))
        // Signed by another key: the embedded key is not the product's.
        let other = Signer()
        h.http.on("activate", status: 200, json: ["lease": .string(other.lease()), "activationId": "act_1"])
        #expect(await h.license.activate(KEY) == .failed(.invalidLease))
        #expect(h.stored == nil)
    }

    @Test func acceptsTheLeaseForThisDeviceAndRefusesOneForAnother() async throws {
        let h = try Harness()
        activating(h, lease: h.signer.lease(fp: fingerprintClaim("fp-test"), fpk: .machine))
        #expect(await h.license.activate(KEY) == .activated)
        h.http.setFail(true)
        #expect(await h.license.status() == LicenseStatus(state: .licensed, key: KEY))

        let other = try Harness()
        activating(other, lease: other.signer.lease(fp: fingerprintClaim("fp-another-machine"), fpk: .machine))
        #expect(await other.license.activate(KEY) == .failed(.invalidLease))
    }

    @Test func answersStorageWhenTheStateCannotBeSaved() async throws {
        // The reference rejects; this SDK answers `.storage`, which the app can say and retry.
        let h = try Harness()
        activating(h)
        h.storage.failWrites()
        #expect(await h.license.activate(KEY) == .failed(.storage))
        #expect(h.stored == nil)
    }

    @Test func startsAKeysNotesAfreshAndClearsARefusal() async throws {
        let h = try Harness(
            StoredState(key: "OLD-KEY", activationId: "act_old", checkedMajor: 7, keptMajor: 7, backoffSince: NOW, backoffMs: 60_000, refused: .revoked),
            major: 2
        )
        let window = (NOW + 10 * DAY) / 1000
        activating(h, lease: h.signer.lease(major: openMajor, upgradeUntil: window))
        #expect(await h.license.activate(KEY) == .activated)
        let stored = try #require(h.stored)
        #expect(stored.key == KEY && stored.checkedMajor == 2 && stored.keptMajor == 2)
        #expect(stored.refused == nil && stored.backoffSince == nil && stored.backoffMs == nil)
    }
}

@Suite("test licences", suiteTimeLimit)
struct TestLicenceTests {
    let key = "SLUICE-TEST-TEST-TEST-TEST"

    @Test func licenseTheAppAndSaySoSoAReleaseBuildCanRefuseThem() async throws {
        let h = try Harness()
        h.http.on("activate", status: 200, json: ["lease": .string(h.signer.lease(sub: key, test: true)), "activationId": "act_1"])
        #expect(await h.license.activate(key) == .activated)
        #expect(await h.license.status() == LicenseStatus(state: .licensed, key: key, isTest: true))
    }

    @Test func sayNothingAboutItOnARealLicence() async throws {
        let h = try Harness()
        h.http.on("activate", status: 200, json: ["lease": .string(h.signer.lease(sub: key)), "activationId": "act_1"])
        _ = await h.license.activate(key)
        #expect(await h.license.status() == LicenseStatus(state: .licensed, key: key))
    }

    @Test func keepSayingSoAfterARenewalAndWhenARefreshCannotReachTheServer() async throws {
        let h = try Harness()
        h.http.on("activate", status: 200, json: ["lease": .string(h.signer.lease(sub: key, test: true, ttlSeconds: 60)), "activationId": "act_1"])
        _ = await h.license.activate(key)
        // From an EXPIRED lease, so the status can only come from the renewed one.
        let later = NOW + 2 * HOUR
        h.clock.set(later)
        h.http.on("validate", status: 200, json: ["lease": .string(h.signer.lease(sub: key, test: true, at: later))])
        #expect(await h.license.status() == LicenseStatus(state: .licensed, key: key, isTest: true))
        #expect(h.http.called("validate"))
        h.http.setFail(true)
        #expect(await h.license.refresh() == LicenseStatus(state: .licensed, key: key, isTest: true))
        #expect(h.http.actions == ["activate", "validate", "validate"])
    }
}

@Suite("the endpoints", suiteTimeLimit)
struct EndpointTests {
    /// Where each call was posted, the harness's API base ending in a slash (`https://api.test/`).
    @Test func postsEveryCallToTheProductsEndpointUnderTheAPIBaseWithOneSlash() async throws {
        let h = try Harness()
        h.http.setFail(true)
        _ = await h.license.activate(KEY)
        _ = await h.license.startTrial()
        h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: h.sign(ttl: 3600, at: NOW - 2 * DAY), lastSeen: NOW))
        _ = await h.license.refresh()
        try await h.license.deactivate()
        let urls = h.http.calls.map(\.url.absoluteString)
        #expect(urls == [
            "https://api.test/v1/products/sluice/activate",
            "https://api.test/v1/products/sluice/trial",
            "https://api.test/v1/products/sluice/validate",
            "https://api.test/v1/products/sluice/deactivate",
        ])
    }

    @Test(arguments: [
        ("https://api.test", "sluice", "https://api.test/v1/products/sluice/activate"),
        ("https://api.test/keygrant/", "sluice", "https://api.test/keygrant/v1/products/sluice/activate"),
        // The product is one path segment, whatever it holds.
        ("https://api.test", "slu ice/β?#%", "https://api.test/v1/products/slu%20ice%2F%CE%B2%3F%23%25/activate"),
    ])
    func keepsTheProductOnePathSegment(base: String, product: String, expected: String) async throws {
        let signer = Signer()
        let http = FakeHTTP()
        http.setFail(true)
        let license = try License(
            LicenseConfig(
                product: product, apiBaseURL: try #require(URL(string: base)), publicJWK: signer.publicJWK,
                adapters: LicenseAdapters(storage: MemoryStorage(), registry: MemoryRegistry(), clock: FakeClock(), fingerprinter: GetFingerprinter(), http: http)
            )
        )
        #expect(await license.activate(KEY) == .failed(.network))
        #expect(http.url("activate")?.absoluteString == expected)
    }
}
