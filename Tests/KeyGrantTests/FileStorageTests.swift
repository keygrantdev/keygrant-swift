import Foundation
import Testing

@testable import KeyGrant

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

let stateDir = "/memory/keygrant"
let statePath = "\(stateDir)/sluice.json"
let saved = #"{"activationId":"act_1","key":"SLUICE-AAAA-BBBB-CCCC-DDDD","lastSeen":1}"#

func storage(_ fs: MemoryFileSystem, migrateFrom: String? = nil, sleep: NoSleep = NoSleep()) -> FileStorage {
    FileStorage(path: statePath, fs: fs, migrateFrom: migrateFrom, sleep: sleep.sleep)
}

/// A temp folder for one test, removed after it.
func inTemp(_ test: (String) async throws -> Void) async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("keygrant-\(UInt64.random(in: 0...UInt64.max))").path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try await test(dir)
}

func names(_ dir: String) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted()
}

func json(_ path: String) -> LicenseJSON? {
    (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap { JSONText.parse(decoding: $0) }
}

/// Sets a file's times to `ageMs` ago.
func age(_ path: String, _ ageMs: Double) throws {
    let date = Date(timeIntervalSinceNow: -ageMs / 1000)
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
}

@Suite("the default storage path", suiteTimeLimit)
struct DefaultPathTests {
    @Test(arguments: [
        ("darwin", "/Users/jo", [String: String](), "/Users/jo/Library/Application Support/KeyGrant/sluice.json"),
        ("darwin", "/Users/jo/Library/Containers/com.example.app/Data", [:], "/Users/jo/Library/Containers/com.example.app/Data/Library/Application Support/KeyGrant/sluice.json"),
        ("linux", "/home/jo", ["XDG_CONFIG_HOME": "/home/jo/.cfg"], "/home/jo/.cfg/keygrant/sluice.json"),
        ("linux", "/home/jo", ["XDG_CONFIG_HOME": "/home/jo/.cfg/"], "/home/jo/.cfg/keygrant/sluice.json"),
        ("linux", "/home/jo", [:], "/home/jo/.config/keygrant/sluice.json"),
        ("linux", "/home/jo", ["XDG_CONFIG_HOME": ""], "/home/jo/.config/keygrant/sluice.json"),
        ("linux", "/home/jo", ["XDG_CONFIG_HOME": ".cfg"], "/home/jo/.config/keygrant/sluice.json"),
    ])
    func keepsStatePerUserOnThisMachineNeverInTheWorkingDirectory(platform: String, home: String, env: [String: String], expected: String) {
        #expect(defaultStoragePath(product: "sluice", platform: platform, home: home, environment: env) == expected)
    }

    @Test func isUnderThisUsersHome() {
        let path = FileStorage.defaultPath(product: "sluice")
        #expect(path.hasPrefix("/") && path.hasSuffix("/sluice.json"))
    }
}

@Suite("file storage: writes", suiteTimeLimit)
struct FileStorageWriteTests {
    @Test func writesByRenamingATempFileOverTheStateAndLeavesNoTempBehind() async throws {
        try await inTemp { dir in
            let path = "\(dir)/sluice.json"
            let storage = FileStorage(path: path)
            try await storage.write(StoredState(key: "K", lastSeen: 1))
            try await storage.write(StoredState(key: "K", lastSeen: 2))
            #expect(json(path) == ["key": "K", "lastSeen": 2])
            #expect(names(dir) == ["sluice.json"])
        }
    }

    @Test func replacesTheStateRatherThanWritingIntoIt() async throws {
        try await inTemp { dir in
            // A write in place changes the one file every name for it shares; a rename puts a new
            // file under the name and leaves the old one whole.
            let path = "\(dir)/sluice.json"
            let storage = FileStorage(path: path)
            try await storage.write(StoredState(key: "K", lastSeen: 1))
            #expect(link(path, "\(dir)/old-state") == 0)
            try await storage.write(StoredState(key: "K", lastSeen: 2))
            #expect(json("\(dir)/old-state") == ["key": "K", "lastSeen": 1])
            #expect(json(path) == ["key": "K", "lastSeen": 2])
        }
    }

    @Test func writesAFileOnlyThisUserCanRead() async throws {
        try await inTemp { dir in
            let path = "\(dir)/sluice.json"
            try await FileStorage(path: path).write(StoredState(key: "K"))
            let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
            #expect(permissions == 0o600)
        }
    }

    @Test func clearsTheTempsCrashesLeftOnceAWriteLandsAndNotAnotherInstancesWriteInFlight() async throws {
        try await inTemp { dir in
            func make(_ name: String, _ text: String, ageMs: Double? = nil) throws {
                try Data(text.utf8).write(to: URL(fileURLWithPath: "\(dir)/\(name)"))
                if let ageMs { try age("\(dir)/\(name)", ageMs) }
            }
            try make("sluice.json.1.1.crashed.tmp", #"{"key":"CRASHED"}"#, ageMs: 2 * staleTempMs)
            try make("sluice.json.2.2.inflight.tmp", #"{"key":"IN"#)
            // Another product's temp in the same folder is not this file's to clear.
            try make("maindeck.json.3.3.other.tmp", "{}", ageMs: 2 * staleTempMs)
            try make("sluice.json.4.4.younger.tmp", "{}", ageMs: staleTempMs - 5_000)
            try make("sluice.json.5.5.older.tmp", "{}", ageMs: staleTempMs + 5_000)
            try await FileStorage(path: "\(dir)/sluice.json").write(StoredState(key: "K"))
            #expect(names(dir) == ["maindeck.json.3.3.other.tmp", "sluice.json", "sluice.json.2.2.inflight.tmp", "sluice.json.4.4.younger.tmp"])
        }
    }

    @Test func clearsATempAgedExactlyTheCutoffAndKeepsOneAMillisecondYounger() async throws {
        let now = 1_790_000_000_000
        let edge = "\(statePath).1.1.edge.tmp", inside = "\(statePath).2.2.inside.tmp"
        let fs = MemoryFileSystem([statePath: saved, edge: "{}", inside: "{}"])
        // On the storage's own clock: 60 000 ms old, and 59 999.
        fs.setMtime(edge, Double(now) - staleTempMs)
        fs.setMtime(inside, Double(now) - staleTempMs + 1)
        let storage = FileStorage(path: statePath, fs: fs, migrateFrom: nil, sleep: NoSleep().sleep, now: { now })
        try await storage.write(StoredState(key: "K"))
        #expect(Set(fs.files.keys) == [statePath, inside])
        // The temp it wrote was named by that clock too.
        #expect(fs.ops.contains { $0.hasPrefix("create \(statePath).\(ProcessInfo.processInfo.processIdentifier).\(now).") })
    }

    @Test func namesAFileItSetsAsideByItsOwnClock() async throws {
        let now = 1_790_000_000_000
        let fs = MemoryFileSystem([statePath: #"{"bad"#])
        let storage = FileStorage(path: statePath, fs: fs, migrateFrom: nil, sleep: NoSleep().sleep, now: { now })
        #expect(try await storage.read() == nil)
        #expect(fs.files["\(statePath).\(now).corrupt"] == #"{"bad"#)
    }

    @Test(arguments: ["EPERM", "EBUSY", "EACCES"])
    func triesARenameRefusedAsBusyAgain(code: String) async throws {
        let fs = MemoryFileSystem([statePath: saved])
        fs.failNext(.rename, code, code)
        let sleep = NoSleep()
        try await storage(fs, sleep: sleep).write(StoredState(key: "K", lastSeen: 2))
        #expect(fs.files[statePath].flatMap(JSONText.parse) == ["key": "K", "lastSeen": 2])
        #expect(sleep.slept.count == 2)
        #expect(Array(fs.files.keys) == [statePath])
    }

    @Test func givesUpOnARenameThatStaysBusyKeepingTheStateAndRemovingItsTemp() async throws {
        let fs = MemoryFileSystem([statePath: saved])
        fs.failAlways(.rename, "EBUSY")
        let sleep = NoSleep()
        await #expect(throws: StorageError.self) { try await storage(fs, sleep: sleep).write(StoredState(key: "K")) }
        let waited = sleep.slept.reduce(0, +)
        #expect(waited >= 1_000 && waited <= 2_000)
        #expect(fs.files == [statePath: saved])
    }

    @Test func doesNotTryAgainARenameThatFailedOtherThanForABusyFile() async throws {
        let fs = MemoryFileSystem([statePath: saved])
        fs.failNext(.rename, "ENOSPC")
        let sleep = NoSleep()
        do {
            try await storage(fs, sleep: sleep).write(StoredState(key: "K"))
            Issue.record("the write should have failed")
        } catch {
            #expect((error as? StorageError)?.code == "ENOSPC")
        }
        #expect(sleep.slept.isEmpty)
        #expect(fs.files == [statePath: saved])
    }

    @Test func flushesTheTempAndClosesItBeforeTheRenameAndTheFolderAfter() async throws {
        let fs = MemoryFileSystem([statePath: saved])
        try await storage(fs).write(StoredState(key: "K"))
        let steps = fs.ops.compactMap { $0.split(separator: " ").first.map(String.init) }.filter { !["list", "modifiedMs", "makeDirectory"].contains($0) }
        #expect(steps == ["create", "write", "sync", "close", "rename", "syncDirectory"])
    }

    @Test func failsAWriteWhoseTempCannotBeFlushedTheStateAsItWasAndNoTemp() async throws {
        let fs = MemoryFileSystem([statePath: saved])
        fs.failNext(.sync, "EIO")
        await #expect(throws: StorageError.self) { try await storage(fs).write(StoredState(key: "K")) }
        #expect(fs.files == [statePath: saved])
    }

    @Test func failsNothingWhenTheFolderCannotBeFlushedTheRenameHasLanded() async throws {
        let fs = MemoryFileSystem([statePath: saved])
        fs.failNext(.syncDirectory, "EINVAL")
        try await storage(fs).write(StoredState(key: "K"))
        #expect(fs.files == [statePath: #"{"key":"K"}"#])
    }

    @Test func leavesTheStateAsItWasAndNoTempWhenAWriteFails() async throws {
        try await inTemp { dir in
            // The state path is a folder: the rename over it fails.
            let path = "\(dir)/sluice.json"
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
            let storage = FileStorage(path: path, fs: POSIXFileSystem(), migrateFrom: nil, sleep: NoSleep().sleep)
            await #expect(throws: StorageError.self) { try await storage.write(StoredState(key: "K")) }
            #expect(names(dir) == ["sluice.json"])
        }
    }
}

@Suite("file storage: reads", suiteTimeLimit)
struct FileStorageReadTests {
    @Test func readsAFileHoldingNullAsNoStateSettingNothingAsideAndWritingNothing() async throws {
        // `JSON.parse('null')`: a state of null, which is no state; the text parses, so it is not corrupt.
        let fs = MemoryFileSystem([statePath: "null"])
        #expect(try await storage(fs).read() == nil)
        #expect(try await storage(fs).read(readOnly: true) == nil)
        #expect(fs.changes.isEmpty)
        #expect(fs.files == [statePath: "null"])
    }

    @Test func isNoStateWhenTheFileIsMissingThenRoundTrips() async throws {
        try await inTemp { dir in
            let storage = FileStorage(path: "\(dir)/nested/license.json")
            #expect(try await storage.read() == nil)
            let state = StoredState(key: "K", activationId: "a", lastSeen: 42, otherFields: ["future": ["x": 1]])
            try await storage.write(state)
            #expect(try await storage.read() == state)
        }
    }

    @Test func readsTheStateItHadWhenAWriteCrashedBeforeItsRename() async throws {
        try await inTemp { dir in
            let path = "\(dir)/sluice.json"
            try await FileStorage(path: path).write(StoredState(key: "OLD", lastSeen: 1))
            try Data(#"{"key":"NE"#.utf8).write(to: URL(fileURLWithPath: "\(dir)/sluice.json.123.456.abc.tmp"))
            #expect(try await FileStorage(path: path).read() == StoredState(key: "OLD", lastSeen: 1))
        }
    }

    @Test func readsTheNewestWholeTempWhenTheStateIsMissingByItsTimeNotItsName() async throws {
        try await inTemp { dir in
            let path = "\(dir)/sluice.json"
            let newer = "\(dir)/sluice.json.1.1.a.tmp", older = "\(dir)/sluice.json.9.9.z.tmp", torn = "\(dir)/sluice.json.5.5.m.tmp"
            try Data(#"{"key":"NEW"}"#.utf8).write(to: URL(fileURLWithPath: newer))
            try Data(#"{"key":"OLD"}"#.utf8).write(to: URL(fileURLWithPath: older))
            try Data(#"{"key":"TOR"#.utf8).write(to: URL(fileURLWithPath: torn))
            try age(older, 30_000)
            try age(newer, 20_000)
            try age(torn, 10_000)
            #expect(try await FileStorage(path: path).read() == StoredState(key: "NEW"))
            // A read-only read reads it too, and writes nothing.
            #expect(try await FileStorage(path: path).read(readOnly: true) == StoredState(key: "NEW"))
            #expect(names(dir).count == 3)
            try FileManager.default.removeItem(atPath: newer)
            #expect(try await FileStorage(path: path).read() == StoredState(key: "OLD"))
            try FileManager.default.removeItem(atPath: older)
            #expect(try await FileStorage(path: path).read() == nil)
        }
    }

    @Test func setsAFileThatDoesNotParseAsideAndStartsAfreshNeverFromATemp() async throws {
        try await inTemp { dir in
            let path = "\(dir)/sluice.json"
            try Data(#"{"key":"SLUICE-AA"#.utf8).write(to: URL(fileURLWithPath: path))
            try Data(#"{"key":"FROM-A-TEMP"}"#.utf8).write(to: URL(fileURLWithPath: "\(dir)/sluice.json.1.1.a.tmp"))
            let storage = FileStorage(path: path)
            #expect(try await storage.read() == nil)
            let aside = try #require(names(dir).first { $0.hasPrefix("sluice.json.") && $0.hasSuffix(".corrupt") })
            #expect(try String(contentsOfFile: "\(dir)/\(aside)", encoding: .utf8) == #"{"key":"SLUICE-AA"#)
            // An empty state in its place, so no later read takes the temp instead.
            #expect(try await storage.read() == StoredState())
        }
    }

    @Test func keepsOnlyTheNewestSetAsideFilesByTheTimeInTheirNames() async throws {
        func aside(_ at: Int) -> String { "\(statePath).\(at).corrupt" }
        // 900 sorts after 3000 as text: only the numbers tell which is newest.
        let others = ["\(stateDir)/tunnel.json.100.corrupt": "x", "\(statePath).notes.corrupt": "x"]
        var files = [statePath: #"{"bad"#, aside(900): "x", aside(1000): "x", aside(2000): "x", aside(3000): "x"]
        files.merge(others) { _, new in new }
        let fs = MemoryFileSystem(files)
        #expect(try await storage(fs).read() == nil)
        let kept = fs.files.keys.filter { $0.hasPrefix(statePath + ".") && $0.hasSuffix(".corrupt") && $0 != "\(statePath).notes.corrupt" }
        #expect(kept.count == keepCorrupt)
        #expect(kept.contains(aside(3000)) && kept.contains(aside(2000)))
        #expect(fs.files[aside(1000)] == nil && fs.files[aside(900)] == nil)
        for (path, text) in others { #expect(fs.files[path] == text) }
    }

    @Test func readsReadOnlyWithoutRepairing() async throws {
        let fs = MemoryFileSystem([statePath: #"{"bad"#])
        #expect(try await storage(fs).read(readOnly: true) == nil)
        #expect(fs.files == [statePath: #"{"bad"#])
        #expect(fs.changes.isEmpty)
    }

    @Test func triesAReadThatFailedAgain() async throws {
        let fs = MemoryFileSystem([statePath: saved])
        fs.failNext(.readFile, "EBUSY")
        let sleep = NoSleep()
        #expect(try await storage(fs, sleep: sleep).read() == StoredState(json: try #require(JSONText.parse(saved))))
        #expect(sleep.slept.count == 1)
    }

    @Test(arguments: ["EBUSY", "EACCES", "EIO"])
    func throwsOnAReadThatStillFailsAfterAboutASecond(code: String) async throws {
        let fs = MemoryFileSystem([statePath: saved, "\(statePath).1.1.a.tmp": #"{"key":"FROM-A-TEMP"}"#])
        fs.failAlways(.readFile, code)
        let sleep = NoSleep()
        do {
            _ = try await storage(fs, sleep: sleep).read()
            Issue.record("the read should have failed")
        } catch {
            #expect((error as? StorageError)?.code == code)
        }
        let waited = sleep.slept.reduce(0, +)
        #expect(waited >= 500 && waited <= 1_500)
        #expect(fs.changes.isEmpty)
    }

    @Test func doesNotWaitOnAMissingFile() async throws {
        let sleep = NoSleep()
        #expect(try await storage(MemoryFileSystem(), sleep: sleep).read() == nil)
        #expect(sleep.slept.isEmpty)
    }

    @Test func throwsWritingNothingWhenAFileThatDoesNotParseCannotBeSetAside() async throws {
        let fs = MemoryFileSystem([statePath: #"{"key":"SLUICE-AA"#])
        fs.failAlways(.rename, "EBUSY")
        await #expect(throws: StorageError.self) { try await storage(fs).read() }
        #expect(fs.files == [statePath: #"{"key":"SLUICE-AA"#])
    }

    @Test func dropsAFieldOfTheWrongTypeAndKeepsOnesItDoesNotKnow() async throws {
        let text = #"{"key":42,"activationId":"act_1","lastSeen":"soon","trialStart":1.75,"refused":"bogus","refusedFor":["a",1],"future":{"x":[1,2]}}"#
        let fs = MemoryFileSystem([statePath: text])
        let state = try await storage(fs).read()
        #expect(state == StoredState(activationId: "act_1", trialStart: 1, refusedFor: ["a"], otherFields: ["future": ["x": [1, 2]]]))
    }

    @Test func onAReadThatStaysBusyStatusIsUnknownActivateIsStorageNothingAskedOrWritten() async throws {
        let fs = MemoryFileSystem([statePath: saved])
        fs.failAlways(.readFile, "EBUSY")
        let h = try Harness()
        let license = try License(LicenseConfig(
            product: PRODUCT, apiBaseURL: apiBase, publicJWK: h.signer.publicJWK,
            adapters: LicenseAdapters(storage: storage(fs), clock: h.clock, fingerprinter: h.fingerprinter, http: h.http)
        ))
        #expect(await license.status() == LicenseStatus(state: .unknown, reason: .storage))
        #expect(await license.refresh() == LicenseStatus(state: .unknown, reason: .storage))
        #expect(await license.startTrial() == LicenseStatus(state: .unknown, reason: .storage))
        #expect(await license.activate("SLUICE-EEEE-FFFF-GGGG-HHHH") == .failed(.storage))
        await #expect(throws: StorageError.self) { try await license.deactivate() }
        #expect(h.http.calls.isEmpty)
        #expect(fs.files == [statePath: saved])
        #expect(fs.changes.isEmpty)
    }
}

@Suite("file storage: the state an app kept elsewhere before", suiteTimeLimit)
struct MigrationTests {
    @Test func isCopiedToTheNewPathOnceAndReadFromThereAfter() async throws {
        try await inTemp { dir in
            let legacy = "\(dir)/app/.keygrant/sluice.json", path = "\(dir)/user/sluice.json"
            try FileManager.default.createDirectory(atPath: "\(dir)/app/.keygrant", withIntermediateDirectories: true)
            try Data(saved.utf8).write(to: URL(fileURLWithPath: legacy))
            let storage = FileStorage(path: path, migratingFrom: legacy)
            let expected = StoredState(json: try #require(JSONText.parse(saved)))
            #expect(try await storage.read() == expected)
            #expect(json(path) == JSONText.parse(saved))
            #expect(json(legacy) == JSONText.parse(saved))
            // From then on only the new path.
            try Data(#"{"key":"CHANGED"}"#.utf8).write(to: URL(fileURLWithPath: legacy))
            #expect(try await storage.read() == expected)
        }
    }

    @Test func isIgnoredWhenTheNewPathHasAState() async throws {
        try await inTemp { dir in
            let legacy = "\(dir)/legacy.json", path = "\(dir)/user/sluice.json"
            try Data(saved.utf8).write(to: URL(fileURLWithPath: legacy))
            try await FileStorage(path: path).write(StoredState(key: "NEWER"))
            #expect(try await FileStorage(path: path, migratingFrom: legacy).read() == StoredState(key: "NEWER"))
        }
    }

    @Test func isNoStateAndNothingWrittenWhenItIsMissingOrDoesNotParse() async throws {
        try await inTemp { dir in
            let legacy = "\(dir)/legacy.json", path = "\(dir)/user/sluice.json"
            #expect(try await FileStorage(path: path, migratingFrom: legacy).read() == nil)
            try Data(#"{"key":"SLU"#.utf8).write(to: URL(fileURLWithPath: legacy))
            #expect(try await FileStorage(path: path, migratingFrom: legacy).read() == nil)
            #expect(names(dir) == ["legacy.json"])
        }
    }

    @Test func isStillReadWhenItCannotBeCopiedAndCopiedAtALaterRead() async throws {
        let legacy = "/memory/legacy/sluice.json"
        let fs = MemoryFileSystem([legacy: saved])
        fs.failNext(.write, "ENOSPC")
        let storage = storage(fs, migrateFrom: legacy)
        let expected = StoredState(json: try #require(JSONText.parse(saved)))
        #expect(try await storage.read() == expected)
        #expect(fs.files[statePath] == nil)
        #expect(try await storage.read() == expected)
        #expect(fs.files[statePath].flatMap(JSONText.parse) == JSONText.parse(saved))
    }

    @Test func isReadNotCopiedByAReadOnlyRead() async throws {
        let legacy = "/memory/legacy/sluice.json"
        let fs = MemoryFileSystem([legacy: saved])
        #expect(try await storage(fs, migrateFrom: legacy).read(readOnly: true) == StoredState(json: try #require(JSONText.parse(saved))))
        #expect(fs.changes.isEmpty)
    }
}

/// The engine's own save, as a `License` makes it: one per app process.
func saver(_ fs: MemoryFileSystem) throws -> License {
    try License(LicenseConfig(
        product: PRODUCT, apiBaseURL: apiBase, publicJWK: Signer().publicJWK,
        adapters: LicenseAdapters(storage: storage(fs), clock: FakeClock(), http: FakeHTTP())
    ))
}

@Suite("file storage: saves from more than one process", suiteTimeLimit)
struct ConcurrentSaveTests {
    @Test func stampsEverySaveWithTheNextRevision() async throws {
        let fs = MemoryFileSystem()
        let one = try saver(fs)
        try await one.save([.key: .string("K")])
        #expect(fs.files[statePath].flatMap(JSONText.parse)?["rev"] == 1)
        try await one.save([.checkedMajor: .int(2)])
        let state = fs.files[statePath].flatMap(JSONText.parse)
        #expect(state?["rev"] == 2 && state?["key"] == "K" && state?["checkedMajor"] == 2)
    }

    @Test(arguments: [[statePath: #"{"key":"K","rev":4}"#], [statePath: #"{"key":"K"}"#], [:]])
    func losesNeitherOfTwoSavesThatInterleave(files: [String: String]) async throws {
        let fs = MemoryFileSystem(files)
        let (a, b) = (try saver(fs), try saver(fs))
        // A has read the state and is about to write it; B saves in between.
        let held = fs.holdNext(.create)
        async let first: Void = a.save([.keptMajor: .int(2)])
        await eventually { held.reached }
        try await b.save([.checkedMajor: .int(3)])
        held.release()
        try await first
        let state = fs.files[statePath].flatMap(JSONText.parse)
        #expect(state?["keptMajor"] == 2 && state?["checkedMajor"] == 3)
        #expect(Array(fs.files.keys) == [statePath])
    }

    /// Two saves that interleave, B's landing between A's read and A's write.
    struct Interleaved: Sendable {
        var name: String
        var b: StatePatch
        var bAsked: Asked?
        var a: StatePatch
        var aAsked: Asked?
        var gone: [StateField]
    }

    static let removals = [
        Interleaved(name: "B clears the refusal", b: [.refused: .clear], a: [.keptMajor: .int(2)], gone: [.refused]),
        Interleaved(name: "B drops the key", b: [.key: .clear, .activationId: .clear], a: [.keptMajor: .int(2)], gone: [.key, .activationId]),
        Interleaved(
            name: "B's answer, asked for later, clears the refusal A's older answer would set again",
            b: [.lease: .string("L2"), .refused: .clear], bAsked: Asked(at: 2_000, activationId: "act_1", seen: 100),
            a: [.keptMajor: .int(2), .refused: .refusal(.revoked), .lease: .clear], aAsked: Asked(at: 1_000, activationId: "act_1", seen: 100),
            gone: [.refused]
        ),
    ]

    // A field another process REMOVED stays removed: the patch is merged again onto its state,
    // never the whole state this one first made.
    @Test(arguments: Self.removals)
    func keepsWhatAnotherProcessRemovedInBetween(_ c: Interleaved) async throws {
        let fs = MemoryFileSystem([statePath: #"{"key":"K","activationId":"act_1","refused":"revoked","verdictAt":100,"rev":4}"#])
        let (a, b) = (try saver(fs), try saver(fs))
        let held = fs.holdNext(.create)
        async let first: Void = a.save(c.a, basis: Basis(answer: c.aAsked))
        await eventually { held.reached }
        try await b.save(c.b, basis: Basis(answer: c.bAsked))
        held.release()
        try await first
        let state = StoredState(json: try #require(fs.files[statePath].flatMap(JSONText.parse)))
        #expect(state.keptMajor == 2, "\(c.name)")
        for field in c.gone { #expect(state[field] == nil, "\(c.name): \(field)") }
        if c.bAsked != nil { #expect(state.lease == "L2" && state.verdictAt == 2_000, "\(c.name)") }
    }

    @Test func keepsTheHigherKeptMajorAnotherProcessNotedInBetween() async throws {
        let fs = MemoryFileSystem([statePath: #"{"key":"K","activationId":"act_1","keptMajor":2,"rev":1}"#])
        let (a, b) = (try saver(fs), try saver(fs))
        let about = Basis(about: About(activationId: "act_1"))
        let held = fs.holdNext(.create)
        async let first: Void = a.save([.keptMajor: .int(3)], basis: about)
        await eventually { held.reached }
        try await b.save([.keptMajor: .int(5)], basis: about)
        held.release()
        try await first
        #expect(fs.files[statePath].flatMap(JSONText.parse)?["keptMajor"] == 5)
    }

    @Test func failsWithConflictAfterAFewTriesWhenTheStateKeepsChangingUnderIt() async throws {
        let fs = MemoryFileSystem([statePath: #"{"key":"K","rev":1}"#])
        let other = Counter()
        // Another process saves every time this one has read and is about to write.
        fs.before(.create) {
            let rev = other.next() + 1
            fs.set(statePath, #"{"key":"OTHER","rev":\#(rev)}"#)
        }
        let one = try saver(fs)
        do {
            try await one.save([.keptMajor: .int(2)])
            Issue.record("the save should have failed")
        } catch {
            #expect((error as? StorageError)?.code == conflictCode)
        }
        #expect(fs.ops.filter { $0.hasPrefix("create") }.count == updateAttempts)
        #expect(fs.files[statePath].flatMap(JSONText.parse) == ["key": "OTHER", "rev": .number(Double(other.count + 1))])
        #expect(Array(fs.files.keys) == [statePath])
    }
}

@Suite("file storage: a call behind one that has not finished", suiteTimeLimit)
struct ReadOnlyStorageTests {
    /// A License whose first status() is stuck on its read, and a second asked behind it.
    func behindAStuckRead(_ fs: MemoryFileSystem, migrateFrom: String? = nil) async throws -> (LicenseStatus, MemoryFileSystem.Hold) {
        let license = try License(
            LicenseConfig(
                product: PRODUCT, apiBaseURL: apiBase, publicJWK: Signer().publicJWK, httpTimeout: 0.1,
                adapters: LicenseAdapters(storage: storage(fs, migrateFrom: migrateFrom), clock: FakeClock(), fingerprinter: GetFingerprinter(), http: FakeHTTP())
            ),
            timing: quick
        )
        let stuck = fs.holdNext(.readFile)
        Task { _ = await license.status() }
        await eventually { stuck.reached }
        return (await license.status(), stuck)
    }

    @Test func doesNotSetAFileThatDoesNotParseAsideNorWriteInItsPlace() async throws {
        let fs = MemoryFileSystem([statePath: #"{"bad"#])
        let (answer, stuck) = try await behindAStuckRead(fs)
        #expect(answer == LicenseStatus(state: .unlicensed, isStalled: true))
        #expect(fs.changes.isEmpty)
        stuck.release()
    }

    @Test func readsAStateKeptElsewhereBeforeWithoutCopyingIt() async throws {
        let legacy = "/memory/legacy/sluice.json"
        let trial = #"{"trialStart":\#(wallClockMs() - DAY),"trialEndsAt":\#(wallClockMs() + 13 * DAY)}"#
        let fs = MemoryFileSystem([legacy: trial])
        let (answer, stuck) = try await behindAStuckRead(fs, migrateFrom: legacy)
        // Read: trial evidence (a trial with no lease, which runs no trial), not "nothing held".
        #expect(answer == LicenseStatus(state: .expired, reason: .trial, isStalled: true))
        #expect(fs.changes.isEmpty)
        stuck.release()
    }

    @Test func isUnknownStillWritingNothingWhenTheStateCannotBeRead() async throws {
        let fs = MemoryFileSystem([statePath: saved])
        fs.failAlways(.readFile, "EBUSY")
        let (answer, stuck) = try await behindAStuckRead(fs)
        #expect(answer == LicenseStatus(state: .unknown, reason: .storage, isStalled: true))
        #expect(fs.changes.isEmpty)
        stuck.release()
    }
}

extension StatePatch {
    init(_ changes: [StateField: Change]) {
        self.init()
        for (field, change) in changes { self[field] = change }
    }
}

/// The default storage, as an app that gives no storage adapter gets it: under the home folder this
/// process has. Serialized, and the environment put back after: these tests set it.
@Suite("the default storage, under this process's home", .serialized, suiteTimeLimit)
struct DefaultStorageTests {
    /// `body` with these environment variables set (nil: unset), and as they were after it.
    func withEnvironment(_ values: [String: String?], _ body: () async throws -> Void) async throws {
        let before = values.keys.map { ($0, POSIX.environment($0)) }
        for (name, value) in values {
            if let value { setenv(name, value, 1) } else { unsetenv(name) }
        }
        defer {
            for (name, value) in before {
                if let value { setenv(name, value, 1) } else { unsetenv(name) }
            }
        }
        try await body()
    }

    @Test func activatesIntoTheDefaultPathWhenNoStorageIsGiven() async throws {
        try await inTemp { dir in
            try await withEnvironment(["HOME": dir, "XDG_CONFIG_HOME": "\(dir)/config"]) {
                let signer = Signer()
                let http = FakeHTTP()
                http.on("activate", status: 200, json: ["lease": .string(signer.lease()), "activationId": "act_1"])
                let license = try License(
                    LicenseConfig(
                        product: PRODUCT, apiBaseURL: apiBase, publicJWK: signer.publicJWK,
                        adapters: LicenseAdapters(registry: MemoryRegistry(), clock: FakeClock(), fingerprinter: GetFingerprinter(), http: http)
                    )
                )
                #expect(await license.activate(KEY) == .activated)
                let path = FileStorage.defaultPath(product: PRODUCT)
                #if os(macOS)
                #expect(path == "\(dir)/Library/Application Support/KeyGrant/sluice.json")
                #else
                #expect(path == "\(dir)/config/keygrant/sluice.json")
                #endif
                let stored = try #require(json(path))
                #expect(stored["key"] == .string(KEY) && stored["activationId"] == "act_1")
                #expect(await license.status() == LicenseStatus(state: .licensed, key: KEY))
            }
        }
    }

    @Test func keepsTheStateUnderTheHomeFolderWhenNoConfigFolderIsSet() async throws {
        try await inTemp { dir in
            try await withEnvironment(["HOME": dir, "XDG_CONFIG_HOME": nil]) {
                #if os(macOS)
                #expect(FileStorage.defaultPath(product: PRODUCT) == "\(dir)/Library/Application Support/KeyGrant/sluice.json")
                #else
                #expect(FileStorage.defaultPath(product: PRODUCT) == "\(dir)/.config/keygrant/sluice.json")
                #endif
            }
        }
    }
}
