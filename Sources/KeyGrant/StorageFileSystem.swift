import Foundation

/// The file operations under the default storage, and what it does around them: tries again on a
/// busy file, a temp file flushed to the disk, and the clearing of what crashes and corrupt files
/// leave behind (the reference's `storage-fs.ts`).

/// A new file being written: what is written is flushed to the disk by `sync`.
protocol StorageFile: Sendable {
    func write(_ data: Data) async throws
    func sync() async throws
    func close() async throws
}

/// The file operations the storage uses: the real ones, or stand-ins in tests. Each failure is a
/// `StorageError` named by its errno.
protocol StorageFileSystem: Sendable {
    func readFile(_ path: String) async throws -> String
    /// A new file to write, failing when there is one by that name.
    func create(_ path: String) async throws -> any StorageFile
    func rename(_ from: String, _ to: String) async throws
    /// Removes a file; one that is not there is not an error.
    func remove(_ path: String) async throws
    func list(_ directory: String) async throws -> [String]
    /// When a file was last written, in milliseconds since 1970.
    func modifiedMs(_ path: String) async throws -> Double
    func makeDirectory(_ path: String) async throws
    /// Flushes a folder's entries (a rename in it) to the disk.
    func syncDirectory(_ path: String) async throws
}

/// The real file system: POSIX calls, each on a thread of its own.
struct POSIXFileSystem: StorageFileSystem {
    func readFile(_ path: String) async throws -> String {
        try await blocking { try POSIX.readText(path) }
    }

    func create(_ path: String) async throws -> any StorageFile {
        POSIXFile(fd: try await blocking { try POSIX.createFile(path) }, path: path)
    }

    func rename(_ from: String, _ to: String) async throws {
        try await blocking { try POSIX.rename(from, to) }
    }

    func remove(_ path: String) async throws {
        try await blocking { try POSIX.remove(path) }
    }

    func list(_ directory: String) async throws -> [String] {
        try await blocking { try POSIX.list(directory) }
    }

    func modifiedMs(_ path: String) async throws -> Double {
        try await blocking { try POSIX.modifiedMs(path) }
    }

    func makeDirectory(_ path: String) async throws {
        try await blocking { try POSIX.makeDirectories(path) }
    }

    func syncDirectory(_ path: String) async throws {
        try await blocking { try POSIX.syncDirectory(path) }
    }
}

private struct POSIXFile: StorageFile {
    let fd: Int32
    let path: String

    func write(_ data: Data) async throws {
        let (fd, path) = (fd, path)
        try await blocking { try POSIX.writeAll(fd, data, path: path) }
    }

    func sync() async throws {
        let (fd, path) = (fd, path)
        try await blocking { try POSIX.flush(fd, path: path) }
    }

    func close() async throws {
        let (fd, path) = (fd, path)
        try await blocking { try POSIX.close(fd, path: path) }
    }
}

/// Waits between tries of a read that failed other than for a missing file: about a second in all.
let readBackoffMs = [50, 100, 200, 300, 350]
/// Waits between tries of a rename a busy file refused: about a second and a half in all.
let renameBackoffMs = [50, 100, 200, 400, 800]
/// How many set-aside `.corrupt` files of a state file are kept: the newest.
let keepCorrupt = 3
/// How old a temp file must be to be a crash's leftover rather than another instance's write in flight.
let staleTempMs = 60_000.0

/// Errors a busy file gives a rename (an antivirus scan, an indexer, a backup), worth another try.
func busy(_ code: String?) -> Bool {
    ["EBUSY", "EPERM", "EACCES"].contains(code ?? "")
}

func missing(_ code: String?) -> Bool {
    code == "ENOENT"
}

/// The errno name of a storage failure.
func codeOf(_ error: Error) -> String? {
    (error as? StorageError)?.code
}

/// Sleeps the milliseconds given; a test makes it record them instead.
typealias Sleep = @Sendable (Int) async -> Void

let realSleep: Sleep = { ms in await pause(Double(ms) / 1000) }

/// `work`, tried again after each wait in `backoff` while its error is worth another try; the
/// last error otherwise.
func retrying<T: Sendable>(
    _ backoff: [Int],
    worthAgain: (String?) -> Bool,
    sleep: Sleep,
    _ work: () async throws -> T
) async throws -> T {
    for wait in backoff {
        do {
            return try await work()
        } catch {
            if !worthAgain(codeOf(error)) { throw error }
            await sleep(wait)
        }
    }
    return try await work()
}

/// A file's text, tried again for about a second on any failure but a missing file; nil when it is missing.
func readText(_ fs: any StorageFileSystem, _ path: String, sleep: Sleep) async throws -> String? {
    do {
        return try await retrying(readBackoffMs, worthAgain: { !missing($0) }, sleep: sleep) {
            try await fs.readFile(path)
        }
    } catch {
        if missing(codeOf(error)) { return nil }
        throw error
    }
}

/// A state written whole to a new temp file in `directory`, named with the time it was made
/// (`now`, ms since 1970), and flushed to the disk before it is closed, so a rename of it after a
/// power cut finds it whole. Removed when it fails.
func writeTemp(
    _ fs: any StorageFileSystem, _ directory: String, _ prefix: String, _ state: StoredState, now: Int
) async throws -> String {
    try await fs.makeDirectory(directory)
    let unique = String(UInt64.random(in: 0...UInt64.max), radix: 36)
    let pid = ProcessInfo.processInfo.processIdentifier
    let temp = joinPath(directory, "\(prefix)\(pid).\(now).\(unique).tmp")
    do {
        let data = JSONText.data(state.json)
        let file = try await fs.create(temp)
        do {
            try await file.write(data)
            try await file.sync()
        } catch {
            try? await file.close()
            throw error
        }
        try await file.close()
        return temp
    } catch {
        try? await fs.remove(temp)
        throw error
    }
}

/// The names of a storage file's temp files in its folder.
private func temps(_ names: [String], _ prefix: String) -> [String] {
    names.filter { $0.hasPrefix(prefix) && $0.hasSuffix(".tmp") }
}

/// The newest temp file of a storage file that parses, when the file itself is missing (a write
/// that finished but was never renamed in). Never throws.
func leftover(_ fs: any StorageFileSystem, _ directory: String, _ prefix: String) async -> StoredState? {
    do {
        var dated: [(path: String, at: Double)] = []
        for name in temps(try await fs.list(directory), prefix) {
            let path = joinPath(directory, name)
            dated.append((path, try await fs.modifiedMs(path)))
        }
        for (path, _) in dated.sorted(by: { $0.at > $1.at }) {
            // A torn one does not parse: the next older one.
            if let text = try? await fs.readFile(path), let json = JSONText.parse(text), case .object = json {
                return StoredState(json: json)
            }
        }
        return nil
    } catch {
        return nil
    }
}

/// Removes a storage file's temp files `staleTempMs` old or older at `now` (ms since 1970); one
/// whose age cannot be read is taken as new. Never fails the write it follows.
func clearStale(_ fs: any StorageFileSystem, _ directory: String, _ prefix: String, now nowMs: Int) async {
    guard let names = try? await fs.list(directory) else { return }
    let now = Double(nowMs)
    for name in temps(names, prefix) {
        let path = joinPath(directory, name)
        let at = (try? await fs.modifiedMs(path)) ?? now
        if now - at >= staleTempMs { try? await fs.remove(path) }
    }
}

/// Removes all but the newest `keepCorrupt` set-aside files of a state file, newest by the time in
/// their names (when they were set aside; a rename keeps a file's own mtime). Never throws.
func pruneCorrupt(_ fs: any StorageFileSystem, _ directory: String, _ prefix: String) async {
    guard let names = try? await fs.list(directory) else { return }
    let aside = names.compactMap { name -> (name: String, at: Double)? in
        guard name.hasPrefix(prefix) else { return nil }
        let rest = name.dropFirst(prefix.count)
        guard rest.hasSuffix(".corrupt") else { return nil }
        let digits = rest.dropLast(".corrupt".count)
        guard !digits.isEmpty, digits.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }),
            let at = Double(String(digits))
        else { return nil }
        return (name, at)
    }
    for file in aside.sorted(by: { $0.at > $1.at }).dropFirst(keepCorrupt) {
        try? await fs.remove(joinPath(directory, file.name))
    }
}

/// `name` in `directory`.
func joinPath(_ directory: String, _ name: String) -> String {
    directory.hasSuffix("/") ? directory + name : directory + "/" + name
}

/// A path's folder and file name (`dirname`, `basename`).
func splitPath(_ path: String) -> (directory: String, name: String) {
    guard let slash = path.lastIndex(of: "/") else { return (".", path) }
    let name = String(path[path.index(after: slash)...])
    let directory = String(path[..<slash])
    return (directory.isEmpty ? "/" : directory, name)
}
