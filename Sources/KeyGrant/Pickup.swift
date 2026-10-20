import Foundation

/// Key pickup, decided without I/O: what a pickup call sends for what a person typed, the error each
/// refusal of the server is, the keys a confirm hands back (read leniently), and the key a restore
/// activates. A build that may not take a typed key (an App Store build) restores a web buyer's licence
/// by the address the key was sold to: `License.pickUp(email:)` asks for a code,
/// `License.pickUp(email:code:)` trades it for the address's keys, and `License.restoreByEmail(email:code:)`
/// activates the one that fits (`License+Pickup.swift`).
///
/// A pickup never takes a licence away and stores nothing.

/// Why a pickup call did not do what it asked. The raw values are the words every KeyGrant SDK uses.
public enum PickupError: String, Error, Sendable, Hashable, CaseIterable {
    /// The address is blank or longer than any address: nothing was asked.
    case invalidEmail = "invalid-email"
    /// The code is not six digits (nothing was asked, so the address lost none of its wrong tries), or
    /// it is not the address's live code: ask again.
    case wrongCode = "wrong-code"
    /// The address has no live code: it expired (10 minutes), was used, was burnt by its fifth wrong
    /// try, or was never asked for. Ask for a new one with `pickUp(email:)`.
    case codeExpired = "code-expired"
    /// Thirty wrong codes for the address this hour, or too many asks or confirms from this network:
    /// wait `PickupRefusal.retryAfter` seconds.
    case tooManyAttempts = "too-many-attempts"
    /// The product's Key pickup is off: offer another way (support).
    case pickupDisabled = "pickup-disabled"
    /// A count could not be made just now: retry (after `retryAfter` seconds, when the server said).
    case tryAgain = "try-again"
    /// No answer, or an answer that is none of a pickup's (a proxy's page, an unknown product, a 200
    /// that holds no keys): retry.
    case network
}

/// A pickup call that did not do what it asked: the error and, for `.tooManyAttempts` and `.tryAgain`,
/// the seconds the server said to wait, when it said (read from its body, never a header).
public struct PickupRefusal: Error, Sendable, Hashable {
    /// What went wrong.
    public var error: PickupError
    /// The seconds to wait before asking again, when the server gave them.
    public var retryAfter: Int?

    public init(error: PickupError, retryAfter: Int? = nil) {
        self.error = error
        self.retryAfter = retryAfter
    }
}

/// What `License.pickUp(email:)` did: a code is on its way when the address holds a key, and the
/// answer is the same when it does not.
public enum PickUpResult: Sendable, Hashable {
    case sent
    case failed(PickupRefusal)

    public var isSent: Bool {
        if case .sent = self { return true }
        return false
    }

    /// Why not, or nil when the code was asked for.
    public var refusal: PickupRefusal? {
        if case .failed(let refusal) = self { return refusal }
        return nil
    }
}

/// What `License.pickUp(email:code:)` did: the address's keys of the product, or why not.
public enum PickUpKeysResult: Sendable, Hashable {
    case keys([PickedKey])
    case failed(PickupRefusal)

    /// The address's keys, first sold first; nil when the code was not taken.
    public var pickedKeys: [PickedKey]? {
        if case .keys(let keys) = self { return keys }
        return nil
    }

    /// Why not, or nil when the keys were read.
    public var refusal: PickupRefusal? {
        if case .failed(let refusal) = self { return refusal }
        return nil
    }
}

/// The versions a picked key covers: from `minMajor` up to `maxMajor` (nil: no top), and every major
/// from `minMajor` up while `upgradeUntil` (ms since the epoch) is ahead.
public struct PickedVersions: Sendable, Hashable {
    /// The lowest major the key covers.
    public var minMajor: Int
    /// The highest major it covers; nil for no top.
    public var maxMajor: Int?
    /// When (ms since the epoch) its upgrade window ends; nil for no window.
    public var upgradeUntil: Int?

    public init(minMajor: Int, maxMajor: Int? = nil, upgradeUntil: Int? = nil) {
        self.minMajor = minMajor
        self.maxMajor = maxMajor
        self.upgradeUntil = upgradeUntil
    }
}

/// The sale a picked key came with.
public struct PickedSale: Sendable, Hashable {
    /// The sale's id.
    public var id: String
    /// This key's place in the sale, from 1.
    public var index: Int
    /// How many keys the sale made, from 1.
    public var size: Int

    public init(id: String, index: Int, size: Int) {
        self.id = id
        self.index = index
        self.size = size
    }
}

/// One key a pickup handed back: enough for the app to let the customer pick one (by `modelName`), or to
/// let `restoreByEmail(email:code:)` choose and activate one. Never show `key`, and never ask the
/// customer to type anything but the address and the code.
public struct PickedKey: Sendable, Hashable {
    /// The licence key. Activate it with `activate(picked.key, email: address, code: picked.activationCode)`.
    public var key: String
    /// The licence model's kind (`perpetual`, `subscription`); empty when the server did not say.
    public var model: String
    /// The licence model's name, to show.
    public var modelName: String?
    /// The key's state (`active`, ...); empty when the server did not say.
    public var state: String
    /// What the key grants, read as a lease's `ent` is.
    public var entitlements: [String: Entitlement]
    /// When (ms since the epoch) the key ends; nil for a key that does not.
    public var expiresAt: Int?
    /// The versions the key covers. Nil is a key sold without a version and not yet bound: its first
    /// activation binds it to the build's major, so it covers any build.
    public var versions: PickedVersions?
    /// How many devices the key allows.
    public var deviceLimit: Int
    /// How many devices hold a seat now.
    public var activeDevices: Int
    /// True when this device already holds a seat on the key (a reinstall takes it back).
    public var held: Bool
    /// The sale the key came with, when it came with one.
    public var sale: PickedSale?
    /// The code a user-locked key's activation takes, already proven by the pickup (the address's code
    /// is all a lock's code proves); nil on any other key.
    public var activationCode: String?

    public init(
        key: String, model: String = "", modelName: String? = nil, state: String = "",
        entitlements: [String: Entitlement] = [:], expiresAt: Int? = nil, versions: PickedVersions? = nil,
        deviceLimit: Int = 0, activeDevices: Int = 0, held: Bool = false, sale: PickedSale? = nil,
        activationCode: String? = nil
    ) {
        self.key = key
        self.model = model
        self.modelName = modelName
        self.state = state
        self.entitlements = entitlements
        self.expiresAt = expiresAt
        self.versions = versions
        self.deviceLimit = deviceLimit
        self.activeDevices = activeDevices
        self.held = held
        self.sale = sale
        self.activationCode = activationCode
    }
}

/// Why `License.restoreByEmail(email:code:)` did not activate a key: the confirm's error, no key to
/// activate, or what `activate` answers.
public enum RestoreError: Error, Sendable, Hashable {
    /// The code was not taken (see `PickupError`).
    case pickup(PickupRefusal)
    /// The address holds no key of the product.
    case noKey
    /// What activating the key answers (see `LicenseError`), or the keys' own `.upgrade` (they are for
    /// an older major than this build: buy an upgrade) and `.outdated` (their lowest version is newer:
    /// update the app), with nothing activated for those two. `.network` behind a call that has not
    /// finished, as `activate` answers.
    case license(LicenseError)

    /// The error's word: a pickup's, a license error's, or `no-key`.
    public var word: String {
        switch self {
        case .pickup(let refusal): refusal.error.rawValue
        case .noKey: "no-key"
        case .license(let error): error.rawValue
        }
    }

    /// The seconds to wait before asking again, when a pickup refusal said.
    public var retryAfter: Int? {
        if case .pickup(let refusal) = self { return refusal.retryAfter }
        return nil
    }
}

/// What `License.restoreByEmail(email:code:)` did.
public enum RestoreResult: Sendable, Hashable {
    /// A key of the address is activated on this device.
    case restored
    case failed(RestoreError)

    public var isRestored: Bool {
        if case .restored = self { return true }
        return false
    }

    /// Why not, or nil when a key was activated.
    public var error: RestoreError? {
        if case .failed(let error) = self { return error }
        return nil
    }
}

// MARK: - what a pickup call sends

/// What a pickup call sends for what a person typed, or the error that refuses it before anything is
/// sent. `code` is nil for the ask for a code.
enum PickupAsk: Sendable, Hashable {
    case send(email: String, code: String?)
    case refused(PickupError)
}

/// What a pickup call sends for what a person typed. `code` nil is the ask for a code (`pickUp(email:)`);
/// a code, even a blank one, is a confirm. The address is entered as an activation's is: trimmed, and a
/// blank one, or one longer than any address, is `.invalidEmail`. The code is entered as an activation's
/// is (ends trimmed, spaces dropped): a blank one, or one that is not six ASCII digits, is `.wrongCode`,
/// refused here without costing the address one of its wrong tries. The address is judged first.
func pickupAsk(email: String, code: String?) -> PickupAsk {
    let entered = jsTrim(email)
    if entered.isEmpty || entered.utf16.count > maxEmail { return .refused(.invalidEmail) }
    guard let code else { return .send(email: entered, code: nil) }
    // Judged by scalars, so no grapheme cluster hides a space or a digit.
    let typed = jsTrim(code).unicodeScalars.filter { $0 != " " }
    guard typed.count == pickupCodeDigits, typed.allSatisfy({ (0x30...0x39).contains($0.value) }) else {
        return .refused(.wrongCode)
    }
    return .send(email: entered, code: String(String.UnicodeScalarView(typed)))
}

/// How many digits a code has.
private let pickupCodeDigits = 6

/// The error a refused pickup call is, from the server's body (`json`, as parsed; nil for none): each
/// pickup word as itself; the per-network limit (`rate-limited`) as `.tooManyAttempts`; a count that
/// could not be made (`unavailable`) as `.tryAgain`; a body the server refused to read
/// (`invalid-request`) as `.invalidEmail`, since what a person typed is all a pickup sends; and
/// anything else, a proxy's page or an unknown product included, as `.network`. The status is never
/// read. `retryAfter` is kept, on the two errors that wait, when the body gives it as a whole number of
/// seconds.
func pickupRefusal(_ json: LicenseJSON?) -> PickupRefusal {
    let error: PickupError
    switch errorOf(json) {
    case "pickup-disabled": error = .pickupDisabled
    case "wrong-code": error = .wrongCode
    case "code-expired": error = .codeExpired
    case "too-many-attempts", "rate-limited": error = .tooManyAttempts
    case "try-again", "unavailable": error = .tryAgain
    case "invalid-request": error = .invalidEmail
    default: error = .network
    }
    guard error == .tooManyAttempts || error == .tryAgain else { return PickupRefusal(error: error) }
    return PickupRefusal(error: error, retryAfter: figureOf(json?["retryAfter"]))
}

// MARK: - the keys a confirm hands back

/// The keys a confirm's 200 answers, read leniently, in the order given; nil when the body is not a
/// pickup's answer at all (not an object, or `keys` not a list), which the SDK takes as no answer
/// (`.network`). A member that is not an object with a `key` (text, 1 to `maxKey` UTF-16 units) is left
/// out; every other field falls back when it is not what it should be.
func pickedKeysOf(_ json: LicenseJSON?) -> [PickedKey]? {
    guard let keys = json?["keys"]?.arrayValue else { return nil }
    return keys.compactMap(pickedKey)
}

/// One key of a confirm's answer, or nil when it has no key.
private func pickedKey(_ json: LicenseJSON) -> PickedKey? {
    guard case .object(let member) = json, let key = member["key"]?.stringValue, (1...maxKey).contains(key.utf16.count) else {
        return nil
    }
    return PickedKey(
        key: key,
        model: member["model"]?.stringValue ?? "",
        modelName: member["modelName"]?.stringValue,
        state: member["state"]?.stringValue ?? "",
        entitlements: entitlementsOf(member["entitlements"]),
        expiresAt: figureOf(member["expiresAt"]),
        versions: pickedVersions(member["versions"]),
        deviceLimit: figureOf(member["deviceLimit"]) ?? 0,
        activeDevices: figureOf(member["activeDevices"]) ?? 0,
        held: member["held"] == .bool(true),
        sale: pickedSale(member["sale"]),
        activationCode: member["activationCode"]?.stringValue.flatMap { isPickupCode($0) ? $0 : nil }
    )
}

/// Exactly six ASCII digits.
private func isPickupCode(_ text: String) -> Bool {
    let scalars = text.unicodeScalars
    return scalars.count == pickupCodeDigits && scalars.allSatisfy { (0x30...0x39).contains($0.value) }
}

/// A key's versions as read: nil for a key not yet bound and for anything that is not an object with a
/// whole `minMajor`; else `minMajor`, and `maxMajor` and `upgradeUntil` each a whole number or nil.
private func pickedVersions(_ json: LicenseJSON?) -> PickedVersions? {
    guard case .object(let member)? = json, let minMajor = figureOf(member["minMajor"]) else { return nil }
    return PickedVersions(minMajor: minMajor, maxMajor: figureOf(member["maxMajor"]), upgradeUntil: figureOf(member["upgradeUntil"]))
}

/// A key's sale, kept only with a text `id` and whole `index` and `size` of at least 1.
private func pickedSale(_ json: LicenseJSON?) -> PickedSale? {
    guard case .object(let member)? = json, let id = member["id"]?.stringValue, let index = countOf(member["index"]),
        let size = countOf(member["size"])
    else { return nil }
    return PickedSale(id: id, index: index, size: size)
}

// MARK: - the key a restore activates

/// How long (ms) the keys a confirm answered are kept in memory, never stored, for a confirm or a
/// restore with the same address and code: a code's own life. The first confirm spends the code, so a
/// restore whose activation got no answer, or a restore after `pickUp(email:code:)`, needs no new one.
let pickupKeysKeepMs = 10 * 60_000

/// The keys the last confirm answered, with the address and code as sent and when (the clock adapter,
/// ms): kept in memory by a `License`.
struct KeptKeys: Sendable {
    var email: String
    var code: String
    var keys: [PickedKey]
    var at: Int

    /// The keys, when they were answered for this address and code and are younger than
    /// `pickupKeysKeepMs` at `now`.
    func keys(email: String, code: String, now: Int) -> [PickedKey]? {
        let age = now - at
        return self.email == email && self.code == code && age >= 0 && age < pickupKeysKeepMs ? keys : nil
    }
}

/// Whether a key covers the build's `major` at `now` (ms): a key not yet bound always does; else from
/// `minMajor` up to `maxMajor` (nil: no top), and every major from `minMajor` up while `upgradeUntil`
/// is after `now`.
func pickedKeyCovers(_ versions: PickedVersions?, major: Int, now: Int) -> Bool {
    guard let versions else { return true }
    if major < versions.minMajor { return false }
    guard let maxMajor = versions.maxMajor, major > maxMajor else { return true }
    return versions.upgradeUntil.map { $0 > now } ?? false
}

/// Why no picked key is activated.
enum Unchosen: String, Error, Sendable, Hashable {
    case noKey = "no-key"
    case upgrade
    case outdated
}

/// The key `restoreByEmail(email:code:)` activates, by its place in `keys` (the server's order: first
/// sold first), or why none is. Of the keys that cover the build's `major`: the first this device
/// already holds a seat on (`held`, a reinstall takes that seat back), else the first with a free seat,
/// else the first (its activation answers `limit`). No key at all is `.noKey`; none that covers the
/// build is `.upgrade` when one of them is for an older major than the build (buy an upgrade), else
/// `.outdated` (update the app).
func chosenKey(_ keys: [PickedKey], major: Int, now: Int) -> Result<Int, Unchosen> {
    if keys.isEmpty { return .failure(.noKey) }
    let covering = keys.indices.filter { pickedKeyCovers(keys[$0].versions, major: major, now: now) }
    if let index = covering.first(where: { keys[$0].held })
        ?? covering.first(where: { keys[$0].activeDevices < keys[$0].deviceLimit }) ?? covering.first
    {
        return .success(index)
    }
    return .failure(keys.contains { $0.versions.map { $0.minMajor <= major } ?? false } ? .upgrade : .outdated)
}
