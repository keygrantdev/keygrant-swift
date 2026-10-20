import Foundation
import Testing

@testable import KeyGrant

/// Key pickup: what `pickUp(email:)` and `pickUp(email:code:)` send and answer, and the key
/// `restoreByEmail(email:code:)` activates. The rules each piece follows are held to the conformance
/// vectors (`pickupAsks`, `pickupRefusals`, `pickedKeys`, `pickupChoices`); these are the calls
/// around them.
@Suite("key pickup", suiteTimeLimit)
struct PickupTests {
    static let address = "Mara@Studio.example"
    static let month = 30 * 24 * 3600

    /// A key as a confirm's answer gives it, with what a test leaves out filled in.
    func picked(
        _ key: String = KEY, minMajor: Int = 1, maxMajor: Int? = 1, activeDevices: Int = 0, held: Bool = false,
        activationCode: String? = nil
    ) -> LicenseJSON {
        var members: [String: LicenseJSON] = [
            "key": .string(key), "model": "perpetual", "modelName": "Single", "state": "active",
            "versions": .object([
                "minMajor": .number(Double(minMajor)), "maxMajor": maxMajor.map { .number(Double($0)) } ?? .null,
                "upgradeUntil": .null,
            ]),
            "deviceLimit": 1, "activeDevices": .number(Double(activeDevices)), "held": .bool(held),
        ]
        if let activationCode { members["activationCode"] = .string(activationCode) }
        return .object(members)
    }

    func confirming(_ keys: [LicenseJSON], _ h: Harness? = nil) throws -> Harness {
        let h = try h ?? Harness()
        h.http.on("confirm", status: 200, json: ["keys": .array(keys)])
        return h
    }

    func activating(_ h: Harness) {
        h.http.on("activate", status: 200, json: ["lease": .string(h.sign()), "activationId": "act_1"])
    }

    // MARK: - pickUp(email:)

    @Test func asksForACodeWithTheAddressTrimmedAndAnswersSent() async throws {
        let h = try Harness()
        h.http.on("pickup", status: 200, json: ["ok": true])
        #expect(await h.license.pickUp(email: "  Mara@Studio.example\n") == .sent)
        #expect(h.http.body("pickup") == ["email": "Mara@Studio.example"])
        #expect(h.http.url("pickup")?.path.hasSuffix("/v1/products/sluice/pickup") == true)
    }

    @Test func refusesABlankAddressBeforeItAsksAndAnswersEachRefusalAsItsError() async throws {
        let h = try Harness()
        #expect(await h.license.pickUp(email: "   ") == .failed(PickupRefusal(error: .invalidEmail)))
        let long = String(repeating: "a", count: 254) + "@b.example"
        #expect(await h.license.pickUp(email: long) == .failed(PickupRefusal(error: .invalidEmail)))
        #expect(h.http.count("pickup") == 0)

        h.http.on("pickup", status: 403, json: ["error": "pickup-disabled"])
        #expect(await h.license.pickUp(email: Self.address) == .failed(PickupRefusal(error: .pickupDisabled)))
        h.http.on("pickup", status: 429, json: ["error": "rate-limited", "retryAfter": 120])
        #expect(await h.license.pickUp(email: Self.address) == .failed(PickupRefusal(error: .tooManyAttempts, retryAfter: 120)))
        h.http.setFail(true)
        #expect(await h.license.pickUp(email: Self.address) == .failed(PickupRefusal(error: .network)))
    }

    @Test func readsTheWaitFromTheBodyAndTheWordDecidesNeverTheStatus() async throws {
        let h = try Harness()
        h.http.on("pickup", status: 503, json: ["error": "unavailable", "retryAfter": 60])
        #expect(await h.license.pickUp(email: Self.address) == .failed(PickupRefusal(error: .tryAgain, retryAfter: 60)))
        h.http.on("pickup", status: 502, json: ["error": "wrong-code"])
        #expect(await h.license.pickUp(email: Self.address) == .failed(PickupRefusal(error: .wrongCode)))
        h.http.on("pickup", status: 404, json: ["error": "unknown-product"])
        #expect(await h.license.pickUp(email: Self.address) == .failed(PickupRefusal(error: .network)))
    }

    @Test func writesNothingWhenItAsksForACode() async throws {
        let h = try Harness()
        h.http.on("pickup", status: 200, json: ["ok": true])
        _ = await h.license.pickUp(email: Self.address)
        #expect(h.storage.writes == 0)
        #expect(h.stored == nil)
    }

    // MARK: - pickUp(email:code:)

    @Test func sendsTheAddressTheCodeAndThisDevicesFingerprintsAndAnswersTheKeysAsRead() async throws {
        let h = try confirming([["key": .string(KEY), "model": "perpetual", "modelName": "Single", "state": "active", "held": true]])
        let result = await h.license.pickUp(email: Self.address, code: " 123 456 ")
        let keys = try #require(result.pickedKeys)
        #expect(keys == [PickedKey(key: KEY, model: "perpetual", modelName: "Single", state: "active", held: true)])
        let body = try #require(h.http.body("confirm"))
        #expect(body["email"]?.stringValue == Self.address)
        #expect(body["code"]?.stringValue == "123456")
        #expect(body["fingerprints"] == ["fp-test"])
        #expect(h.http.url("confirm")?.path.hasSuffix("/v1/products/sluice/pickup/confirm") == true)
    }

    @Test func sendsNoFingerprintsForAProductWhoseDevicesAreNotHeld() async throws {
        let h = try confirming([], Harness(deviceHold: false))
        #expect(await h.license.pickUp(email: Self.address, code: "123456").pickedKeys == [])
        #expect(try #require(h.http.body("confirm")).has("fingerprints") == false)
    }

    @Test func refusesACodeThatIsNotSixDigitsBeforeItAsksCostingTheAddressNoTry() async throws {
        let h = try Harness()
        for code in ["12345", "", "   ", "12345a", "\u{FF11}\u{FF12}\u{FF13}\u{FF14}\u{FF15}\u{FF16}"] {
            #expect(await h.license.pickUp(email: Self.address, code: code) == .failed(PickupRefusal(error: .wrongCode)), "\(code)")
        }
        // The address is judged first.
        #expect(await h.license.pickUp(email: "", code: "12") == .failed(PickupRefusal(error: .invalidEmail)))
        #expect(h.http.count("confirm") == 0)
    }

    @Test func answersTheServersWordsAndA200ThatIsNoPickupAnswerAsNetwork() async throws {
        let h = try Harness()
        let words: [(Int, String, PickupError)] = [
            (403, "wrong-code", .wrongCode), (403, "code-expired", .codeExpired), (403, "pickup-disabled", .pickupDisabled),
            (503, "try-again", .tryAgain), (400, "invalid-request", .invalidEmail),
        ]
        for (status, word, error) in words {
            h.http.on("confirm", status: status, json: ["error": .string(word)])
            #expect(await h.license.pickUp(email: Self.address, code: "123456") == .failed(PickupRefusal(error: error)), "\(word)")
        }
        h.http.on("confirm", status: 429, json: ["error": "too-many-attempts", "retryAfter": 3000])
        #expect(
            await h.license.pickUp(email: Self.address, code: "123456")
                == .failed(PickupRefusal(error: .tooManyAttempts, retryAfter: 3000)))
        for body: LicenseJSON in [["ok": true], ["keys": "no"], []] {
            h.http.on("confirm", status: 200, json: body)
            #expect(await h.license.pickUp(email: Self.address, code: "123456") == .failed(PickupRefusal(error: .network)))
        }
        h.http.setFail(true)
        #expect(await h.license.pickUp(email: Self.address, code: "123456") == .failed(PickupRefusal(error: .network)))
    }

    @Test func writesNothingWhenItConfirms() async throws {
        let h = try confirming([picked()])
        #expect(await h.license.pickUp(email: Self.address, code: "123456").pickedKeys?.count == 1)
        #expect(h.storage.writes == 0)
        #expect(h.stored == nil)
    }

    @Test func asksAgainWithAnotherCodeAndOnceTheKeysAreTenMinutesOld() async throws {
        let h = try confirming([])
        _ = await h.license.pickUp(email: Self.address, code: "123456")
        _ = await h.license.pickUp(email: Self.address, code: "654321")
        #expect(h.http.count("confirm") == 2)
        _ = await h.license.pickUp(email: Self.address, code: "654321")
        #expect(h.http.count("confirm") == 2)
        h.clock.set(NOW + pickupKeysKeepMs)
        _ = await h.license.pickUp(email: Self.address, code: "654321")
        #expect(h.http.count("confirm") == 3)
        // Another address asks again too.
        _ = await h.license.pickUp(email: "other@studio.example", code: "654321")
        #expect(h.http.count("confirm") == 4)
    }

    // MARK: - restoreByEmail

    @Test func confirmsThenActivatesTheKeyThatFitsWithTheAddressAndStoresTheActivationNeverTheCode() async throws {
        let h = try confirming([picked()])
        activating(h)
        #expect(await h.license.restoreByEmail(email: Self.address, code: "123456") == .restored)
        let body = try #require(h.http.body("activate"))
        #expect(body["key"]?.stringValue == KEY)
        #expect(body["email"]?.stringValue == Self.address)
        #expect(!body.has("code"))
        let stored = try #require(h.stored).json.jsonText
        #expect(stored.contains(KEY))
        #expect(!stored.lowercased().contains("studio") && !stored.contains("123456"), "\(stored)")
        #expect(await h.license.status().state == .licensed)
        #expect(h.http.actions == ["confirm", "activate"])
    }

    @Test func activatesTheAddressAsThePickupSentItTrimmed() async throws {
        let h = try confirming([picked()])
        activating(h)
        #expect(await h.license.restoreByEmail(email: "  Mara@Studio.example\n", code: " 123 456 ") == .restored)
        #expect(h.http.body("confirm")?["email"]?.stringValue == Self.address)
        #expect(h.http.body("confirm")?["code"]?.stringValue == "123456")
        #expect(h.http.body("activate")?["email"]?.stringValue == Self.address)
    }

    @Test func activatesACodeLockedKeyWithTheCodeThePickupHandedBack() async throws {
        let h = try confirming([picked(activationCode: "654321")])
        activating(h)
        #expect(await h.license.restoreByEmail(email: Self.address, code: "123456") == .restored)
        let body = try #require(h.http.body("activate"))
        #expect(body["key"]?.stringValue == KEY)
        #expect(body["email"]?.stringValue == Self.address)
        #expect(body["code"]?.stringValue == "654321")
        // Neither the pickup's code nor the lock's is stored.
        let stored = try #require(h.stored).json.jsonText
        #expect(!stored.contains("654321") && !stored.contains("123456"), "\(stored)")
    }

    @Test func choosesTheKeyThisDeviceHoldsThenOneWithASeat() async throws {
        let a = "SLUICE-AAAA-AAAA-AAAA-AAAA"
        let b = "SLUICE-BBBB-BBBB-BBBB-BBBB"
        let c = "SLUICE-CCCC-CCCC-CCCC-CCCC"
        let h = try confirming([picked(a, activeDevices: 1), picked(b), picked(c, activeDevices: 1, held: true)])
        h.http.on("activate", status: 409, json: ["error": "limit"])
        #expect(await h.license.restoreByEmail(email: Self.address, code: "123456") == .failed(.license(.limit)))
        #expect(h.http.body("activate")?["key"]?.stringValue == c)
        _ = try confirming([picked(a, activeDevices: 1), picked(b)], h)
        _ = await h.license.restoreByEmail(email: Self.address, code: "654321")
        #expect(h.http.calls.last { $0.action == "activate" }?.body["key"]?.stringValue == b)
    }

    @Test func answersNoKeyForAnAddressWithNoneAndUpgradeOrOutdatedActivatingNothing() async throws {
        let h = try Harness(major: 2)
        _ = try confirming([], h)
        #expect(await h.license.restoreByEmail(email: Self.address, code: "123456") == .failed(.noKey))
        // Keys for an older major: buy an upgrade.
        _ = try confirming([picked()], h)
        #expect(await h.license.restoreByEmail(email: Self.address, code: "222222") == .failed(.license(.upgrade)))
        // Keys that start at a major after this build: update the app.
        _ = try confirming([picked(minMajor: 3, maxMajor: nil)], h)
        #expect(await h.license.restoreByEmail(email: Self.address, code: "333333") == .failed(.license(.outdated)))
        #expect(h.http.count("activate") == 0)
        #expect(h.stored == nil)
    }

    @Test func answersAPickupRefusalAndAnActivationsAsTheyCome() async throws {
        let h = try Harness()
        h.http.on("confirm", status: 403, json: ["error": "code-expired"])
        #expect(await h.license.restoreByEmail(email: Self.address, code: "123456") == .failed(.pickup(PickupRefusal(error: .codeExpired))))
        h.http.on("confirm", status: 429, json: ["error": "too-many-attempts", "retryAfter": 3600])
        let waiting = await h.license.restoreByEmail(email: Self.address, code: "123456")
        #expect(waiting.error == .pickup(PickupRefusal(error: .tooManyAttempts, retryAfter: 3600)))
        #expect(waiting.error?.retryAfter == 3600)
        #expect(waiting.error?.word == "too-many-attempts")
        // The typed refusals ask nothing.
        #expect(await h.license.restoreByEmail(email: "", code: "123456") == .failed(.pickup(PickupRefusal(error: .invalidEmail))))
        #expect(await h.license.restoreByEmail(email: Self.address, code: "12") == .failed(.pickup(PickupRefusal(error: .wrongCode))))
        #expect(h.http.count("confirm") == 2)

        _ = try confirming([picked()], h)
        h.http.on("activate", status: 409, json: ["error": "limit"])
        #expect(await h.license.restoreByEmail(email: Self.address, code: "123456") == .failed(.license(.limit)))
        h.http.on("activate", status: 403, json: ["error": "user-code-invalid"])
        #expect(await h.license.restoreByEmail(email: Self.address, code: "123456") == .failed(.license(.userCodeInvalid)))
        h.http.setFail(true)
        #expect(await h.license.restoreByEmail(email: Self.address, code: "123456") == .failed(.license(.network)))
    }

    @Test func keepsTheConfirmedKeysInMemorySoARetryOrARestoreAfterPickUpAsksOnce() async throws {
        let h = try confirming([picked()])
        h.http.on("activate", status: 503, json: ["error": "unavailable"])
        #expect(await h.license.restoreByEmail(email: Self.address, code: "123456") == .failed(.license(.network)))
        activating(h)
        #expect(await h.license.restoreByEmail(email: Self.address, code: " 123 456 ") == .restored)
        #expect(h.http.count("confirm") == 1)
        // Done with once activated: the same pair asks again.
        #expect(await h.license.pickUp(email: Self.address, code: "123456").pickedKeys != nil)
        #expect(h.http.count("confirm") == 2)
        // Kept in memory only: nothing of them is stored.
        #expect(!(try #require(h.stored).json.jsonText.contains("123456")))
    }

    @Test func leavesTheLicenceThisDeviceHoldsAsItWasWhenARestoreFails() async throws {
        let h = try Harness()
        activating(h)
        #expect(await h.license.activate(KEY) == .activated)
        let before = try #require(h.stored).json
        _ = try confirming([picked("SLUICE-OTHR-BBBB-CCCC-DDDD")], h)
        h.http.on("activate", status: 409, json: ["error": "limit"])
        #expect(await h.license.restoreByEmail(email: Self.address, code: "123456") == .failed(.license(.limit)))
        h.http.setFail(true)
        #expect(await h.license.restoreByEmail(email: Self.address, code: "654321") == .failed(.pickup(PickupRefusal(error: .network))))
        #expect(try #require(h.stored).json == before)
    }

    // MARK: - behind a call that has not finished

    @Test func answersPickupsBesideAStuckCallAndARestoreNetworkAskingNothing() async throws {
        let h = try Harness(httpTimeout: 0.2, timing: quick)
        h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: h.sign(), lastSeen: NOW, checkedMajor: 1))
        h.http.on("validate", status: 403, json: ["error": "revoked"])
        h.http.on("pickup", status: 200, json: ["ok": true])
        _ = try confirming([], h)
        h.storage.holdNextWrite()
        let stuck = Task { await h.license.refresh() }
        await eventually { h.storage.writes == 1 }
        try await Task.sleep(nanoseconds: nanoseconds(0.2 + quick.lockGrace + 0.05))
        #expect(await h.license.pickUp(email: Self.address) == .sent)
        #expect(await h.license.pickUp(email: Self.address, code: "123456").pickedKeys == [])
        #expect(await h.license.restoreByEmail(email: Self.address, code: "654321") == .failed(.license(.network)))
        #expect(h.http.count("confirm") == 1)
        #expect(h.storage.writes == 1)
        h.storage.releaseWrite()
        _ = await answer { await stuck.value }
    }

    // MARK: - the pieces

    @Test func asksForACodeWithAnAddressAloneAndConfirmsWithACode() {
        #expect(pickupAsk(email: Self.address, code: nil) == .send(email: Self.address, code: nil))
        #expect(pickupAsk(email: Self.address, code: "123456") == .send(email: Self.address, code: "123456"))
        #expect(pickupAsk(email: "", code: "123456") == .refused(.invalidEmail))
    }

    @Test func readsARefusalLeniently() {
        #expect(pickupRefusal(nil) == PickupRefusal(error: .network))
        #expect(pickupRefusal(["error": "unavailable", "retryAfter": 60]) == PickupRefusal(error: .tryAgain, retryAfter: 60))
        #expect(pickupRefusal(["error": "wrong-code", "retryAfter": 60]) == PickupRefusal(error: .wrongCode))
        #expect(pickupRefusal(["error": "too-many-attempts", "retryAfter": 1.5]) == PickupRefusal(error: .tooManyAttempts))
    }

    @Test func readsAConfirmsKeysLenientlyAndNoneFromWhatIsNoAnswer() {
        #expect(pickedKeysOf(["keys": "no"]) == nil)
        #expect(pickedKeysOf([]) == nil)
        #expect(pickedKeysOf(nil) == nil)
        let read = pickedKeysOf([
            "keys": [["key": ""], 7, ["key": .string(KEY), "held": "yes", "activationCode": "12345"]]
        ])
        #expect(read == [PickedKey(key: KEY)])
    }

    @Test func judgesAKeysVersionsAsTheServerDoes() {
        func covers(_ versions: PickedVersions?, _ major: Int) -> Bool { pickedKeyCovers(versions, major: major, now: NOW) }
        #expect(covers(nil, 9))
        #expect(!covers(PickedVersions(minMajor: 2, maxMajor: 3), 1))
        #expect(!covers(PickedVersions(minMajor: 2, maxMajor: 3), 4))
        #expect(covers(PickedVersions(minMajor: 2, maxMajor: 3, upgradeUntil: NOW + 1), 4))
        #expect(!covers(PickedVersions(minMajor: 2, maxMajor: 3, upgradeUntil: NOW), 4))
        #expect(covers(PickedVersions(minMajor: 2), 40))
    }

    @Test func choosesTheKeyHeldThenOneWithAFreeSeatThenTheFirst() {
        let covered = PickedVersions(minMajor: 1, maxMajor: 1)
        let full = PickedKey(key: "A", versions: covered, deviceLimit: 1, activeDevices: 1)
        let free = PickedKey(key: "B", versions: covered, deviceLimit: 1)
        let held = PickedKey(key: "C", versions: covered, deviceLimit: 1, activeDevices: 1, held: true)
        #expect(chosenKey([full, free, held], major: 1, now: NOW) == .success(2))
        #expect(chosenKey([full, free], major: 1, now: NOW) == .success(1))
        #expect(chosenKey([full, PickedKey(key: "D", versions: covered, deviceLimit: 1, activeDevices: 1)], major: 1, now: NOW) == .success(0))
        let later = PickedKey(key: "E", versions: PickedVersions(minMajor: 3))
        #expect(chosenKey([later], major: 1, now: NOW) == .failure(.outdated))
    }
}
