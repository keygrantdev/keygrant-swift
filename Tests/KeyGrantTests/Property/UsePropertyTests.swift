import Foundation
import Testing

@testable import KeyGrant

/// A property test of `use(_:_:)` over the real `License`: seeded random sequences of spends, check-ins and
/// releases, from two processes of the app over one state file, against a server whose answers are lost, late,
/// refused or lost after it has recorded the spend, with a disk that refuses its writes and a device clock that
/// jumps forward and back. The properties (`PropertyWorld.swift`):
///
/// - `use` and `status` never fail for an outcome;
/// - a spend the offline allowance covers is refused only for the journal's size, and asks the server unless a
///   wait runs;
/// - a spend it does not cover is never refused without asking, unless a void under a minute old stands (by the
///   device clock too), and never asks while one does;
/// - the stored journal holds no more than 64 entries (but for the spends the customer was told were made while
///   only memory could hold them) and 16 voids, and a process holds no more than 16 voids in memory, none of
///   them marked told;
/// - offline, the unsynced spends of a meter never pass its allowance, those same told spends apart;
/// - the server never holds more than the customer was told and the refusals it recorded, at any step; once
///   everything is reported it holds every spend the customer was told was made, once (but for what the
///   contract lets a release or the end of a process drop unreported), a spend they were refused after it
///   recorded it is there only when nothing could have lost its void, and every status shows what the server
///   has left;
/// - what `use` answers as `left` is the figure less the unsynced less the spend when made offline, and never
///   more than the server has when made online.
///
/// The oracle takes its constants, figures and waits from the contract, not from the code it judges. A case
/// replayed runs the same way every time (a test below holds it to that), which is what lets a failing one be
/// shrunk and kept. `PROPERTY_RUNS` and `PROPERTY_SEED` choose how many sequences run and from which seed: the
/// default is 1500, a hunt is `PROPERTY_RUNS=20000`. A failing case is shrunk and printed as data, with what
/// happened: add it to the kept cases (`PropertyCases.swift`).
@Suite("metered uses: the property test", suiteTimeLimit)
struct UsePropertyTests {
    /// A failing case with steps taken out while it fails the same way: the shortest sequence that shows the bug.
    func shrink(_ testCase: Case, _ failure: PropertyFailure) async -> Case {
        var best = testCase
        var size = (best.steps.count + 1) / 2
        while size >= 1 {
            var at = 0
            while at < best.steps.count {
                var steps = best.steps
                steps.removeSubrange(at..<min(at + size, steps.count))
                let trial = best.with(steps: steps)
                if let again = await runCase(trial, trace: false).failure, again.invariant == failure.invariant {
                    best = trial
                } else {
                    at += size
                }
            }
            if size == 1 { break }
            size /= 2
        }
        var lean = best
        lean.preload = []
        if let bare = await runCase(lean, trace: false).failure, bare.invariant == failure.invariant { return lean }
        return best
    }

    /// A setting from the environment: a whole number, else the default (`takesItsSettingsFromTheEnvironmentAsWholeNumbers`
    /// fails a value that is none, so a typo is not read as the default without a word).
    static func setting(_ name: String, _ fallback: Int) -> Int {
        ProcessInfo.processInfo.environment[name].flatMap { Int($0) } ?? fallback
    }

    static let runs = setting("PROPERTY_RUNS", 1500)
    static let first = setting("PROPERTY_SEED", 1)
    /// The sequences are run in slices of this many, each its own test case: they run beside one another,
    /// and each keeps the suite's time limit to itself.
    static let perSlice = 150
    static let slices = max(1, (runs + perSlice - 1) / perSlice)

    @Test(arguments: ["PROPERTY_RUNS", "PROPERTY_SEED"])
    func takesItsSettingsFromTheEnvironmentAsWholeNumbers(name: String) {
        if let text = ProcessInfo.processInfo.environment[name] {
            #expect(Int(text) != nil, "\(name) must be a whole number: \(text)")
        }
    }

    @Test func runsAtLeastOneSequenceSoThatNothingPassesForNothing() {
        #expect(Self.runs >= 1, "PROPERTY_RUNS must be at least 1")
    }

    @Test(arguments: 0..<UsePropertyTests.slices)
    func keepsEveryPropertyOfTheContractOverSeededSequences(slice: Int) async throws {
        let from = Self.first + slice * Self.perSlice
        let seeds = from..<max(from, min(Self.first + Self.runs, from + Self.perSlice))
        for seed in seeds {
            let testCase = generate(seed)
            guard let failure = await runCase(testCase, trace: false).failure else { continue }
            let small = await shrink(testCase, failure)
            let again = await runCase(small, trace: true)
            Issue.record(
                """
                seed \(seed): \(failure.message)
                shrunk to \(small.steps.count) steps (\(again.failure?.message ?? "no longer fails")):
                \(small.text)
                \(again.trace.joined(separator: "\n"))
                """
            )
            return
        }
    }

    /// The first line two traces differ at, with the lines before it.
    func difference(_ a: String, _ b: String) -> String {
        let (x, y) = (a.split(separator: "\n", omittingEmptySubsequences: false), b.split(separator: "\n", omittingEmptySubsequences: false))
        let at = (0..<min(x.count, y.count)).first { x[$0] != y[$0] } ?? min(x.count, y.count)
        let before = x[max(0, at - 6)..<at].joined(separator: "\n")
        return "\(before)\n--- first run, line \(at):\n\(at < x.count ? String(x[at]) : "(ends)")\n--- other run:\n\(at < y.count ? String(y[at]) : "(ends)")"
    }

    @Test func aCaseReplayedRunsTheSameWayEveryTimeTheSameRequestsAnswersAndJournals() async throws {
        func traced(_ testCase: Case) async -> String {
            let run = await runCase(testCase, trace: true)
            return run.trace.joined(separator: "\n") + (run.failure.map { "\nfailed: \($0.message)" } ?? "")
        }
        for seed in 1...60 {
            let testCase = generate(seed)
            let first = await traced(testCase)
            for again in 0..<2 {
                let next = await traced(testCase)
                #expect(first == next, "seed \(seed) ran differently the \(again + 2)nd time:\n\(difference(first, next))")
            }
        }
    }

    @Test func generatesTheFirstDrawsTheReferenceGenerates() {
        // The reference's generator, line for line: the first draws of mulberry32(1).
        var rng = Rng(1)
        #expect([rng.next(), rng.next(), rng.next()] == [0.6270739405881613, 0.002735721180215478, 0.5274470399599522])
    }

    @Test(arguments: PropertyCases.golden.map(\.seed))
    func generatesTheCaseTheReferenceGeneratesFromASeedSoASeedFoundThereMeansTheSameHere(seed: Int) throws {
        let reference = try #require(PropertyCases.golden.first { $0.seed == seed }).json
        let made = generate(seed)
        // Both through the same serializer, so a number the reference wrote is compared as the number it is.
        #expect(try Case.from(json: reference).text == made.text, "seed \(seed)")
        // And it is data: the case survives its own JSON.
        #expect(try made.text == Case.from(json: made.text).text, "seed \(seed)")
    }

    @Test(arguments: PropertyCases.shapes.map(\.seed))
    func generatesTheLongCasesTheReferenceGeneratesByWhatTheyHold(seed: Int) throws {
        // A storm of voids (6) and a journal past its cap (115): their size, their steps in order and their first draw.
        let shape = try #require(PropertyCases.shapes.first { $0.seed == seed })
        let made = generate(seed)
        #expect(made.preload.count == shape.preload, "seed \(seed)")
        #expect(made.preload.filter { $0.kind == .void }.count == shape.voids, "seed \(seed)")
        #expect(made.steps.map(\.kind).joined(separator: " ") == shape.steps, "seed \(seed)")
        #expect(made.steps.compactMap(\.draws.first).first == shape.firstDraw, "seed \(seed)")
    }

    /// A kept case holds: each is a bug the property test found, shrunk to the steps that show it.
    @Test(arguments: 0..<PropertyCases.found.count)
    func holdsTheKeptCase(index: Int) async throws {
        let (name, json) = PropertyCases.found[index]
        let run = await runCase(try Case.from(json: json), trace: true)
        #expect(run.failure == nil, "\(name): \(run.failure?.message ?? "")\n\(run.trace.joined(separator: "\n"))")
    }

    /// The kept cases are not dropped quietly: `holdsTheKeptCase` runs one test for each of those found, ten, and each
    /// has a name that says what it showed.
    @Test func keepsTheTenCasesThatWereFoundEachNamed() {
        #expect(PropertyCases.found.count == 10)
        #expect(PropertyCases.found.allSatisfy { !$0.name.isEmpty })
        #expect(Set(PropertyCases.found.map { $0.name }).count == 10)
    }
}
