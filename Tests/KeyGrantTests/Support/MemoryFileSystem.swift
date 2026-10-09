import Foundation

@testable import KeyGrant

/// Files in memory, as one or more processes see them: failures queued per operation (`failNext`)
/// or given every time (`failAlways`), an operation held until released (`holdNext`), something
/// another process does just before an operation (`before`), each file's mtime (else now), every
/// operation in order (`ops`) and every one that changes a file (`changes`).
final class MemoryFileSystem: StorageFileSystem {
    enum Op: String, Sendable {
        case readFile, create, write, sync, close, rename, remove, list, modifiedMs, makeDirectory, syncDirectory
    }

    private struct State {
        var files: [String: String]
        var mtimes: [String: Double] = [:]
        var queued: [Op: [String]] = [:]
        var always: [Op: String] = [:]
        var holds: [Op: [Hold]] = [:]
        var before: [Op: @Sendable () -> Void] = [:]
        var ops: [String] = []
        var changes: [String] = []
    }

    /// An operation held until released.
    final class Hold: Sendable {
        private let state = Locked<(reached: Bool, released: Bool, waiter: CheckedContinuation<Void, Never>?)>((false, false, nil))

        var reached: Bool { state.current.reached }

        func release() {
            let waiter = state.withValue { state -> CheckedContinuation<Void, Never>? in
                state.released = true
                defer { state.waiter = nil }
                return state.waiter
            }
            waiter?.resume()
        }

        func wait() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let released = state.withValue { state -> Bool in
                    state.reached = true
                    if state.released { return true }
                    state.waiter = continuation
                    return false
                }
                if released { continuation.resume() }
            }
        }
    }

    private let state: Locked<State>

    init(_ files: [String: String] = [:]) {
        state = Locked(State(files: files))
    }

    var files: [String: String] { state.current.files }
    var ops: [String] { state.current.ops }
    var changes: [String] { state.current.changes }

    func set(_ path: String, _ text: String?) { state.withValue { $0.files[path] = text } }
    func setMtime(_ path: String, _ ms: Double) { state.withValue { $0.mtimes[path] = ms } }
    func failNext(_ op: Op, _ codes: String...) { state.withValue { $0.queued[op, default: []] += codes } }
    func failAlways(_ op: Op, _ code: String) { state.withValue { $0.always[op] = code } }
    func before(_ op: Op, _ action: @escaping @Sendable () -> Void) { state.withValue { $0.before[op] = action } }

    /// Holds the next `op` until the hold is released.
    func holdNext(_ op: Op) -> Hold {
        let hold = Hold()
        state.withValue { $0.holds[op, default: []].append(hold) }
        return hold
    }

    private func enter(_ op: Op, _ path: String, changing: Bool = false) async throws {
        let (before, hold) = state.withValue { state -> ((@Sendable () -> Void)?, Hold?) in
            let hold = state.holds[op]?.isEmpty == false ? state.holds[op]?.removeFirst() : nil
            return (state.before[op], hold)
        }
        before?()
        if let hold { await hold.wait() }
        let code = state.withValue { state -> String? in
            if var queue = state.queued[op], !queue.isEmpty {
                let code = queue.removeFirst()
                state.queued[op] = queue
                return code
            }
            return state.always[op]
        }
        if let code { throw StorageError(code: code, operation: op.rawValue, path: path) }
        state.withValue { state in
            state.ops.append("\(op.rawValue) \(path)")
            if changing { state.changes.append("\(op.rawValue) \(path)") }
        }
    }

    private func missing(_ op: Op, _ path: String) -> StorageError {
        StorageError(code: "ENOENT", operation: op.rawValue, path: path)
    }

    func readFile(_ path: String) async throws -> String {
        try await enter(.readFile, path)
        guard let text = state.current.files[path] else { throw missing(.readFile, path) }
        return text
    }

    func create(_ path: String) async throws -> any StorageFile {
        try await enter(.create, path, changing: true)
        let exists = state.withValue { state -> Bool in
            if state.files[path] != nil { return true }
            state.files[path] = ""
            return false
        }
        if exists { throw StorageError(code: "EEXIST", operation: "create", path: path) }
        return MemoryFile(fs: self, path: path)
    }

    fileprivate func writeFile(_ path: String, _ data: Data) async throws {
        try await enter(.write, path, changing: true)
        state.withValue { $0.files[path] = String(decoding: data, as: UTF8.self) }
    }

    fileprivate func syncFile(_ path: String) async throws { try await enter(.sync, path) }
    fileprivate func closeFile(_ path: String) async throws { try await enter(.close, path) }

    func rename(_ from: String, _ to: String) async throws {
        try await enter(.rename, "\(from) \(to)", changing: true)
        let moved = state.withValue { state -> Bool in
            guard let text = state.files[from] else { return false }
            state.files[to] = text
            state.files[from] = nil
            return true
        }
        if !moved { throw missing(.rename, from) }
    }

    func remove(_ path: String) async throws {
        try await enter(.remove, path, changing: true)
        state.withValue { _ = $0.files.removeValue(forKey: path) }
    }

    func list(_ directory: String) async throws -> [String] {
        try await enter(.list, directory)
        return state.current.files.keys.compactMap { path in
            let (folder, name) = splitPath(path)
            return folder == directory ? name : nil
        }
    }

    func modifiedMs(_ path: String) async throws -> Double {
        try await enter(.modifiedMs, path)
        return state.current.mtimes[path] ?? Double(wallClockMs())
    }

    func makeDirectory(_ path: String) async throws { try await enter(.makeDirectory, path) }
    func syncDirectory(_ path: String) async throws { try await enter(.syncDirectory, path) }
}

private struct MemoryFile: StorageFile {
    let fs: MemoryFileSystem
    let path: String

    func write(_ data: Data) async throws { try await fs.writeFile(path, data) }
    func sync() async throws { try await fs.syncFile(path) }
    func close() async throws { try await fs.closeFile(path) }
}

/// Waits that take no time, recorded: what a retry would have slept.
final class NoSleep: Sendable {
    private let value = Locked<[Int]>([])
    var slept: [Int] { value.current }
    var sleep: Sleep { { [value] ms in value.withValue { $0.append(ms) } } }
}
