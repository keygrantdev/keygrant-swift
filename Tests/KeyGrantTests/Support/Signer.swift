import Crypto
import Foundation

@testable import KeyGrant

/// The moment most tests run at, and a day.
let NOW = 1_757_000_000_000
let DAY = 86_400_000
let HOUR = 3_600_000
let PRODUCT = "sluice"
let KEY = "SLUICE-AAAA-BBBB-CCCC-DDDD"

/// Signs leases as the server does, with a key of its own.
struct Signer: Sendable {
    /// The private key, raw (a CryptoKit key is kept as bytes so this stays `Sendable` everywhere).
    private let privateKey: Data

    init() {
        privateKey = Curve25519.Signing.PrivateKey().rawRepresentation
    }

    /// The id a lease names this key by (its thumbprint), as a check-in reports it.
    var kid: String { (try? publicKeyBytes(fromJWK: publicJWK)).map(keyId(ofKey:)) ?? "" }

    /// The public key as a JWK, as provisioning hands it out.
    var publicJWK: String {
        let x = (try? Curve25519.Signing.PrivateKey(rawRepresentation: privateKey))
            .map { base64URLEncode($0.publicKey.rawRepresentation) } ?? ""
        return #"{"kty":"OKP","crv":"Ed25519","x":"\#(x)"}"#
    }

    /// `header.payload` signed exactly as given.
    func sign(input: String) -> String {
        guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: privateKey),
            let signature = try? key.signature(for: Data(input.utf8))
        else { return "\(input).signing-failed" }
        return "\(input).\(base64URLEncode(signature))"
    }

    /// A JWS of any payload, valid claims or not.
    func sign(payload: LicenseJSON, header: LicenseJSON = ["alg": "EdDSA", "typ": "JWT"]) -> String {
        sign(input: "\(part(header)).\(part(payload))")
    }

    /// A lease as the server signs one: `iat` the second of `at`, `exp` that plus `ttl`.
    func lease(
        sub: String = KEY,
        product: String = PRODUCT,
        aid: String = "act_1",
        model: String = "perpetual",
        lim: Int = 3,
        major: Int = 1,
        minMajor: Int? = nil,
        upgradeUntil: Int? = nil,
        fp: String? = nil,
        fpk: DeviceKind? = nil,
        test: Bool? = nil,
        ttlSeconds: Int = 30 * 24 * 3600,
        at: Int = NOW
    ) -> String {
        let iat = at / 1000
        var claims: [String: LicenseJSON] = [
            "iss": "keygrant", "sub": .string(sub), "product": .string(product), "aid": .string(aid),
            "model": .string(model), "lim": .number(Double(lim)), "major": .number(Double(major)), "ent": [:],
            "iat": .number(Double(iat)), "exp": .number(Double(iat + ttlSeconds)),
        ]
        if let minMajor { claims["minMajor"] = .number(Double(minMajor)) }
        if let upgradeUntil { claims["upgradeUntil"] = .number(Double(upgradeUntil)) }
        if let fp { claims["fp"] = .string(fp) }
        if let fpk { claims["fpk"] = .string(fpk.rawValue) }
        if let test { claims["test"] = .bool(test) }
        return sign(payload: .object(claims))
    }

    /// A trial lease as the server signs one: `sub` `trial:<claim>`, `aid` the claim.
    func trialLease(device: String, kind: DeviceKind? = .machine, ttlSeconds: Int = 7 * 24 * 3600, at: Int = NOW) -> String {
        let claim = fingerprintClaim(device)
        let iat = at / 1000
        var claims: [String: LicenseJSON] = [
            "iss": "keygrant", "sub": .string("trial:\(claim)"), "product": .string(PRODUCT), "aid": .string(claim),
            "model": "trial", "lim": 1, "major": .number(Double(openMajor)), "ent": [:],
            "iat": .number(Double(iat)), "exp": .number(Double(iat + ttlSeconds)),
        ]
        if let kind { claims["fpk"] = .string(kind.rawValue) }
        return sign(payload: .object(claims))
    }

    private func part(_ value: LicenseJSON) -> String {
        base64URLEncode(JSONText.data(value))
    }
}
