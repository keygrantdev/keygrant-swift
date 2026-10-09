import Foundation

@testable import KeyGrant

/// A `License` over fakes: a storage in memory, a registry stash, a clock and a server the test sets, a
/// fingerprinter that answers `fp-test` unless told otherwise, and a key to sign leases with.
final class Harness: Sendable {
    let license: License
    let storage: MemoryStorage
    let registry: MemoryRegistry
    let clock: FakeClock
    let http: FakeHTTP
    let signer: Signer
    let fingerprinter: any Fingerprinter
    let timing: Timing

    init(
        _ initial: StoredState? = nil,
        major: Int = 1,
        deviceName: String? = nil,
        httpTimeout: TimeInterval = 15,
        fingerprinter: (any Fingerprinter)? = nil,
        deviceHold: Bool = true,
        timing: Timing = .standard
    ) throws {
        storage = MemoryStorage(initial)
        registry = MemoryRegistry()
        clock = FakeClock()
        http = FakeHTTP()
        signer = Signer()
        self.fingerprinter = fingerprinter ?? GetFingerprinter("fp-test")
        self.timing = timing
        license = try License(
            LicenseConfig(
                product: PRODUCT,
                apiBaseURL: apiBase,
                publicJWK: signer.publicJWK,
                major: major,
                deviceName: deviceName,
                deviceHold: deviceHold,
                httpTimeout: httpTimeout,
                adapters: LicenseAdapters(storage: storage, registry: registry, clock: clock, fingerprinter: self.fingerprinter, http: http)
            ),
            timing: timing
        )
    }

    /// Another build of the app on this device: the same storage, server and key, another major.
    func license(major: Int, fingerprinter: (any Fingerprinter)? = nil) throws -> License {
        try License(
            LicenseConfig(
                product: PRODUCT,
                apiBaseURL: apiBase,
                publicJWK: signer.publicJWK,
                major: major,
                adapters: LicenseAdapters(
                    storage: storage, registry: registry, clock: clock, fingerprinter: fingerprinter ?? self.fingerprinter, http: http
                )
            ),
            timing: timing
        )
    }

    var stored: StoredState? { storage.stored }

    /// A lease as the harness's `sign(sub, model, ttl, now)` makes one: activation `act_1`, major 1.
    func sign(_ sub: String = KEY, model: String = "perpetual", ttl: Int = 30 * 24 * 3600, at: Int = NOW) -> String {
        signer.lease(sub: sub, model: model, ttlSeconds: ttl, at: at)
    }
}

/// The API base every harness's `License` posts to (the fake server reads only the action).
let apiBase = URL(string: "https://api.test/") ?? URL(fileURLWithPath: "/")

extension LicenseJSON {
    /// Whether this object has a member named `key`.
    func has(_ key: String) -> Bool { objectValue?[key] != nil }
}
