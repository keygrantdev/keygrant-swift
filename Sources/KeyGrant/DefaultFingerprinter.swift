import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// The default fingerprinter: the operating system's machine id (`IOPlatformUUID` on macOS,
/// `/etc/machine-id` on Linux), hashed so the raw id never leaves the machine; the host name's
/// when the machine has no id to read, and `identify` says which (`kind`). A read that did not
/// finish gives NO fingerprint and is not kept, so the next call reads again: a device's
/// fingerprint never changes with how fast a read was. A settled fingerprint is kept for the
/// process, shared by every default fingerprinter in it.
///
/// `get()` waits as long as an activation does and THROWS when the id still could not be read;
/// the SDK itself uses `identify`. A wrapper around this fingerprinter should delegate `identify`,
/// to keep the kind and the host-name alternate.
public final class DefaultFingerprinter: Fingerprinter {
    /// Where the id is read from.
    private let source: any MachineIdSource
    /// Where the fingerprint it settles on is kept.
    private let cache: FingerprintCache
    /// What the bound on a read is kept by.
    private let ticker: any Ticker

    public init() {
        source = SystemMachineIdSource()
        cache = .process
        ticker = SystemTicker()
    }

    /// A fingerprinter reading `source`, keeping what it settles on in `cache` (one of its own
    /// unless given), its reads bounded on `ticker`.
    init(source: any MachineIdSource, cache: FingerprintCache = FingerprintCache(), ticker: any Ticker = SystemTicker()) {
        self.source = source
        self.cache = cache
        self.ticker = ticker
    }

    public func get() async throws -> String {
        guard let fingerprint = try await identify(timeout: Timing.standard.activateMachineId).fingerprint else {
            throw FingerprintUnavailable()
        }
        return fingerprint
    }

    /// As `identityOf`, with the settled fingerprint kept: the host name's alternate is this
    /// call's, the fingerprint the one first settled on.
    public func identify(timeout: TimeInterval) async throws -> DeviceIdentity {
        let host = hostNames()
        if let settled = cache.settled { return withHostAlternate(settled, legacy: hostNamesFingerprint(host)) }
        let identity = identityOf(await readMachineId(source, timeout: timeout, on: ticker), host: host)
        if let fingerprint = identity.fingerprint, let kind = identity.kind {
            cache.keep(Settled(fingerprint: fingerprint, kind: kind))
        }
        return identity
    }
}

/// A settled fingerprint, and what it hashes.
struct Settled: Sendable, Hashable {
    var fingerprint: String
    var kind: DeviceKind
}

/// Where a default fingerprinter keeps the fingerprint it settled on: the process's own
/// (`process`, shared by every `DefaultFingerprinter()`, so the id is read once per process), or
/// one of a test's.
final class FingerprintCache: Sendable {
    static let process = FingerprintCache()

    private let value = Locked<Settled?>(nil)

    var settled: Settled? { value.current }

    func keep(_ found: Settled) {
        value.withValue { $0 = found }
    }
}

/// Who this device is, as the default fingerprinter answers (`identify`), from a reading of its
/// machine id (`readMachineId`) and its host names (nil when they cannot be read):
///  - `id`: the machine id's fingerprint (`machineFingerprint`), kind `machine`, with the host
///    name's (`hostFingerprint`) as an alternate, none when the two are the same;
///  - `unavailable` (no id to read): the host name's, kind `hostname`, no alternate;
///  - `transient` (the read did not finish): no fingerprint this time, and the host name's as an
///    alternate.
/// The host name's is `unknownHost`'s when the names cannot be read.
func identityOf(_ reading: MachineIdReading, host: HostNames?) -> DeviceIdentity {
    let legacy = hostNamesFingerprint(host)
    return withHostAlternate(settledOn(reading, hostFingerprint: legacy), legacy: legacy)
}

/// What a reading of the machine id settles on: its fingerprint; the host name's when there is no
/// id to read; nil when the read did not finish, which settles nothing.
private func settledOn(_ reading: MachineIdReading, hostFingerprint: String) -> Settled? {
    switch reading {
    case .id(let id): Settled(fingerprint: machineFingerprint(id), kind: .machine)
    case .unavailable: Settled(fingerprint: hostFingerprint, kind: .hostname)
    case .transient: nil
    }
}

/// Who a settled fingerprint is (nil: none this time), with the host name's (`legacy`) as an
/// alternate when it is another.
private func withHostAlternate(_ known: Settled?, legacy: String) -> DeviceIdentity {
    guard let known else { return DeviceIdentity(fingerprint: nil, alternates: [legacy]) }
    let alternates = sameText(known.fingerprint, legacy) ? [] : [legacy]
    return DeviceIdentity(fingerprint: known.fingerprint, kind: known.kind, alternates: alternates)
}

/// What `DefaultFingerprinter.get()` throws when the machine id could not be read in time.
public struct FingerprintUnavailable: Error, Sendable, CustomStringConvertible {
    public var description: String { "this machine's id could not be read in time" }
}

/// The fingerprint of a machine id as it is read (its case kept).
public func machineFingerprint(_ id: String) -> String {
    hashFingerprint("machine-id|" + id)
}

/// What is hashed when not even the host name can be read.
let unknownHost = "unknown-host"

/// The fingerprint the SDKs gave before the machine id: the host name, platform and architecture
/// (with Node's names, so a machine has one whichever SDK reads it), hashed. Still offered as an
/// alternate, and the fingerprint when the machine has no id to read.
public func hostnameFingerprint() -> String {
    hostNamesFingerprint(hostNames())
}

/// What a host-name fingerprint hashes, as Node names them (`hostFingerprint`).
struct HostNames: Sendable, Hashable {
    var host: String
    var platform: String
    var arch: String
}

/// This machine's host names, or nil when its host name cannot be read.
func hostNames() -> HostNames? {
    systemHostName().map { HostNames(host: $0, platform: nodePlatform, arch: nodeArch) }
}

/// The host-name fingerprint of these names; when they could not be read (nil), `unknownHost`'s.
func hostNamesFingerprint(_ names: HostNames?) -> String {
    guard let names else { return hashFingerprint(unknownHost) }
    return hostFingerprint(host: names.host, platform: names.platform, arch: names.arch)
}

/// What `hostnameFingerprint` hashes, from the host name and Node's names for the platform and
/// architecture (`darwin`/`linux`/`win32`, `x64`/`arm64`/`ia32`/`arm`): every SDK composes it the
/// same way, so a machine is one device whichever reads it.
public func hostFingerprint(host: String, platform: String, arch: String) -> String {
    hashFingerprint("\(host)|\(platform)|\(arch)")
}

/// The host name, as `gethostname` gives it (Node's `os.hostname()`).
func systemHostName() -> String? {
    var buffer = [CChar](repeating: 0, count: 257)
    let status = buffer.withUnsafeMutableBufferPointer { bytes -> Int32 in
        guard let start = bytes.baseAddress else { return -1 }
        return gethostname(start, 256)
    }
    guard status == 0 else { return nil }
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
}

/// Node's `os.platform()` for this process.
let nodePlatform = nodePlatformName(swiftOS: swiftOS)

/// Node's `os.arch()` for this process (the process's architecture, as Node's is).
let nodeArch = nodeArchName(swiftArch: swiftArch)

/// Node's `os.platform()` name for an operating system as Swift's `#if os(…)` names it; one
/// Node has no name for, lower-cased.
func nodePlatformName(swiftOS os: String) -> String {
    switch os {
    case "macOS": "darwin"
    case "Linux": "linux"
    case "Windows": "win32"
    case "FreeBSD": "freebsd"
    case "OpenBSD": "openbsd"
    case "Android": "android"
    default: os.lowercased()
    }
}

/// Node's `os.arch()` name for an architecture as Swift's `#if arch(…)` names it; one Node has no
/// name for, as Swift names it.
func nodeArchName(swiftArch arch: String) -> String {
    switch arch {
    case "x86_64": "x64"
    case "arm64": "arm64"
    case "i386": "ia32"
    case "arm": "arm"
    // Node names 64-bit PowerPC `ppc64` whatever its byte order.
    case "powerpc64", "powerpc64le": "ppc64"
    case "s390x": "s390x"
    case "riscv64": "riscv64"
    default: arch
    }
}

/// The operating system this was built for, as `#if os(…)` names it.
let swiftOS: String = {
    #if os(macOS)
    return "macOS"
    #elseif os(iOS)
    return "iOS"
    #elseif os(tvOS)
    return "tvOS"
    #elseif os(watchOS)
    return "watchOS"
    #elseif os(visionOS)
    return "visionOS"
    #elseif os(Linux)
    return "Linux"
    #elseif os(Android)
    return "Android"
    #elseif os(Windows)
    return "Windows"
    #elseif os(FreeBSD)
    return "FreeBSD"
    #elseif os(OpenBSD)
    return "OpenBSD"
    #elseif os(WASI)
    return "WASI"
    #else
    return "unknown"
    #endif
}()

/// The architecture this was built for, as `#if arch(…)` names it.
let swiftArch: String = {
    #if arch(x86_64)
    return "x86_64"
    #elseif arch(arm64)
    return "arm64"
    #elseif arch(i386)
    return "i386"
    #elseif arch(arm)
    return "arm"
    #elseif arch(powerpc64le)
    return "powerpc64le"
    #elseif arch(powerpc64)
    return "powerpc64"
    #elseif arch(s390x)
    return "s390x"
    #elseif arch(riscv64)
    return "riscv64"
    #elseif arch(wasm32)
    return "wasm32"
    #else
    return "unknown"
    #endif
}()

/// The real system: IOKit on macOS, the files on Linux.
struct SystemMachineIdSource: MachineIdSource {
    var platform: String { nodePlatform }

    func platformUUID() async throws -> String? {
        #if os(macOS)
        return PlatformExpert.uuid()
        #else
        return nil
        #endif
    }

    func readFile(_ path: String) async throws -> String {
        try await blocking { try POSIX.readText(path) }
    }

    func modifiedMs(_ path: String) async throws -> Double? {
        try await blocking { try POSIX.modifiedMs(path) }
    }
}
