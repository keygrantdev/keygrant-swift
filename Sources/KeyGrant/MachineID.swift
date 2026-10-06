import Foundation

/// The operating system's own id for this machine, which the default fingerprinter hashes (the
/// reference's `machine-id.ts`). It survives renaming the computer, which the host name does not.
///
///  - macOS: `IOPlatformUUID` of the platform expert device, read in-process through IOKit (the
///    value `/usr/sbin/ioreg -rd1 -c IOPlatformExpertDevice` prints, which a sandboxed app could
///    not run), so a Mac has the same fingerprint here as under the Electron SDK.
///  - Linux (and anything else): `/etc/machine-id`, else `/var/lib/dbus/machine-id`.
///
/// What a read gives is one of three, and the difference keeps a device's identity from ever
/// changing because a read was slow:
///  - `id`: the machine's id.
///  - `unavailable`: there is none to read, and there will not be on the next try either. The
///    fingerprint falls back to the host name, consistently.
///  - `transient`: the read did not finish (a timeout, an error nobody expected). There is NO
///    fingerprint this time, and the next call reads again.
enum MachineIdReading: Sendable, Hashable {
    case id(String)
    case unavailable
    case transient
}

/// Where the machine id is read from: the real system, or a stand-in in tests.
protocol MachineIdSource: Sendable {
    /// Node's name for the platform: `darwin`, `linux`, …
    var platform: String { get }
    /// macOS: the platform expert's `IOPlatformUUID`, or nil when there is none.
    func platformUUID() async throws -> String?
    /// A file's text. Throws a `StorageError` with an errno `code` (`ENOENT`, `EACCES`) when it cannot be read.
    func readFile(_ path: String) async throws -> String
    /// When a file's content was last written (ms since 1970); nil when the source cannot say,
    /// and then the id's age is not judged.
    func modifiedMs(_ path: String) async throws -> Double?
}

/// Where Linux keeps it: systemd's file, else the D-Bus one older systems have.
let linuxMachineIdFiles = ["/etc/machine-id", "/var/lib/dbus/machine-id"]

/// Errors that mean there is nothing to read, now or on the next try.
private let unavailableCodes: Set<String> = ["ENOENT", "EACCES", "EPERM", "ENOTDIR", "EISDIR"]

/// Filesystems held in memory: an id on one of them is written afresh every boot.
private let inMemoryFilesystems: Set<String> = ["tmpfs", "ramfs"]

/// How far before the boot time an id may have been written and still count as written at this boot.
let bootSlackMs = 5_000.0

/// This machine's id, or why there is none. Never throws, and never takes much longer than
/// `timeout` (on `ticker`): every read is bounded.
func readMachineId(
    _ source: any MachineIdSource, timeout: TimeInterval, on ticker: any Ticker = SystemTicker()
) async -> MachineIdReading {
    let bound = ReadBound(timeout: timeout, ticker: ticker)
    if source.platform == "darwin" {
        do {
            // In-process, so bounded by `timeout` itself: the reference's extra half second is
            // for `ioreg`, a process killed at its time box.
            let uuid = try await bound.run { try await source.platformUUID() }
            return idIn(uuid)
        } catch {
            return failureKind(error)
        }
    }
    // An id on a filesystem in memory is new every boot: no id to hold a device to.
    if await transientMachineId(source, bound) { return .unavailable }
    for path in linuxMachineIdFiles {
        let reading = await fromFile(source, path, bound)
        if reading == .unavailable { continue }
        // Written at this boot: a volatile root, whatever its filesystem.
        if case .id = reading, await writtenThisBoot(source, path, bound) { return .unavailable }
        return reading
    }
    return .unavailable
}

/// The bound every read of the machine id is held to.
private struct ReadBound: Sendable {
    var timeout: TimeInterval
    var ticker: any Ticker

    func run<T: Sendable>(_ read: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withTimeout(timeout, on: ticker, read)
    }
}

private func idIn(_ value: String?) -> MachineIdReading {
    guard let value else { return .unavailable }
    let id = jsTrim(value)
    return id.isEmpty ? .unavailable : .id(id)
}

/// Whether a failed read is for good (`unavailable`) or this time only (`transient`): a file that
/// is not there or not ours to read is for good; a timeout, and anything unexpected, this time only.
func failureKind(_ error: Error) -> MachineIdReading {
    if let error = error as? StorageError, unavailableCodes.contains(error.code) { return .unavailable }
    return .transient
}

/// A file's id, or why there is none.
private func fromFile(_ source: any MachineIdSource, _ path: String, _ bound: ReadBound) async -> MachineIdReading {
    do {
        let text = try await bound.run { try await source.readFile(path) }
        return idIn(text)
    } catch {
        return failureKind(error)
    }
}

/// Whether `/etc/machine-id` lives on a filesystem in memory, and so changes every boot. False
/// when mountinfo cannot be read, which leaves the id read as it always was.
private func transientMachineId(_ source: any MachineIdSource, _ bound: ReadBound) async -> Bool {
    do {
        let info = try await bound.run { try await source.readFile("/proc/self/mountinfo") }
        guard let fstype = machineIdFilesystem(info) else { return false }
        return inMemoryFilesystems.contains(fstype)
    } catch {
        return false
    }
}

/// The path whose filesystem says whether the id is transient.
private let machineIdPath = "/etc/machine-id"

/// The type of the filesystem `/etc/machine-id` is on, from `/proc/self/mountinfo` (one mount per
/// line: the mount point is the fifth field, octal-escaped; the type the first field after the
/// ` - ` separator). The mount holding it is the one whose mount point is the longest prefix of the
/// path on a path boundary; of several at that point, the one on top. Nil when no line can be read so.
func machineIdFilesystem(_ mountinfo: String) -> String? {
    var mounts: [Mount] = []
    for line in jsSplit(mountinfo, "\n") {
        let fields = jsSplit(line, " ")
        guard fields.count > 4 else { continue }
        let separator = fields.indices.first(where: { $0 >= 6 && sameText(fields[$0], "-") })
        guard let separator, separator + 1 < fields.count else { continue }
        let point = unescapeOctal(fields[4])
        let holds = sameText(point, machineIdPath) || sameText(point, "/")
            || machineIdPath.unicodeScalars.starts(with: (point + "/").unicodeScalars)
        if holds {
            mounts.append(Mount(id: fields[0], parent: fields[1], point: point, fstype: fields[separator + 1]))
        }
    }
    guard let deepest = mounts.map({ $0.point.utf16.count }).max() else { return nil }
    return topMount(mounts.filter { $0.point.utf16.count == deepest })?.fstype
}

/// `text` split at every `separator`, empty parts kept: JavaScript's `split` by a one-character
/// string, which splits code units, where Swift's `split` keeps a `\r\n` together.
func jsSplit(_ text: String, _ separator: Unicode.Scalar) -> [String] {
    text.unicodeScalars.split(separator: separator, omittingEmptySubsequences: false).map {
        String(String.UnicodeScalarView($0))
    }
}

/// One line of mountinfo that holds /etc/machine-id: its id, its parent's, its mount point and type.
private struct Mount {
    var id: String
    var parent: String
    var point: String
    var fstype: String
}

/// Of mounts at one point, the one on top: the one no other there names as its parent. When that
/// does not settle it (none, or more than one), the last listed.
private func topMount(_ atPoint: [Mount]) -> Mount? {
    let tops = atPoint.indices.filter { index in
        !atPoint.indices.contains { other in other != index && sameText(atPoint[other].parent, atPoint[index].id) }
    }
    if tops.count == 1, let only = tops.first { return atPoint[only] }
    return atPoint.last
}

/// A mount point with its `\NNN` octal escapes decoded, each to the character of that code, as
/// the reference decodes them (`String.fromCharCode`).
private func unescapeOctal(_ text: String) -> String {
    let scalars = Array(text.unicodeScalars)
    var out = String.UnicodeScalarView()
    var index = 0
    while index < scalars.count {
        if scalars[index] == "\\", let value = octalValue(scalars, from: index + 1), let scalar = Unicode.Scalar(value) {
            out.append(scalar)
            index += 4
        } else {
            out.append(scalars[index])
            index += 1
        }
    }
    return String(out)
}

/// The value of three octal digits at `start`, or nil when there are not three there.
private func octalValue(_ scalars: [Unicode.Scalar], from start: Int) -> UInt32? {
    guard start + 2 < scalars.count else { return nil }
    var value: UInt32 = 0
    for scalar in scalars[start...(start + 2)] {
        guard ("0"..."7").contains(scalar) else { return nil }
        value = value * 8 + (scalar.value - 0x30)
    }
    return value
}

/// Whether the machine-id file was written at this boot: its content (mtime) no older than the
/// system's boot time (`btime` in `/proc/stat`, less `bootSlackMs`). False when either cannot be
/// read, which leaves the id read as it always was. Never throws.
private func writtenThisBoot(_ source: any MachineIdSource, _ path: String, _ bound: ReadBound) async -> Bool {
    do {
        async let written = bound.run { try await source.modifiedMs(path) }
        async let procStat = bound.run { try await source.readFile("/proc/stat") }
        guard let mtime = try await written, let btime = bootTime(in: try await procStat) else { return false }
        return mtime >= btime * 1000 - bootSlackMs
    } catch {
        return false
    }
}

/// The `btime` line of `/proc/stat`, in seconds: the first line that is exactly `btime` and its
/// digits (`/^btime (\d+)$/m`, whose lines end at `\n`, `\r`, U+2028 or U+2029).
func bootTime(in procStat: String) -> Double? {
    let lineBreaks: Set<Unicode.Scalar> = ["\n", "\r", "\u{2028}", "\u{2029}"]
    let label = "btime ".unicodeScalars
    for line in procStat.unicodeScalars.split(omittingEmptySubsequences: false, whereSeparator: { lineBreaks.contains($0) }) {
        guard line.starts(with: label) else { continue }
        let digits = line.dropFirst(label.count)
        if !digits.isEmpty, digits.allSatisfy({ ("0"..."9").contains($0) }) {
            return Double(String(String.UnicodeScalarView(digits)))
        }
    }
    return nil
}
