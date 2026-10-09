import Foundation
import Testing

@testable import KeyGrant

/// The pure decisions, past what the vectors pin.
@Suite("offline decisions", suiteTimeLimit)
struct OfflineTests {
    @Test(arguments: [
        (StoredState(), 3, Refusal?.none),
        (StoredState(refused: .revoked), 1, .revoked),
        (StoredState(refused: .revoked, refusedMajor: 4), 2, .revoked),
        (StoredState(refused: .upgrade, refusedMajor: 4), 4, .upgrade),
        (StoredState(refused: .upgrade, refusedMajor: 4), 5, .upgrade),
        (StoredState(refused: .upgrade, refusedMajor: 4), 3, nil),
        (StoredState(refused: .outdated, refusedMajor: 2), 2, .outdated),
        (StoredState(refused: .outdated, refusedMajor: 2), 1, .outdated),
        (StoredState(refused: .outdated, refusedMajor: 2), 3, nil),
        (StoredState(refused: .upgrade), 1, .upgrade),
        (StoredState(refused: .outdated), 9, .outdated),
    ])
    func standingRefusalByBuild(state: StoredState, major: Int, expected: Refusal?) {
        #expect(standingRefusal(state, major: major, device: nil) == expected)
    }

    @Test func aDeviceRefusalStandsForTheDeviceItWasGivenForAndOnlyWhileThisRunCanTell() {
        let refused = StoredState(refused: .device, refusedFor: ["A"])
        #expect(standingRefusal(refused, major: 1, device: (ownClaim: "A", canTell: true)) == .device)
        #expect(standingRefusal(refused, major: 1, device: (ownClaim: "B", canTell: true)) == nil)
        #expect(standingRefusal(refused, major: 1, device: (ownClaim: "A", canTell: false)) == nil)
        #expect(standingRefusal(refused, major: 1, device: nil) == nil)
        // With no device recorded (an older state): stands.
        #expect(standingRefusal(StoredState(refused: .device), major: 1, device: (ownClaim: "B", canTell: true)) == .device)
    }

    @Test func renewsEarlyAtTheBoundaries() {
        func claims(lifeMs: Int) -> LeaseClaims {
            var claims = baseClaims
            claims.iat = 1_757_000_000
            claims.exp = claims.iat + Double(lifeMs / 1000)
            return claims
        }
        func at(lifeMs: Int, left: Int) -> Int { 1_757_000_000_000 + lifeMs - left }
        let cases: [(life: Int, left: Int, renew: Bool)] = [
            (30 * DAY, Waits.renewWithinMs, false), (30 * DAY, Waits.renewWithinMs - 1, true),
            (7 * DAY, 7 * DAY / 2, false), (7 * DAY, 7 * DAY / 2 - 1, true),
            (HOUR, 30 * 60_000, false), (HOUR, 30 * 60_000 - 1, true),
        ]
        for c in cases {
            #expect(renewsEarly(claims(lifeMs: c.life), now: at(lifeMs: c.life, left: c.left)) == c.renew, "\(c)")
        }
    }

    @Test func asksAtTheBoundariesOfEachWait() {
        let since = 1_757_000_000_000
        let unanswered = StoredState(backoffSince: since, backoffMs: Waits.retryUnansweredMs)
        let answered = StoredState(backoffSince: since, backoffMs: Waits.askAgainMs)
        let legacy = StoredState(backoffSince: since)
        #expect(askDue(answered, clockNow: since, force: true))
        #expect(askDue(StoredState(), clockNow: since, force: false))
        #expect(askDue(answered, clockNow: since - 1, force: false))
        #expect(!askDue(unanswered, clockNow: since + Waits.retryUnansweredMs - 1, force: false))
        #expect(askDue(unanswered, clockNow: since + Waits.retryUnansweredMs, force: false))
        #expect(!askDue(answered, clockNow: since + Waits.askAgainMs - 1, force: false))
        #expect(askDue(answered, clockNow: since + Waits.askAgainMs, force: false))
        #expect(!askDue(legacy, clockNow: since + Waits.askAgainMs - 1, force: false))
        #expect(askDue(legacy, clockNow: since + Waits.askAgainMs, force: false))
    }

    @Test func supersededAnAsksAnswerOutOfDateByTheTimeItIsSaved() {
        let asked = Asked(at: 1_000, activationId: "act_1", seen: 500)
        #expect(superseded(StoredState(activationId: "act_1", verdictAt: 500), asked) == nil)
        #expect(superseded(StoredState(activationId: "act_1", verdictAt: 2_000), asked) == .answer)
        #expect(superseded(StoredState(activationId: "act_1", verdictAt: 800), asked) == nil)
        #expect(superseded(StoredState(activationId: "act_1", verdictAt: 1_000), asked) == nil)
        #expect(superseded(StoredState(activationId: "act_2", verdictAt: 500), asked) == .activation)
        #expect(superseded(StoredState(verdictAt: 500), asked) == .activation)
        // One process's own answer saves over the one it saw, even stamped later (a clock put back).
        #expect(superseded(StoredState(activationId: "act_1", verdictAt: 2_000), Asked(at: 1_000, activationId: "act_1", seen: 2_000)) == nil)
        // Times are compared only for a stamp the asker did not see.
        #expect(superseded(StoredState(activationId: "act_1"), Asked(at: 1_000, activationId: "act_1")) == nil)
        #expect(superseded(StoredState(activationId: "act_1", verdictAt: 2_000), Asked(at: 1_000, activationId: "act_1")) == .answer)
    }

    /// Text compared as JavaScript compares it: an activation id only canonically equivalent to
    /// the stored one (decomposed where it is composed) is another activation.
    @Test func takesAnActivationIdOnlyCanonicallyEquivalentToTheStoredOneForAnotherActivation() {
        let composed = "act_\u{E9}", decomposed = "act_e\u{301}"
        #expect(composed == decomposed)
        #expect(superseded(StoredState(activationId: composed), Asked(at: 1, activationId: decomposed)) == .activation)
        #expect(superseded(StoredState(activationId: composed), Asked(at: 1, activationId: composed)) == nil)
        // So nothing of its answer but trial evidence lands on it.
        let patch: StatePatch = [.lease: .string("L"), .trialStart: .int(5)]
        let landed = merged(StoredState(activationId: composed), patch, Basis(answer: Asked(at: 1, activationId: decomposed)))
        #expect(landed.lease == nil && landed.trialStart == 5)
    }

    @Test(arguments: [
        // The key, the activation and the product of the lease, each decomposed where the device's is composed.
        ("SLUICE-CAF\u{C9}", "SLUICE-CAFE\u{301}", "act_\u{E9}", "act_\u{E9}", "caf\u{E9}", "caf\u{E9}"),
        ("SLUICE-CAF\u{C9}", "SLUICE-CAF\u{C9}", "act_\u{E9}", "act_e\u{301}", "caf\u{E9}", "caf\u{E9}"),
        ("SLUICE-CAF\u{C9}", "SLUICE-CAF\u{C9}", "act_\u{E9}", "act_\u{E9}", "caf\u{E9}", "cafe\u{301}"),
    ])
    func holdsALeaseToItsKeyActivationAndProductUnitForUnit(
        key: String, sub: String, activationId: String, aid: String, product: String, claimed: String
    ) {
        var claims = baseClaims
        claims.sub = sub
        claims.aid = aid
        claims.product = claimed
        let holder = LeaseHolder(key: key, activationId: activationId, claims: [], canTell: true)
        #expect(checkLease(.valid(claims), product: product, major: 1, holder: holder) == .refused(.tampered))
        // The very same text is this licence's lease.
        claims.sub = key
        claims.aid = activationId
        claims.product = product
        #expect(checkLease(.valid(claims), product: product, major: 1, holder: holder) == .ok(test: false, claims: claims))
    }

    @Test func takesAnFpClaimOf128UTF16UnitsAndNoLonger() throws {
        let signer = Signer()
        let key = try publicKeyBytes(fromJWK: signer.publicJWK)
        // 64 characters of two units each: 128 units, the most the claim holds.
        let longest = String(repeating: "😀", count: 64)
        let over = String(repeating: "😀", count: 65)
        #expect(longest.utf16.count == 128 && over.count == 65)
        #expect(verifyLease(signer.lease(fp: longest), publicKey: key, now: NOW).claims?.fp == longest)
        #expect(verifyLease(signer.lease(fp: longest), publicKey: key, now: NOW).failure == nil)
        #expect(verifyLease(signer.lease(fp: over), publicKey: key, now: NOW).failure == .badClaims)
        #expect(verifyLease(signer.lease(fp: ""), publicKey: key, now: NOW).failure == .badClaims)
    }

    @Test func withoutVerdictLeavesOutWhatTheServerSaidAndKeepsWhatTheDeviceKnows() {
        let patch: StatePatch = [
            .lease: .string("L"), .refused: .refusal(.revoked), .refusedMajor: .int(2), .refusedFor: .strings(["c"]), .backoffSince: .int(1),
            .backoffMs: .int(2), .checkedMajor: .int(3), .verdictAt: .int(4), .keptMajor: .int(5), .deviceKind: .deviceKind(.machine),
        ]
        #expect(withoutVerdict(patch) == [.keptMajor: .int(5), .deviceKind: .deviceKind(.machine)])
    }

    let answer: StatePatch = [
        .lease: .string("LA"), .checkedMajor: .int(3), .keptMajor: .int(3), .deviceKind: .deviceKind(.machine), .trialStart: .int(100),
        .trialEndsAt: .int(900), .trialLease: .string("T"),
    ]
    let asked = Asked(at: 1_000, activationId: "act_1", seen: 500)

    @Test(arguments: [
        StoredState(trialStart: 200),
        StoredState(key: "B", activationId: "act_2", lease: "LB", trialStart: 200, deviceKind: .hostname),
    ])
    func keepsOnlyTheTrialEvidenceOfAnAnswerAboutAnActivationNoLongerStored(latest: StoredState) {
        var expected = latest
        expected.trialStart = 100
        expected.trialEndsAt = 900
        expected.trialLease = "T"
        #expect(merged(latest, answer, Basis(answer: asked)) == expected)
    }

    @Test func keepsOnlyTheTrialEvidenceOfANoteAboutAnActivationNoLongerStored() {
        let about = Basis(about: About(activationId: "act_1"))
        #expect(merged(StoredState(activationId: "act_2"), [.keptMajor: .int(3)], about) == StoredState(activationId: "act_2"))
        #expect(merged(StoredState(activationId: "act_1"), [.keptMajor: .int(3)], about) == StoredState(activationId: "act_1", keptMajor: 3))
        #expect(merged(StoredState(), [.keptMajor: .int(3)], about) == StoredState())
    }

    @Test func keepsTheVerdictOfANewerAnswerAndSavesTheRestOfAnOlderOne() {
        let latest = StoredState(activationId: "act_1", refused: .revoked, verdictAt: 2_000)
        #expect(merged(latest, answer, Basis(answer: asked)) == StoredState(
            activationId: "act_1", trialStart: 100, trialEndsAt: 900, trialLease: "T", keptMajor: 3, refused: .revoked,
            deviceKind: .machine, verdictAt: 2_000
        ))
    }

    @Test func anActivationsAnswer() {
        let activated: StatePatch = [
            .key: .string("K"), .activationId: .string("act_1"), .lease: .string("LA"), .checkedMajor: .int(2),
            .deviceKind: .deviceKind(.machine),
        ] + leased
        let refusedLater = StoredState(key: "K", activationId: "act_1", refused: .revoked, verdictAt: 2_000)
        // The same seat, under a refusal asked for later: the key and kind land, not the lease.
        #expect(merged(refusedLater, activated, Basis(activation: Asked(at: 1_000, activationId: "act_1", seen: 500))) == StoredState(
            key: "K", activationId: "act_1", refused: .revoked, deviceKind: .machine, verdictAt: 2_000
        ))
        // The same seat, over the verdict it saw: lands whole.
        let over = merged(refusedLater, activated, Basis(activation: Asked(at: 1_000, activationId: "act_1", seen: 2_000)))
        #expect(over.lease == "LA" && over.checkedMajor == 2 && over.verdictAt == 1_000 && over.refused == nil)
        // Another activation: lands whole, whatever was stored.
        var other = activated
        other[.activationId] = .string("act_2")
        let fresh = merged(refusedLater, other, Basis(activation: Asked(at: 1_000, activationId: "act_2")))
        #expect(fresh.activationId == "act_2" && fresh.lease == "LA" && fresh.verdictAt == 1_000 && fresh.refused == nil)
    }

    @Test(arguments: [
        ("a lower one noted", 5, Int?.some(3), Basis(about: About(activationId: "act_1")), Int?.some(5)),
        ("a higher one noted", 3, 5, Basis(about: About(activationId: "act_1")), 5),
        ("an answer that noted none", 5, nil, Basis(answer: Asked(at: 1, activationId: "act_1")), 5),
        ("a deactivation, based on nothing", 5, nil, Basis(), nil),
        ("a fresh activation", 5, nil, Basis(activation: Asked(at: 1, activationId: "act_2")), nil),
        ("an activation of the same seat", 5, 3, Basis(activation: Asked(at: 1, activationId: "act_1")), 5),
    ])
    func theKeptMajorOnlyGoesUpForTheStoredActivation(_ name: String, stored: Int, noted: Int?, basis: Basis, expected: Int?) {
        let saved = merged(StoredState(activationId: "act_1", keptMajor: stored), [.keptMajor: .int(orClear: noted)], basis)
        #expect(saved.keptMajor == expected, "\(name)")
    }

    @Test func stampsAnAnswerAndATrialAnswerWithWhenTheyWereAskedFor() {
        #expect(merged(StoredState(activationId: "act_1"), [.lease: .string("L")], Basis(answer: asked)).verdictAt == 1_000)
        #expect(merged(StoredState(), [.trialEndsAt: .int(9)], Basis(trial: Stamp(at: 7))) == StoredState(trialEndsAt: 9, trialAt: 7))
    }

    @Test func aTrialAnswerIsTakenWholeFromTheNewest() {
        let stored = StoredState(trialStart: 50, trialEndsAt: 500, trialLease: "NEWER", trialAt: 2_000)
        // Loses its end and lease to a newer one stored since, whichever ends first.
        for end in [400, 600] {
            let older: StatePatch = [.trialStart: .int(60), .trialEndsAt: .int(end), .trialLease: .string("OLDER")]
            #expect(merged(stored, older, Basis(trial: Stamp(at: 1_000))) == stored)
        }
        // Wins over an older one, a later end included (a trial the server extended).
        let extended: StatePatch = [.trialStart: .int(60), .trialEndsAt: .int(900), .trialLease: .string("EXT")]
        #expect(merged(stored, extended, Basis(trial: Stamp(at: 3_000))) == StoredState(trialStart: 50, trialEndsAt: 900, trialLease: "EXT", trialAt: 3_000))
        // Wins over a stored one with no stamp (an older SDK's).
        let unstamped = StoredState(trialEndsAt: 500, trialLease: "OLD")
        #expect(merged(unstamped, [.trialEndsAt: .int(400), .trialLease: .string("NEW")], Basis(trial: Stamp(at: 1))) == StoredState(
            trialEndsAt: 400, trialLease: "NEW", trialAt: 1
        ))
        // Wins over the one it saw, even stamped later (a clock put back).
        let mine = merged(stored, [.trialEndsAt: .int(300), .trialLease: .string("MINE")], Basis(trial: Stamp(at: 1_000, seen: 2_000)))
        #expect(mine.trialEndsAt == 300 && mine.trialLease == "MINE" && mine.trialAt == 1_000)
    }

    @Test func theTrialStartCannotBeClearedByAPatch() {
        #expect(merged(StoredState(trialStart: 5), [.trialStart: .clear]).trialStart == 5)
    }

    @Test func noStoredValueCanOverflowTheArithmetic() {
        // A state a custom storage adapter built in code: any value at all.
        #expect(askDue(StoredState(backoffSince: Int.min, backoffMs: Int.max), clockNow: Int.max, force: false))
        #expect(trialStatusOf(StoredState(trialEndsAt: Int.max), now: Int.min, leaseValid: true).trialDaysLeft == Int.max / Waits.dayMs + 1)
        #expect(trialStatusOf(StoredState(trialEndsAt: Int.min), now: Int.max, leaseValid: true).trialDaysLeft == 0)
        #expect(trialStatusOf(StoredState(trialStart: 0), now: Int.min, leaseValid: true, leaseEndsAt: Int.max).trialDaysLeft == Int.max / Waits.dayMs + 1)
    }

    @Test func aCustomStorageMayHoldAnyValueAndStatusStillAnswers() async throws {
        let h = try Harness(StoredState(
            key: KEY, activationId: "act_1", lease: "x", trialStart: Int.min, trialEndsAt: Int.max, lastSeen: Int.max,
            backoffSince: Int.min, backoffMs: Int.max, refusedMajor: Int.min, verdictAt: Int.max, rev: Int.max
        ))
        h.http.setFail(true)
        #expect(await h.license.status() == LicenseStatus(state: .invalid, reason: .tampered))
    }
}

@Suite("the wire", suiteTimeLimit)
struct WireTests {
    @Test func trimsAsJavaScriptTrims() {
        #expect(jsTrim("\u{0085}k\u{0085}") == "\u{0085}k\u{0085}")
        #expect(jsTrim("\u{180E}k") == "\u{180E}k")
        #expect(jsTrim("\u{FEFF}\u{2028}\u{3000} k \t\r\n") == "k")
        #expect(jsTrim(" \u{00A0} ") == "")
    }

    @Test func upperCasesAsJavaScriptDoes() {
        #expect(enteredKey("straße") == "STRASSE")
        #expect(enteredKey("\u{FB01}x") == "FIX")
    }

    @Test func cutsAtTheUnitBeforeAnOrphanedHighSurrogate() {
        #expect(trimToLength("ab😀", 3) == "ab")
        #expect(trimToLength("ab😀", 4) == "ab😀")
        #expect(trimToLength(nil, 3) == nil)
        #expect(trimToLength("abc", 0) == "")
    }

    @Test func readsTheTrialBodyAsTheReferenceDoes() {
        #expect(parseTrialBody(["trialStart": 1.5, "trialEndsAt": 2]) == TrialBody(trialStart: 1, trialEndsAt: 2))
        #expect(parseTrialBody(["trialStart": 1, "trialEndsAt": "2"]) == nil)
    }
}
