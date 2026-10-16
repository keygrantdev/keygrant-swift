import Foundation
import Testing

@testable import KeyGrant

/// The kept cases that showed the oracle what it did not see, each held to its term: a case fails against the
/// oracle without the term that was added for it, by the property that term serves, and holds with it. (The first
/// four kept cases are bugs of the code, not of the oracle: they fail against a `reportable` that carries a spend
/// made offline and held in memory under its own id, which the mutation check of the work that added them ran.)
@Suite("metered uses: the property oracle", suiteTimeLimit)
struct UsePropertyOracleTests {
    /// The kept cases (by the start of their name) that need a term of the oracle, the term, and the property the
    /// case fails without it.
    static let needs: [(case: String, term: String, invariant: String)] = [
        ("a landing that opens several voids in a journal of fifteen", "oneVoidPerLanding", "void-replaced"),
        ("a landing that opens a void and confirms it in the same save", "ignoreHeldVoids", "void-replaced"),
        ("a landing that opens a void and confirms it in the same save", "confirmedHeldVoidsNotCounted", "void-replaced"),
        ("a second spend meets the journal the first filled", "crowdedByEntryCountOnly", "void-lost"),
        ("a void held in memory (the disk refusing writes) lands in a journal of sixteen voids", "ignoreHeldVoids", "void-replaced"),
        ("two calls of one process on one meter", "everyUnansweredIsOwed", "void-lost"),
        ("a void held in memory finds no room in a journal at its size", "noRoomNotExcused", "void-dropped"),
    ]

    @Test(arguments: needs.indices)
    func aKeptCaseFailsTheOracleWithoutTheTermItWasKeptForByThePropertyThatTermServes(row: Int) async throws {
        let (name, term, invariant) = Self.needs[row]
        let weakening = try #require(OracleWeakening.named.first { $0.name == term }).term
        let kept = try #require(PropertyCases.found.first { $0.name.hasPrefix(name) }, "no kept case: \(name)")
        let testCase = try Case.from(json: kept.json)
        let weakened = await runCase(testCase, trace: false, weakening: weakening)
        #expect(weakened.failure?.invariant == invariant, "\(name) without \(term): \(weakened.failure?.message ?? "no failure")")
        #expect(await runCase(testCase, trace: false).failure == nil, "\(name) with every term")
    }

    @Test func everyTermOfTheOracleHasAKeptCaseAndTheTermsAreTheWholeSet() {
        #expect(OracleWeakening.named.reduce(into: OracleWeakening()) { $0.formUnion($1.term) }.rawValue == (1 << OracleWeakening.named.count) - 1)
        #expect(Set(Self.needs.map { $0.term }) == Set(OracleWeakening.named.map { $0.name }))
    }
}
