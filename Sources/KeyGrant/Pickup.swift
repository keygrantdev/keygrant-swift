import Crypto
import Foundation

/// Buying from the app with no key typed, decided without I/O: the purchase secret
/// `purchaseURL(paymentLink:)` keeps (`newPurchaseSecret`), the reference to it a link carries
/// (`purchaseReference`, `purchaseLink`, built as `upgradeURL(paymentLink:)`'s link is:
/// `referencedLink`), how long a secret is held (`purchaseTokenKept`), when `status()` asks for the
/// key bought with it (`claimDue`), and what that ask's answer saves and says (`claimOutcome`).
/// Purchases.swift makes the requests and the saves.
extension Waits {
    /// How long after an ask for a bought key that brought none back (`claimAskedAt`) before
    /// `status()` asks again on its own (`claimDue`); `refresh()` and `startTrial()` ask at once.
    static let claimWaitMs = 5 * 60_000
    /// How long after `purchaseURL(paymentLink:)` last handed a link out (`purchaseTokenAt`) an
    /// unforced `status()` still asks for the bought key (`claimDue`): a customer who buys does so
    /// soon after opening the link. After it, only `refresh()` and `startTrial()` ask, until
    /// `purchaseTokenMs`, so an abandoned checkout does not put the network in front of every launch.
    static let claimEagerMs = dayMs
    /// How long a purchase secret is held after `purchaseURL(paymentLink:)` last handed out its
    /// link (`purchaseTokenKept`, by the guarded clock): a secret past it is dropped, never sent. A
    /// drop is the device's alone: it revokes nothing on the server.
    static let purchaseTokenMs = 30 * dayMs
}

/// What starts every purchase reference, so the server tells one apart from an activation id or a key.
let purchaseReferencePrefix = "kgp_"

/// The query parameter a payment link names its checkout's buyer by.
private let referenceName = "client_reference_id"

/// What JavaScript's `encodeURIComponent` leaves as it is.
private let uriComponentCharacters = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()"
)

/// A new purchase secret: the base64url (no padding) of 32 bytes from the system's
/// cryptographically secure generator (`SystemRandomNumberGenerator`: `arc4random_buf` on Apple
/// platforms, `getrandom` on Linux), 43 characters. It stays on the device (`purchaseToken`) and is
/// sent only in the ask for the key bought with it: a link carries the reference to it
/// (`purchaseReference`), so a link that leaks (browser history, the seller's checkout session)
/// claims nothing. Random, and never the fingerprint: a fingerprint is no secret.
func newPurchaseSecret() -> String {
    var generator = SystemRandomNumberGenerator()
    return newPurchaseSecret(using: &generator)
}

/// A purchase secret from `generator`'s next four 64-bit draws, each as its eight little-endian
/// bytes: `newPurchaseSecret()` hands it the system's secure generator, a test one it records.
func newPurchaseSecret<G: RandomNumberGenerator>(using generator: inout G) -> String {
    var bytes = Data(capacity: 32)
    for _ in 0..<4 {
        withUnsafeBytes(of: generator.next().littleEndian) { bytes.append(contentsOf: $0) }
    }
    return base64URLEncode(bytes)
}

/// The reference a payment link carries for `secret`: `kgp_` and the base64url (no padding) of the
/// SHA-256 of the secret's UTF-8 bytes, 47 characters. The checkout keeps it on the key it mints; the
/// server derives it from the secret an ask sends, to find that key.
func purchaseReference(_ secret: String) -> String {
    purchaseReferencePrefix + base64URLEncode(Data(SHA256.hash(data: Data(secret.utf8))))
}

/// The link `purchaseURL(paymentLink:)` answers for a held `secret`: the link with its reference
/// (`referencedLink`), or nil when the link is not an absolute URL.
func purchaseLink(_ link: URL, _ secret: String) -> URL? {
    referencedLink(link, purchaseReference(secret))
}

/// A payment link's text when it is an absolute URL (a scheme, `:` and the rest, as `URL` reads
/// it), else nil: a path such as `/buy`, or a bare host such as `buy.stripe.com/x`, is not one.
func absoluteLink(_ link: URL) -> String? {
    let absolute = link.absoluteURL
    guard let scheme = absolute.scheme, !scheme.isEmpty else { return nil }
    return absolute.absoluteString
}

/// `link` with `reference` as its one `client_reference_id`, or nil when the link is not an
/// absolute URL (`absoluteLink`). Its query is edited as text (`referencedLinkText`).
func referencedLink(_ link: URL, _ reference: String) -> URL? {
    guard let text = absoluteLink(link) else { return nil }
    return URL(string: referencedLinkText(text, reference))
}

/// The text of an absolute link with `reference` as its one `client_reference_id`: every
/// parameter named exactly `client_reference_id` (its text before the first `=`, or all of it) and
/// every empty one left out, the others kept as written and in their order, and
/// `client_reference_id=<reference>` (percent-encoded as `encodeURIComponent` encodes) added last.
/// The fragment is kept after the query.
func referencedLinkText(_ text: String, _ reference: String) -> String {
    let hash = text.firstIndex(of: "#") ?? text.endIndex
    let beforeFragment = text[..<hash]
    let mark = beforeFragment.firstIndex(of: "?")
    let base = beforeFragment[..<(mark ?? beforeFragment.endIndex)]
    let query = mark.map { beforeFragment[beforeFragment.index(after: $0)...] } ?? ""
    // `split` leaves out the empty parts.
    let kept = query.split(separator: "&").filter { !sameText(String($0.prefix { $0 != "=" }), referenceName) }
    let encoded = reference.addingPercentEncoding(withAllowedCharacters: uriComponentCharacters) ?? reference
    let parts = kept.map(String.init) + ["\(referenceName)=\(encoded)"]
    return "\(base)?\(parts.joined(separator: "&"))\(text[hash...])"
}

/// Whether the stored purchase secret is still held at `now` (the guarded clock): there is one,
/// stamped with when its link was last handed out (`purchaseTokenAt`), and less than
/// `Waits.purchaseTokenMs` has passed since. A stamp ahead of `now` holds it too: no time has
/// passed that can be measured. A secret with no stamp is not held.
func purchaseTokenKept(_ state: StoredState, now: Int) -> Bool {
    guard state.purchaseToken != nil, let at = state.purchaseTokenAt else { return false }
    return difference(now, at) < Waits.purchaseTokenMs
}

/// Whether `status()` asks for the bought key now, unforced (`refresh()` and `startTrial()`
/// always ask). Only while the link is fresh: less than `Waits.claimEagerMs` since
/// `purchaseURL(paymentLink:)` last handed it out (`purchaseTokenAt`, judged at `now`, the guarded
/// clock; a stamp ahead of `now` is fresh), so an abandoned checkout does not put the network in
/// front of every launch for a month. And only once the wait is over (`claimAskedAt`, judged at
/// `clockNow`, the device clock, as `askDue`: the wait is courtesy, not protection): not asked
/// since the link, the device clock set back before the last ask, or `Waits.claimWaitMs` since it.
/// The two clocks are never compared with each other.
func claimDue(_ state: StoredState, clockNow: Int, now: Int) -> Bool {
    guard let at = state.purchaseTokenAt, difference(now, at) < Waits.claimEagerMs else { return false }
    guard let asked = state.claimAskedAt else { return true }
    return clockNow < asked || difference(clockNow, asked) >= Waits.claimWaitMs
}

/// At most this many fingerprints in a claim's `fingerprints`: the server's bound.
let maxClaimFingerprints = 4

/// At most this many UTF-16 units in each of a claim's `fingerprints`: the server's bound.
let maxClaimFingerprintLength = 200

/// What an ask for the key bought with a purchase secret sends (`claimRequest`).
struct ClaimRequest: Sendable, Hashable {
    /// The purchase secret.
    var token: String
    var fingerprint: String
    var fingerprintKind: DeviceKind?
    /// Every fingerprint the run read, within the server's bounds; left out when empty.
    var fingerprints: [String]
    var name: String?
    var major: Int

    /// The body as JSON: absent members left out.
    var json: LicenseJSON {
        var body: [String: LicenseJSON] = [
            "token": .string(token), "fingerprint": .string(fingerprint), "major": .number(Double(major)),
        ]
        if let fingerprintKind { body["fingerprintKind"] = .string(fingerprintKind.rawValue) }
        if !fingerprints.isEmpty { body["fingerprints"] = .array(fingerprints.map(LicenseJSON.string)) }
        if let name { body["name"] = .string(name) }
        return .object(body)
    }
}

/// The claim's body, or nil when none is sent. The fingerprint is a first activation's
/// (`activationIdentity`: the device's own, else the host name), and from `status()` and
/// `refresh()` (`start` false) only the device's own: a claim under the host-name fallback could
/// take the seat under a fingerprint the next ask does not send, so with no own fingerprint
/// nothing is sent (and nothing saved). `fingerprints` is every fingerprint the run read, its own
/// first, then the host name and any other alternates, whether or not the device is held (they
/// only match this claim to an earlier one, and judge no seat), within the server's bounds: those
/// of 1 to `maxClaimFingerprintLength` UTF-16 units, never cut (a cut one matches nothing), the
/// first `maxClaimFingerprints` of them; left out when none is. A body with too many, or one too
/// long, is refused with an error word, which would drop the secret. `name` only when the app gave one.
func claimRequest(secret: String, device: Device, name: String?, major: Int, start: Bool) -> ClaimRequest? {
    if !start && device.own == nil { return nil }
    guard let identity = activationIdentity(device, installKind: nil) else { return nil }
    let fingerprints = device.fingerprints.filter { (1...maxClaimFingerprintLength).contains($0.utf16.count) }
    return ClaimRequest(
        token: secret, fingerprint: identity.fingerprint, fingerprintKind: identity.kind,
        fingerprints: Array(fingerprints.prefix(maxClaimFingerprints)), name: name, major: major
    )
}

/// The purchase secret and its stamps, which a save about a secret writes only while it is about
/// the stored one (`aboutStored`).
let purchaseFields: Set<StateField> = [.purchaseToken, .purchaseTokenAt, .claimAskedAt]

/// What an activation (a typed key's, or a bought key picked up) and a deactivation clear: the
/// purchase secret and its stamps. A secret left on a keyed install would, after a later
/// deactivation, activate the device on a key the customer may have meant for another machine.
let noPurchase: StatePatch = [.purchaseToken: .clear, .purchaseTokenAt: .clear, .claimAskedAt: .clear]

/// The purchase secret a save is about (`Basis.purchase`).
struct PurchaseBasis: Sendable, Hashable {
    /// The secret: a save lands only while it is the one stored, so one another process made
    /// meanwhile is neither dropped nor stamped by it.
    var token: String
    /// For a wait, the `purchaseTokenAt` its asker read: it lands only while that is stored too. A
    /// link handed out again since (another process's `purchaseURL(paymentLink:)`) cleared the wait
    /// so that the next `status()` asks at once, and a late answer must not start it again. A drop
    /// carries none: a spent secret is dead however recently its link was handed out.
    var at: Int?
}

/// Whether a save about a purchase secret is about the one stored, its link as handed out when
/// its asker read it (`PurchaseBasis`): else `merged` leaves out its purchase fields. `at` is
/// compared for equality only.
func aboutStored(_ latest: StoredState, _ purchase: PurchaseBasis) -> Bool {
    guard sameText(latest.purchaseToken, purchase.token) else { return false }
    return purchase.at == nil || latest.purchaseTokenAt == purchase.at
}

/// An activation the server answered with a lease that licenses this build (`activationPatch`).
struct Activation: Sendable {
    var key: String
    var activationId: String
    var lease: String
    /// The lease's claims.
    var claims: LeaseClaims
    /// The time the lease was judged at.
    var now: Int
    /// This build's major.
    var major: Int
    /// What the activation's fingerprint hashes: none for one of unknown kind.
    var kind: DeviceKind?
}

/// What an activation saves, a typed key's (`activate(_:)`) and a bought key's (`claimOutcome`)
/// alike, stamped as an activation: the key, the activation, the lease, the major heard, the kept
/// major (`keptWith`, cleared when it keeps none), any refusal and wait cleared (`leased`), what
/// the install is keyed by (cleared for a fingerprint of unknown kind), and the purchase secret and
/// its stamps cleared (`noPurchase`).
func activationPatch(_ a: Activation) -> StatePatch {
    let patch: StatePatch = [
        .key: .string(a.key),
        .activationId: .string(a.activationId),
        .lease: .string(a.lease),
        .checkedMajor: .int(a.major),
        .keptMajor: .int(orClear: keptWith(nil, claims: a.claims, now: a.now, major: a.major)),
    ]
    return patch + leased + [.deviceKind: .deviceKind(orClear: a.kind)] + noPurchase
}

/// What an answer to an ask for a bought key is judged from (`claimOutcome`).
struct ClaimInput: Sendable {
    /// The answer; nil when there was none (it threw or timed out, or no fingerprint could be sent).
    var response: LicenseHTTPResponse?
    /// The offline check (`checkLease`, as of `now`, for the key and activation it came with, on
    /// this device) of the lease a 200 carried with a key and an activation id; nil otherwise.
    var check: LeaseCheck?
    /// The device clock when the claim was asked: where the wait before asking again starts.
    var clockNow: Int
    /// The time the lease was judged at: the guarded clock, reconciled to the server's.
    var now: Int
    /// This build's major.
    var major: Int
    /// What the claim's fingerprint hashes.
    var kind: DeviceKind?
}

/// What an answer to an ask for a bought key does.
struct ClaimOutcome: Sendable, Hashable {
    enum Kind: String, Sendable, Hashable {
        /// A key that licenses this build: saved as an activation.
        case bought
        /// The secret kept, and the wait before asking again started.
        case kept
        /// The secret let go.
        case dropped
    }

    var result: Kind
    /// The status a bought key gives; nil otherwise, and the caller answers as with no secret held.
    var status: LicenseStatus?
    /// What is saved: a bought key as an activation, a kept or dropped secret about that secret.
    var patch: StatePatch
}

/// What an answer to an ask for a bought key saves and says:
///  - a 200 with a key, an activation id and a lease (strings) whose lease licenses this build
///    here (`check`): saved exactly as `activate(_:)` saves (`activationPatch`), and licensed
///    (`leaseStatus`), even when it also says pending or carries an error word;
///  - a 200 with all three whose lease does not license this build here: the secret dropped (the
///    customer has the key by email, and typing it gives the proper error);
///  - a 200 `{pending: true}` ("not bought yet"), no answer, a 5xx or a 429, and any other answer
///    with no error word (a captive portal's page, a 404 page from a server with no claim endpoint):
///    the secret kept, and the wait started (`claimAskedAt`);
///  - any other answer with an error word (`spent`, `pickup-off`, a refusal): the secret dropped.
func claimOutcome(_ input: ClaimInput) -> ClaimOutcome {
    let kept = ClaimOutcome(result: .kept, status: nil, patch: [.claimAskedAt: .int(input.clockNow)])
    let dropped = ClaimOutcome(result: .dropped, status: nil, patch: noPurchase)
    guard let response = input.response, !noAnswer(response.status) else { return kept }
    let body = parseClaimBody(response.json)
    if response.status == 200, let key = body.key, let activationId = body.activationId, let lease = body.lease {
        guard let check = input.check, case .ok(_, let claims) = check else { return dropped }
        let activation = Activation(
            key: key, activationId: activationId, lease: lease, claims: claims, now: input.now, major: input.major, kind: input.kind
        )
        return ClaimOutcome(result: .bought, status: leaseStatus(check, key: key), patch: activationPatch(activation))
    }
    if response.status == 200 && body.pending { return kept }
    return body.error == nil ? kept : dropped
}
