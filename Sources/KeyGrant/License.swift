import Foundation

/// Client-side licensing for a desktop app. Verifies signed JWT leases OFFLINE and only contacts
/// the server to activate, to renew a lease nearing its end or past it, to tell it of a newer
/// major, to spend a metered use (`use(_:_:)`) or report the uses this device spent while it
/// got no answer, or (at most once a day, in the background) to report a running trial's
/// launch: so an outage, no network, a 5xx, a 429, an
/// ambiguous 4xx or an unusable answer never locks out a paying customer while their lease is
/// valid. Only an explicit verdict from the server, or the lease's own end, does.
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
    /// The product's Ed25519 public keys, raw, with their ids.
    let keys: KeySet
    /// The ids of licence files this build refuses.
    let revokedFiles: [String]
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
    /// The journal changes this process could not save (`License+Journal.swift`): merged into every
    /// state a call reads, and saved by the next call that can.
    let held = Locked<Held>(Held())
    /// The launch report last sent (`reportLaunch`), which the SDK itself never awaits: kept so a
    /// test can wait for it (`launchReportSettled`).
    let launchReport = Locked<Task<Void, Never>?>(nil)
    /// The keys the last pickup confirm answered, in memory only (`Pickup.swift`).
    let keptPickup = Locked<KeptKeys?>(nil)

    /// A licence for `config.product`. Throws `LicenseConfigError` when `config.publicJWK` is not
    /// an Ed25519 public key (embedded at build time, so this is found the first time the app runs).
    public convenience init(_ config: LicenseConfig) throws {
        try self.init(config, timing: .standard)
    }

    init(_ config: LicenseConfig, timing: Timing) throws {
        keys = try KeySet(publicJWK: config.publicJWK)
        revokedFiles = config.revokedLicenseFiles
        product = config.product
        // As the server reads it (`majorOf`): one reading, used wherever the major is.
        major = majorOf(config.major)
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
        registry = adapters.registry ?? defaultRegistry(product: config.product)
        clock = adapters.clock ?? SystemClock()
        http = adapters.http ?? URLSessionHTTP()
        reader = DeviceIdentityReader(
            adapters.fingerprinter ?? DefaultFingerprinter(product: config.product),
            slack: timing.identifySlack, ticker: timing.ticker
        )
        self.timing = timing
        calls = CallQueue(grace: config.httpTimeout + timing.lockGrace, ticker: timing.ticker)
    }

    // MARK: - the public API

    /// Activate a licence key on this device. The key is trimmed and upper-cased first.
    ///
    /// A user-locked key asks a NEW device who it is, and only a new device: `email` is the address
    /// the key was sold to and, for a key that mails a code to it, `code` is the code that came.
    /// The first activation of such a key is answered `.userEmailRequired`; with the address,
    /// `.userCodeRequired` (a code was just mailed) or a lease; with the code, a lease. Neither is
    /// stored. A key that is not locked ignores both once they reach the server, but an address
    /// longer than any email, or a code that is not six digits (its spaces dropped), is refused here
    /// for any key (`.userEmailMismatch`, `.userCodeInvalid`), asking nothing: the key is judged
    /// first, then the address, then the code. A blank is none.
    public func activate(_ key: String, email: String? = nil, code: String? = nil) async -> ActivateResult {
        do {
            return try await calls.runThrowing { readOnly in
                // Behind a call that has not settled nothing may be written: answered as not
                // reaching the server, to retry.
                if readOnly { return .failed(.network) }
                return try await self.activateNow(key, email: email, code: code)
            }
        } catch {
            // The state could not be read or saved (the reference rejects): try again.
            return .failed(.storage)
        }
    }

    /// The licence's status. Offline-first: it asks the server only when the lease nears its end
    /// or has ended, when a refusal is due to be asked again, when this build is a newer major than
    /// the server last heard on an open lease, when the journal of metered uses this device spent
    /// without an answer holds an entry a request would report (and the journal's own wait is not
    /// running), when a trial's lease does not verify while the trial
    /// is stored as still running (a lease signed before the product's key was rotated, say), or
    /// when `forceOnline`; each at most once per wait unless forced. A running
    /// trial also reports its launch, at most once a day, in the background: the answer never
    /// waits for it. Never throws.
    public func status(forceOnline: Bool = false) async -> LicenseStatus {
        await calls.run { readOnly in
            if !readOnly {
                await self.saveUnsavedTrial()
                await self.saveUnsavedJournal()
            }
            guard let view = await self.loadForStatus(readOnly: readOnly) else {
                return readOnly ? LicenseStatus.unreadable.stalled() : .unreadable
            }
            let status = await self.statusNow(view, force: forceOnline, readOnly: readOnly)
            return readOnly ? status.stalled() : status
        }
    }

    /// Whether the licence this device holds grants the entitlement `code`: a flag that is on, a
    /// number that is not zero, or a text that is not empty (`grants`). Offline, from the stored
    /// lease or stored offline licence file only: the entitlements of the status `status()` gives
    /// from what is stored, with no ask and no write, so a licence that does not license this
    /// build, and none at all, grant nothing.
    /// A running trial grants what its trial lease does. A state that cannot be read grants nothing
    /// just now.
    public func has(_ code: String) async -> Bool {
        guard let view = await loadForStatus(readOnly: true) else { return false }
        return grants(await statusNow(view, force: false, readOnly: true).entitlements, code)
    }

    /// As `has(_:)`, but throwing `MissingEntitlement`, which names `code`, when the licence does not
    /// grant that entitlement: for work that may run only when it does.
    public func require(_ code: String) async throws {
        if await !has(code) { throw MissingEntitlement(entitlement: code) }
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
            guard let state = await self.loadForStatus(readOnly: readOnly)?.state else {
                return readOnly ? LicenseStatus.unreadable.stalled() : .unreadable
            }
            if !readOnly { return await self.startTrialNow(state) }
            return await self.trialStatus(state, now: self.effectiveNow(state)).stalled()
        }
    }

    /// `paymentLink` with this device's ACTIVATION id as `client_reference_id`, or nil when the
    /// device holds no activated licence, its state cannot be read just now, or the link is not an
    /// absolute URL. Send a customer there to buy an upgrade for the key they hold. The activation
    /// id, never the key: a URL lands in browser history and logs, and the activation id grants
    /// nothing on its own. The link's own parameters and fragment are kept as written
    /// (`referencedLink`). Selling through Paddle, the link is the tenant's own checkout page,
    /// which gives `client_reference_id` to Paddle.js as custom data under the same name.
    public func upgradeURL(paymentLink: URL) async -> URL? {
        // Read-only: this runs outside the one-at-a-time order, beside any call.
        guard let state = try? await load(readOnly: true).state, nonEmpty(state.key) != nil,
            let activationId = nonEmpty(state.activationId)
        else { return nil }
        return referencedLink(paymentLink, activationId)
    }
}

/// A trial answer that could not be saved, and what it was based on.
struct UnsavedTrial: Sendable {
    var patch: StatePatch
    var basis: Basis
}
