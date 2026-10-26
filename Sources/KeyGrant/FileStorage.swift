import Foundation

/// The default storage: one JSON file per product, read and written so that neither a crash nor a
/// busy disk ever costs a customer their licence.
///
/// **Read:** only a MISSING file is "no state", and even then the newest whole temp file left
/// beside it (a write that finished but was never renamed in) is read first, else the state at
/// `migratingFrom`, copied over once. Any other failure to read is tried again for about a second
/// and then THROWS: a save built on a read that failed would write what it read over the real
/// state. A file that does not parse is set aside (`<file>.<ms>.corrupt`, the newest three kept)
/// and an empty state written in its place. A read-only read (behind a call that has not finished)
/// writes nothing at all: no copy, no set-aside.
///
/// **Write:** atomically: to a temp file beside it (readable by this user only), flushed to the
/// disk, then renamed over it (tried again for a while when the file is busy), and the folder
/// flushed after. A temp file is unique to its write and removed when its write fails; a write
/// that lands clears temp files a crash left (over a minute old).
///
/// **Update:** every save stamps the state with the next revision (`rev`) and, just before its
/// rename, reads the file again; when another process saved since, the patch is merged onto that
/// newer state and tried again, five times at most (then `StorageError` code `ECONFLICT`).
public final class FileStorage: StorageAdapter {
    /// The state file.
    public let path: String
    private let fs: any StorageFileSystem
    private let migrateFrom: String?
    private let sleep: Sleep
    /// The wall clock (ms since 1970): what names a temp or set-aside file, and ages a temp file.
    private let now: @Sendable () -> Int
    private let directory: String
    /// The file's name and a dot: what its temp files and set-aside files start with.
    private let prefix: String

    /// Storage at `path`. `migratingFrom`: where an app kept its state before, copied to `path`
    /// the first time `path` is missing.
    public convenience init(path: String, migratingFrom legacyPath: String? = nil) {
        self.init(path: path, fs: POSIXFileSystem(), migrateFrom: legacyPath, sleep: realSleep)
    }

    init(
        path: String,
        fs: any StorageFileSystem,
        migrateFrom: String?,
        sleep: @escaping Sleep,
        now: @escaping @Sendable () -> Int = wallClockMs
    ) {
        self.path = path
        self.fs = fs
        self.migrateFrom = migrateFrom
        self.sleep = sleep
        self.now = now
        let (directory, name) = splitPath(path)
        self.directory = directory
        prefix = name + "."
    }

    /// Where the default storage keeps a product's state: a folder of this user's on THIS machine,
    /// never the working directory and never one that roams between machines.
    ///  - macOS (a Mac Catalyst app's included): `~/Library/Application Support/KeyGrant/<product>.json`.
    ///    In a sandboxed app the home folder is the app's container, so the file is inside the container.
    ///  - iOS and iPadOS: the same under the app's container (`NSHomeDirectory()`, which in the
    ///    Simulator is the container where `HOME` may not be): its Application Support folder
    ///    (contract section 6).
    ///  - Linux and others: `$XDG_CONFIG_HOME/keygrant/<product>.json`, else `~/.config/keygrant/...`.
    /// Read from the environment as it is when called (`storageHome`: `HOME`, else the user's home
    /// folder; on iOS and iPadOS, the container).
    public static func defaultPath(product: String) -> String {
        let home = storageHome(platform: nodePlatform, home: POSIX.environment("HOME"))
        var environment: [String: String] = [:]
        if let configured = POSIX.environment("XDG_CONFIG_HOME") { environment["XDG_CONFIG_HOME"] = configured }
        return defaultStoragePath(product: product, platform: nodePlatform, home: home, environment: environment)
    }

    public func read(readOnly: Bool) async throws -> StoredState? {
        try await load(readOnly: readOnly).state
    }

    public func write(_ state: StoredState) async throws {
        try await place(state)
    }

    public func update(_ merge: @escaping @Sendable (StoredState) -> StoredState) async throws {
        var attempt = 1
        while true {
            let base = try await load(readOnly: false)
            var next = merge(base.state ?? StoredState())
            next.rev = clampToSafe((base.state?.rev ?? 0) + 1)
            do {
                try await place(next, allowed: { try await self.unchanged(base.rev) })
                return
            } catch {
                if codeOf(error) != conflictCode || attempt >= updateAttempts { throw error }
            }
            attempt += 1
        }
    }

    /// A state read, and the revision of the FILE it was read from (none when it came from anywhere else).
    private struct Loaded {
        var state: StoredState?
        var rev: Int?
    }

    private func load(readOnly: Bool) async throws -> Loaded {
        guard let text = try await readText(fs, path, sleep: sleep) else {
            if let temp = await leftover(fs, directory, prefix) { return Loaded(state: temp) }
            return Loaded(state: await migrated(copy: !readOnly))
        }
        guard let json = JSONText.parse(text) else {
            if readOnly { return Loaded() }
            // Kept aside before anything is written in its place; a rename that cannot be made
            // throws, as a read that cannot be made does.
            let aside = "\(path).\(now()).corrupt"
            try await retrying(renameBackoffMs, worthAgain: busy, sleep: sleep) { try await fs.rename(path, aside) }
            try? await place(StoredState())
            await pruneCorrupt(fs, directory, prefix)
            return Loaded()
        }
        if case .null = json { return Loaded() }
        let state = StoredState(json: json)
        return Loaded(state: state, rev: state.rev)
    }

    /// A whole state put in place, once `allowed` (when given) has not thrown, just before the rename.
    private func place(_ state: StoredState, allowed: (@Sendable () async throws -> Void)? = nil) async throws {
        let temp = try await writeTemp(fs, directory, prefix, state, now: now())
        do {
            try await retrying(renameBackoffMs, worthAgain: busy, sleep: sleep) {
                try await allowed?()
                try await fs.rename(temp, path)
            }
        } catch {
            try? await fs.remove(temp)
            throw error
        }
        try? await fs.syncDirectory(directory)
        await clearStale(fs, directory, prefix, now: now())
    }

    /// Throws `ECONFLICT` when the file's revision is no longer `rev`: another process saved since it was read.
    private func unchanged(_ rev: Int?) async throws {
        let text: String?
        do {
            text = try await fs.readFile(path)
        } catch {
            guard missing(codeOf(error)) else { throw error }
            text = nil
        }
        if case .rev(let stored) = revisionOf(text), stored == rev { return }
        throw StorageError(code: conflictCode, operation: "save", path: path)
    }

    /// The state at `migrateFrom`, copied to `path` once (`copy`, false on a read-only read) and
    /// returned; nil when there is none or it does not parse. Never throws.
    private func migrated(copy: Bool) async -> StoredState? {
        guard let from = migrateFrom, !from.isEmpty, let text = try? await fs.readFile(from),
            let json = JSONText.parse(text), case .object = json
        else { return nil }
        let state = StoredState(json: json)
        if copy { try? await place(state) }
        return state
    }
}

/// How many times a save is merged onto a state another process changed under it before it fails.
let updateAttempts = 5

/// The code of the error a save fails with when the state kept changing under it.
let conflictCode = "ECONFLICT"

/// The revision a file's text carries.
enum Revision: Hashable {
    /// The text does not parse: equal to no revision at all.
    case unparseable
    /// None for a missing file or an unstamped state.
    case rev(Int?)
}

func revisionOf(_ text: String?) -> Revision {
    guard let text else { return .rev(nil) }
    guard let json = JSONText.parse(text) else { return .unparseable }
    return .rev(StoredState(json: json).rev)
}

/// The home folder the default storage is under, for a platform (Node's name) and `$HOME` (`home`,
/// nil when unset): `$HOME` unless it is empty, else the user's home folder (`NSHomeDirectory()`);
/// on iOS and iPadOS always the app's container, `NSHomeDirectory()`, which in the Simulator is the
/// container where `$HOME` may not be.
func storageHome(platform: String, home: String?) -> String {
    if platform == "ios" { return NSHomeDirectory() }
    return home.flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
}

/// Where the default storage keeps a product's state, for a platform (Node's name), a home folder
/// and an environment. An empty or relative `$XDG_CONFIG_HOME` is taken as unset, as the XDG spec says.
func defaultStoragePath(product: String, platform: String, home: String, environment: [String: String]) -> String {
    let file = "\(product).json"
    if platform == "darwin" || platform == "ios" {
        return joinPath(joinPath(joinPath(joinPath(home, "Library"), "Application Support"), "KeyGrant"), file)
    }
    let configured = environment["XDG_CONFIG_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil }
    let config = configured ?? joinPath(home, ".config")
    return joinPath(joinPath(config, "keygrant"), file)
}
