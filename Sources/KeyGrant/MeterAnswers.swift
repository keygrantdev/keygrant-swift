import Foundation

/// What a request reports of the journal, the reports an answer confirms, and what a `use` answer
/// saves and says.

// MARK: - reports

/// The report a body carries: the journal's entries, oldest first, at most `maxPendingSpends`, a void
/// marked; none for an empty journal (the member is absent, never an empty list).
func spendsReported(_ spends: [SpendEntry]) -> LicenseJSON? {
    let report = spends.prefix(maxPendingSpends).map { entry -> LicenseJSON in
        var members: [String: LicenseJSON] = [
            "id": .string(entry.id), "meter": .string(entry.meter), "n": .number(Double(entry.n)), "at": .number(Double(entry.at)),
        ]
        if entry.kind == .void { members["void"] = .bool(true) }
        return .object(members)
    }
    return report.isEmpty ? nil : .array(report)
}

/// A report the server names as recorded: how many it holds of a spend, or that it took a void.
enum Confirmed: Sendable, Hashable {
    /// The server holds this many of the spend with this id.
    case count(id: String, n: Int)
    /// The server took the spend with this id back (a void).
    case void(id: String)

    var id: String {
        switch self {
        case .count(let id, _), .void(let id): id
        }
    }
}

/// The reports an answer names as recorded (`spends`), read leniently: a member of another shape
/// confirms nothing. A void names itself (its `void` is JSON `true`; its `n` is then not read); any
/// other names how many the server holds (a whole number from 1 to 2^53 - 1). No answer at all, a 5xx
/// and a 429 confirm nothing, whatever their body says.
func spendsConfirmed(_ response: LicenseHTTPResponse?) -> [Confirmed] {
    guard let response, !noAnswer(response.status), case .array(let listed)? = response.json?["spends"] else { return [] }
    return listed.compactMap { member -> Confirmed? in
        guard case .object(let fields) = member, let id = fields["id"]?.stringValue else { return nil }
        if fields["void"] == .bool(true) { return .void(id: id) }
        return countOf(fields["n"]).map { .count(id: id, n: $0) }
    }
}

// MARK: - what an answer does

/// What a `use` answer comes to.
enum UseOutcomeKind: String, Sendable, Hashable, CaseIterable {
    /// A 200 with `spent: true`.
    case spent
    /// Fewer left than asked.
    case usedUp = "used-up"
    /// The server knows no such meter.
    case noMeter = "no-meter"
    /// The server's verdict on the key, this build or this device.
    case refused
    /// No usable answer: the spend comes from the offline allowance, in doubt when it was sent.
    case unanswered
}

/// What a `use` answer is judged from.
struct UseInput: Sendable {
    /// The answer; nil when there was none at all (the request threw or timed out).
    var response: LicenseHTTPResponse?
    /// When the request was made, by the device clock (ms): where the wait before asking again starts.
    var askedAt: Int
    /// This build's major, sent with the request.
    var major: Int
    /// Who this device is, as the request read it: a machine id keys the install, and a device refusal
    /// is held to its own claim.
    var device: Device
}

/// What a `use` answer does.
struct UseOutcome: Sendable, Hashable {
    var kind: UseOutcomeKind
    /// The refusal, when the server's verdict was one.
    var refusal: Refusal?
    /// What the answer says is left, for `.usedUp`.
    var left: Int?
    /// What is saved as the answer to the ask.
    var patch: StatePatch
    /// The figures saved (the newer by `at` is kept).
    var figures: [String: MeterFigure]
    /// The reports the answer confirms.
    var confirmed: [Confirmed]

    /// An answer that saves and confirms nothing.
    fileprivate init(_ kind: UseOutcomeKind, patch: StatePatch = StatePatch()) {
        self.kind = kind
        self.patch = patch
        refusal = nil
        left = nil
        figures = [:]
        confirmed = []
    }
}

/// The figures a `use` answer gives, each stamped with the server's time (`at`); none for an answer
/// without a whole `at`.
private func answeredFigures(_ body: LicenseJSON?) -> [String: MeterFigure] {
    guard let at = figureOf(body?["at"]) else { return [:] }
    return metersOf(body?["meters"]).mapValues {
        MeterFigure(left: $0.left, total: $0.total, offline: $0.offline, resets: $0.resets, at: at)
    }
}

/// What a `use` answer saves and says. No answer at all: the wait (`retryUnansweredMs`) and the
/// device's kind. A 5xx or a 429, and any answer that is neither a spend nor a recognised word:
/// nothing, the offline path. A 200 is a spend only with `spent: true`. On any other status,
/// `used-up`, `unknown-meter` and a validate's verdicts (`refusalOf`, stored as a validate's are) are
/// read; each saves the reports it confirms, and a verdict its refusal.
func useOutcome(_ input: UseInput) -> UseOutcome {
    let keyed = keyedBy(input.device)
    guard let response = input.response else {
        let wait: StatePatch = [.backoffSince: .int(input.askedAt), .backoffMs: .int(Waits.retryUnansweredMs)]
        return UseOutcome(.unanswered, patch: wait + keyed)
    }
    if noAnswer(response.status) { return UseOutcome(.unanswered) }
    let body = response.json
    var outcome: UseOutcome
    if response.status == 200 {
        guard body?["spent"] == .bool(true) else { return UseOutcome(.unanswered) }
        outcome = UseOutcome(.spent)
        outcome.figures = answeredFigures(body)
    } else if errorOf(body) == "used-up" {
        outcome = UseOutcome(.usedUp)
        outcome.left = figureOf(body?["left"])
        outcome.figures = answeredFigures(body)
    } else if errorOf(body) == "unknown-meter" {
        outcome = UseOutcome(.noMeter)
    } else if let refused = refusalOf(errorOf(body)) {
        let verdict: StatePatch = [
            .checkedMajor: .int(input.major), .backoffSince: .int(input.askedAt), .backoffMs: .int(Waits.askAgainMs),
        ]
        outcome = UseOutcome(.refused, patch: verdict + keyed + refusalPatch(refused, major: input.major, ownClaim: input.device.ownClaim))
        outcome.refusal = refused
    } else {
        return UseOutcome(.unanswered)
    }
    outcome.confirmed = spendsConfirmed(response)
    return outcome
}
