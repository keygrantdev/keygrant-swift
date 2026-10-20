import Foundation
import Testing

@testable import KeyGrant

/// What the metered-uses vector tests share. The groups themselves are read from `conformance/vectors.json`
/// as every other group is (`ConformanceTests.file`), where they come before the key-pickup groups, and a missing file or group
/// FAILS the test that needs it. The captured request bodies (`wire-bodies.json`) sit beside the
/// reference's generator, so only the repository that holds the reference has them: a test that needs them
/// is SKIPPED, with the reason, outside that repository (the public export of this SDK, which has
/// `vectors.json` alone), and FAILS inside it, where a test that cannot find its file must never pass, or
/// be skipped.
enum MeterVectors {
    /// The groups, in the file's order.
    static let groups = [
        "meterClaims", "meterLeases", "useAmounts", "meterFigures", "meterStatuses", "offlineSpends", "useAsks",
        "syncAsks", "useOutcomes", "journals", "spendReports", "spendConfirmations",
    ]

    /// The vectors the groups hold, and how many of them no Swift call can hold (a fraction and a
    /// text are JavaScript's only).
    static let vectorCount = 412
    static let jsOnly = 2

    /// The file `relative` in a folder above this one (or under that folder's `sdk` folder), or nil.
    static func above(_ relative: String) -> URL? {
        var folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            for candidate in [folder.appendingPathComponent(relative), folder.appendingPathComponent("sdk").appendingPathComponent(relative)]
            where FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            folder.deleteLastPathComponent()
        }
        return nil
    }

    /// Whether this is the repository that holds the reference: it has the script that exports the SDKs.
    static let inRepository = above("scripts/export-sdk.mjs") != nil

    /// The bodies the reference captured of the requests that carry a report (`wire-bodies.json`).
    static let wireBodies: LicenseJSON? = {
        if let given = ProcessInfo.processInfo.environment["KEYGRANT_WIRE_BODIES"], !given.isEmpty {
            return (try? Data(contentsOf: URL(fileURLWithPath: given))).flatMap { JSONText.parse(decoding: $0) }
        }
        return above("conformance/wire-bodies.json").flatMap { (try? Data(contentsOf: $0)).flatMap { JSONText.parse(decoding: $0) } }
    }()

    /// The captured bodies are skipped, with the reason, only outside the repository that holds the reference.
    static var wireBodiesEnabled: ConditionTrait {
        .enabled(
            if: wireBodies != nil || inRepository,
            "the reference's captured request bodies are not in this checkout (it is not the repository that holds the reference)"
        )
    }

    /// The constants the metered-uses vectors state, as this package holds them.
    static var constants: [String: LicenseJSON] {
        [
            "MAX_METER_USES": .number(Double(maxMeterUses)),
            "MAX_PENDING_SPENDS": .number(Double(maxPendingSpends)),
            "MAX_PENDING_VOIDS": .number(Double(maxPendingVoids)),
            "PENDING_MAX_MS": .number(Double(pendingMaxMs)),
            "USE_TIMEOUT_MS": .number(Timing.standard.statusCheck * 1000),
        ]
    }
}
