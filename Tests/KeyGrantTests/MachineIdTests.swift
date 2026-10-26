import Foundation
import Testing

@testable import KeyGrant

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

@Suite("the machine id", suiteTimeLimit)
struct MachineIdTests {
    let root = "22 1 8:1 / / rw,relatime shared:1 - ext4 /dev/sda1 rw"
    let overMachineId = "29 23 0:25 /machine-id /etc/machine-id ro,relatime shared:5 - tmpfs tmpfs rw"

    @Test func readsTheMacsIOPlatformUUIDThroughIOKit() async {
        #expect(await readMachineId(mac(.value("564D8A1C-3F6E-4E3B-9F2A-1B2C3D4E5F60")), timeout: 1, on: ManualTicker()) == .id("564D8A1C-3F6E-4E3B-9F2A-1B2C3D4E5F60"))
        #expect(await readMachineId(mac(.value("  padded \n")), timeout: 1, on: ManualTicker()) == .id("padded"))
        // No platform expert, or no UUID on it: nothing to read, for good.
        #expect(await readMachineId(mac(.value(nil)), timeout: 1, on: ManualTicker()) == .unavailable)
        #expect(await readMachineId(mac(.value("  ")), timeout: 1, on: ManualTicker()) == .unavailable)
        // A failure nobody expected, or no answer in time: this time only.
        #expect(await readMachineId(mac(.failure(ScriptedMachineSource.Odd())), timeout: 1, on: ManualTicker()) == .transient)
        #expect(await readMachineId(mac(.hang), timeout: 0.1) == .transient)
    }

    #if os(macOS) || targetEnvironment(macCatalyst)
    /// A Mac app and a Mac Catalyst app read the same id, this Mac's, through IOKit, and are the
    /// same device: the Mac's fingerprint (`machine-id|<id>`, never an install id), with its host
    /// name beside it.
    @Test func readsThisMacsIOPlatformUUIDInAMacAppAndAMacCatalystAppAlike() async throws {
        #expect(nodePlatform == "darwin")
        // The bound is not what is tested: generous, so a busy runner cannot fail it.
        let reading = await readMachineId(SystemMachineIdSource(), timeout: 10)
        guard case .id(let id) = reading else {
            Issue.record("no IOPlatformUUID: \(reading)")
            return
        }
        #expect(UUID(uuidString: id) != nil)
        let identity = try await DefaultFingerprinter(source: SystemMachineIdSource(), cache: FingerprintCache()).identify(timeout: 10)
        #expect(identity == DeviceIdentity(fingerprint: machineFingerprint(id), kind: .machine, alternates: [HOST]))
        // No Keychain install id: on a Mac it would need a provisioning profile.
        #expect(try await SystemMachineIdSource(product: "sluice").installId() == nil)
    }
    #endif

    #if targetEnvironment(macCatalyst)
    /// Compiled only for Mac Catalyst, where `#if os(iOS)` holds: the SDK names the platform as the
    /// Mac it runs on. `ci/sdk/test-swift-macos.sh` checks this test passed, by its name, to know the
    /// Catalyst run ran: rename both together.
    @Test func namesAMacCatalystAppAsTheMacItRunsOn() {
        #expect(swiftOS == "macOS" && nodePlatform == "darwin")
    }
    #endif

    @Test func readsEtcMachineIdOnLinuxElseTheDBusOneTrimmed() async {
        #expect(await readMachineId(linuxMachine(id: "a1b2c3d4e5f6\n"), timeout: 1, on: ManualTicker()) == .id("a1b2c3d4e5f6"))
        let dbus = ScriptedMachineSource(platform: "linux", files: ["/var/lib/dbus/machine-id": .text("dbus0001\n")])
        #expect(await readMachineId(dbus, timeout: 1, on: ManualTicker()) == .id("dbus0001"))
        // An empty systemd file, or one not ours to read: the D-Bus one is read.
        let empty = linuxMachine(id: "\n", more: ["/var/lib/dbus/machine-id": .text("dbus0002")])
        #expect(await readMachineId(empty, timeout: 1, on: ManualTicker()) == .id("dbus0002"))
        let denied = linuxMachine(more: ["/etc/machine-id": .failure("EACCES"), "/var/lib/dbus/machine-id": .text("dbus0003")])
        #expect(await readMachineId(denied, timeout: 1, on: ManualTicker()) == .id("dbus0003"))
    }

    @Test(arguments: ["ENOENT", "EACCES", "EPERM", "ENOTDIR", "EISDIR"])
    func readsAFileThatIsNotThereOrNotOursAsNothingToRead(code: String) async {
        let source = ScriptedMachineSource(platform: "linux", files: ["/etc/machine-id": .failure(code), "/var/lib/dbus/machine-id": .failure(code)])
        #expect(await readMachineId(source, timeout: 1, on: ManualTicker()) == .unavailable)
    }

    @Test(arguments: ["EAGAIN", "EIO", "EMFILE"])
    func readsAnyOtherFailureAsAReadThatDidNotFinish(code: String) async {
        #expect(await readMachineId(linuxMachine(more: ["/etc/machine-id": .failure(code)]), timeout: 1, on: ManualTicker()) == .transient)
        #expect(await readMachineId(mac(.failure(StorageError(code: code, operation: "x", path: "y"))), timeout: 1, on: ManualTicker()) == .transient)
    }

    @Test func givesNoIdOnceTheTimeBoxIsOutWhenAReadNeverFinishes() async {
        let started = Date()
        #expect(await readMachineId(linuxMachine(more: ["/etc/machine-id": .hang]), timeout: 0.15) == .transient)
        #expect(Date().timeIntervalSince(started) < 1.5)
    }

    @Test func hasNoIdToHoldADeviceToWhenAMemoryFilesystemHoldsIt() async {
        let source = linuxMachine(id: "transient-id\n", more: ["/proc/self/mountinfo": .text("\(root)\n\(overMachineId)\n")])
        #expect(await readMachineId(source, timeout: 1, on: ManualTicker()) == .unavailable)
        // So the host name: a `hostname` fingerprint, never held to its device.
        let identity = try? await DefaultFingerprinter(source: source).identify(timeout: 1)
        #expect(identity == DeviceIdentity(fingerprint: HOST, kind: .hostname, alternates: []))
    }

    @Test(arguments: [
        ("the path as a mount's root, not its mount point", "30 23 0:25 /etc/machine-id /run/host-id ro,relatime - tmpfs tmpfs rw"),
        ("a mount point it is only a prefix of", "31 23 0:26 / /etc/machine-id.d rw,relatime - tmpfs tmpfs rw"),
    ])
    func readsTheIdWhenMountinfoOnlySeemsToHoldIt(_ name: String, line: String) async {
        let source = linuxMachine(more: ["/proc/self/mountinfo": .text("\(root)\n\(line)\n")])
        #expect(await readMachineId(source, timeout: 1, on: ManualTicker()) == .id("a1b2c3d4e5f6"), "\(name)")
    }

    @Test func classifiesByTheFilesystemHoldingTheId() {
        let rootTmpfs = "1 0 0:1 / / rw,relatime shared:1 - tmpfs tmpfs rw"
        let cases: [(String, [String], String?)] = [
            ("an impermanent root", [rootTmpfs], "tmpfs"),
            ("an impermanent /etc", [root, "2 1 0:2 / /etc rw,relatime shared:2 - tmpfs none rw"], "tmpfs"),
            ("no optional field", [root, "2 1 0:2 / /etc rw - tmpfs none rw"], "tmpfs"),
            ("two optional fields", [root, "2 1 0:2 / /etc rw shared:2 master:1 - tmpfs tmpfs rw"], "tmpfs"),
            ("an overmount listed BEFORE the mount it covers", ["5 29 8:1 /etc/machine-id /etc/machine-id ro - ext4 /dev/sda1 rw", root, overMachineId], "ext4"),
            ("a prefix but not a parent", [root, "2 1 0:2 / /et rw - tmpfs tmpfs rw"], "ext4"),
            ("systemd's transient id", [root, overMachineId], "tmpfs"),
            ("an escaped mount point", [root, "2 1 0:2 / /et\\143 rw - tmpfs tmpfs rw"], "tmpfs"),
            ("a ramfs /etc", [root, "2 1 0:2 / /etc rw master:4 - ramfs ramfs rw"], "ramfs"),
            ("a stable id bound in from a disk", [root, "3 1 8:1 /etc/machine-id /etc/machine-id ro,relatime - ext4 /dev/sda1 rw"], "ext4"),
            ("a persisted id over an impermanent root", [rootTmpfs, "3 1 8:2 /persist/etc/machine-id /etc/machine-id rw - btrfs /dev/sda2 rw"], "btrfs"),
            ("a disk bound over a tmpfs one", [root, overMachineId, "5 29 8:1 /etc/machine-id /etc/machine-id ro - ext4 /dev/sda1 rw"], "ext4"),
            ("neither over the other, a tmpfs last", [root, "3 1 8:1 /etc/machine-id /etc/machine-id ro - ext4 /dev/sda1 rw", "4 1 0:25 /machine-id /etc/machine-id ro - tmpfs tmpfs rw"], "tmpfs"),
            ("neither over the other, a disk last", [root, "4 1 0:25 /machine-id /etc/machine-id ro - tmpfs tmpfs rw", "3 1 8:1 /etc/machine-id /etc/machine-id ro - ext4 /dev/sda1 rw"], "ext4"),
            ("a CRLF line end does not hide a line", ["\(root)\r", "2 1 0:2 / /etc rw - tmpfs none rw"], "tmpfs"),
            ("nothing readable", ["garbage", "", "1 2 3"], nil),
        ]
        for (name, lines, expected) in cases {
            #expect(machineIdFilesystem(lines.joined(separator: "\n")) == expected, "\(name)")
        }
    }

    @Test func readsTheIdAsAlwaysWhenMountinfoCannotBeRead() async {
        for mountinfo in [ScriptedMachineSource.File?.none, .failure("EIO"), .failure("EACCES")] {
            var source = ScriptedMachineSource(platform: "linux", files: ["/etc/machine-id": .text("a1b2c3d4e5f6\n")])
            if let mountinfo { source.files["/proc/self/mountinfo"] = mountinfo }
            #expect(await readMachineId(source, timeout: 1, on: ManualTicker()) == .id("a1b2c3d4e5f6"))
        }
    }

    // MARK: an id written at this boot

    let btime = 1_757_000_000
    var booted: Double { Double(btime) * 1000 }

    /// A Linux machine booted at `btime`, whose id file was written at `mtime`.
    func written(_ mtime: Double?, procStat: ScriptedMachineSource.File? = nil) -> ScriptedMachineSource {
        linuxMachine(more: [
            "/etc/machine-id": .text("a1b2c3d4e5f6\n", mtimeMs: mtime),
            "/proc/stat": procStat ?? .text("cpu 1 2 3\nbtime \(btime)\n"),
        ])
    }

    @Test func isNoIdWhenTheFileIsNewerThanTheBoot() async {
        #expect(await readMachineId(written(booted + 3_000), timeout: 1, on: ManualTicker()) == .unavailable)
    }

    @Test func isTheIdWhenTheFileDatesFromBeforeTheBoot() async {
        #expect(await readMachineId(written(booted - 90 * Double(DAY)), timeout: 1, on: ManualTicker()) == .id("a1b2c3d4e5f6"))
    }

    @Test func countsTheSlackBeforeBtimeAsThisBootAndNotAMillisecondMore() async {
        #expect(await readMachineId(written(booted - bootSlackMs), timeout: 1, on: ManualTicker()) == .unavailable)
        #expect(await readMachineId(written(booted - bootSlackMs - 1), timeout: 1, on: ManualTicker()) == .id("a1b2c3d4e5f6"))
    }

    @Test func readsTheIdAsAlwaysWhenProcStatOrTheFilesTimeCannotBeRead() async {
        #expect(await readMachineId(written(booted + 3_000, procStat: .failure("ENOENT")), timeout: 1, on: ManualTicker()) == .id("a1b2c3d4e5f6"))
        #expect(await readMachineId(written(booted + 3_000, procStat: .text("cpu 1 2 3\n")), timeout: 1, on: ManualTicker()) == .id("a1b2c3d4e5f6"))
        #expect(await readMachineId(written(nil), timeout: 1, on: ManualTicker()) == .id("a1b2c3d4e5f6"))
    }

    @Test func readsBtimeOnlyFromALineThatIsExactlyIt() {
        #expect(bootTime(in: "cpu 1\nbtime 1757000000\n") == 1_757_000_000)
        #expect(bootTime(in: "cpu 1\r\nbtime 1757000000\r\n") == 1_757_000_000)
        #expect(bootTime(in: "xbtime 1\nbtime 2") == 2)
        #expect(bootTime(in: "btime 12a\nbtime \n") == nil)
    }
}

@Suite("the default fingerprinter", suiteTimeLimit)
struct DefaultFingerprinterTests {
    @Test func hashesTheMachineIdSoTheRawIdNeverLeavesTheMachine() async throws {
        let fingerprinter = DefaultFingerprinter(source: mac(.value("3f2504e0-4f89-11d3-9a0c-0305e82c3301")))
        let fingerprint = try await fingerprinter.get()
        #expect(fingerprint == hashFingerprint("machine-id|3f2504e0-4f89-11d3-9a0c-0305e82c3301"))
        #expect(fingerprint.range(of: "3f2504e0") == nil)
    }

    @Test func offersTheHostNameFingerprintAsAnAlternateBesideTheMachineIds() async throws {
        let identity = try await DefaultFingerprinter(source: mac(.value(UUID_))).identify(timeout: 1)
        #expect(identity == DeviceIdentity(fingerprint: MACHINE, kind: .machine, alternates: [HOST]))
    }

    @Test func survivesARenameTheFingerprintFollowsTheMachineId() async throws {
        let before = try await DefaultFingerprinter(source: linuxMachine(id: "same-machine")).get()
        let after = try await DefaultFingerprinter(source: linuxMachine(id: "same-machine")).get()
        #expect(before == after && before != HOST)
    }

    @Test func fallsBackToTheHostNameForGoodWhenTheMachineHasNoIdToRead() async throws {
        for source in [mac(.value(nil)), ScriptedMachineSource(platform: "linux"), ScriptedMachineSource(platform: "freebsd")] {
            let fingerprinter = DefaultFingerprinter(source: source)
            #expect(try await fingerprinter.get() == HOST)
            // Settled: kept, with no host-name alternate besides itself.
            #expect(try await fingerprinter.identify(timeout: 1) == DeviceIdentity(fingerprint: HOST, kind: .hostname, alternates: []))
        }
    }

    @Test func givesNoFingerprintForAReadThatDidNotFinishAndDoesNotKeepThat() async throws {
        let flaky = mac(.failure(ScriptedMachineSource.Odd()), .value(UUID_))
        let fingerprinter = DefaultFingerprinter(source: flaky)
        // Not a stand-in: no fingerprint, and the host-name one only as what it may have been activated under.
        #expect(try await fingerprinter.identify(timeout: 1) == DeviceIdentity(fingerprint: nil, alternates: [HOST]))
        #expect(try await fingerprinter.identify(timeout: 1).fingerprint == MACHINE)
        #expect(try await fingerprinter.identify(timeout: 1).fingerprint == MACHINE)
        // Kept once read: two reads in all.
        #expect(flaky.reads.count == 2)
    }

    @Test func getThrowsWhenTheIdCannotBeReadRatherThanAnswerAStandIn() async {
        let fingerprinter = DefaultFingerprinter(source: mac(.failure(ScriptedMachineSource.Odd())))
        await #expect(throws: FingerprintUnavailable.self) { try await fingerprinter.get() }
    }

    @Test func composesTheHostNameFingerprintWithNodesNames() {
        let name = systemHostName() ?? "unknown"
        #expect(HOST == hashFingerprint("\(name)|\(nodePlatform)|\(nodeArch)"))
        #expect(["darwin", "linux"].contains(nodePlatform))
        #expect(["x64", "arm64"].contains(nodeArch))
        #expect(nodePlatform == nodePlatformName(swiftOS: swiftOS) && nodeArch == nodeArchName(swiftArch: swiftArch))
    }

    @Test(arguments: [
        ("macOS", "darwin"), ("Linux", "linux"), ("Windows", "win32"), ("FreeBSD", "freebsd"), ("OpenBSD", "openbsd"),
        // iOS and iPadOS, which Node does not run on: the name the SDK's own rules for them go by.
        ("Android", "android"), ("iOS", "ios"),
    ])
    func namesThePlatformAsNodeDoes(swift: String, node: String) {
        #expect(nodePlatformName(swiftOS: swift) == node)
    }

    @Test(arguments: [
        ("x86_64", "x64"), ("arm64", "arm64"), ("i386", "ia32"), ("arm", "arm"), ("powerpc64le", "ppc64"),
        ("powerpc64", "ppc64"), ("s390x", "s390x"), ("riscv64", "riscv64"),
    ])
    func namesTheArchitectureAsNodeDoes(swift: String, node: String) {
        #expect(nodeArchName(swiftArch: swift) == node)
    }

    /// Node's `os.hostname()` is `gethostname`: the name the kernel holds, as `uname` gives it.
    @Test func readsTheHostNameAsTheSystemHoldsIt() throws {
        var system = utsname()
        #expect(uname(&system) == 0)
        let nodename = withUnsafeBytes(of: system.nodename) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        #expect(!nodename.isEmpty)
        #expect(systemHostName() == nodename)
        #if os(Linux)
        let kernel = try String(contentsOfFile: "/proc/sys/kernel/hostname", encoding: .utf8)
        #expect(systemHostName() == kernel.trimmingCharacters(in: .newlines))
        #endif
    }

    @Test func readsTheIdOnceForEveryFingerprinterSharingTheCache() async throws {
        let source = mac(.value(UUID_))
        let cache = FingerprintCache()
        let first = DefaultFingerprinter(source: source, cache: cache)
        let second = DefaultFingerprinter(source: source, cache: cache)
        #expect(try await first.identify(timeout: 1).fingerprint == MACHINE)
        #expect(try await second.identify(timeout: 1) == DeviceIdentity(fingerprint: MACHINE, kind: .machine, alternates: [HOST]))
        #expect(source.reads.count == 1)
        // A fingerprinter with a cache of its own reads for itself.
        #expect(try await DefaultFingerprinter(source: source).identify(timeout: 1).fingerprint == MACHINE)
        #expect(source.reads.count == 2)
    }

    @Test func readsThisMachineOnce() async throws {
        // The system's own id (in a container, often none: then the host name), settled for the process.
        let first = try await DefaultFingerprinter().identify(timeout: 2)
        let second = try await DefaultFingerprinter().identify(timeout: 2)
        let fingerprint = try #require(first.fingerprint)
        #expect(fingerprint.count == 64 && fingerprint.allSatisfy(\.isHexDigit))
        #expect(second == first)
        // In the cache every default fingerprinter of the process shares.
        #expect(FingerprintCache.process.settled?.fingerprint == fingerprint)
    }

    @Test func isTheOneALicenseMakesWhateverTheProductOffAPhone() throws {
        // On a Mac (in a Mac Catalyst run too: this is its pin of the Mac's defaults) or on Linux, a
        // product's default reads the machine, through the process's cache.
        let fingerprinter = DefaultFingerprinter(product: "sluice")
        #expect(fingerprinter.cache === FingerprintCache.process)
        #expect((fingerprinter.source as? SystemMachineIdSource)?.product == "sluice")
        // A licence given no fingerprinter makes that one, and given no stash, the one that keeps nothing.
        let license = try License(LicenseConfig(product: "sluice", apiBaseURL: apiBase, publicJWK: Signer().publicJWK))
        let made = try #require(license.reader.fingerprinter as? DefaultFingerprinter)
        #expect(made.cache === FingerprintCache.process && (made.source as? SystemMachineIdSource)?.product == "sluice")
        #expect(license.registry is NoRegistryStash)
        #expect(defaultRegistry(product: "sluice") is NoRegistryStash)
    }
}
