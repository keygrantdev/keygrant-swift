import Foundation
import Testing

@testable import KeyGrant

/// What a lease grants, as every status that rests on it hands it to the app (the reference's
/// `describe('entitlements')` in license.test.ts).
@Suite("entitlements", suiteTimeLimit)
struct EntitlementTests {
    let pro: [String: Entitlement] = ["edition": "pro", "seats": 5, "beta": false]
    let proJSON: LicenseJSON = ["edition": "pro", "seats": 5, "beta": false]

    /// Activates `KEY` with the server answering `lease`.
    func activated(_ h: Harness, _ lease: String) async {
        h.http.on("activate", status: 200, json: ["lease": .string(lease), "activationId": "act_1"])
        #expect(await h.license.activate(KEY) == .activated)
    }

    /// `lease` stored as the licence `KEY` holds, the server last told of this build.
    func holding(_ h: Harness, _ lease: String) {
        h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: lease, lastSeen: NOW, checkedMajor: 1))
    }

    @Test func handsTheAppWhatTheLeaseGrantsOnceActivated() async throws {
        let h = try Harness()
        await activated(h, signedLease(h.signer, ["ent": proJSON]))
        let status = await h.license.status()
        #expect(status == LicenseStatus(state: .licensed, key: KEY, entitlements: pro))
        #expect(status.entitlements["edition"] == .string("pro"))
        #expect(status.entitlements["seats"]?.numberValue == 5 && status.entitlements["beta"]?.boolValue == false)
    }

    @Test func saysNothingOfThemWhenTheLeaseGrantsNoneSoTheStatusIsWhatItWas() async throws {
        // As `isTest`: an app comparing whole statuses sees no change.
        let h = try Harness()
        await activated(h, signedLease(h.signer, ["ent": [:]]))
        let status = await h.license.status()
        #expect(status == LicenseStatus(state: .licensed, key: KEY))
        #expect(status.entitlements.isEmpty)
        #expect(status.hashValue == LicenseStatus(state: .licensed, key: KEY).hashValue)
    }

    @Test func keepsTheGoodMembersOfAMalformedEntAndTheLicenceItRidesOn() async throws {
        let h = try Harness()
        holding(h, signedLease(h.signer, ["ent": ["edition": "pro", "nested": ["tier": "gold"], "none": .null, "list": [1], "seats": 2]]))
        #expect(await h.license.status() == LicenseStatus(state: .licensed, key: KEY, entitlements: ["edition": "pro", "seats": 2]))
    }

    @Test(arguments: [LicenseJSON.null, LicenseJSON.array(["pro"]), LicenseJSON.string("pro"), LicenseJSON.number(42), LicenseJSON.bool(true)])
    func readsAnEntThatIsNotAnObjectAsNoneNeverAsARefusal(ent: LicenseJSON) async throws {
        let h = try Harness()
        holding(h, signedLease(h.signer, ["ent": ent]))
        #expect(await h.license.status() == LicenseStatus(state: .licensed, key: KEY))
        #expect(h.http.calls.isEmpty)
    }

    @Test func takesThemFromTheRenewedLeaseNotTheOneItReplaced() async throws {
        // From an EXPIRED lease, so the status can only come from the renewal.
        let h = try Harness()
        await activated(h, signedLease(h.signer, ["ent": ["edition": "basic"], "exp": .number(Double(NOW / 1000 + 60))]))
        let later = NOW + 2 * HOUR
        h.clock.set(later)
        h.http.on("validate", status: 200, json: ["lease": .string(signedLease(h.signer, ["ent": proJSON], at: later))])
        #expect(await h.license.status() == LicenseStatus(state: .licensed, key: KEY, entitlements: pro))
        #expect(h.http.called("validate"))
    }

    @Test func refreshTakesTheNewLeasesWhenTheServerAnswersAndTheHeldLeasesWhenItCannot() async throws {
        let h = try Harness()
        await activated(h, signedLease(h.signer, ["ent": ["edition": "basic"]]))
        h.http.on("validate", status: 200, json: ["lease": .string(signedLease(h.signer, ["ent": proJSON]))])
        #expect(await h.license.refresh() == LicenseStatus(state: .licensed, key: KEY, entitlements: pro))
        h.http.setFail(true)
        #expect(await h.license.refresh() == LicenseStatus(state: .licensed, key: KEY, entitlements: pro))
        #expect(h.http.actions == ["activate", "validate", "validate"])
    }

    @Test func carriesATestLicencesBesideItsTestFlag() async throws {
        let h = try Harness()
        await activated(h, signedLease(h.signer, ["ent": proJSON, "test": true]))
        #expect(await h.license.status() == LicenseStatus(state: .licensed, key: KEY, isTest: true, entitlements: pro))
    }

    @Test func carriesNoneOnAStatusThatDoesNotLicenseThoughTheLeaseGrantsThem() async throws {
        let h = try Harness(major: 2)
        h.http.setFail(true)
        // A newer build than the lease covers.
        holding(h, signedLease(h.signer, ["ent": proJSON]))
        #expect(await h.license.status() == LicenseStatus(state: .invalid, reason: .upgrade, key: KEY))
        // A lease past its end, the server out of reach.
        holding(h, signedLease(h.signer, ["ent": proJSON, "major": 2, "exp": .number(Double(NOW / 1000 - 1))]))
        #expect(await h.license.status() == LicenseStatus(state: .expired, reason: .offline, key: KEY))
        // A lease for another key.
        holding(h, signedLease(h.signer, ["ent": proJSON, "major": 2, "sub": "SLUICE-ZZZZ-ZZZZ-ZZZZ-ZZZZ"]))
        #expect(await h.license.status() == LicenseStatus(state: .invalid, reason: .tampered))
    }

    @Test func carriesNoneWhenTheServerRevokesTheKeyThoughTheLeaseItHeldGrantedThem() async throws {
        let h = try Harness()
        await activated(h, signedLease(h.signer, ["ent": proJSON]))
        h.http.on("validate", status: 403, json: ["error": "revoked"])
        #expect(await h.license.refresh() == LicenseStatus(state: .invalid, reason: .revoked, key: KEY))
        h.http.setFail(true)
        #expect(await h.license.status() == LicenseStatus(state: .invalid, reason: .revoked, key: KEY))
    }

    @Test func carriesNoneOnARefusalTheServerGaveThoughTheLeaseItKeepsGrantsThem() async throws {
        // An upgrade refusal keeps the lease (a rollback runs offline on it), so the entitlements
        // are still on the device: the refusal must not carry them.
        let h = try Harness()
        await activated(h, signedLease(h.signer, ["ent": proJSON]))
        h.http.on("validate", status: 403, json: ["error": "upgrade-required"])
        #expect(await h.license.refresh() == LicenseStatus(state: .invalid, reason: .upgrade, key: KEY))
        #expect(h.stored?.lease != nil)
        h.http.setFail(true)
        #expect(await h.license.status() == LicenseStatus(state: .invalid, reason: .upgrade, key: KEY))
    }

    @Test func carriesNoneOnAStoredRefusalAnsweredBehindACallThatHasNotFinished() async throws {
        let ticker = ManualTicker()
        let h = try Harness(timing: Timing(ticker: ticker))
        let lease = signedLease(h.signer, ["ent": proJSON])
        h.storage.set(StoredState(
            key: KEY, activationId: "act_1", lease: lease, lastSeen: NOW, checkedMajor: 1, refused: .upgrade, refusedMajor: 1
        ))
        h.storage.hangNextRead()
        let stuck = Task { await h.license.status() }
        await eventually { h.storage.hungReads == 1 }
        let later = Task { await h.license.status() }
        // The stuck call started at 0: its HTTP bound and the lock grace end at 30 s.
        await eventually { ticker.deadlinesMs == [30_000] }
        ticker.advance(ms: 30_000)
        #expect(await answer { await later.value } == LicenseStatus(state: .invalid, reason: .upgrade, key: KEY, isStalled: true))
        h.storage.releaseAll()
        _ = await answer { await stuck.value }
    }

    @Test func keepsTheHeldLeasesWhenAnEarlyRenewalGetsNoAnswer() async throws {
        // Five days left of thirty: due to renew early, and the server is out of reach.
        let h = try Harness()
        let iat = NOW / 1000 - 25 * 86_400
        holding(h, signedLease(h.signer, ["ent": proJSON, "iat": .number(Double(iat)), "exp": .number(Double(NOW / 1000 + 5 * 86_400))]))
        h.http.setFail(true)
        #expect(await h.license.status() == LicenseStatus(state: .licensed, key: KEY, entitlements: pro))
        #expect(h.http.actions == ["validate"])
    }

    @Test func handsATrialTheTrialLeasesFromStartTrialAndEveryStatusAfter() async throws {
        let h = try Harness()
        let trialLease = signedLease(
            h.signer, ["sub": "trial:fp-test", "model": "trial", "ent": proJSON, "exp": .number(Double(NOW / 1000 + 5 * 86_400))]
        )
        h.http.on(
            "trial", status: 200,
            json: ["trialStart": .number(Double(NOW - 2 * DAY)), "trialEndsAt": .number(Double(NOW + 5 * DAY)), "lease": .string(trialLease)]
        )
        let trial = LicenseStatus(state: .trial, trialDaysLeft: 5, trialEndsAt: NOW + 5 * DAY, entitlements: pro)
        #expect(await h.license.startTrial() == trial)
        h.http.setFail(true)
        #expect(await h.license.status() == trial)
    }

    @Test func givesATrialNoneOnceItsLeaseNoLongerRunsIt() async throws {
        let h = try Harness()
        let trialLease = signedLease(
            h.signer, ["sub": "trial:fp-test", "model": "trial", "ent": proJSON, "exp": .number(Double(NOW / 1000 + 86_400))]
        )
        h.storage.set(StoredState(trialStart: NOW - 6 * DAY, trialEndsAt: NOW + DAY, trialLease: trialLease, lastSeen: NOW))
        h.clock.set(NOW + 2 * DAY)
        h.http.setFail(true)
        #expect(await h.license.status() == LicenseStatus(state: .expired, reason: .trial))
    }

    @Test func stillCarriesThemBehindACallThatHasNotFinishedFromTheLeaseHeld() async throws {
        let ticker = ManualTicker()
        let h = try Harness(timing: Timing(ticker: ticker))
        holding(h, signedLease(h.signer, ["ent": proJSON]))
        h.storage.hangNextRead()
        let stuck = Task { await h.license.status() }
        await eventually { h.storage.hungReads == 1 }
        let later = Task { await h.license.status() }
        // The stuck call started at 0: its HTTP bound and the lock grace end at 30 s.
        await eventually { ticker.deadlinesMs == [30_000] }
        ticker.advance(ms: 30_000)
        #expect(await answer { await later.value } == LicenseStatus(state: .licensed, key: KEY, entitlements: pro, isStalled: true))
        h.storage.releaseAll()
        _ = await answer { await stuck.value }
    }

    @Test func cannotBeChangedThroughAStatusWhichLeavesTheNextStatusAsTheLeaseSays() async throws {
        let h = try Harness()
        holding(h, signedLease(h.signer, ["ent": proJSON]))
        var first = await h.license.status()
        first.entitlements["edition"] = "studio"
        first.entitlements["extra"] = true
        #expect(first.entitlements["edition"] == "studio")
        #expect(await h.license.status().entitlements == pro)
    }
}

/// The status a lease gives offline, and the entitlements it carries (`leaseStatus`,
/// `trialLeaseOf`, `trialStatusOf`; the reference's `describe('entitlements in a status')` in
/// offline.test.ts): only a lease that licenses, or a trial lease that runs a trial, carries them.
@Suite("entitlements in a status", suiteTimeLimit)
struct EntitlementsInAStatusTests {
    let pro: [String: Entitlement] = ["edition": "pro", "seats": 5]

    var granting: LeaseClaims {
        var claims = baseClaims
        claims.ent = pro
        return claims
    }

    /// A trial lease's claims, for the device whose claim is `claim-own`, granting `pro`.
    var trial: LeaseClaims {
        var claims = granting
        claims.model = "trial"
        claims.aid = "claim-own"
        claims.fpk = .machine
        claims.exp = claims.iat + 7 * 86_400
        return claims
    }

    @Test func licensedWithTheLeasesEntitlementsAndItsTestFlag() {
        #expect(leaseStatus(.ok(test: false, claims: granting), key: KEY) == LicenseStatus(state: .licensed, key: KEY, entitlements: pro))
        var test = granting
        test.test = true
        #expect(leaseStatus(.ok(test: true, claims: test), key: KEY) == LicenseStatus(state: .licensed, key: KEY, isTest: true, entitlements: pro))
    }

    @Test func takesTheTestFlagFromTheCheckItsOneSource() {
        var test = granting
        test.test = true
        #expect(leaseStatus(.ok(test: true, claims: granting), key: KEY).isTest)
        #expect(!leaseStatus(.ok(test: false, claims: test), key: KEY).isTest)
    }

    @Test func licensedByALeaseThatGrantsNoneIsTheStatusItWasBefore() {
        let status = leaseStatus(.ok(test: false, claims: baseClaims), key: KEY)
        #expect(status == LicenseStatus(state: .licensed, key: KEY))
        #expect(status.json == ["state": "licensed", "key": .string(KEY)])
    }

    @Test(arguments: [
        (LeaseCheck.Reason.expired, LicenseStatus(state: .expired, reason: .offline, key: KEY)),
        (.upgrade, LicenseStatus(state: .invalid, reason: .upgrade, key: KEY)),
        (.outdated, LicenseStatus(state: .invalid, reason: .outdated, key: KEY)),
        (.device, LicenseStatus(state: .invalid, reason: .device, key: KEY)),
        (.tampered, LicenseStatus(state: .invalid, reason: .tampered)),
    ])
    func notLicensedCarriesNone(reason: LeaseCheck.Reason, expected: LicenseStatus) {
        #expect(leaseStatus(.refused(reason), key: KEY) == expected)
    }

    @Test func aValidTrialLeaseGivesItsEndAndItsEntitlements() {
        let lease = trialLeaseOf(.valid(trial), product: PRODUCT, claims: ["claim-own"], canTell: true)
        #expect(lease == TrialLease(valid: true, endsAt: Int(trial.exp) * 1000, entitlements: pro))
    }

    @Test func aTrialLeaseNotValidHereSaysNothingOfItsEndOrItsEntitlements() {
        var licence = trial
        licence.model = "perpetual"
        // Expired; another product's; another device's; a licence's.
        #expect(trialLeaseOf(.invalid(.expired, trial), product: PRODUCT, claims: ["claim-own"], canTell: true) == .invalid)
        #expect(trialLeaseOf(.valid(trial), product: "maindeck", claims: ["claim-own"], canTell: true) == .invalid)
        #expect(trialLeaseOf(.valid(trial), product: PRODUCT, claims: ["claim-other"], canTell: true) == .invalid)
        #expect(trialLeaseOf(.valid(licence), product: PRODUCT, claims: ["claim-own"], canTell: true) == .invalid)
        #expect(TrialLease.invalid == TrialLease(valid: false, endsAt: nil, entitlements: [:]))
    }

    @Test func aRunningTrialCarriesTheEntitlementsItIsGivenAndEveryOtherAnswerNone() {
        let state = StoredState(trialStart: NOW, trialLease: "stored")
        let running = LicenseStatus(state: .trial, trialDaysLeft: 3, trialEndsAt: NOW + 3 * DAY)
        var granted = running
        granted.entitlements = pro
        #expect(trialStatusOf(state, now: NOW, leaseValid: true, leaseEndsAt: NOW + 3 * DAY, leaseEntitlements: pro) == granted)
        #expect(trialStatusOf(state, now: NOW, leaseValid: true, leaseEndsAt: NOW + 3 * DAY, leaseEntitlements: [:]) == running)
        #expect(trialStatusOf(state, now: NOW, leaseValid: true, leaseEndsAt: NOW + 3 * DAY) == running)
        #expect(trialStatusOf(state, now: NOW, leaseValid: false, leaseEntitlements: pro) == LicenseStatus(state: .expired, reason: .trial))
        #expect(trialStatusOf(StoredState(), now: NOW, leaseValid: true, leaseEndsAt: NOW + 3 * DAY, leaseEntitlements: pro) == LicenseStatus(state: .unlicensed))
    }
}

/// The `ent` claim, read leniently (`entitlementsOf`, `docs/specs/sdk-contract.md` section 2.1).
@Suite("the entitlements claim", suiteTimeLimit)
struct EntitlementsClaimTests {
    @Test func keepsEveryKindOfValueAsSigned() {
        let ent: LicenseJSON = ["edition": "pro", "seats": 5, "ratio": 0.5, "discount": -2, "beta": false, "cloud": true, "label": ""]
        let read = entitlementsOf(ent)
        #expect(read == [
            "edition": .string("pro"), "seats": .number(5), "ratio": .number(0.5), "discount": .number(-2), "beta": .bool(false),
            "cloud": .bool(true), "label": .string(""),
        ])
        #expect(LicenseJSON.object(read.mapValues(\.json)) == ent)
    }

    @Test func dropsTheMalformedMembersAndKeepsTheRest() {
        let ent: LicenseJSON = ["nested": ["tier": "gold"], "edition": "pro", "none": .null, "list": ["a"], "seats": 2]
        #expect(entitlementsOf(ent) == ["edition": "pro", "seats": 2])
    }

    @Test(arguments: [nil, LicenseJSON.null, LicenseJSON.array([]), LicenseJSON.array(["pro", true]), "pro", 42, true] as [LicenseJSON?])
    func readsAnythingButAnObjectAsNone(ent: LicenseJSON?) {
        #expect(entitlementsOf(ent).isEmpty)
    }

    @Test func takesNamesAsTheyAreAProtoNameAndTextBeyondASCIIIncluded() {
        #expect(entitlementsOf(["__proto__": "pro", "seats": 1]) == ["__proto__": "pro", "seats": 1])
        #expect(entitlementsOf(["\u{E9}dition": "Pro Studio \u{2713}", "版本": "专业版"]) == ["\u{E9}dition": "Pro Studio \u{2713}", "版本": "专业版"])
    }

    @Test func enforcesNoneOfTheCapsTheServerHoldsThemTo() {
        var many: [String: LicenseJSON] = [:]
        for index in 0..<20 { many["n\(index)"] = .number(Double(index)) }
        many[String(repeating: "k", count: 40)] = true
        many["long"] = .string(String(repeating: "v", count: 100))
        let read = entitlementsOf(.object(many))
        #expect(read.count == 22)
        #expect(read.mapValues(\.json) == many)
    }

    @Test func keepsAFlagAndANumberApartAndReadsNumbersAsDoubles() throws {
        // Read from JSON text, as a lease's payload is: `true` is never 1, nor `1` true.
        let json = try #require(JSONText.parse(#"{"on":true,"one":1,"off":false,"zero":0,"five":5.0}"#))
        let read = entitlementsOf(json)
        #expect(read == ["on": .bool(true), "one": .number(1), "off": .bool(false), "zero": .number(0), "five": .number(5)])
        #expect(read["on"] != .number(1) && read["one"] != .bool(true) && read["zero"] != .bool(false))
        #expect(read["five"] == 5 && read["five"]?.numberValue == 5)
    }

    @Test func readsNumbersCorrectlyRoundedAsJavaScriptDoes() throws {
        // Each the nearest double to its text, as JavaScript's `Number` gives it (bit patterns from
        // Node), and written back as JavaScript prints it.
        let texts = ["ratio": "221.62324973788606", "share": "975.1952520418383", "total": "123456789012345680000"]
        let bits: [String: UInt64] = ["ratio": 0x406B_B3F1_A96F_2EC2, "share": 0x408E_798F_E04D_7162, "total": 0x441A_C53A_7E04_BCDA]
        let json = try #require(JSONText.parse("{" + texts.map { #""\#($0.key)":\#($0.value)"# }.joined(separator: ",") + "}"))
        let read = entitlementsOf(json)
        for (name, text) in texts {
            let number = try #require(read[name]?.numberValue, "\(name)")
            #expect(number.bitPattern == bits[name], "\(name)")
            #expect(JSONText.numberText(number) == text, "\(name)")
        }
    }

    @Test func keepsNamesAndTextsPastUFFFFAsSigned() throws {
        let json = try #require(JSONText.parse(#"{"\ud83c\udfb5":"Pro \ud834\udd1e","seats":1}"#))
        let read = entitlementsOf(json)
        #expect(read == ["\u{1F3B5}": .string("Pro \u{1D11E}"), "seats": 1])
        #expect(read.keys.contains { $0.unicodeScalars.elementsEqual("\u{1F3B5}".unicodeScalars) })
    }

    @Test func readsTheClaimLenientlyInASignedLeaseThatStillVerifies() throws {
        let signer = Signer()
        let key = try publicKeyBytes(fromJWK: signer.publicJWK)
        let malformed = verifyLease(signedLease(signer, ["ent": ["edition": "pro", "nested": ["tier": "gold"]]]), publicKey: key, now: NOW)
        #expect(malformed.failure == nil && malformed.claims?.ent == ["edition": "pro"])
        let absent = verifyLease(signedLease(signer, [:]), publicKey: key, now: NOW)
        #expect(absent.failure == nil && absent.claims?.ent == [:])
        let list = verifyLease(signedLease(signer, ["ent": ["pro"]]), publicKey: key, now: NOW)
        #expect(list.failure == nil && list.claims?.ent == [:])
        // Only `ent` is read leniently: another optional claim present as null still fails the claims.
        #expect(verifyLease(signedLease(signer, ["ent": [:], "fp": .null]), publicKey: key, now: NOW).failure == .badClaims)
    }
}

/// `Entitlement`, the value an app reads.
@Suite("an entitlement", suiteTimeLimit)
struct EntitlementValueTests {
    @Test func readsAsItsKindAndNothingElse() {
        let flag = Entitlement.bool(true), number = Entitlement.number(5), text = Entitlement.string("pro")
        #expect(flag.boolValue == true && flag.numberValue == nil && flag.stringValue == nil)
        #expect(number.numberValue == 5 && number.boolValue == nil && number.stringValue == nil)
        #expect(text.stringValue == "pro" && text.boolValue == nil && text.numberValue == nil)
        // Written as literals, as an app compares them.
        let literals: [Entitlement] = [true, 5, 0.5, "pro"]
        #expect(literals == [.bool(true), .number(5), .number(0.5), .string("pro")])
    }

    @Test func comparesAsJavaScriptDoes() {
        #expect(Entitlement.number(5) == .number(5.0))
        #expect(Entitlement.number(0) == .number(-0.0) && Entitlement.number(0).hashValue == Entitlement.number(-0.0).hashValue)
        #expect(Entitlement.bool(true) != .number(1) && Entitlement.bool(false) != .number(0))
        #expect(Entitlement.string("5") != .number(5))
        // Text unit for unit: an "é" decomposed is another text than one composed.
        let composed = "\u{E9}", decomposed = "e\u{301}"
        #expect(composed == decomposed)
        #expect(Entitlement.string(composed) != .string(decomposed))
        #expect(Set<Entitlement>([.string("pro"), "pro", .number(1), 1.0]).count == 2)
    }

    @Test func aStatusComparesItsEntitlementsByContent() {
        let one = LicenseStatus(state: .licensed, key: KEY, entitlements: ["edition": "pro", "seats": 5])
        var other = LicenseStatus(state: .licensed, key: KEY)
        other.entitlements["seats"] = 5.0
        other.entitlements["edition"] = "pro"
        #expect(one == other && one.hashValue == other.hashValue)
        #expect(one != LicenseStatus(state: .licensed, key: KEY, entitlements: ["edition": "basic", "seats": 5]))
        #expect(one != LicenseStatus(state: .licensed, key: KEY))
    }
}

/// A lease signed by `signer` over any claims (`KEY`'s activation `act_1`, major 1, 30 days from
/// `at`), `over` replacing or adding to them: `ent` as given, malformed or not, and absent unless
/// given. The server never signs a malformed `ent`; the SDK still has to read one.
func signedLease(_ signer: Signer, _ over: [String: LicenseJSON], at: Int = NOW) -> String {
    let iat = at / 1000
    var claims: [String: LicenseJSON] = [
        "iss": "keygrant", "sub": .string(KEY), "product": .string(PRODUCT), "aid": "act_1", "model": "perpetual", "lim": 3,
        "major": 1, "iat": .number(Double(iat)), "exp": .number(Double(iat + 30 * 24 * 3600)),
    ]
    claims.merge(over) { _, given in given }
    return signer.sign(payload: .object(claims))
}
