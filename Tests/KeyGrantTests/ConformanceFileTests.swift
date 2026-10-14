import Foundation
import Testing

@testable import KeyGrant

/// The licence-file groups of `conformance/vectors.json`, after the key-set groups: a file's
/// container read for its token, a file's token verified, judged and given as a status, and a file
/// given where a lease goes, answered from each vector's own JSON with the conventions of the other
/// groups (ConformanceTests.swift).
extension ConformanceTests {
    /// The token a file's content holds, or none.
    @Test func licenseFileContainers() throws {
        for vector in try group("licenseFileContainers") {
            let bytes = try #require(canonicalBase64URLDecode(try vector.string("bytes")), "\(vector.name): bytes")
            #expect((licenseFileToken(bytes).map(LicenseJSON.string) ?? .null) == vector["expect"], "\(vector.name)")
        }
    }

    /// A file verified against a key set, judged for a product, a build and a denylist, and the status
    /// it gives stored.
    @Test func licenseFiles() throws {
        for vector in try group("licenseFiles") {
            let keys = try KeySet(publicJWK: try #require(vector["keys"]).jsonText)
            let verified = verifyLicenseFile(try vector.string("token"), keys: keys)
            #expect(verified.json == vector["verify"], "\(vector.name): verify")
            let revoked = try #require(vector["revoked"]?.arrayValue).compactMap(\.stringValue)
            let check = checkLicenseFile(verified, product: try vector.string("product"), major: try vector.int("major"), revoked: revoked)
            #expect(check.json == vector["expect"], "\(vector.name): expect")
            #expect(licenseFileStatus(check).json == vector["status"], "\(vector.name): status")
        }
    }

    /// A file given where a lease goes: refused by the lease verifier as it is, and never a trial lease.
    @Test func filesAsLeases() throws {
        let key = try KeySet(publicJWK: try #require(Self.file?["publicJwk"]).jsonText)
        for vector in try group("filesAsLeases") {
            let claims = try #require(vector["holder"]?["claims"]?.arrayValue).compactMap(\.stringValue)
            let canTell = try vector.bool("holder", "canTell")
            let holder = LeaseHolder(
                key: try vector.string("holder", "key"), activationId: try vector.string("holder", "activationId"),
                claims: claims, canTell: canTell
            )
            let verified = verifyLease(try vector.string("token"), keys: key, now: try vector.int("now"))
            #expect(verified.json == vector["verify"], "\(vector.name): verify")
            let check = checkLease(verified, product: try vector.string("product"), major: try vector.int("major"), holder: holder)
            #expect(check.json == vector["expect"], "\(vector.name): expect")
            let trial = trialLeaseValid(verified, product: try vector.string("product"), claims: claims, canTell: canTell)
            #expect(.bool(trial) == vector["trial"], "\(vector.name): trial")
        }
    }
}

extension FileVerifyResult {
    /// As the vectors say it: `{valid, reason?, claims?}`.
    var json: LicenseJSON {
        switch self {
        case .valid(let claims): ["valid": true, "claims": claims.json]
        case .invalid(let failure): ["valid": false, "reason": .string(failure.rawValue)]
        }
    }
}

extension LicenseFileCheck {
    /// As the vectors say it: `{ok: true, kind, test}` or `{ok: false, reason}`.
    var json: LicenseJSON {
        switch self {
        case .taken(let claims): ["ok": true, "kind": .string(claims.kind.rawValue), "test": .bool(claims.test == true)]
        case .refused(let error, _): ["ok": false, "reason": .string(error.rawValue)]
        }
    }
}
