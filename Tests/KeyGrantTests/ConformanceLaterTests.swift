import Foundation
import Testing

@testable import KeyGrant

/// The groups of `conformance/vectors.json` after the first ones: answered from each vector's own
/// JSON, with the conventions of the other groups (ConformanceTests.swift).
extension ConformanceTests {
    /// The major a build configured as `configured` runs as (`majorOf`). A configured major with a
    /// fraction, which `LicenseConfig.major` (an `Int`) cannot hold, is skipped here, as the README
    /// says (each such vector is marked `jsOnly`); every whole one, below zero included, is
    /// reproduced, whether marked `jsOnly` or not.
    @Test func majors() throws {
        let vectors = try group("majors")
        var reproduced = 0
        for vector in vectors {
            let given = vector["configured"] ?? .null
            let configured = given.isNull ? nil : given.intValue
            guard given.isNull || configured.map({ Double($0) == given.numberValue }) == true else {
                #expect(vector["jsOnly"] == true, "\(vector.name): a fraction not marked jsOnly")
                continue
            }
            #expect(.number(Double(majorOf(configured))) == vector["expect"], "\(vector.name)")
            reproduced += 1
        }
        #expect(reproduced == 6 && vectors.count - reproduced == 4)
    }

    /// The link `upgradeURL(paymentLink:)` answers for the stored activation id (`referencedLink`):
    /// the link with the reference as its one `client_reference_id`.
    @Test func referencedLinks() throws {
        for vector in try group("referencedLinks") {
            let link = try #require(URL(string: try vector.string("link")), "\(vector.name)")
            let url = KeyGrant.referencedLink(link, try vector.string("reference"))
            #expect(url.map { LicenseJSON.string($0.absoluteString) } == vector["expect"], "\(vector.name)")
        }
    }

    /// When a running trial reports its launch (`trialReportDue`), by the guarded clock.
    @Test func trialReportDue() throws {
        for vector in try group("trialReportDue") {
            let state = StoredState(json: try #require(vector["state"]))
            #expect(.bool(KeyGrant.trialReportDue(state, now: try vector.int("now"))) == vector["expect"], "\(vector.name)")
        }
    }
}
