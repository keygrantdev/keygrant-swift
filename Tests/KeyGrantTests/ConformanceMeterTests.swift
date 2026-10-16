import Foundation
import Testing

@testable import KeyGrant

/// The metered-uses groups: what every KeyGrant SDK must answer for the same inputs, answered from
/// each vector's own JSON through the functions the SDK itself decides with, with the conventions of
/// the harness around this extension (ConformanceTests.swift). They close `conformance/vectors.json`.
extension ConformanceTests {
    @Test func theCapturedRequestBodiesAreFoundWhereTheyAreMade() {
        // The captured request bodies sit beside the reference's generator in the repository that makes them.
        if MeterVectors.inRepository { #expect(MeterVectors.wireBodies != nil, "conformance/wire-bodies.json") }
    }

    @Test func theHarnessAnswersEveryMeterGroupTheVectorsHold() throws {
        let root = try #require(Self.file, "conformance/vectors.json not found above the tests")
        for name in MeterVectors.groups { #expect(root[name]?.arrayValue != nil, "\(name): no such group") }
        let total = MeterVectors.groups.reduce(0) { $0 + (root[$1]?.arrayValue?.count ?? 0) }
        #expect(total == MeterVectors.vectorCount)
    }

    // MARK: - the lease's met

    @Test func metersAreReadFromALeasesClaimAsTheReferenceReadsThem() throws {
        for vector in try group("meterClaims") {
            // The claim as the JSON text a lease carries it in; null is a lease with none.
            let claim = try vector["json"]?.stringValue.map { try #require(JSONText.parse($0), "\(vector.name): the claim is JSON") }
            #expect(metersJSON(metersOf(claim)) == vector["expect"], "\(vector.name)")
        }
    }

    @Test func leasesThatCarryMetersVerifyAndCheckAsTheReference() throws {
        let key = try KeySet(publicJWK: try #require(Self.file?["publicJwk"]).jsonText)
        for vector in try group("meterLeases") {
            let holder = LeaseHolder(
                key: try vector.string("holder", "key"),
                activationId: try vector.string("holder", "activationId"),
                claims: try #require(vector["holder"]?["claims"]?.arrayValue).compactMap(\.stringValue),
                canTell: try vector.bool("holder", "canTell")
            )
            let verified = verifyLease(try vector.string("token"), keys: key, now: try vector.int("now"))
            #expect(verified.json == vector["verify"], "\(vector.name): verify")
            let check = checkLease(verified, product: try vector.string("product"), major: try vector.int("major"), holder: holder)
            #expect(check.json == vector["expect"], "\(vector.name): checkLease")
        }
    }

    // MARK: - what a call asks for, and the figures

    @Test func whatACallAsksForIsWhatTheReferenceReads() throws {
        var skipped = 0
        for vector in try group("useAmounts") {
            if vector["jsOnly"] == true {
                // A fraction or a text: no Swift call holds one.
                if case .number(let given)? = vector["n"] { #expect(!isWhole(given), "\(vector.name) is marked jsOnly but is whole") }
                skipped += 1
                continue
            }
            // A call that gave no amount is a spend of 1.
            let n = try vector["n"].map { try #require($0.intValue, "\(vector.name): an amount") } ?? 1
            let answer: LicenseJSON
            switch askedFor(try vector.string("meter"), n) {
            case .success(let asked): answer = ["meter": .string(asked.meter), "n": .number(Double(asked.n))]
            case .failure(let error): answer = ["refused": .string(error.rawValue)]
            }
            #expect(answer == vector["expect"], "\(vector.name)")
        }
        #expect(skipped == MeterVectors.jsOnly)
    }

    @Test func baseFiguresAreTheReferences() throws {
        for vector in try group("meterFigures") {
            let figures = figuresOf(
                met: metersOf(vector["met"]), iat: try #require(vector["iat"]?.numberValue), stored: storedFigures(vector["figures"])
            )
            #expect(metersJSON(figures) == vector["expect"], "\(vector.name)")
        }
    }

    @Test func statusesShowTheMetersAsTheReferenceDoes() throws {
        for vector in try group("meterStatuses") {
            let shown = meterStatusOf(metersOf(vector["figures"]), spendsOf(vector["spends"]))
            let answer = shown.mapValues { status -> LicenseJSON in
                [
                    "left": .number(Double(status.left)), "total": .number(Double(status.total)),
                    "offline": .number(Double(status.offline)), "unsynced": .number(Double(status.unsynced)),
                    "resets": .bool(status.resets),
                ]
            }
            #expect(.object(answer) == vector["expect"], "\(vector.name)")
        }
    }

    @Test func aSpendWithNoAnswerIsAllowedAsTheReferenceAllowsIt() throws {
        for vector in try group("offlineSpends") {
            let verdict = offlineSpend(
                metersOf(vector["figures"]), spendsOf(vector["spends"]), try vector.string("meter"), try vector.int("n")
            )
            let answer: LicenseJSON
            switch verdict {
            case .allowed(let left, let limit): answer = ["ok": true, "left": .number(Double(left)), "limit": .number(Double(limit))]
            case .noMeter: answer = ["ok": false, "error": "no-meter"]
            case .offlineLimit(let left): answer = ["ok": false, "error": "offline-limit", "left": .number(Double(left))]
            }
            #expect(answer == vector["expect"], "\(vector.name)")
        }
    }

    // MARK: - when to ask

    @Test func aCallAsksTheServerWhenTheReferenceDoes() throws {
        for vector in try group("useAsks") {
            let asks = useAsksNow(
                StoredState(json: try #require(vector["state"])), clockNow: try vector.int("clockNow"), now: try vector.int("now"),
                covered: try vector.bool("covered")
            )
            #expect(.bool(asks) == vector["expect"], "\(vector.name)")
        }
    }

    @Test func aValidLeaseAsksToReportAJournalWhenTheReferenceDoes() throws {
        for vector in try group("syncAsks") {
            var claims = baseClaims
            claims.major = try #require(vector["claims"]?["major"]?.numberValue)
            claims.iat = try #require(vector["claims"]?["iat"]?.numberValue)
            claims.exp = try #require(vector["claims"]?["exp"]?.numberValue)
            let asks = asksOnValidLease(
                claims: claims, state: StoredState(json: try #require(vector["state"])), major: try vector.int("major"),
                now: try vector.int("now"), clockNow: try vector.int("clockNow")
            )
            #expect(.bool(asks) == vector["expect"], "\(vector.name)")
        }
    }

    // MARK: - what an answer does

    @Test func aUseAnswerDoesWhatTheReferenceDoes() throws {
        for vector in try group("useOutcomes") {
            let outcome = useOutcome(
                UseInput(
                    response: try response(vector["response"]), askedAt: try vector.int("askedAt"), major: try vector.int("major"),
                    device: deviceOf(
                        kind: vector["device"]?["kind"]?.stringValue.flatMap(DeviceKind.init(rawValue:)),
                        ownClaim: vector["device"]?["ownClaim"]?.stringValue
                    )
                )
            )
            var answer: [String: LicenseJSON] = ["outcome": .string(outcome.kind.rawValue)]
            if let refusal = outcome.refusal { answer["refusal"] = .string(refusal.rawValue) }
            if let left = outcome.left { answer["left"] = .number(Double(left)) }
            answer["patch"] = outcome.patch.json
            answer["figures"] = .object(outcome.figures.mapValues(storedFigureJSON))
            answer["confirmed"] = confirmedJSON(outcome.confirmed)
            #expect(.object(answer) == vector["expect"], "\(vector.name)")
        }
    }

    @Test func everyKindOfAnswerHasAVector() throws {
        let seen = Set(try group("useOutcomes").compactMap { $0["expect"]?["outcome"]?.stringValue })
        #expect(seen == Set(UseOutcomeKind.allCases.map(\.rawValue)))
    }

    // MARK: - the journal

    @Test func theJournalLandsAsTheReferenceLandsIt() throws {
        for vector in try group("journals") {
            let landed = journaled(StoredState(json: try #require(vector["latest"])), try op(vector["op"]), now: try vector.int("now"))
            let answer: LicenseJSON = [
                "spends": .array(landed.spends.map(spendJSON)), "meterFigures": .object(landed.meterFigures.mapValues(storedFigureJSON)),
                "refused": .bool(landed.refused),
            ]
            #expect(answer == vector["expect"], "\(vector.name)")
        }
    }

    @Test func aReportCarriesTheJournalAsTheReferenceReportsIt() throws {
        for vector in try group("spendReports") {
            #expect((spendsReported(spendsOf(vector["spends"])) ?? .null) == vector["expect"], "\(vector.name)")
        }
    }

    @Test func anAnswerConfirmsTheReportsTheReferenceSaysItDoes() throws {
        for vector in try group("spendConfirmations") {
            #expect(confirmedJSON(spendsConfirmed(try response(vector["response"]))) == vector["expect"], "\(vector.name)")
        }
    }

    // MARK: - reading the vectors

    func confirmedJSON(_ confirmed: [Confirmed]) -> LicenseJSON {
        .array(
            confirmed.map { entry in
                switch entry {
                case .count(let id, let n): ["id": .string(id), "n": .number(Double(n))]
                case .void(let id): ["id": .string(id), "void": true]
                }
            }
        )
    }

    /// One change to the journal as a vector gives it.
    func op(_ json: LicenseJSON?) throws -> JournalOp {
        let json = try #require(json)
        let kind = try json.string("kind")
        if kind == "deactivated" { return .deactivated }
        let about = try json.string("about")
        switch kind {
        case let word where SpendKind(rawValue: word) != nil:
            return .spend(
                SpendOp(
                    kind: try #require(SpendKind(rawValue: word)), about: about, id: try json.string("id"),
                    meter: try json.string("meter"), n: try json.int("n"), at: try json.int("at"), limit: json["limit"]?.intValue,
                    told: json["told"] == true
                )
            )
        case "confirmed":
            let entries = try #require(json["entries"]?.arrayValue).map { entry -> Confirmed in
                let id = try entry.string("id")
                return entry["void"] == true ? .void(id: id) : .count(id: id, n: try entry.int("n"))
            }
            return .confirmed(about: about, entries: entries)
        case "figures": return .figures(about: about, figures: storedFigures(json["figures"]))
        case "activated": return .activated(about: about)
        default: throw VectorError(description: "unknown op \(json)")
        }
    }
}
