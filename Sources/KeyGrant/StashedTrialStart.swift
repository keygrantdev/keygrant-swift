import Foundation

/// One stored item: the one a trial stash keeps its start in (`KeychainTrialStash`), or the one an
/// iPhone or iPad keeps its install id in (`InstallId`). A Keychain item (`KeychainItem`) on Apple
/// platforms, a dictionary in a test.
protocol StashItem: Sendable {
    /// The item's data; nil when there is no item. Throws when it cannot be read (a locked
    /// keychain, an app without the entitlement it needs).
    func data() async throws -> Data?
    /// Adds the item, there being none.
    func add(_ data: Data) async throws
    /// Replaces the data of the item there is.
    func update(_ data: Data) async throws
}

/// A trial start kept in a stash item, as decimal digits (ms since 1970), only ever moved earlier.
enum StashedTrialStart {
    /// The start the item holds; nil when there is none, or its data is not one.
    static func read(_ item: some StashItem) async throws -> Int? {
        try await item.data().flatMap(start(in:))
    }

    /// `ms` written to the item, on what was read of it: added when there is none, replacing one
    /// that holds a later start (or none at all), and left alone when it holds this start or an
    /// earlier one. An item that cannot be read is not written either, and the read's error is
    /// thrown: writing blind would replace an earlier start nobody could see.
    static func write(_ ms: Int, to item: some StashItem) async throws {
        let value = Data(String(ms).utf8)
        guard let stored = try await item.data() else {
            try await item.add(value)
            return
        }
        if let start = start(in: stored), start <= ms { return }
        try await item.update(value)
    }

    /// `read(_:)`, given up after `seconds` on `ticker` (`TimeoutError`, which the SDK reads as no
    /// stash): for a stash that bounds itself, the SDK bounding none.
    static func read(_ item: some StashItem, within seconds: TimeInterval, on ticker: any Ticker) async throws -> Int? {
        try await withTimeout(seconds, on: ticker) { try await read(item) }
    }

    /// `write(_:to:)`, its caller answered after `seconds` on `ticker` (`TimeoutError`). The write
    /// itself is not stopped: it goes on to finish, still only on what it read.
    static func write(_ ms: Int, to item: some StashItem, within seconds: TimeInterval, on ticker: any Ticker) async throws {
        try await withTimeout(seconds, on: ticker) { try await write(ms, to: item) }
    }

    /// The start an item's data holds, or nil when it holds none.
    static func start(in data: Data) -> Int? {
        String(data: data, encoding: .utf8).flatMap { Int($0) }
    }
}
