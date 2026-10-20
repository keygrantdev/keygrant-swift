import Foundation
import Testing

@testable import KeyGrant

/// The key-pickup groups, which close `conformance/vectors.json`: what a pickup call sends for what a
/// person typed, the error each refusal of the server is, the keys a confirm hands back as read, and
/// the key a restore activates, answered from each vector's own JSON through the functions the SDK
/// itself decides with, with the conventions of the other groups (ConformanceTests.swift).
extension ConformanceTests {
    /// The groups, in the file's order, and the vectors they hold (25, 24, 33 and 18).
    static let pickupGroups = ["pickupAsks", "pickupRefusals", "pickedKeys", "pickupChoices"]
    static let pickupVectorCount = 100

    @Test func theHarnessAnswersEveryPickupGroupTheVectorsHold() throws {
        let root = try #require(Self.file, "conformance/vectors.json not found above the tests")
        for name in Self.pickupGroups { #expect(root[name]?.arrayValue != nil, "\(name): no such group") }
        let total = Self.pickupGroups.reduce(0) { $0 + (root[$1]?.arrayValue?.count ?? 0) }
        #expect(total == Self.pickupVectorCount)
    }

    /// What is sent for what was typed, or why it is refused. The code is null for the ask for a code.
    @Test func whatAPersonTypedForAPickupIsSentTrimmedOrRefusedBeforeAnythingIsAsked() throws {
        for vector in try group("pickupAsks") {
            let answer: LicenseJSON
            switch pickupAsk(email: try vector.string("email"), code: vector["code"]?.stringValue) {
            case .send(let email, let code):
                var send: [String: LicenseJSON] = ["email": .string(email)]
                if let code { send["code"] = .string(code) }
                answer = ["send": .object(send)]
            case .refused(let error):
                answer = ["refused": .string(error.rawValue)]
            }
            #expect(answer == vector["expect"], "\(vector["email"] ?? .null) \(vector["code"] ?? .null)")
        }
    }

    /// A refused call is the error of the server's word, with a wait only where one helps.
    @Test func aRefusedPickupCallIsTheErrorOfTheServersWord() throws {
        for vector in try group("pickupRefusals") {
            let refusal = pickupRefusal(vector["json"])
            var answer: [String: LicenseJSON] = ["error": .string(refusal.error.rawValue)]
            if let wait = refusal.retryAfter { answer["retryAfter"] = .number(Double(wait)) }
            #expect(.object(answer) == vector["expect"], "\(vector["json"] ?? .null)")
        }
    }

    /// A confirm's keys are read leniently, and a body that is no pickup answer is none.
    @Test func aConfirmsKeysAreReadLeniently() throws {
        for vector in try group("pickedKeys") {
            let answer = pickedKeysOf(vector["json"]).map { LicenseJSON.array($0.map(\.json)) } ?? .null
            #expect(answer == vector["expect"], "\(vector["json"] ?? .null)")
        }
    }

    /// The key a restore activates is the one held, then one with a seat, then the first.
    @Test func theKeyARestoreActivatesIsTheOneHeldThenOneWithASeatThenTheFirst() throws {
        for vector in try group("pickupChoices") {
            let given = try #require(vector["keys"])
            let keys = try #require(pickedKeysOf(["keys": given]), "keys as read")
            // The vectors give the keys as read: reading them again changes none.
            #expect(LicenseJSON.array(keys.map(\.json)) == vector["keys"])
            let answer: LicenseJSON
            switch chosenKey(keys, major: try vector.int("major"), now: try vector.int("now")) {
            case .success(let index): answer = ["index": .number(Double(index))]
            case .failure(let refused): answer = ["refused": .string(refused.rawValue)]
            }
            #expect(answer == vector["expect"], "\(vector["keys"] ?? .null)")
        }
    }
}

extension PickedKey {
    /// As the vectors write a key: a sale and an activation code only when there is one.
    var json: LicenseJSON {
        var members: [String: LicenseJSON] = [
            "key": .string(key), "model": .string(model), "modelName": modelName.map(LicenseJSON.string) ?? .null,
            "state": .string(state), "entitlements": .object(entitlements.mapValues(\.json)),
            "expiresAt": expiresAt.map { .number(Double($0)) } ?? .null,
            "deviceLimit": .number(Double(deviceLimit)), "activeDevices": .number(Double(activeDevices)), "held": .bool(held),
        ]
        members["versions"] = versions.map {
            .object([
                "minMajor": .number(Double($0.minMajor)), "maxMajor": $0.maxMajor.map { .number(Double($0)) } ?? .null,
                "upgradeUntil": $0.upgradeUntil.map { .number(Double($0)) } ?? .null,
            ])
        } ?? .null
        if let sale {
            members["sale"] = .object(["id": .string(sale.id), "index": .number(Double(sale.index)), "size": .number(Double(sale.size))])
        }
        if let activationCode { members["activationCode"] = .string(activationCode) }
        return .object(members)
    }
}
