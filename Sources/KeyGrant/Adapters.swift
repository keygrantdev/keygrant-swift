import Foundation

// All platform I/O lives behind these. Each has a default (`License` uses it when the app gives
// none); a test gives its own.

/// Where the licence state is kept.
public protocol StorageAdapter: Sendable {
    /// The stored state, or nil for none. `readOnly` (a call behind one that has not finished):
    /// read and write nothing, not even to repair or migrate.
    func read(readOnly: Bool) async throws -> StoredState?

    /// Save a whole state.
    func write(_ state: StoredState) async throws

    /// Save `merge` of the state as stored at the moment of saving, merged again onto a newer one
    /// when another process saved in between. Optional: the default reads, merges and writes.
    func update(_ merge: @escaping @Sendable (StoredState) -> StoredState) async throws
}

extension StorageAdapter {
    public func read() async throws -> StoredState? {
        try await read(readOnly: false)
    }

    public func update(_ merge: @escaping @Sendable (StoredState) -> StoredState) async throws {
        try await write(merge(try await read(readOnly: false) ?? StoredState()))
    }
}

/// A trial start kept where it survives the app being deleted (the Windows registry, the
/// Keychain: `KeychainTrialStash`), so a reinstall cannot restart a trial. The default keeps nothing,
/// except on iOS and iPadOS, where it is the Keychain (`defaultRegistry(product:)`).
public protocol RegistryStash: Sendable {
    /// The trial start stashed (ms since 1970), or nil for none.
    func readTrialStart() async throws -> Int?
    func writeTrialStart(_ ms: Int) async throws
}

/// The default registry stash on a Mac and on Linux: keeps nothing.
public struct NoRegistryStash: RegistryStash {
    public init() {}
    public func readTrialStart() async throws -> Int? { nil }
    public func writeTrialStart(_ ms: Int) async throws {}
}

/// The registry stash a licence keeps where the app gives none: the Keychain on iOS and iPadOS
/// (contract 4.1), which every app there may use without asking; nothing elsewhere, the Mac's data
/// protection keychain (a Mac Catalyst app's too) needing an entitlement not every app has, and Linux
/// having none.
func defaultRegistry(product: String) -> any RegistryStash {
    #if os(iOS) && !targetEnvironment(macCatalyst)
    return KeychainTrialStash(product: product)
    #else
    return NoRegistryStash()
    #endif
}

/// The device's wall clock. (Not named `Clock`: the standard library's `Clock` protocol would be
/// shadowed by it in every file that imports KeyGrant.)
public protocol LicenseClock: Sendable {
    /// Milliseconds since 1970.
    func now() -> Int
}

/// The default clock: the system's.
public struct SystemClock: LicenseClock {
    public init() {}
    public func now() -> Int { wallClockMs() }
}

/// Who this device is.
public protocol Fingerprinter: Sendable {
    /// This device's fingerprint. A throw, or no answer in time, is read as "cannot tell this
    /// time". A fingerprinter with only `get()` says nothing of what its fingerprint hashes, so its
    /// seats are NEVER held to their device: implement `identify` and report `kind: .machine` for a
    /// stable machine id that should be.
    func get() async throws -> String

    /// Optional, and what the SDK uses when given: this device's fingerprint (nil when it cannot be
    /// read this time), what it hashes (`kind`), and any other fingerprints this device has been
    /// activated under (`alternates`). A wrapper around `DefaultFingerprinter` should delegate it,
    /// to keep its kind and its host-name alternate.
    func identify(timeout: TimeInterval) async throws -> DeviceIdentity
}

extension Fingerprinter {
    /// Not implemented: the SDK then uses `get()`, with no kind and no alternates.
    public func identify(timeout: TimeInterval) async throws -> DeviceIdentity {
        throw IdentifyNotImplemented()
    }
}

/// What the default `identify` throws, so the SDK knows to use `get()`.
struct IdentifyNotImplemented: Error, Sendable {}

/// A response: its status and its body, parsed (nil when it is not JSON). 4xx and 5xx are responses.
///
/// Formerly `HTTPResponse`, a name that collides with the HTTP types of many other modules.
public struct LicenseHTTPResponse: Sendable, Hashable {
    public var status: Int
    public var json: LicenseJSON?

    public init(status: Int, json: LicenseJSON?) {
        self.status = status
        self.json = json
    }
}

/// The name `LicenseHTTPResponse` had before: kept so code written against it still builds. An
/// app that also imports a module with an `HTTPResponse` of its own names this one
/// `LicenseHTTPResponse`.
@available(*, deprecated, renamed: "LicenseHTTPResponse")
public typealias HTTPResponse = LicenseHTTPResponse

/// The minimal HTTP the SDK needs.
public protocol HTTPAdapter: Sendable {
    /// POST `body` as JSON to `url`. Throws when nothing answered (no network, a timeout), never
    /// for a 4xx or 5xx. `timeout` is how long the call may take; the SDK holds every call to it
    /// itself as well, whatever the adapter does with it.
    func post(_ url: URL, body: LicenseJSON, timeout: TimeInterval) async throws -> LicenseHTTPResponse
}

/// Every adapter, any of them nil to use the default.
public struct LicenseAdapters: Sendable {
    /// Default: `FileStorage` at `FileStorage.defaultPath(product:)`.
    public var storage: (any StorageAdapter)?
    /// Default: `NoRegistryStash`; on iOS and iPadOS, `KeychainTrialStash`.
    public var registry: (any RegistryStash)?
    /// Default: `SystemClock`.
    public var clock: (any LicenseClock)?
    /// Default: `DefaultFingerprinter(product:)`.
    public var fingerprinter: (any Fingerprinter)?
    /// Default: `URLSessionHTTP`.
    public var http: (any HTTPAdapter)?

    public init(
        storage: (any StorageAdapter)? = nil,
        registry: (any RegistryStash)? = nil,
        clock: (any LicenseClock)? = nil,
        fingerprinter: (any Fingerprinter)? = nil,
        http: (any HTTPAdapter)? = nil
    ) {
        self.storage = storage
        self.registry = registry
        self.clock = clock
        self.fingerprinter = fingerprinter
        self.http = http
    }
}
