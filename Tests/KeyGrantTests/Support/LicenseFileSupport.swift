import Foundation

@testable import KeyGrant

// Licence-file test support: Ada's offline file and key file signed as the server signs them, a
// file's text, the statuses a file gives, and the harness's app rebuilt with a denylist.

let adaName = "Ada Lovelace"
let adaEmail = "ada@example.com"
let ada = LicensedTo(name: adaName, email: adaEmail)

extension Signer {
    /// Ada's OFFLINE file (`lf_1`, this product's `KEY`, majors 1 to 3, issued at NOW) with `over`
    /// laid over its claims (`null` removes one), signed under a file header naming this key.
    func offlineFile(_ over: [String: LicenseJSON] = [:]) -> String {
        licenseFile([
            "iss": "keygrant", "kind": "offline", "fid": "lf_1", "sub": .string(KEY), "product": .string(PRODUCT),
            "name": .string(adaName), "email": .string(adaEmail), "major": 3, "ent": [:], "iat": .number(Double(NOW / 1000)),
        ], over)
    }

    /// Ada's KEY file (`lf_2`, `KEY` in lower case, her email alone), with `over` laid over it.
    func keyFile(_ over: [String: LicenseJSON] = [:]) -> String {
        licenseFile([
            "iss": "keygrant", "kind": "key", "fid": "lf_2", "sub": .string(KEY.lowercased()), "product": .string(PRODUCT),
            "email": .string(adaEmail), "iat": .number(Double(NOW / 1000)),
        ], over)
    }

    private func licenseFile(_ claims: [String: LicenseJSON], _ over: [String: LicenseJSON]) -> String {
        var claims = claims
        for (name, value) in over {
            claims[name] = value.isNull ? nil : value
        }
        let header = base64URLEncode(Data(#"{"alg":"EdDSA","typ":"kglicense+jwt","kid":"\#(kid)"}"#.utf8))
        return sign(input: "\(header).\(base64URLEncode(JSONText.data(.object(claims))))")
    }
}

/// A licence file's text as the server writes one: notes, then the token on a line of its own, CRLF
/// as a mail gateway may leave it.
func licenseFileText(_ token: String) -> String {
    "# KeyGrant license file\r\n# Product: \(PRODUCT)\r\n\r\n\(token)\r\n"
}

/// `token` with its payload swapped for `other`'s, under its own header and signature.
func payloadSwapped(_ token: String, _ other: String) -> String {
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    let payload = other.split(separator: ".", omittingEmptySubsequences: false)[1]
    return "\(parts[0]).\(payload).\(parts[2])"
}

/// What a status gives for Ada's offline file.
let fileLicensed = LicenseStatus(state: .licensed, key: KEY, source: .file, licensedTo: ada)

/// A stored file's status that does not license this build, with whose it is.
func fileInvalid(_ reason: LicenseReason) -> LicenseStatus {
    LicenseStatus(state: .invalid, reason: reason, key: KEY, source: .file, licensedTo: ada)
}

/// A stored file's status with nothing of the file read.
func fileUnread(_ reason: LicenseReason) -> LicenseStatus {
    LicenseStatus(state: .invalid, reason: reason, source: .file)
}

/// `KEY` licensed by its lease.
let keyLicensed = LicenseStatus(state: .licensed, key: KEY)

extension Harness {
    /// The harness's app as major 2, its adapters kept, with `revoked` as its denylist and `keys` as
    /// its key set (the harness's key when none).
    func fileApp(revoked: [String] = [], keys: String? = nil) throws -> License {
        try License(
            LicenseConfig(
                product: PRODUCT,
                apiBaseURL: apiBase,
                publicJWK: keys ?? signer.publicJWK,
                major: 2,
                revokedLicenseFiles: revoked,
                adapters: LicenseAdapters(storage: storage, registry: registry, clock: clock, fingerprinter: fingerprinter, http: http)
            ),
            timing: timing
        )
    }

    /// A licence lease for `KEY` on act_1, covering majors 1 to 3, for thirty days.
    func leaseTo3(at: Int = NOW) -> String {
        signer.lease(major: 3, at: at)
    }
}
