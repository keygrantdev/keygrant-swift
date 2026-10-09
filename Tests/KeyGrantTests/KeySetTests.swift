import Foundation
import Testing

@testable import KeyGrant

/// A key set (`LicenseConfig.publicJWK` holding several keys): a lease verified by the key it
/// names, the ids of the keys reported at each check-in, a lease signed by a key the build does
/// not carry; and `has(_:)` and `require(_:)`, read offline from the stored lease.
@Suite struct KeySetTests {
    /// A lease for the harness's licence, signed by `signer` under a header naming `kid`, granting `ent`.
    func lease(_ signer: Signer, kid: String?, ent: [String: LicenseJSON] = [:], ttl: Int = 30 * 24 * 3600) -> String {
        let iat = NOW / 1000
        let claims: LicenseJSON = [
            "iss": "keygrant", "sub": .string(KEY), "product": .string(PRODUCT), "aid": "act_1", "model": "perpetual",
            "lim": 3, "major": 1, "ent": .object(ent), "iat": .number(Double(iat)), "exp": .number(Double(iat + ttl)),
        ]
        guard let kid else { return signer.sign(payload: claims) }
        // The header byte for byte as the server writes it: only that form names a key.
        let header = base64URLEncode(Data(#"{"alg":"EdDSA","typ":"JWT","kid":"\#(kid)"}"#.utf8))
        let payload = base64URLEncode(Data((claims.jsonText).utf8))
        return signer.sign(input: "\(header).\(payload)")
    }

    /// The harness's app, built again with `publicJWK` (its storage, clock, device and server kept).
    func build(_ h: Harness, _ publicJWK: String) throws -> License {
        try License(
            LicenseConfig(
                product: PRODUCT, apiBaseURL: apiBase, publicJWK: publicJWK,
                adapters: LicenseAdapters(storage: h.storage, registry: h.registry, clock: h.clock, fingerprinter: h.fingerprinter, http: h.http)
            ),
            timing: h.timing
        )
    }

    func set(_ signers: Signer...) -> String { "{\"keys\":[\(signers.map(\.publicJWK).joined(separator: ","))]}" }

    @Test func activatesOnALeaseTheStagedKeySignedWhenTheBuildCarriesItAndReportsItsKeyIds() async throws {
        let h = try Harness()
        let next = Signer()
        let signed = lease(next, kid: next.kid)
        h.http.on("activate", status: 200, json: ["lease": .string(signed), "activationId": "act_1"])
        let app = try build(h, set(h.signer, next))
        #expect(await app.activate(KEY) == .activated)
        #expect(h.http.body("activate")?["kids"] == .array([.string(h.signer.kid), .string(next.kid)]))
        #expect(h.stored?.lease == signed)
    }

    @Test func refusesAnActivationWhoseLeaseNamesAKeyTheBuildDoesNotCarry() async throws {
        let h = try Harness()
        let next = Signer()
        h.http.on("activate", status: 200, json: ["lease": .string(lease(next, kid: next.kid)), "activationId": "act_1"])
        #expect(await h.license.activate(KEY) == .failed(.invalidLease))
        #expect(h.stored?.lease == nil)
    }

    @Test func answersAStoredLeaseSignedByAKeyTheBuildDoesNotCarryAsUnknownKeyWithTheKey() async throws {
        let next = Signer()
        let h = try Harness(StoredState(key: KEY, activationId: "act_1", lease: lease(next, kid: next.kid)))
        h.http.setFail(true)
        #expect(await h.license.status() == LicenseStatus(state: .invalid, reason: .unknownKey, key: KEY))
    }

    @Test func sendsTheIdsOfTheKeysItCarriesWithEachValidate() async throws {
        let h = try Harness()
        h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: h.sign(ttl: 2 * 24 * 3600)))
        h.http.on("validate", status: 503, json: [:])
        _ = await h.license.refresh()
        #expect(h.http.body("validate")?["kids"] == .array([.string(h.signer.kid)]))
    }

    @Test func takesOneKeyAsASetOfOneALeaseNamingItsKeyVerifiesAndOneNamingNone() async throws {
        let h = try Harness()
        h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: lease(h.signer, kid: h.signer.kid)))
        #expect(await h.license.status().state == .licensed)
        h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: lease(h.signer, kid: nil)))
        #expect(await h.license.status().state == .licensed)
    }

    @Test func readsAJWKSetAListOneJWKOrAnX() throws {
        let one = Signer()
        let x = try #require(JSONText.parse(one.publicJWK)?["x"]?.stringValue)
        for text in [set(one), "[\(one.publicJWK),\(one.publicJWK)]", one.publicJWK, x] {
            #expect(try KeySet(publicJWK: text).kids == [one.kid], "\(text)")
        }
        #expect(throws: LicenseConfigError.self) { try KeySet(publicJWK: "{\"keys\":[]}") }
        #expect(throws: LicenseConfigError.self) { try KeySet(publicJWK: "[]") }
        #expect(throws: LicenseConfigError.self) { try KeySet(publicJWK: "{\"keys\":[{\"kty\":\"EC\"}]}") }
        // A JWK whose `keys` member is not a list is refused, never read as the one JWK it also is.
        #expect(throws: LicenseConfigError.self) { try KeySet(publicJWK: String(one.publicJWK.dropLast()) + ",\"keys\":\"x\"}") }
    }

    func licensed(_ ent: [String: LicenseJSON]) throws -> Harness {
        let h = try Harness()
        h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: lease(h.signer, kid: nil, ent: ent)))
        return h
    }

    let ent: [String: LicenseJSON] = ["cloud": true, "beta": false, "seats": 0, "devices": 5, "edition": "pro", "blank": ""]

    @Test func hasAnswersFromTheStoredLeaseAFlagOnANumberNotZeroATextNotEmpty() async throws {
        let h = try licensed(ent)
        #expect(await h.license.has("cloud"))
        #expect(await !h.license.has("beta"))
        #expect(await !h.license.has("seats"))
        #expect(await h.license.has("devices"))
        #expect(await h.license.has("edition"))
        #expect(await !h.license.has("blank"))
        #expect(await !h.license.has("export"))
        #expect(await !h.license.has("Cloud"))
    }

    @Test func hasNeverGoesOnlineAndNeverWrites() async throws {
        let h = try licensed(ent)
        // A lease near its end, which status() would renew.
        h.clock.set(NOW + 29 * 86_400_000)
        let writes = h.storage.writes
        #expect(await h.license.has("cloud"))
        #expect(h.http.calls.isEmpty)
        #expect(h.storage.writes == writes)
    }

    @Test func hasGrantsNothingOnALeaseThatDoesNotLicenseThisBuildNorWithNoLicence() async throws {
        let h = try licensed(ent)
        h.clock.set(NOW + 31 * 86_400_000)
        #expect(await !h.license.has("cloud"))
        h.storage.set(nil)
        #expect(await !h.license.has("cloud"))
    }

    @Test func hasGrantsNothingAndDoesNotThrowWhileTheStateCannotBeRead() async throws {
        let h = try licensed(ent)
        h.storage.failRead(1)
        #expect(await !h.license.has("cloud"))
    }

    @Test func hasGrantsNothingOverAStoredRefusalThoughTheLeaseItKeptStillVerifies() async throws {
        let h = try Harness()
        let kept = lease(h.signer, kid: nil, ent: ent)
        // The server refused this build's major: the lease is kept for builds it covers.
        h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: kept, lastSeen: NOW, checkedMajor: 1, refused: .upgrade, refusedMajor: 1))
        #expect(await !h.license.has("cloud"))
        // Revoked: the refusal stands over any lease still held.
        h.storage.set(StoredState(key: KEY, activationId: "act_1", lease: kept, lastSeen: NOW, checkedMajor: 1, refused: .revoked))
        #expect(await !h.license.has("cloud"))
    }

    @Test func hasGrantsDuringARunningTrialWhatItsTrialLeaseSignsAndAsksNothing() async throws {
        let h = try Harness()
        let claim = fingerprintClaim("fp-test")
        let iat = NOW / 1000
        let claims: LicenseJSON = [
            "iss": "keygrant", "sub": .string("trial:\(claim)"), "product": .string(PRODUCT), "aid": .string(claim), "fpk": "machine",
            "model": "trial", "lim": 1, "major": .number(Double(openMajor)), "ent": ["cloud": true],
            "iat": .number(Double(iat)), "exp": .number(Double(iat + 5 * 86_400)),
        ]
        h.storage.set(StoredState(trialStart: NOW - 2 * 86_400_000, trialEndsAt: NOW + 5 * 86_400_000, trialLease: h.signer.sign(payload: claims), lastSeen: NOW))
        #expect(await h.license.has("cloud"))
        #expect(await !h.license.has("export"))
        #expect(h.http.calls.isEmpty)
    }

    @Test func requirePassesForAGrantedCodeAndThrowsNamingTheCodeOtherwise() async throws {
        let h = try licensed(ent)
        try await h.license.require("cloud")
        await #expect(throws: MissingEntitlement(entitlement: "seats")) { try await h.license.require("seats") }
    }
}
