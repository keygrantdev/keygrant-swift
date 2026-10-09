import Foundation

/// Client-side licensing for a desktop app. Verifies signed JWT leases OFFLINE and only contacts
/// the server to activate, to renew a lease nearing its end or past it, to tell it of a newer
/// major, to pick up a key bought through `purchaseURL(paymentLink:)`, or (at most once a day, in
/// the background) to report a running trial's launch: so an outage, no network, a 5xx, a 429, an
/// ambiguous 4xx or an unusable answer never locks out a paying customer while their lease is
/// valid. Only an explicit verdict from the server, or the lease's own end, does.
///
/// Calls on one `License` run one at a time; create one per app and share it. Every call answers:
/// `status()`, `refresh()` and `startTrial()` never throw (storage that cannot be read just now is
/// `.unknown`/`.storage`), `activate(_:)` answers a `LicenseError`, and only `deactivate()` and
/// `purchaseURL(paymentLink:)`, which the customer asked for and can try again, throw.
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
    /// The launch report last sent (`reportLaunch`), which the SDK itself never awaits: kept so a
    /// test can wait for it (`launchReportSettled`).
    let launchReport = Locked<Task<Void, Never>?>(nil)

    /// A licence for `config.product`. Throws `LicenseConfigError` when `config.publicJWK` is not
    /// an Ed25519 public key (embedded at build time, so this is found the first time the app runs).
    public convenience init(_ config: LicenseConfig) throws {
        try self.init(config, timing: .standard)
    }

    init(_ config: LicenseConfig, timing: Timing) throws {
        publicKey = try publicKeyBytes(fromJWK: config.publicJWK)
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
    /// is stored as still running (a lease signed before the product's key was rotated, say), when
    /// no key is held and a purchase secret is (`purchaseURL(paymentLink:)`: the key bought with
    /// it, asked for under this device's own fingerprint, 5 minutes after the last ask, for a day
    /// after the link), or when `forceOnline`; each at most once per wait unless forced. A running
    /// trial also reports its launch, at most once a day, in the background: the answer never
    /// waits for it. Never throws.
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
    /// state cannot be read, and the server's trial when it cannot be saved. With no key held and
    /// a purchase secret held (`purchaseURL(paymentLink:)`), the key bought with it is asked for
    /// first, whatever the wait says, under the device's own fingerprint or else its host name:
    /// bought, it is the answer (`.licensed`), and no trial is asked. The device is read once for
    /// both asks. Never throws.
    public func startTrial() async -> LicenseStatus {
        // It may make two requests (a claim bounded as a status check is, then the trial ask): the
        // calls behind it wait that much longer.
        await calls.run(extraGrace: timing.statusCheck) { readOnly in
            guard let state = await self.loadForStatus(readOnly: readOnly) else {
                return readOnly ? LicenseStatus.unreadable.stalled() : .unreadable
            }
            if !readOnly {
                // The device read once, given an activation's time, for both asks.
                let device = await self.device(self.timing.activateMachineId, installKind: state.deviceKind)
                switch await self.pickUp(state, ask: PickupAsk(start: true, force: true, device: device)) {
                case .licensed(let status): return status
                case .state(let picked): return await self.startTrialNow(picked, device: device)
                }
            }
            return await self.trialStatus(state, now: self.effectiveNow(state)).stalled()
        }
    }

    /// `paymentLink` with this device's ACTIVATION id as `client_reference_id`, or nil when the
    /// device holds no activated licence, its state cannot be read just now, or the link is not an
    /// absolute URL. Send a customer there to buy an upgrade for the key they hold. The activation
    /// id, never the key: a URL lands in browser history and logs, and the activation id grants
    /// nothing on its own. The link is built as `purchaseURL(paymentLink:)` builds its own.
    public func upgradeURL(paymentLink: URL) async -> URL? {
        // Read-only: this runs outside the one-at-a-time order, beside any call.
        guard let state = try? await load(readOnly: true), nonEmpty(state.key) != nil,
            let activationId = nonEmpty(state.activationId)
        else { return nil }
        return referencedLink(paymentLink, activationId)
    }

    /// `paymentLink` with a PURCHASE REFERENCE as its `client_reference_id`, or nil while the
    /// device holds a key (any key: use `upgradeURL(paymentLink:)`, or the plain link). Send a
    /// customer with no key there to buy: the checkout keeps the reference on the key it mints, and
    /// once they are back the SDK asks for that key (at once on `refresh()` or `startTrial()`, and
    /// from `status()` for a day after the link), activates this device on it and answers
    /// `.licensed`, with nothing typed.
    ///
    /// The reference is a hash of a one-time secret (256 random bits, never the fingerprint) that
    /// stays on the device and is sent only in that ask, so a link that leaks claims nothing. The
    /// secret is made the first time, kept, and its link handed out again by every later call; it
    /// is dropped 30 days after the last one, or once a key bought with it is picked up. Throws
    /// `InvalidPaymentLink` when the link is not an absolute URL (before anything is read), the
    /// storage's error when the state cannot be read or the secret cannot be saved (a link whose
    /// secret is not kept could never be picked up), and `LicenseCallError.previousCallUnfinished`
    /// behind a call that has not finished while no secret is held (one held gives its link as it
    /// is, nothing saved).
    public func purchaseURL(paymentLink: URL) async throws -> URL? {
        guard absoluteLink(paymentLink) != nil else { throw InvalidPaymentLink(link: paymentLink.absoluteString) }
        return try await calls.runThrowing { readOnly in try await self.purchaseURLNow(paymentLink, readOnly: readOnly) }
    }
}

/// A trial answer that could not be saved, and what it was based on.
struct UnsavedTrial: Sendable {
    var patch: StatePatch
    var basis: Basis
}
