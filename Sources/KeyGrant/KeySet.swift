import Crypto
import Foundation

// The product's public keys: the set a build carries, each key's id, and the key a lease names.

/// What a lease's header is, up to the key id it names.
let leaseHeaderStart = #"{"alg":"EdDSA","typ":"JWT","kid":""#

/// The key a lease's header names (`kid`), or nil when it names none. A header names a key only when
/// it is, byte for byte, the header the server writes for one: canonical base64url of
/// `{"alg":"EdDSA","typ":"JWT","kid":"<kid>"}`, `<kid>` 1 to 64 characters of the base64url alphabet.
/// Any other header names no key. It is matched as bytes, never parsed. A licence file's header is
/// matched the same way from its own start (`licenseFileHeaderStart`).
func keyId(ofHeader header: String, start startText: String = leaseHeaderStart) -> String? {
    guard let bytes = canonicalBase64URLDecode(header) else { return nil }
    let start = Array(startText.utf8)
    let end = Array(#""}"#.utf8)
    let all = Array(bytes)
    guard all.count >= start.count + end.count, all.starts(with: start), all.suffix(end.count).elementsEqual(end) else { return nil }
    let kid = all[start.count..<(all.count - end.count)]
    let base64url: (UInt8) -> Bool = { b in
        (0x41...0x5A).contains(b) || (0x61...0x7A).contains(b) || (0x30...0x39).contains(b) || b == 0x2D || b == 0x5F
    }
    guard (1...64).contains(kid.count), kid.allSatisfy(base64url) else { return nil }
    return String(decoding: kid, as: UTF8.self)
}

/// A key's id, the `kid` a lease's header names it by: its RFC 7638 thumbprint, the base64url (no
/// padding) of the SHA-256 of `{"crv":"Ed25519","kty":"OKP","x":"<x>"}`, with `x` the key's 32
/// bytes written canonically. Computed from the key itself, so a JWK with no `kid` member has one
/// all the same.
func keyId(ofKey raw: Data) -> String {
    let members = "{\"crv\":\"Ed25519\",\"kty\":\"OKP\",\"x\":\"\(base64URLEncode(raw))\"}"
    return base64URLEncode(Data(SHA256.hash(data: Data(members.utf8))))
}

/// A product's key set: the key that signs its leases, and the next one once the product has one
/// staged, each raw with its id, in the order given, a key given twice kept once.
struct KeySet: Sendable, Hashable {
    struct Key: Sendable, Hashable {
        var kid: String
        var key: Data

        /// Whether `signature` is this key's Ed25519 signature over `signed`. Bytes that are not
        /// a point on the curve, and a signature of any length but 64 bytes, verify nothing.
        func verifies(_ signature: Data, for signed: Data) -> Bool {
            guard signature.count == 64, let key = try? Curve25519.Signing.PublicKey(rawRepresentation: key) else { return false }
            return key.isValidSignature(signature, for: signed)
        }
    }

    let keys: [Key]

    /// The set of raw keys, which must not be empty.
    init(raw: [Data]) throws {
        var keys: [Key] = []
        for key in raw {
            let kid = keyId(ofKey: key)
            if !keys.contains(where: { $0.kid == kid }) { keys.append(Key(kid: kid, key: key)) }
        }
        guard !keys.isEmpty else { throw LicenseConfigError.invalidPublicKey("the key set holds no key") }
        self.keys = keys
    }

    /// The set from `publicJWK`: a JWK set (`{"keys":[...]}`, as `/pubkey` answers it), a JSON list
    /// of JWKs, or one key as `publicKeyBytes(fromJWK:)` reads it, a set of one.
    init(publicJWK text: String) throws {
        let trimmed = jsTrim(text)
        var list: [LicenseJSON]?
        if trimmed.hasPrefix("[") {
            guard case .array(let items)? = JSONText.parse(trimmed) else {
                throw LicenseConfigError.invalidPublicKey("not a JSON list of keys")
            }
            list = items
        } else if trimmed.hasPrefix("{"), case .object(let members)? = JSONText.parse(trimmed), let keys = members["keys"] {
            guard case .array(let items) = keys else { throw LicenseConfigError.invalidPublicKey("its keys are not a list") }
            list = items
        }
        guard let list else {
            try self.init(raw: [publicKeyBytes(fromJWK: trimmed)])
            return
        }
        try self.init(raw: list.map { item in
            guard case .object(let jwk) = item else { throw LicenseConfigError.invalidPublicKey("a key is not a JSON object") }
            return try publicKeyBytes(jwk: jwk)
        })
    }

    /// The ids of its keys, in its order: what a check-in reports as `kids`.
    var kids: [String] { keys.map(\.kid) }

    /// Whether the set holds a key whose id is `kid` (matched exactly) and `signature` is its
    /// Ed25519 signature of 64 bytes over `signed`; nil when the set holds no such key. Only that key
    /// is tried.
    func signedByNamed(_ kid: String, signature: Data, signed: Data) -> Bool? {
        keys.first(where: { $0.kid == kid })?.verifies(signature, for: signed)
    }
}

/// The raw Ed25519 key a product's public JWK holds (or its bare `x`), checked as every KeyGrant SDK
/// checks one: `kty` OKP and `crv` Ed25519, no private `d`, `use` (when given) `sig`, `key_ops` (when
/// given) a list naming `verify`, `alg` (when given) EdDSA or Ed25519, and an `x` of 32 bytes in
/// canonical base64url once its trailing `=` are dropped. No other member is read.
func publicKeyBytes(fromJWK text: String) throws -> Data {
    let trimmed = jsTrim(text)
    guard trimmed.hasPrefix("{") else { return try publicKeyBytes(x: trimmed) }
    guard case .object(let jwk)? = JSONText.parse(trimmed) else {
        throw LicenseConfigError.invalidPublicKey("not a JSON object")
    }
    return try publicKeyBytes(jwk: jwk)
}

/// The raw key of a parsed public JWK, checked as `publicKeyBytes(fromJWK:)` says.
func publicKeyBytes(jwk: [String: LicenseJSON]) throws -> Data {
    guard jwk["kty"]?.stringValue == "OKP", jwk["crv"]?.stringValue == "Ed25519" else {
        throw LicenseConfigError.invalidPublicKey("not an Ed25519 key (kty OKP, crv Ed25519)")
    }
    guard jwk["d"] == nil else {
        throw LicenseConfigError.invalidPublicKey("it holds the PRIVATE key (d): embed only the public key")
    }
    if let use = jwk["use"], use.stringValue != "sig" {
        throw LicenseConfigError.invalidPublicKey("its use is not sig")
    }
    if let ops = jwk["key_ops"], !(ops.arrayValue ?? []).contains(.string("verify")) {
        throw LicenseConfigError.invalidPublicKey("its key_ops do not include verify")
    }
    if let alg = jwk["alg"], !["EdDSA", "Ed25519"].contains(alg.stringValue ?? "") {
        throw LicenseConfigError.invalidPublicKey("its alg is not EdDSA")
    }
    guard let value = jwk["x"]?.stringValue else { throw LicenseConfigError.invalidPublicKey("no x") }
    return try publicKeyBytes(x: value)
}

/// The raw key of a JWK's `x`: 32 bytes of canonical base64url, once the trailing `=` a key pasted
/// with padding has are dropped.
func publicKeyBytes(x: String) throws -> Data {
    var unpadded = Substring(x)
    while unpadded.hasSuffix("=") { unpadded = unpadded.dropLast() }
    guard let bytes = canonicalBase64URLDecode(String(unpadded)), bytes.count == 32 else {
        throw LicenseConfigError.invalidPublicKey("x is not 32 bytes of base64url")
    }
    return bytes
}
