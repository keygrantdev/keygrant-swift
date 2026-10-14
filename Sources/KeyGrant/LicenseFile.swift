import Foundation

// Licence files: the token a file's content holds, and the token verified against a key set. A
// licence file is a compact JWS signed with the product's Ed25519 key, as a lease is, but never taken
// for one, either way: its header is exactly `{"alg":"EdDSA","typ":"kglicense+jwt","kid":"<kid>"}`,
// and its claims carry none of the `aid`, `lim`, `exp` and `model` every lease reader requires.

/// What a licence file's header is, up to the key id it names.
let licenseFileHeaderStart = #"{"alg":"EdDSA","typ":"kglicense+jwt","kid":""#

/// The token a licence file's content holds, or nil when it is no licence file's container: more
/// than `maxLicenseFileBytes`; not UTF-8 (read strictly); or not exactly one line once each line
/// (split on LF) is trimmed of spaces, tabs and carriage returns at both ends, and empty lines and
/// lines starting with `#` are left out. One leading byte-order mark is dropped; a lone CR breaks
/// no line. Whether the token is a licence file's at all is `verifyLicenseFile`'s to say.
func licenseFileToken(_ content: Data) -> String? {
    guard content.count <= maxLicenseFileBytes else { return nil }
    var bytes = [UInt8](content)
    guard isStrictUTF8(bytes) else { return nil }
    if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
    let edges: Set<UInt8> = [0x20, 0x09, 0x0D]
    var token: ArraySlice<UInt8>?
    for line in bytes.split(separator: 0x0A, omittingEmptySubsequences: false) {
        let trimmed = line.drop(while: edges.contains).reversed().drop(while: edges.contains).reversed()
        guard let first = trimmed.first, first != 0x23 else { continue }
        if token != nil { return nil }
        token = ArraySlice(trimmed)
    }
    return token.map { String(decoding: $0, as: UTF8.self) }
}

/// Whether `bytes` are well-formed UTF-8 (RFC 3629): no overlong form, no surrogate, nothing past
/// U+10FFFF, no sequence cut short. A strict decoder refuses anything else.
func isStrictUTF8(_ bytes: [UInt8]) -> Bool {
    var index = 0
    while index < bytes.count {
        let lead = bytes[index]
        let (count, low, high): (Int, UInt8, UInt8)
        switch lead {
        case 0x00...0x7F: index += 1; continue
        case 0xC2...0xDF: (count, low, high) = (1, 0x80, 0xBF)
        case 0xE0: (count, low, high) = (2, 0xA0, 0xBF)
        case 0xE1...0xEC, 0xEE...0xEF: (count, low, high) = (2, 0x80, 0xBF)
        case 0xED: (count, low, high) = (2, 0x80, 0x9F)
        case 0xF0: (count, low, high) = (3, 0x90, 0xBF)
        case 0xF1...0xF3: (count, low, high) = (3, 0x80, 0xBF)
        case 0xF4: (count, low, high) = (3, 0x80, 0x8F)
        default: return false
        }
        // Every continuation byte there, the first in its narrower range (no overlong form, no
        // surrogate, nothing past U+10FFFF).
        guard index + count < bytes.count else { return false }
        guard (low...high).contains(bytes[index + 1]) else { return false }
        for next in bytes[(index + 2)..<(index + 1 + count)] where !(0x80...0xBF).contains(next) { return false }
        index += 1 + count
    }
    return true
}

/// A licence file's claims, as the reference's schema reads them. Numbers are `Double`, as
/// JavaScript reads them, so majors are compared as the reference compares them.
struct LicenseFileClaims: Sendable, Hashable {
    var iss = "keygrant"
    var kind: LicenseFileKind
    var fid: String
    var sub: String
    var product: String
    var name: String?
    var email: String?
    var iat: Double
    var test: Bool?
    /// An offline file's highest major; 0 on a key file, whose versions are never read.
    var major: Double = 0
    /// An offline file's lowest major, when it names one.
    var minMajor: Double?
    /// An offline file's entitlements, read leniently as a lease's `ent` is.
    var ent: [String: Entitlement] = [:]
}

extension LicenseFileClaims {
    /// The claims a payload holds, or nil when they are not a licence file's: `iss` keygrant, `kind`
    /// key or offline, a non-empty `fid`, `sub` and `product`, a `name` and/or `email` (each non-empty
    /// when present; an optional claim present as `null` does not hold), a whole `iat` of at least 0,
    /// `test` a flag when present; an offline file's whole `major` of at least 1 and `minMajor` (when
    /// present) too, and its `ent` read leniently. A key file's versions and entitlements are not read.
    init?(json: LicenseJSON) {
        guard case .object(let claims) = json, claims["iss"]?.stringValue == "keygrant",
            let kind = claims["kind"]?.stringValue.flatMap(LicenseFileKind.init(rawValue:)),
            let fid = filled(claims["fid"]), let sub = filled(claims["sub"]), let product = filled(claims["product"]),
            let iat = claims["iat"]?.numberValue, isWhole(iat), iat >= 0,
            let name = present(claims["name"], filled), let email = present(claims["email"], filled),
            name != nil || email != nil,
            let test = present(claims["test"], { $0?.boolValue })
        else { return nil }
        self.init(kind: kind, fid: fid, sub: sub, product: product, name: name, email: email, iat: iat, test: test)
        guard kind == .offline else { return }
        guard let major = claims["major"]?.numberValue, isWhole(major), major >= 1,
            let minMajor = present(claims["minMajor"], { $0?.numberValue.flatMap { isWhole($0) && $0 >= 1 ? $0 : nil } })
        else { return nil }
        self.major = major
        self.minMajor = minMajor
        ent = entitlementsOf(claims["ent"])
    }

    /// The claims as JSON, as the reference's schema gives them back: absent claims left out, an
    /// offline file's `ent` always there, a key file's versions and entitlements never.
    var json: LicenseJSON {
        var members: [String: LicenseJSON] = [
            "iss": .string(iss), "kind": .string(kind.rawValue), "fid": .string(fid), "sub": .string(sub),
            "product": .string(product), "iat": .number(iat),
        ]
        if let name { members["name"] = .string(name) }
        if let email { members["email"] = .string(email) }
        if let test { members["test"] = .bool(test) }
        if kind == .offline {
            members["major"] = .number(major)
            if let minMajor { members["minMajor"] = .number(minMajor) }
            members["ent"] = .object(ent.mapValues(\.json))
        }
        return .object(members)
    }
}

/// A non-empty string, or nil.
private func filled(_ value: LicenseJSON?) -> String? {
    guard let text = value?.stringValue, !text.isEmpty else { return nil }
    return text
}

/// An optional claim: `.some(nil)` when absent, `.some(value)` when present and of its type, and nil
/// (the claims do not hold) when present but not of its type, `null` included.
private func present<T>(_ value: LicenseJSON?, _ read: (LicenseJSON?) -> T?) -> T?? {
    guard let value else { return .some(nil) }
    guard let read = read(value) else { return nil }
    return .some(read)
}

/// Why a licence file's token does not verify.
enum FileVerifyFailure: String, Sendable, Hashable {
    case malformed
    case notALicenseFile = "not-a-license-file"
    case unknownKey = "unknown-key"
    case badSignature = "bad-signature"
    case badClaims = "bad-claims"
}

/// What verifying a licence file's token gave.
enum FileVerifyResult: Sendable, Hashable {
    case valid(LicenseFileClaims)
    case invalid(FileVerifyFailure)
}

/// A licence file's token verified against a key set, in this order: three parts (`malformed`); a
/// licence file's header, matched as bytes (`notALicenseFile`); the signature canonical base64url
/// (`malformed`); the key the header names in the set (`unknownKey`); a signature of 64 bytes verified
/// by THAT key alone (`badSignature`: no other key is tried); the payload canonical base64url of JSON
/// matching the claims (`badClaims`). It never expires, so there is no time to judge it at.
func verifyLicenseFile(_ token: String, keys: KeySet) -> FileVerifyResult {
    let parts = jsSplit(token, ".")
    guard parts.count == 3 else { return .invalid(.malformed) }
    let header = parts[0], payload = parts[1], signature = parts[2]
    guard let kid = keyId(ofHeader: header, start: licenseFileHeaderStart) else { return .invalid(.notALicenseFile) }
    guard let signatureBytes = canonicalBase64URLDecode(signature) else { return .invalid(.malformed) }
    guard let signed = keys.signedByNamed(kid, signature: signatureBytes, signed: Data("\(header).\(payload)".utf8)) else {
        return .invalid(.unknownKey)
    }
    guard signed else { return .invalid(.badSignature) }
    // Decoded as TextDecoder does, then read as JSON.parse reads it, as a lease's payload is.
    guard let payloadBytes = canonicalBase64URLDecode(payload), let json = JSONText.parse(decoding: payloadBytes),
        let claims = LicenseFileClaims(json: json)
    else { return .invalid(.badClaims) }
    return .valid(claims)
}
