import Foundation
import Testing

@testable import KeyGrant

/// The purchase groups of `conformance/vectors.json`, after every other one: answered from each
/// vector's own JSON, with the conventions of the other groups (ConformanceTests.swift).
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

    /// The link `purchaseURL(paymentLink:)` answers for a held secret (`purchaseLink`): the link
    /// with the secret's reference as its one `client_reference_id`, built by the rule
    /// `upgradeURL(paymentLink:)` builds its own by (`referencedLink`).
    @Test func purchaseUrls() throws {
        for vector in try group("purchaseUrls") {
            let link = try #require(URL(string: try vector.string("link")), "\(vector.name)")
            let url = purchaseLink(link, try vector.string("secret"))
            #expect(url.map { LicenseJSON.string($0.absoluteString) } == vector["expect"], "\(vector.name)")
        }
    }

    /// The reference a link carries for a purchase secret (`purchaseReference`).
    @Test func purchaseReferences() throws {
        for vector in try group("purchaseReferences") {
            #expect(.string(purchaseReference(try vector.string("secret"))) == vector["expect"], "\(vector.name)")
        }
    }

    /// The body a claim sends (`claimRequest`, which the pickup calls), or none: the device read as
    /// the `devices` group reads one, with no install kind (no key is held).
    @Test func claimBodies() throws {
        let vectors = try group("claimBodies")
        for vector in vectors {
            let identity = try #require(vector["identity"])
            let device = deviceFrom(
                DeviceIdentity(
                    fingerprint: identity["fingerprint"]?.stringValue,
                    kind: identity["kind"]?.stringValue.flatMap(DeviceKind.init(rawValue:)),
                    alternates: (identity["alternates"]?.arrayValue ?? []).compactMap(\.stringValue)
                ),
                installKind: nil,
                deviceHold: try vector.bool("deviceHold")
            )
            let body = claimRequest(
                secret: try vector.string("secret"), device: device, name: vector["deviceName"]?.stringValue,
                major: try vector.int("major"), start: try vector.bool("start")
            )
            #expect(body?.json ?? .null == vector["expect"], "\(vector.name)")
        }
        // A body sent and none sent are both pinned.
        #expect(vectors.contains { $0["expect"] == .null } && vectors.contains { $0["expect"] != .null })
    }

    /// The 30-day bound on a purchase secret (`purchaseTokenKept`), by the guarded clock.
    @Test func purchaseTokenKept() throws {
        for vector in try group("purchaseTokenKept") {
            let state = StoredState(json: try #require(vector["state"]))
            #expect(.bool(KeyGrant.purchaseTokenKept(state, now: try vector.int("now"))) == vector["expect"], "\(vector.name)")
        }
    }

    /// When an unforced `status()` asks for a bought key (`claimDue`): the link's day of freshness
    /// by the guarded clock (`now`), the 5-minute wait by the device clock (`clockNow`).
    @Test func claimDue() throws {
        for vector in try group("claimDue") {
            let state = StoredState(json: try #require(vector["state"]))
            let due = KeyGrant.claimDue(state, clockNow: try vector.int("clockNow"), now: try vector.int("now"))
            #expect(.bool(due) == vector["expect"], "\(vector.name)")
        }
    }

    /// A claim's answer body, read (`parseClaimBody`): members it does not know are ignored.
    @Test func parseClaimBody() throws {
        for vector in try group("parseClaimBody") {
            #expect(KeyGrant.parseClaimBody(vector["body"]).json == vector["expect"], "\(vector["body"] ?? .null)")
        }
    }

    /// What a claim's answer saves and says (`claimOutcome`, which the pickup calls): the check given
    /// is the one made, and the lease is never verified here.
    @Test func claimOutcomes() throws {
        let vectors = try group("claimOutcomes")
        for vector in vectors {
            let input = ClaimInput(
                response: try response(vector["response"]),
                check: try check(vector["check"]),
                clockNow: try vector.int("clockNow"),
                now: try vector.int("now"),
                major: try vector.int("major"),
                kind: vector["kind"]?.stringValue.flatMap(DeviceKind.init(rawValue:))
            )
            #expect(claimOutcome(input).json == vector["expect"], "\(vector.name)")
        }
        // Every result is pinned.
        #expect(Set(vectors.compactMap { $0["expect"]?["result"]?.stringValue }) == ["bought", "kept", "dropped"])
    }

    /// When a running trial reports its launch (`trialReportDue`), by the guarded clock.
    @Test func trialReportDue() throws {
        for vector in try group("trialReportDue") {
            let state = StoredState(json: try #require(vector["state"]))
            #expect(.bool(KeyGrant.trialReportDue(state, now: try vector.int("now"))) == vector["expect"], "\(vector.name)")
        }
    }
}

extension ClaimBody {
    /// As the vectors say it: each member only when it holds something, `pending` only when true.
    var json: LicenseJSON {
        var members: [String: LicenseJSON] = [:]
        if let key { members["key"] = .string(key) }
        if let activationId { members["activationId"] = .string(activationId) }
        if let lease { members["lease"] = .string(lease) }
        if pending { members["pending"] = true }
        if let error { members["error"] = .string(error) }
        return .object(members)
    }
}

extension ClaimOutcome {
    /// As the vectors say it: `{result, status, patch}`, no status as `null`.
    var json: LicenseJSON {
        ["result": .string(result.rawValue), "status": status?.json ?? .null, "patch": patch.json]
    }
}
