import Foundation

@testable import KeyGrant

/// A machine-id source a test scripts: each file's text or failure (unlisted: `ENOENT`) and when
/// it was written; on macOS, what IOKit gives for the platform expert's UUID; on iOS, what the
/// Keychain gives for the install id.
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

    /// What one read of an id answers: the id (nil: none), a failure, or nothing at all.
    enum Answer: Sendable {
        case value(String?)
        case failure(Error & Sendable)
        case hang
    }

    var platform: String
    var files: [String: File] = [:]
    /// What `platformUUID()` answers, in turn; the last answer repeats.
    var uuids: [Answer] = [.value(nil)]
    /// What `installId()` answers, in turn; the last answer repeats.
    var installIds: [Answer] = [.value(nil)]
    /// How many `platformUUID()` calls were made (shared, so a copy counts too).
    let reads = Counter()
    /// How many `installId()` calls were made (shared, so a copy counts too).
    let installReads = Counter()

    struct Odd: Error {}

    func platformUUID() async throws -> String? {
        try await answer(uuids, call: reads.next())
    }

    func installId() async throws -> String? {
        try await answer(installIds, call: installReads.next())
    }

    /// The answer of call number `call` (from 1) of `script`.
    private func answer(_ script: [Answer], call: Int) async throws -> String? {
        switch script[min(call, script.count) - 1] {
        case .value(let id): return id
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
func mac(_ uuids: ScriptedMachineSource.Answer...) -> ScriptedMachineSource {
    ScriptedMachineSource(platform: "darwin", uuids: uuids.isEmpty ? [.value(nil)] : uuids)
}

/// An iPhone or iPad whose Keychain read of its install id answers `ids` in turn.
func iPhone(_ ids: ScriptedMachineSource.Answer...) -> ScriptedMachineSource {
    ScriptedMachineSource(platform: "ios", installIds: ids.isEmpty ? [.value(nil)] : ids)
}
