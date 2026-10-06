import Foundation

/// Client-side licensing for a desktop app. Verifies signed JWT leases OFFLINE and only contacts
/// the server to activate, to renew a lease nearing its end or past it, or to tell it of a newer
/// major: so an outage, no network, a 5xx, a 429, an ambiguous 4xx or an unusable answer never
/// locks out a paying customer while their lease is valid. Only an explicit verdict from the
/// server, or the lease's own end, does.
///
/// Calls on one `License` run one at a time; create one per app and share it. Every call answers:
/// `status()`, `refresh()` and `startTrial()` never throw (storage that cannot be read just now is
/// `.unknown`/`.storage`), `activate(_:)` answers a `LicenseError`, and only `deactivate()`, which
/// the customer asked for and can try again, throws.
public final class License: Sendable {
    let product: String
    let major: Int
    /// The API base, without a trailing slash.
    let base: String
    /// The product's Ed25519 public key, raw.
    let publicKey: Data
    let httpTimeout: TimeInterval
    let deviceHold: Bool
    let deviceName: String?
    let storage: any StorageAdapter
    let registry: any RegistryStash
    let clock: any LicenseClock
    let http: any HTTPAdapter
    let reader: DeviceIdentityReader
    let timing: Timing
    let calls: CallQueue
    /// The server's trial when it could not be saved (`startTrial`), kept for this process: merged
    /// into every state a status reads, and saved by the next call that can.
    let unsavedTrial = Locked<UnsavedTrial?>(nil)

    /// A licence for `config.product`. Throws `LicenseConfigError` when `config.publicJWK` is not
    /// an Ed25519 public key (embedded at build time, so this is found the first time the app runs).
    public convenience init(_ config: LicenseConfig) throws {
        try self.init(config, timing: .standard)
    }

    init(_ config: LicenseConfig, timing: Timing) throws {
        publicKey = try publicKeyBytes(fromJWK: config.publicJWK)
        product = config.product
        major = config.major
        var base = config.apiBaseURL.absoluteString
        if base.hasSuffix("/") { base.removeLast() }
        self.base = base
        httpTimeout = config.httpTimeout
        deviceHold = config.deviceHold
        // Cut, because the app supplies it and the public endpoint bounds every string it takes: a
        // long one would turn an activation into a 400. A label can lose its end.
        deviceName = trimToLength(config.deviceName, maxDeviceName)
        let adapters = config.adapters
        storage = adapters.storage ?? FileStorage(path: FileStorage.defaultPath(product: config.product))
        registry = adapters.registry ?? NoRegistryStash()
        clock = adapters.clock ?? SystemClock()
        http = adapters.http ?? URLSessionHTTP()
        reader = DeviceIdentityReader(
            adapters.fingerprinter ?? DefaultFingerprinter(), slack: timing.identifySlack, ticker: timing.ticker
        )
        self.timing = timing
        calls = CallQueue(grace: config.httpTimeout + timing.lockGrace, ticker: timing.ticker)
    }

    // MARK: - the public API

    /// Activate a licence key on this device. The key is trimmed and upper-cased first.
    public func activate(_ key: String) async -> ActivateResult {
        do {
            return try await calls.runThrowing { readOnly in
                // Behind a call that has not settled nothing may be written: answered as not
                // reaching the server, to retry.
                if readOnly { return .failed(.network) }
                return try await self.activateNow(key)
            }
        } catch {
            // The state could not be read or saved (the reference rejects): try again.
            return .failed(.storage)
        }
    }

    /// The licence's status. Offline-first: it asks the server only when the lease nears its end
    /// or has ended, when a refusal is due to be asked again, when this build is a newer major than
    /// the server last heard on an open lease, when a trial's lease does not verify while the trial
    /// is stored as still running (a lease signed before the product's key was rotated, say), or
    /// when `forceOnline`; each at most once per wait unless forced. Never throws.
    public func status(forceOnline: Bool = false) async -> LicenseStatus {
        await calls.run { readOnly in
            if !readOnly { await self.saveUnsavedTrial() }
            guard let state = await self.loadForStatus(readOnly: readOnly) else {
                return readOnly ? LicenseStatus.unreadable.stalled() : .unreadable
            }
            let status = await self.statusNow(state, force: forceOnline, readOnly: readOnly)
            return readOnly ? status.stalled() : status
        }
    }

    /// `status()` forced online, whatever the waits say: call it when the customer says they have
    /// paid (back from a checkout, or a "Try again" on a lockout screen).
    public func refresh() async -> LicenseStatus {
        await status(forceOnline: true)
    }

    /// Release this device's activation and drop the local licence, keeping the trial evidence;
    /// and say whether the seat is now free (`released`): false when KeyGrant could not be asked,
    /// or answered anything but a 200 (a 5xx, a 429, a proxy's page), so the app does not tell the
    /// customer a seat is free that the server may still hold. The local licence is dropped either
    /// way. Another device's seat is never released: an activation stored here that is another
    /// device's (a state file copied from another PC) is only dropped, and nothing is asked.
    /// Throws `LicenseCallError.previousCallUnfinished` behind a call that has not finished
    /// (nothing is released or dropped then), and the storage's error when the state cannot be
    /// saved (the local licence is kept then: call it again).
    @discardableResult
    public func deactivate() async throws -> DeactivateResult {
        try await calls.runThrowing { readOnly in
            if readOnly { throw LicenseCallError.previousCallUnfinished }
            return try await self.deactivateNow()
        }
    }

    /// Begin (or re-sync) a trial for this device. Answers as `status()` does: `.unknown` when the
    /// state cannot be read, and the server's trial when it cannot be saved. Never throws.
    public func startTrial() async -> LicenseStatus {
        await calls.run { readOnly in
            guard let state = await self.loadForStatus(readOnly: readOnly) else {
                return readOnly ? LicenseStatus.unreadable.stalled() : .unreadable
            }
            if !readOnly { return await self.startTrialNow(state) }
            return await self.trialStatus(state, now: self.effectiveNow(state)).stalled()
        }
    }

    /// `paymentLink` with this device's ACTIVATION id as `client_reference_id`, or nil when the
    /// device holds no activated licence (or its state cannot be read just now). Send a customer
    /// there to buy an upgrade for the key they hold. The activation id, never the key: a URL
    /// lands in browser history and logs, and the activation id grants nothing on its own.
    public func upgradeURL(paymentLink: URL) async -> URL? {
        // Read-only: this runs outside the one-at-a-time order, beside any call.
        guard let state = try? await load(readOnly: true), nonEmpty(state.key) != nil,
            let activationId = nonEmpty(state.activationId)
        else { return nil }
        return withClientReference(paymentLink, activationId)
    }
}

/// A trial answer that could not be saved, and what it was based on.
struct UnsavedTrial: Sendable {
    var patch: StatePatch
    var basis: Basis
}

/// `link` with `client_reference_id` set to `value`: the first one replaced in place and any
/// others removed, else added, as `URLSearchParams.set` does; the link's other parameters kept as
/// written, and its fragment after them. Built as text, so a link of any shape gives nil at worst
/// (`URLComponents`' setters stop the process on a query they do not like).
func withClientReference(_ link: URL, _ value: String) -> URL? {
    let text = link.absoluteString
    let hash = text.firstIndex(of: "#") ?? text.endIndex
    let fragment = text[hash...]
    let beforeFragment = text[..<hash]
    let mark = beforeFragment.firstIndex(of: "?")
    let base = beforeFragment[..<(mark ?? beforeFragment.endIndex)]
    let query = mark.map { beforeFragment[beforeFragment.index(after: $0)...] } ?? ""
    let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    let reference = "client_reference_id=" + (value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value)
    var pairs: [String] = []
    var placed = false
    for pair in query.split(separator: "&") {
        let rawName = String(pair.prefix { $0 != "=" })
        let name = rawName.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? rawName
        if name == "client_reference_id" {
            if !placed { pairs.append(reference) }
            placed = true
        } else {
            pairs.append(String(pair))
        }
    }
    if !placed { pairs.append(reference) }
    return URL(string: "\(base)?\(pairs.joined(separator: "&"))\(fragment)")
}
