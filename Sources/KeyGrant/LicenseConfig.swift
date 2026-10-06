import Foundation

/// How a `License` is set up.
public struct LicenseConfig: Sendable {
    /// The product slug, matching the KeyGrant product.
    public var product: String
    /// The KeyGrant API base, e.g. `https://api.keygrant.dev`.
    public var apiBaseURL: URL
    /// The product's public key, embedded at build time for offline verification: the `publicJwk`
    /// of `GET https://api.keygrant.dev/v1/products/<product>/pubkey` (public, no API key), as
    /// JSON (`{"kty":"OKP","crv":"Ed25519","x":"…"}`), or its bare `x`. Fetch it once and ship it
    /// with the app.
    public var publicJWK: String
    /// The running app's major version. Set it: the server binds and checks keys by it.
    public var major: Int
    /// A human device name reported to the server (cut to 120 UTF-16 units).
    public var deviceName: String?
    /// Whether a licence is held to the device it was activated on. False for a product on
    /// non-persistent, pooled VDI, where every session may be another machine: no kind is then
    /// reported for its fingerprint, no lease is judged by its device, and the server is told no
    /// fingerprints to check. The device limit still counts seats.
    public var deviceHold: Bool
    /// How long a request may take before the SDK abandons it, for every call that names no
    /// shorter bound of its own. Kept by the SDK whatever the HTTP adapter does with it.
    public var httpTimeout: TimeInterval
    /// Adapter overrides; any left nil uses the default.
    public var adapters: LicenseAdapters

    public init(
        product: String,
        apiBaseURL: URL,
        publicJWK: String,
        major: Int = 1,
        deviceName: String? = nil,
        deviceHold: Bool = true,
        httpTimeout: TimeInterval = 15,
        adapters: LicenseAdapters = LicenseAdapters()
    ) {
        self.product = product
        self.apiBaseURL = apiBaseURL
        self.publicJWK = publicJWK
        self.major = major
        self.deviceName = deviceName
        self.deviceHold = deviceHold
        self.httpTimeout = httpTimeout
        self.adapters = adapters
    }
}

/// The SDK's own time bounds (seconds), and the clock they are kept by, set apart so a test can
/// run them shorter, or on a clock it moves by hand.
struct Timing: Sendable {
    /// How long past its HTTP bound a call may hold the next one waiting.
    var lockGrace: TimeInterval = 15
    /// How long a check `status()` makes on a valid lease may hold it up.
    var statusCheck: TimeInterval = statusCheckTimeout
    /// How long `status()` may spend reading the machine id.
    var machineId: TimeInterval = 2
    /// How long `activate()` and `startTrial()` may: a person is waiting, and a seat is at stake.
    var activateMachineId: TimeInterval = 10
    /// How much longer than its own bound a fingerprinter's `identify` is given.
    var identifySlack: TimeInterval = 1
    /// What every bound above, the HTTP bound and the lock grace are kept by.
    var ticker: any Ticker = SystemTicker()

    static let standard = Timing()
}
