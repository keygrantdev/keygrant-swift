import Foundation

/// What `status()` says of the licence.
public enum LicenseState: String, Sendable, Hashable, CaseIterable {
    /// A lease licenses this build on this device (`isTest` says whether it is a test licence).
    case licensed
    /// A trial is running (`trialEndsAt`, `trialDaysLeft`).
    case trial
    /// The lease ran out and could not be renewed (`reason` `.offline`), or the trial ended (`.trial`).
    case expired
    /// The licence does not license this build or this device: `reason` says why.
    case invalid
    /// Nothing is held: no licence and no trial.
    case unlicensed
    /// The licence file could not be read just now (`reason` `.storage`, an antivirus scan holding
    /// it, say): nothing is known either way. Keep running as before and ask again shortly; never
    /// show the activation screen for it.
    case unknown
}

/// Why a licence does not license this build, as `LicenseStatus.reason` gives it.
public enum LicenseReason: String, Sendable, Hashable, CaseIterable {
    /// The key was revoked or has expired, or this device's activation was released.
    case revoked
    /// The build is NEWER than the key covers: buy an upgrade.
    case upgrade
    /// The build is OLDER than the key's lowest version: update the app.
    case outdated
    /// The lease ran out and the server could not be reached to renew it.
    case offline
    /// The lease is not for this licence at all (another key or activation, another product, a bad signature).
    case tampered
    /// The licence was activated on another device: activate again on this one.
    case device
    /// The trial has ended.
    case trial
    /// The licence file could not be read just now (state `.unknown`).
    case storage
    /// The lease is signed by a key this build does not carry (`LicenseConfig.publicJWK`). Asked
    /// online, the server signs one with the key it uses now, which a build carrying that key verifies.
    case unknownKey = "unknown-key"
}

/// What `status()`, `refresh()` and `startTrial()` answer.
public struct LicenseStatus: Sendable, Hashable {
    public var state: LicenseState
    public var reason: LicenseReason?
    /// The licence key, when the status is about one.
    public var key: String?
    /// Whole days left of the trial, rounded up.
    public var trialDaysLeft: Int?
    /// When the trial ends, in milliseconds since 1970 (the server's word). See `trialEndDate`.
    public var trialEndsAt: Int?
    /// A TEST licence: one the developer made to exercise their app, which lapses on its own
    /// within 30 days. It licenses the app like any other; check this to refuse test licences in
    /// a release build.
    public var isTest: Bool
    /// What the licence grants beyond the base product, by name, as its lease signs them (the
    /// `ent` claim): `status.entitlements["edition"] == .string("pro")`. On a `.licensed` status,
    /// from the licence's lease; on a `.trial` status, from the trial's. Empty on every other
    /// status (an `.invalid` one included, whatever the lease held grants), and when the lease
    /// grants none. A malformed member of the claim is left out, and never costs the licence.
    ///
    /// Names are dictionary keys, which Swift compares by canonical equivalence (an "é" composed
    /// and one decomposed are one key); KeyGrant signs names only in Unicode's composed form (NFC),
    /// so no two names a lease carries are ever taken for one.
    ///
    /// The app's own copy: a dictionary is a value, so changing it changes nothing the SDK holds,
    /// nor the next status. Compared and hashed by content, as `Hashable` needs: a dictionary's
    /// equality and hash do not depend on the order it keeps its members in.
    public var entitlements: [String: Entitlement]
    /// An earlier call on this `License` has not finished (a storage adapter stuck, say), so this
    /// answer comes from what is stored, with no ask and no write. A restart clears it.
    public var isStalled: Bool

    public init(
        state: LicenseState,
        reason: LicenseReason? = nil,
        key: String? = nil,
        trialDaysLeft: Int? = nil,
        trialEndsAt: Int? = nil,
        isTest: Bool = false,
        entitlements: [String: Entitlement] = [:],
        isStalled: Bool = false
    ) {
        self.state = state
        self.reason = reason
        self.key = key
        self.trialDaysLeft = trialDaysLeft
        self.trialEndsAt = trialEndsAt
        self.isTest = isTest
        self.entitlements = entitlements
        self.isStalled = isStalled
    }

    /// `trialEndsAt` as a `Date`.
    public var trialEndDate: Date? {
        trialEndsAt.map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }

    /// What `status()` answers when the stored state cannot be read just now.
    static let unreadable = LicenseStatus(state: .unknown, reason: .storage)

    /// This status, answered from storage behind a call that has not finished.
    func stalled() -> LicenseStatus {
        var status = self
        status.isStalled = true
        return status
    }
}

/// One thing a licence grants beyond the base product, as its lease signs it (the `ent` claim): a
/// flag, a number or a text. `LicenseStatus.entitlements` holds them by name.
///
/// Equal as JavaScript compares such values (the reference SDK's `===`): a number as a number (`5`
/// and `5.0` are the same entitlement, `0` and `-0` too), a text unit for unit (an "é" composed
/// and one decomposed are two texts, where Swift's `String` equality takes them as one), and a
/// flag never equal to a number (`true` is not `1`).
public enum Entitlement: Sendable {
    /// A flag: `"beta": true`.
    case bool(Bool)
    /// A number, a `Double` as JSON and JavaScript read one: `"seats": 5`.
    case number(Double)
    /// A text: `"edition": "pro"`.
    case string(String)

    /// The flag; nil for a number or a text.
    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// The number; nil for a flag or a text.
    public var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    /// The text; nil for a flag or a number.
    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}

extension Entitlement: Hashable {
    public static func == (lhs: Entitlement, rhs: Entitlement) -> Bool {
        switch (lhs, rhs) {
        case (.bool(let a), .bool(let b)): a == b
        case (.number(let a), .number(let b)): a == b
        case (.string(let a), .string(let b)): sameText(a, b)
        default: false
        }
    }

    /// Consistent with `==`: values it equates hash alike (a `Double` hashes `0` and `-0` alike,
    /// and texts equal unit for unit are equal to Swift too).
    public func hash(into hasher: inout Hasher) {
        switch self {
        case .bool(let value):
            hasher.combine(0 as UInt8)
            hasher.combine(value)
        case .number(let value):
            hasher.combine(1 as UInt8)
            hasher.combine(value)
        case .string(let value):
            hasher.combine(2 as UInt8)
            hasher.combine(value)
        }
    }
}

extension Entitlement: ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByStringLiteral
{
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
}

/// Why `activate(_:)` did not activate.
public enum LicenseError: String, Error, Sendable, Hashable, CaseIterable {
    /// No such key, or text that cannot be a key.
    case invalidKey = "invalid-key"
    /// The key is on as many devices as it allows.
    case limit
    /// The key was revoked, or has expired.
    case revoked
    /// This build is newer than the key covers.
    case upgrade
    /// The key is for a later version than this build: update the app.
    case outdated
    /// The server could not be reached, or its answer could not be used: try again.
    case network
    /// Kept for parity with the reference's error words; this SDK never answers it.
    case notConfigured = "not-configured"
    /// The server's lease failed offline verification: an integrity or configuration error
    /// (the embedded public key is not the product's, say).
    case invalidLease = "invalid-lease"
    /// The licence file could not be read or saved: try again. (The reference rejects instead.)
    case storage
}

/// What `activate(_:)` answers.
public enum ActivateResult: Sendable, Hashable {
    case activated
    case failed(LicenseError)

    public var isActivated: Bool {
        if case .activated = self { return true }
        return false
    }

    /// Why it did not activate, or nil when it did.
    public var error: LicenseError? {
        if case .failed(let error) = self { return error }
        return nil
    }
}

/// What `deactivate()` did about the seat. The local licence is dropped either way; this says
/// whether the device's seat is free for another one.
public struct DeactivateResult: Sendable, Hashable {
    /// True when KeyGrant confirmed the release (a 200), or when this device held no activation to
    /// release. False when it could not be asked, or answered anything else (a 5xx, a 429, a
    /// proxy's page): the seat may still be held, and the app should say so (the developer's
    /// dashboard, or support, can release it), not tell the customer it is free.
    public var released: Bool

    public init(released: Bool) {
        self.released = released
    }
}

/// A definitive refusal from the server, as `StoredState.refused` keeps it.
public enum Refusal: String, Sendable, Hashable, CaseIterable {
    case revoked, upgrade, outdated, device
}

/// What a fingerprint hashes: the operating system's machine id, or the host name.
public enum DeviceKind: String, Sendable, Hashable, CaseIterable {
    case machine, hostname
}

/// Who this device is, as far as a fingerprinter can tell this time (`Fingerprinter.identify`).
public struct DeviceIdentity: Sendable, Hashable {
    /// What a normal run gives, or nil when it cannot be told this time.
    public var fingerprint: String?
    /// What `fingerprint` hashes. Only a seat keyed by a `.machine` id is held to its device;
    /// nil means unknown, and such a seat never is.
    public var kind: DeviceKind?
    /// Other fingerprints this device answers to (such as the host-name fingerprint).
    public var alternates: [String]

    public init(fingerprint: String?, kind: DeviceKind? = nil, alternates: [String] = []) {
        self.fingerprint = fingerprint
        self.kind = kind
        self.alternates = alternates
    }
}

/// Why a `License` call could not run.
public enum LicenseCallError: Error, Sendable, Hashable, CustomStringConvertible {
    /// `deactivate()` behind a call that has not finished: the local licence cannot be dropped
    /// safely until it has. Also `purchaseURL(paymentLink:)` there when no purchase secret is held:
    /// a new one could not be saved, and a link whose secret is not kept could never be picked up.
    /// Try again.
    case previousCallUnfinished

    public var description: String {
        switch self {
        case .previousCallUnfinished: "a previous licence call has not finished; try again"
        }
    }
}

/// A payment link `purchaseURL(paymentLink:)` cannot carry a purchase reference: not an absolute URL
/// (a scheme, `:` and the rest), such as a path (`/buy`) or a bare host (`buy.stripe.com/x`).
public struct InvalidPaymentLink: Error, Sendable, Hashable, CustomStringConvertible {
    /// The link as it was given.
    public var link: String

    public var description: String { "the payment link is not an absolute URL: \(link)" }
}

/// What `License.require(_:)` throws when the licence does not grant an entitlement: names it.
public struct MissingEntitlement: Error, Sendable, Hashable, CustomStringConvertible {
    /// The entitlement's code, as the app asked for it.
    public let entitlement: String

    public init(entitlement: String) {
        self.entitlement = entitlement
    }

    public var description: String { "the licence does not grant \"\(entitlement)\"" }
}

/// Whether entitlements grant `code`: a flag that is on, a number that is not zero, or a text that
/// is not empty. Absent, off, zero or empty is not granted. The code is matched exactly, case
/// included (as Swift compares strings: by their canonical form).
public func grants(_ entitlements: [String: Entitlement], _ code: String) -> Bool {
    switch entitlements[code] {
    case .bool(let flag)?: flag
    case .number(let number)?: number != 0
    case .string(let text)?: !text.isEmpty
    case nil: false
    }
}

/// A `LicenseConfig` the SDK cannot work with.
public enum LicenseConfigError: Error, Sendable, Hashable, CustomStringConvertible {
    /// `publicJWK` is not the product's Ed25519 public keys (a JWK set `{"keys":[...]}`, a list of
    /// JWKs, one JWK `{"kty":"OKP","crv":"Ed25519","x":"..."}`, or its bare `x`).
    case invalidPublicKey(String)

    public var description: String {
        switch self {
        case .invalidPublicKey(let why): "publicJWK is not the product's Ed25519 public key: \(why)"
        }
    }
}
