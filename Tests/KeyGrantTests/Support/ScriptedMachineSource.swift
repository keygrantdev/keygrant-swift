import Foundation

@testable import KeyGrant

/// A machine-id source a test scripts: each file's text or failure (unlisted: `ENOENT`) and when
/// it was written; on macOS, what IOKit gives for the platform expert's UUID.
struct ScriptedMachineSource: MachineIdSource {
    enum File: Sendable {
        case text(String, mtimeMs: Double? = nil)
        /// A read that fails with this errno name.
        case failure(String)
        /// A read that fails in a way nobody expected (no errno: a process killed, say).
        case odd
        /// A read that never finishes.
        case hang
    }

    enum PlatformUUID: Sendable {
        case value(String?)
        case failure(Error & Sendable)
        case hang
    }

    var platform: String
    var files: [String: File] = [:]
    /// What `platformUUID()` answers, in turn; the last answer repeats.
    var uuids: [PlatformUUID] = [.value(nil)]
    /// How many `platformUUID()` calls were made (shared, so a copy counts too).
    let reads = Counter()

    struct Odd: Error {}

    func platformUUID() async throws -> String? {
        let call = reads.next()
        let answer = uuids[min(call, uuids.count) - 1]
        switch answer {
        case .value(let uuid): return uuid
        case .failure(let error): throw error
        case .hang:
            try await Task.sleep(nanoseconds: hangNanoseconds)
            return nil
        }
    }

    func readFile(_ path: String) async throws -> String {
        switch files[path] {
        case nil: throw StorageError(code: "ENOENT", operation: "open", path: path)
        case .text(let text, _)?: return text
        case .failure(let code)?: throw StorageError(code: code, operation: "open", path: path)
        case .odd?: throw Odd()
        case .hang?:
            try await Task.sleep(nanoseconds: hangNanoseconds)
            throw Odd()
        }
    }

    func modifiedMs(_ path: String) async throws -> Double? {
        guard case .text(_, let mtime)? = files[path], let mtime else {
            throw StorageError(code: "ENOENT", operation: "stat", path: path)
        }
        return mtime
    }
}

/// A Linux machine with a persistent root (no tmpfs over /etc), its id in /etc/machine-id.
func linuxMachine(id: String = "a1b2c3d4e5f6\n", more: [String: ScriptedMachineSource.File] = [:]) -> ScriptedMachineSource {
    var files: [String: ScriptedMachineSource.File] = [
        "/proc/self/mountinfo": .text("22 1 8:1 / / rw,relatime shared:1 - ext4 /dev/sda1 rw\n"),
        "/etc/machine-id": .text(id),
    ]
    files.merge(more) { _, new in new }
    return ScriptedMachineSource(platform: "linux", files: files)
}

/// A Mac whose IOKit read answers `uuids` in turn.
func mac(_ uuids: ScriptedMachineSource.PlatformUUID...) -> ScriptedMachineSource {
    ScriptedMachineSource(platform: "darwin", uuids: uuids.isEmpty ? [.value(nil)] : uuids)
}
