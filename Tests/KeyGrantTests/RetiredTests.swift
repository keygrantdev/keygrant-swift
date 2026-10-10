import Foundation
import Testing

@testable import KeyGrant

/// What an earlier version stored to buy from the app with no key typed (a purchase secret and the two
/// stamps beside it), through the whole engine over the default file storage: never sent, and gone from
/// the file once the SDK saves.
@Suite("an earlier version's purchase secret", suiteTimeLimit)
struct RetiredTests {
    static let token = "q1w2e3r4t5y6u7i8o9p0a1s2d3f4g5h6j7k8l9z0x1c"
    static let retired = ["purchaseToken", "purchaseTokenAt", "claimAskedAt"]

    /// A licence over the default file storage (on a file system in memory), every other adapter the
    /// harness's.
    func overFile(_ h: Harness, _ fs: MemoryFileSystem) throws -> License {
        try License(
            LicenseConfig(
                product: PRODUCT,
                apiBaseURL: apiBase,
                publicJWK: h.signer.publicJWK,
                adapters: LicenseAdapters(
                    storage: storage(fs), registry: h.registry, clock: h.clock, fingerprinter: h.fingerprinter, http: h.http
                )
            ),
            timing: h.timing
        )
    }

    /// A file system holding `state` as an earlier version wrote it: with the three fields beside it.
    func earlier(_ state: [String: LicenseJSON]) -> MemoryFileSystem {
        var members = state
        members["purchaseToken"] = .string(Self.token)
        members["purchaseTokenAt"] = .number(Double(NOW - DAY))
        members["claimAskedAt"] = .number(Double(NOW - 60_000))
        return MemoryFileSystem([statePath: JSONText.text(.object(members))])
    }

    func saved(_ fs: MemoryFileSystem) throws -> [String: LicenseJSON] {
        try #require(fs.files[statePath].flatMap(JSONText.parse)?.objectValue)
    }

    func expectLeftOut(_ fs: MemoryFileSystem) throws {
        let file = try saved(fs)
        for name in Self.retired {
            #expect(file[name] == nil, "\(name) is still in the file")
        }
    }

    func expectNeverSent(_ h: Harness) {
        #expect(!h.http.called("claim"))
        for call in h.http.calls {
            #expect(!JSONText.text(call.body).contains(Self.token), "\(call.action) sent the secret")
        }
    }

    @Test func aRunningTrialNeverSendsThemAndItsFirstSaveLeavesThemOut() async throws {
        let h = try Harness()
        let lease = h.signer.trialLease(device: "fp-test", kind: nil, ttlSeconds: 5 * 24 * 3600)
        let fs = earlier([
            "trialStart": .number(Double(NOW - 2 * DAY)), "trialEndsAt": .number(Double(NOW + 5 * DAY)),
            "trialLease": .string(lease), "lastSeen": .number(Double(NOW)),
        ])
        h.http.on(
            "trial", status: 200,
            json: ["trialStart": .number(Double(NOW - 2 * DAY)), "trialEndsAt": .number(Double(NOW + 5 * DAY)), "lease": .string(lease)]
        )
        let license = try overFile(h, fs)
        #expect(await license.status().state == .trial)
        await license.launchReportSettled()
        // The launch report's stamp is the first save, and it carries none of them.
        #expect(try saved(fs)["trialReportedAt"] == .number(Double(NOW)))
        try expectLeftOut(fs)
        #expect(await license.refresh().state == .trial)
        #expect(await license.startTrial().state == .trial)
        try expectLeftOut(fs)
        expectNeverSent(h)
    }

    @Test func anActivationLeavesThemOutAndALaterDeactivationActivatesNothing() async throws {
        let h = try Harness()
        let fs = earlier(["lastSeen": .number(Double(NOW))])
        h.http.on("activate", status: 200, json: ["lease": .string(h.sign()), "activationId": "act_1"])
        h.http.on("deactivate", status: 200, json: [:])
        let license = try overFile(h, fs)
        #expect(await license.activate(KEY) == .activated)
        try expectLeftOut(fs)
        #expect(try await license.deactivate().released)
        try expectLeftOut(fs)
        #expect(await license.status().state == .unlicensed)
        expectNeverSent(h)
    }

    @Test func aDeactivationAloneLeavesThemOut() async throws {
        let h = try Harness()
        let fs = earlier([
            "key": .string(KEY), "activationId": "act_1", "lease": .string(h.sign()),
            "checkedMajor": 1, "lastSeen": .number(Double(NOW)),
        ])
        h.http.on("deactivate", status: 200, json: [:])
        let license = try overFile(h, fs)
        #expect(await license.status().state == .licensed)
        #expect(try await license.deactivate().released)
        try expectLeftOut(fs)
        expectNeverSent(h)
    }
}
