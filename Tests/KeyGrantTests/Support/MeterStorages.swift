import Foundation

@testable import KeyGrant

/// Storages that misbehave as a test says, over the harness's own, and a `License` over them.

extension Harness {
    /// Another `License` over this harness's clock, server, fingerprinter and key, whose storage is `storage`.
    func app(storage: any StorageAdapter, major: Int = 1, httpTimeout: TimeInterval = 15) throws -> License {
        try License(
            LicenseConfig(
                product: PRODUCT, apiBaseURL: apiBase, publicJWK: signer.publicJWK, major: major, httpTimeout: httpTimeout,
                adapters: LicenseAdapters(storage: storage, registry: registry, clock: clock, fingerprinter: fingerprinter, http: http)
            ),
            timing: timing
        )
    }

    /// The server's answer to a validate: a lease, renewing.
    func renewing(_ lease: String? = nil) {
        http.on("validate", status: 200, json: ["lease": .string(lease ?? signer.meteredLease())])
    }

    /// The `spends` of the `nth` (from 0) validate request, or nil when it carried none.
    func report(_ nth: Int = 0) -> LicenseJSON? {
        let bodies = http.calls.filter { $0.action == "validate" }.map { $0.body }
        return bodies.indices.contains(nth) ? bodies[nth]["spends"] : nil
    }
}

/// A storage with a merge of its own (`update`, as the default file storage has) that lets a second
/// process save before this one's merge, and misbehaves as it is told.
final class Racing: StorageAdapter {
    let inner: MemoryStorage
    /// Entries another process saved just before this one's first merge.
    private let theirs: Locked<[SpendEntry]?>
    /// The other process's state has no figures.
    private let dropFigures: Bool
    /// Reads fail once a save has landed.
    private let failReadsAfter: Bool
    private let saved = Flag()

    init(over h: Harness, theirs: [SpendEntry], dropFigures: Bool = false, failReadsAfter: Bool = false) {
        inner = h.storage
        self.theirs = Locked(theirs)
        self.dropFigures = dropFigures
        self.failReadsAfter = failReadsAfter
    }

    func read(readOnly: Bool) async throws -> StoredState? {
        if failReadsAfter && saved.on { throw StorageError(code: "EIO", operation: "read", path: "memory") }
        return try await inner.read(readOnly: readOnly)
    }

    func write(_ state: StoredState) async throws {
        try await inner.write(state)
    }

    func update(_ merge: @escaping @Sendable (StoredState) -> StoredState) async throws {
        var latest = inner.stored ?? StoredState()
        if let theirs = theirs.withValue({ held -> [SpendEntry]? in
            defer { held = nil }
            return held
        }) {
            latest.spends = theirs
            latest.rev = 9
            if dropFigures { latest.meterFigures = nil }
        }
        try await inner.write(merge(latest))
        saved.set(true)
    }
}

/// A storage that fails its saves as the test says: all of them while `failing`, and the first of a
/// run once the disk is back, and lets a second process's entry in before one.
final class Flaky: StorageAdapter {
    let inner: MemoryStorage
    private let failing: Flag
    private let saves = Counter()
    /// The save, counted from the first once the disk is back, that finds another process's entry.
    private let injectAt: Int

    init(over h: Harness, injectAt: Int = 0) {
        inner = h.storage
        failing = Flag(true)
        self.injectAt = injectAt
    }

    func diskBack() { failing.set(false) }

    func read(readOnly: Bool) async throws -> StoredState? { try await inner.read(readOnly: readOnly) }
    func write(_ state: StoredState) async throws { try await inner.write(state) }

    func update(_ merge: @escaping @Sendable (StoredState) -> StoredState) async throws {
        if failing.on { throw StorageError(code: "EBUSY", operation: "save", path: "memory") }
        let save = saves.next()
        // The first save of the next call fails; before the second another process lands an entry the held spend joins.
        if save == 1 { throw StorageError(code: "EBUSY", operation: "save", path: "memory") }
        var latest = inner.stored ?? StoredState()
        if save == injectAt { latest.spends = [entry(id: spendId("Y"), .offline, 1, NOW - 5)] }
        try await inner.write(merge(latest))
    }
}
