import Crypto
import Foundation

/// The lease's `major` claim for a key with no upper bound.
let openMajor = 1_000_000

/// A lease's claims. Numbers are kept as `Double`, as JavaScript reads them, so every comparison
/// and sum is the reference's.
struct LeaseClaims: Sendable, Hashable {
    var iss = "keygrant"
    var sub: String
    var product: String
    var aid: String
    var fp: String?
    var fpk: DeviceKind?
    var model: String
    var lim: Double
    var major: Double
    var minMajor: Double?
    var upgradeUntil: Double?
    var ent: [String: Entitlement] = [:]
    var iat: Double
    var exp: Double
    var grace: Bool?
    var test: Bool?
}

/// The licence models a lease may name.
private let licenseModels: Set<String> = ["perpetual", "subscription", "trial"]

extension LeaseClaims {
    /// The claims a payload holds, checked as the server's claims schema checks them: nil when any
    /// does not hold. An optional claim present as `null` does not hold either, but for `ent`,
    /// which never fails the claims: it is read leniently (`entitlementsOf`). Claims it does not
    /// know are ignored.
    init?(json: LicenseJSON) {
        guard case .object(let claims) = json, claims["iss"]?.stringValue == "keygrant",
            let sub = nonEmptyString(claims["sub"]), let product = nonEmptyString(claims["product"]),
            let aid = nonEmptyString(claims["aid"]), let model = claims["model"]?.stringValue,
            licenseModels.contains(model)
        else { return nil }
        guard let lim = claims["lim"]?.numberValue, isWhole(lim), lim > 0 else { return nil }
        guard let iat = claims["iat"]?.numberValue, isWhole(iat), iat >= 0,
            let exp = claims["exp"]?.numberValue, isWhole(exp), exp >= 0
        else { return nil }
        guard let fp = optional(claims["fp"], { $0.stringValue.flatMap { (1...128).contains($0.utf16.count) ? $0 : nil } }),
            let fpk = optional(claims["fpk"], { $0.stringValue.flatMap(DeviceKind.init(rawValue:)) }),
            let major = optional(claims["major"], { wholeNumber($0, atLeast: 0) }),
            let minMajor = optional(claims["minMajor"], { wholeNumber($0, atLeast: 1) }),
            let upgradeUntil = optional(claims["upgradeUntil"], { wholeNumber($0, atLeast: 0) }),
            let grace = optional(claims["grace"], { $0.boolValue }),
            let test = optional(claims["test"], { $0.boolValue })
        else { return nil }
        self.init(
            sub: sub, product: product, aid: aid, fp: fp, fpk: fpk, model: model, lim: lim,
            major: major ?? 0, minMajor: minMajor, upgradeUntil: upgradeUntil, ent: entitlementsOf(claims["ent"]),
            iat: iat, exp: exp, grace: grace, test: test
        )
    }
}

/// An optional claim: `.some(nil)` when absent, `.some(value)` when present and of its type, and
/// nil (the claims do not hold) when present but not of its type, `null` included.
private func optional<T>(_ value: LicenseJSON?, _ read: (LicenseJSON) -> T?) -> T?? {
    guard let value else { return .some(nil) }
    guard let read = read(value) else { return nil }
    return .some(read)
}

private func nonEmptyString(_ value: LicenseJSON?) -> String? {
    guard let string = value?.stringValue, !string.isEmpty else { return nil }
    return string
}

/// A whole number of at least `minimum`.
private func wholeNumber(_ value: LicenseJSON, atLeast minimum: Double) -> Double? {
    guard let number = value.numberValue, isWhole(number), number >= minimum else { return nil }
    return number
}

/// The entitlements (`ent`) as a verifier reads them: an object's flag, number and text members,
/// kept as they are; every other member (an object, a list, `null`) dropped; and none at all from
/// anything but an object (absent, `null`, a list, a text, a number, a flag). Never a refusal: a
/// lease that verifies is the server's word, and one malformed entitlement must not take away the
/// licence it rides on, or the entitlements beside it. No cap on how many, or how long, is
/// enforced: the signature already says the server stood behind them.
///
/// A flag and a number stay apart: `JSONText` reads `true` as `.bool` and `1` as `.number`, never
/// one for the other as Foundation's `NSNumber` bridging can.
func entitlementsOf(_ value: LicenseJSON?) -> [String: Entitlement] {
    guard case .object(let members)? = value else { return [:] }
    return members.compactMapValues(Entitlement.init(json:))
}

extension Entitlement {
    /// A JSON value as an entitlement: a flag, a number or a text; nil for anything else.
    init?(json: LicenseJSON) {
        switch json {
        case .bool(let value): self = .bool(value)
        case .number(let value): self = .number(value)
        case .string(let value): self = .string(value)
        case .null, .array, .object: return nil
        }
    }

    /// The entitlement as JSON.
    var json: LicenseJSON {
        switch self {
        case .bool(let value): .bool(value)
        case .number(let value): .number(value)
        case .string(let value): .string(value)
        }
    }
}

/// Whether a number is whole, as JavaScript's `Number.isInteger` reads it.
func isWhole(_ value: Double) -> Bool {
    value.isFinite && value.rounded(.towardZero) == value
}

/// Why a lease does not verify.
enum VerifyFailure: String, Sendable, Hashable {
    case malformed
    /// It names a key (`kid`) the key set does not hold.
    case unknownKey = "unknown-key"
    case badSignature = "bad-signature"
    case badClaims = "bad-claims"
    case expired
}

/// What verifying a lease gave.
enum VerifyResult: Sendable, Hashable {
    case valid(LeaseClaims)
    /// Not valid; an expired lease still carries its claims.
    case invalid(VerifyFailure, LeaseClaims?)

    var claims: LeaseClaims? {
        switch self {
        case .valid(let claims): claims
        case .invalid(_, let claims): claims
        }
    }

    var failure: VerifyFailure? {
        if case .invalid(let failure, _) = self { return failure }
        return nil
    }
}

/// A lease verified offline against a key set, in this order: exactly three parts; the
/// signature, canonical base64url (else `malformed`); the key the header names by its id (`kid`),
/// `unknown-key` when the set holds none of that id, or each key in turn for a lease that names
/// none; Ed25519 over `header.payload` exactly as received (else `bad-signature`); the payload,
/// canonical base64url of JSON matching the claims (else `bad-claims`); then the end, in
/// milliseconds: a lease is valid during its `exp` second and not one millisecond after it. The
/// header is read for `kid` only: the algorithm is the verifier's, never the token's.
func verifyLease(_ token: String, keys: KeySet, now: Int) -> VerifyResult {
    let parts = jsSplit(token, ".")
    guard parts.count == 3 else { return .invalid(.malformed, nil) }
    let header = parts[0], payload = parts[1], signature = parts[2]
    guard let signatureBytes = canonicalBase64URLDecode(signature) else { return .invalid(.malformed, nil) }
    let kid = keyId(ofHeader: header)
    let candidates = keys.keys.filter { kid == nil || $0.kid == kid }
    if candidates.isEmpty { return .invalid(.unknownKey, nil) }
    let signed = Data("\(header).\(payload)".utf8)
    let holds = candidates.contains { candidate in
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: candidate.key) else { return false }
        return key.isValidSignature(signatureBytes, for: signed)
    }
    guard holds else { return .invalid(.badSignature, nil) }
    // Decoded as TextDecoder does (an invalid byte sequence becomes U+FFFD, a byte-order mark is
    // dropped), then read as JSON.parse reads it.
    guard let payloadBytes = canonicalBase64URLDecode(payload),
        let json = JSONText.parse(decoding: payloadBytes),
        let claims = LeaseClaims(json: json)
    else { return .invalid(.badClaims, nil) }
    if claims.exp * 1000 < Double(now) { return .invalid(.expired, claims) }
    return .valid(claims)
}

extension LeaseClaims {
    /// The claims as JSON, defaults applied (`major` 0, `ent` {}): what the reference's parse gives.
    var json: LicenseJSON {
        var members: [String: LicenseJSON] = [
            "iss": .string(iss), "sub": .string(sub), "product": .string(product), "aid": .string(aid),
            "model": .string(model), "lim": .number(lim), "major": .number(major), "ent": .object(ent.mapValues(\.json)),
            "iat": .number(iat), "exp": .number(exp),
        ]
        if let fp { members["fp"] = .string(fp) }
        if let fpk { members["fpk"] = .string(fpk.rawValue) }
        if let minMajor { members["minMajor"] = .number(minMajor) }
        if let upgradeUntil { members["upgradeUntil"] = .number(upgradeUntil) }
        if let grace { members["grace"] = .bool(grace) }
        if let test { members["test"] = .bool(test) }
        return .object(members)
    }
}

// MARK: - base64url

/// Bytes from CANONICAL base64url, as the reference decodes a lease's parts: the URL-safe
/// alphabet, no padding, and nothing the encoder would not have written (encoding the bytes again
/// gives the input back). Nil for anything else.
func canonicalBase64URLDecode(_ input: String) -> Data? {
    let urlSafe = input.utf8.allSatisfy { byte in
        (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) || (0x30...0x39).contains(byte)
            || byte == 0x2D || byte == 0x5F
    }
    guard urlSafe, input.utf8.count % 4 != 1, let bytes = base64URLDecode(input) else { return nil }
    return base64URLEncode(bytes) == input ? bytes : nil
}

/// Bytes from base64url read leniently, as `atob` reads it (the URL-safe alphabet mapped back,
/// padded to a whole quantum, ASCII whitespace skipped, the unused bits of the last character not
/// checked): the decoding `canonicalBase64URLDecode` then holds to the canonical spelling. Nil
/// where `atob` throws.
func base64URLDecode(_ input: String) -> Data? {
    var units = input.utf16.map { unit -> UInt16 in
        switch unit {
        case 0x2D: 0x2B  // - to +
        case 0x5F: 0x2F  // _ to /
        default: unit
        }
    }
    let remainder = units.count % 4
    if remainder != 0 { units += Array(repeating: 0x3D, count: 4 - remainder) }
    return forgivingBase64Decode(units)
}

/// WHATWG "forgiving-base64 decode", over UTF-16 code units.
private func forgivingBase64Decode(_ input: [UInt16]) -> Data? {
    var units = input.filter { !($0 == 0x09 || $0 == 0x0A || $0 == 0x0C || $0 == 0x0D || $0 == 0x20) }
    if units.count % 4 == 0, units.last == 0x3D {
        units.removeLast()
        if units.last == 0x3D { units.removeLast() }
    }
    if units.count % 4 == 1 { return nil }
    var bytes: [UInt8] = []
    bytes.reserveCapacity(units.count * 3 / 4)
    var buffer: UInt32 = 0
    var bits = 0
    for unit in units {
        guard let value = base64Digit(unit) else { return nil }
        buffer = (buffer << 6) | UInt32(value)
        bits += 6
        if bits >= 8 {
            bits -= 8
            bytes.append(UInt8(truncatingIfNeeded: buffer >> UInt32(bits)))
        }
    }
    return Data(bytes)
}

private func base64Digit(_ unit: UInt16) -> UInt8? {
    switch unit {
    case 0x41...0x5A: UInt8(unit - 0x41)
    case 0x61...0x7A: UInt8(unit - 0x61 + 26)
    case 0x30...0x39: UInt8(unit - 0x30 + 52)
    case 0x2B: 62
    case 0x2F: 63
    default: nil
    }
}

/// `bytes` as unpadded base64url.
func base64URLEncode(_ bytes: Data) -> String {
    var text = bytes.base64EncodedString()
    text = text.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    while text.hasSuffix("=") { text.removeLast() }
    return text
}

// MARK: - fingerprints

/// A machine's fingerprint from what identifies it, hashed so the raw identifier never leaves it:
/// lowercase hex SHA-256 of `"keygrant|" + raw`, the same in every KeyGrant SDK.
public func hashFingerprint(_ raw: String) -> String {
    sha256Hex("keygrant|" + raw)
}

/// The `fp` claim for a device fingerprint: a lease's `fp` and a trial lease's `aid` carry it,
/// never the fingerprint itself.
func fingerprintClaim(_ fingerprint: String) -> String {
    sha256Hex("keygrant-fp|" + fingerprint)
}

private let hexDigits = Array("0123456789abcdef".utf8)

func sha256Hex(_ text: String) -> String {
    var hex: [UInt8] = []
    hex.reserveCapacity(64)
    for byte in SHA256.hash(data: Data(text.utf8)) {
        hex.append(hexDigits[Int(byte >> 4)])
        hex.append(hexDigits[Int(byte & 0x0F)])
    }
    return String(decoding: hex, as: UTF8.self)
}
