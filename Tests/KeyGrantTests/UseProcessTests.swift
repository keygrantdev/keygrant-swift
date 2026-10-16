import Foundation
import Testing

@testable import KeyGrant

/// `use(_:_:)` beside a second instance of the app on one state file (two processes), and beside a
/// caller that cancels its task: a call runs to its bounded answer all the same.
@Suite("metered uses: two instances and a cancelled caller", suiteTimeLimit)
struct UseProcessTests {
    let signer = Signer()

    /// One state file holding `stored`, the file system under it.
    func oneFile(_ stored: StoredState) -> MemoryFileSystem {
        MemoryFileSystem([statePath: JSONText.text(stored.json)])
    }

    func saved(_ fs: MemoryFileSystem) -> StoredState {
        StoredState(json: fs.files[statePath].flatMap(JSONText.parse) ?? .null)
    }

    /// An instance of the app over `fs` whose server answers nothing (every request fails) unless told.
    func instance(_ fs: MemoryFileSystem, http given: FakeHTTP? = nil) throws -> License {
        let http = given ?? FakeHTTP()
        if given == nil { http.setFail(true) }
        return try License(
            LicenseConfig(
                product: PRODUCT, apiBaseURL: apiBase, publicJWK: signer.publicJWK,
                adapters: LicenseAdapters(storage: storage(fs), clock: FakeClock(NOW), fingerprinter: GetFingerprinter(), http: http)
            )
        )
    }

    // MARK: - two instances over one file

    @Test func aDeactivateReleasesAllTheSameOverAFileWhoseJournalIsNotOneAndWritesNoneOfItBack() async throws {
        let raw: LicenseJSON = [
            "key": .string(KEY), "activationId": "act_1", "lastSeen": .number(Double(NOW)),
            "lease": .string(signer.meteredLease()), "spends": "junk", "meterFigures": 7,
        ]
        let fs = MemoryFileSystem([statePath: JSONText.text(raw)])
        let http = FakeHTTP()
        http.on("deactivate", status: 200, json: [:])
        let licence = try instance(fs, http: http)
        #expect(try await licence.deactivate().released)
        #expect(http.body("deactivate") == ["key": .string(KEY), "activationId": "act_1"])
        // The junk went with the licence: the file written has none of it.
        let written = try #require(fs.files[statePath].flatMap(JSONText.parse))
        #expect(!written.has("key") && !written.has("spends") && !written.has("meterFigures"))
    }

    @Test func twoInstancesNeverLoseEachOthersSpendsASaveThatFindsTheFileChangedMergesOntoIt() async throws {
        let lease = signer.meteredLease(met: ["exports": ["left": 1_000, "total": 1_000, "offline": 1_000]])
        let fs = oneFile(StoredState(key: KEY, activationId: "act_1", lease: lease, lastSeen: NOW))
        let (a, b) = (try instance(fs), try instance(fs))
        // A's first save has read the file and is making its temp file: there, the other instance spends and
        // saves, so A's revision check finds the file changed and merges onto it.
        let saving = fs.holdNext(.create)
        defer { saving.release() }
        let running = Task { await a.use("exports", 5) }
        await eventually { saving.reached }
        #expect(await b.use("exports", 7).offline)
        saving.release()
        let first = await running.value
        #expect(first.ok && first.offline)
        // A's first save was made twice (merged again), then its spend was saved.
        let spends = (saved(fs).spends ?? []).map { "\($0.kind.rawValue) \($0.n)" }.sorted()
        #expect(spends == ["unanswered 5", "unanswered 7"])
        #expect(await a.status().meters["exports"]?.unsynced == 12)
        #expect(await b.status().meters["exports"]?.unsynced == 12)
    }

    @Test func aSpendTheOtherInstanceMadeIsCountedAgainstTheAllowanceWhereTheSpendLands() async throws {
        let lease = signer.meteredLease(met: ["exports": ["left": 90, "total": 100, "offline": 10]])
        let fs = oneFile(StoredState(key: KEY, activationId: "act_1", lease: lease, lastSeen: NOW))
        let (a, b) = (try instance(fs), try instance(fs))
        let saving = fs.holdNext(.create)
        defer { saving.release() }
        let running = Task { await a.use("exports", 6) }
        await eventually { saving.reached }
        // The other instance takes 6 of the 10 while A's spend waits to land: 12 would pass the allowance.
        #expect(await b.use("exports", 6).ok)
        saving.release()
        #expect(await running.value == .refused(.offlineLimit, left: 84))
        #expect((saved(fs).spends ?? []).filter { $0.kind != .void }.map(\.n) == [6])
    }

    // MARK: - a cancelled caller

    @Test func aCallWhoseTaskIsCancelledBeforeItsRequestIsSentStillSpendsAndAnswers() async throws {
        let h = try Harness.holding()
        h.http.on("use") { _ in Harness.spent(89, at: NOW) }
        // The task is cancelled before it makes the call, and only then let go.
        let start = Gate()
        let task = Task { () -> UseResult in
            await start.wait()
            return await h.license.use("exports", 1)
        }
        task.cancel()
        start.open()
        #expect(await task.value == .spent(left: 89))
        #expect(h.http.count("use") == 1)
        #expect(h.stored?.meterFigures?["exports"]?.left == 89)
    }

    @Test func aCallWhoseTaskIsCancelledWhileItsRequestIsOutRunsToItsBoundedAnswerAndJournalsTheSpendInDoubt() async throws {
        // On a clock the test moves by hand, so the SDK's own bound (5 s) ends where the test says.
        let ticker = ManualTicker()
        let h = try Harness.holding(timing: Timing(ticker: ticker))
        h.http.setHang(true)
        let answered = Flag()
        let task = Task { () -> UseResult in
            let result = await h.license.use("exports", 1)
            answered.set(true)
            return result
        }
        await eventually { ticker.deadlinesMs == [5_000] }
        task.cancel()
        // The caller does not stop waiting: the call is not cut short by the cancel, only by the bound.
        ticker.advance(ms: 4_999)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(!answered.on, "answered 1 ms before the bound")
        ticker.advance(ms: 1)
        // The spend is then made as for no answer: in doubt, journaled and reported with the next request.
        #expect(await answer { await task.value } == .spent(left: 89, offline: true))
        #expect(kindsAndCounts(h.journal) == ["unanswered 1"])
        #expect(h.stored?.backoffMs == Waits.retryUnansweredMs)
    }

    @Test func aCallWhoseTaskIsCancelledWhileItWaitsItsTurnStillRunsAfterTheCallBeforeIt() async throws {
        let ticker = ManualTicker()
        let h = try Harness.holding(timing: Timing(ticker: ticker))
        let gate = Gate()
        let reached = Flag()
        defer { gate.open() }
        h.http.on("validate") { _ in
            reached.set(true)
            await gate.wait()
            return LicenseHTTPResponse(status: 200, json: ["lease": .string(h.signer.meteredLease())])
        }
        h.http.on("use") { _ in Harness.spent(89, at: NOW) }
        let refreshing = Task { await h.license.refresh() }
        await eventually { reached.on }
        let queued = Task { await h.license.use("exports", 1) }
        // Queued: it waits its turn, which it does until the end of the refresh's grace (30 s).
        await eventually { ticker.deadlinesMs.contains(30_000) }
        queued.cancel()
        gate.open()
        _ = await refreshing.value
        #expect(await queued.value == .spent(left: 89))
        #expect(h.http.count("use") == 1)
    }
}
