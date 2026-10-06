import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// A file system call that failed, with the errno name the reference's logic is written in
/// (`ENOENT`, `EBUSY`, …), or `ECONFLICT` for a save another process kept changing under it.
public struct StorageError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The errno name: `ENOENT`, `EACCES`, `EBUSY`, `EIO`, … (`E<number>` for one without a name here).
    public var code: String
    /// What failed: `open`, `read`, `rename`, …
    public var operation: String
    public var path: String

    public init(code: String, operation: String, path: String) {
        self.code = code
        self.operation = operation
        self.path = path
    }

    public var description: String { "\(code): \(operation) \(path)" }
}

/// The blocking POSIX calls under the default storage and the Linux machine id. Each throws a
/// `StorageError` named by its errno.
enum POSIX {
    /// An environment variable as the process has it now (`getenv`), or nil when it is not set.
    static func environment(_ name: String) -> String? {
        getenv(name).map { String(cString: $0) }
    }

    static func failure(_ operation: String, _ path: String, _ code: Int32 = errno) -> StorageError {
        StorageError(code: errnoName(code), operation: operation, path: path)
    }

    static func errnoName(_ code: Int32) -> String {
        switch code {
        case ENOENT: "ENOENT"
        case EACCES: "EACCES"
        case EPERM: "EPERM"
        case EBUSY: "EBUSY"
        case EEXIST: "EEXIST"
        case ENOTDIR: "ENOTDIR"
        case EISDIR: "EISDIR"
        case EIO: "EIO"
        case ENOSPC: "ENOSPC"
        case EAGAIN: "EAGAIN"
        case EMFILE: "EMFILE"
        case ENFILE: "ENFILE"
        case EINVAL: "EINVAL"
        case EROFS: "EROFS"
        case EXDEV: "EXDEV"
        case ENOTEMPTY: "ENOTEMPTY"
        case ELOOP: "ELOOP"
        case ENAMETOOLONG: "ENAMETOOLONG"
        case EDQUOT: "EDQUOT"
        case ETXTBSY: "ETXTBSY"
        case EINTR: "EINTR"
        default: "E\(code)"
        }
    }

    /// A file's text, every byte of it (a `/proc` file says it is empty until read), decoded as
    /// UTF-8 with any invalid sequence as U+FFFD.
    static func readText(_ path: String) throws -> String {
        let fd = openFile(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw failure("open", path) }
        defer { _ = closeFile(fd) }
        var bytes: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = chunk.withUnsafeMutableBytes { readFile(fd, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw failure("read", path)
            }
            if count == 0 { break }
            bytes.append(contentsOf: chunk[0..<count])
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// When a file's content was last written, in milliseconds since 1970 (Node's `mtimeMs`).
    static func modifiedMs(_ path: String) throws -> Double {
        var info = stat()
        guard stat(path, &info) == 0 else { throw failure("stat", path) }
        #if canImport(Darwin)
        let time = info.st_mtimespec
        #else
        let time = info.st_mtim
        #endif
        return Double(time.tv_sec) * 1000 + Double(time.tv_nsec) / 1_000_000
    }

    /// A new file for writing, readable by this user only; fails when there is one by that name.
    static func createFile(_ path: String) throws -> Int32 {
        let fd = openFile(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw failure("open", path) }
        return fd
    }

    static func writeAll(_ fd: Int32, _ data: Data, path: String) throws {
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < buffer.count {
                let written = writeFile(fd, buffer.baseAddress.map { $0 + offset }, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw failure("write", path)
                }
                offset += written
            }
        }
    }

    /// Flushes a file (or a folder's entries) to the disk: on Apple platforms to the medium itself
    /// (`F_FULLFSYNC`, as Node's `sync` does there), else `fsync`.
    static func flush(_ fd: Int32, path: String) throws {
        #if canImport(Darwin)
        if fcntl(fd, F_FULLFSYNC) == 0 { return }
        #endif
        guard fsync(fd) == 0 else { throw failure("fsync", path) }
    }

    static func close(_ fd: Int32, path: String) throws {
        guard closeFile(fd) == 0 else { throw failure("close", path) }
    }

    static func rename(_ from: String, _ to: String) throws {
        guard renameFile(from, to) == 0 else { throw failure("rename", from) }
    }

    /// Removes a file; one that is not there is not an error.
    static func remove(_ path: String) throws {
        guard unlink(path) == 0 else {
            let code = errno
            if code == ENOENT { return }
            throw failure("unlink", path, code)
        }
    }

    /// The names in a folder, `.` and `..` left out.
    static func list(_ path: String) throws -> [String] {
        guard let directory = opendir(path) else { throw failure("opendir", path) }
        defer { closedir(directory) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 { throw failure("readdir", path) }
                return names
            }
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                    String(cString: $0)
                }
            }
            if name != "." && name != ".." { names.append(name) }
        }
    }

    /// Makes a folder and any above it that are missing (`mkdir -p`).
    static func makeDirectories(_ path: String) throws {
        var current = path.hasPrefix("/") ? "/" : ""
        for component in path.split(separator: "/") {
            current += (current.isEmpty || current.hasSuffix("/") ? "" : "/") + component
            if makeDirectory(current, 0o777) != 0 {
                let code = errno
                if code == EEXIST { continue }
                throw failure("mkdir", current, code)
            }
        }
    }

    /// Flushes a folder's entries (a rename in it) to the disk.
    static func syncDirectory(_ path: String) throws {
        let fd = openFile(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw failure("open", path) }
        defer { _ = closeFile(fd) }
        try flush(fd, path: path)
    }
}

// The C calls, at file scope so no member of the same name (`read`, `write`, `close`, `rename`)
// hides them.

private func openFile(_ path: String, _ flags: Int32) -> Int32 {
    open(path, flags)
}

private func openFile(_ path: String, _ flags: Int32, _ mode: mode_t) -> Int32 {
    open(path, flags, mode)
}

private func readFile(_ fd: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
    read(fd, buffer, count)
}

private func writeFile(_ fd: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int {
    write(fd, buffer, count)
}

private func closeFile(_ fd: Int32) -> Int32 {
    close(fd)
}

private func renameFile(_ from: String, _ to: String) -> Int32 {
    rename(from, to)
}

private func makeDirectory(_ path: String, _ mode: mode_t) -> Int32 {
    mkdir(path, mode)
}
