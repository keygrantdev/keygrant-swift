import Foundation
import Testing

@testable import KeyGrant

/// The key-set groups of `conformance/vectors.json`, after the purchase groups: a key's id, a lease
/// verified against a key set, and whether entitlements grant a code, answered from each vector's
/// own JSON with the conventions of the other groups (ConformanceTests.swift).
extension ConformanceTests {
    /// A key's id (`kid`): its RFC 7638 thumbprint.
    @Test func keyIds() throws {
        for vector in try group("keyIds") {
            // null for a JWK the SDK refuses.
            let raw = try? publicKeyBytes(fromJWK: try #require(vector["jwk"]).jsonText)
            #expect((raw.map { LicenseJSON.string(keyId(ofKey: $0)) } ?? .null) == vector["expect"], "\(vector.name)")
        }
    }

    /// A lease verified against a key set, and the set's ids.
    @Test func keySets() throws {
        for vector in try group("keySets") {
            let set = try KeySet(publicJWK: try #require(vector["keys"]).jsonText)
            #expect(.array(set.kids.map(LicenseJSON.string)) == vector["kids"], "\(vector.name): kids")
            let verified = verifyLease(try vector.string("token"), keys: set, now: try vector.int("now"))
            #expect(verified.json == vector["verify"], "\(vector.name): verify")
        }
    }

    /// Whether entitlements, read as a lease's `ent` is read, grant a code (`grants`).
    @Test func grantsGroup() throws {
        for vector in try group("grants") {
            let ent = entitlementsOf(vector["ent"])
            #expect(.bool(grants(ent, try vector.string("code"))) == vector["expect"], "\(vector.name)")
        }
    }
}
