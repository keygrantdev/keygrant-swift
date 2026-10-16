import Foundation

/// Metered uses, decided without I/O: what `License.use(_:_:)` may ask for, the figures a device
/// holds, what it may spend while it gets no answer, and what a status shows. When a spend asks the
/// server is `MeterAsks.swift`, what an answer does `MeterAnswers.swift`, how the journal lands on
/// the stored state `Journal.swift`, and the machinery that makes the request `License+Use.swift`.
///
/// A meter never takes a licence away: nothing here is read to decide whether the app is licensed.

/// The most uses one spend may ask for, and the most a figure of a meter is when the server signs it.
public let maxMeterUses = 1_000_000_000

/// The most entries the journal holds, and a report carries (the server reads no more).
let maxPendingSpends = 64

/// The most `void` entries the journal holds: a void is the take-back of a spend that was refused
/// after it got no answer, and a device out of reach that keeps trying a spend its allowance cannot
/// cover would otherwise fill the journal, leaving no room for the spends it can make. A new void
/// past them takes the place of the oldest.
let maxPendingVoids = 16

/// How long an entry is kept unreported (ms): twice the longest lease. The tenant loses a report,
/// never the customer a use.
let pendingMaxMs = 180 * Waits.dayMs

/// The longest meter code a call may name, in UTF-16 units: an entitlement's name.
let maxMeterCode = 32

// MARK: - what was asked

/// How many uses a call spends: a whole number from 1 to `maxMeterUses` is itself; anything else
/// (0, a negative, past the bound) is none (`.invalidAmount`).
func useAmount(_ n: Int) -> Int? {
    (1...maxMeterUses).contains(n) ? n : nil
}

/// A meter's code as a call names it: 1 to 32 UTF-16 units, matched exactly; anything else is none
/// (`.noMeter`).
func meterCode(_ code: String) -> String? {
    (1...maxMeterCode).contains(code.utf16.count) ? code : nil
}

/// What `use(meter, n)` asks for, or why it asks nothing: the amount is judged before the code.
func askedFor(_ meter: String, _ n: Int) -> Result<(meter: String, n: Int), UseError> {
    guard let amount = useAmount(n) else { return .failure(.invalidAmount) }
    guard let code = meterCode(meter) else { return .failure(.noMeter) }
    return .success((code, amount))
}

/// A spend's id: 16 bytes from the platform's secure random source, base64url with no padding (22
/// characters), never reused.
func newSpendId() -> String {
    var generator = SystemRandomNumberGenerator()
    var bytes = Data()
    for _ in 0..<2 {
        withUnsafeBytes(of: generator.next()) { bytes.append(contentsOf: $0) }
    }
    return base64URLEncode(bytes)
}

// MARK: - the figures

/// `a + b`, held at the top of `Int` rather than overflowing: a state a custom storage adapter built
/// in code may hold any count.
func saturatingSum(_ a: Int, _ b: Int) -> Int {
    let (sum, overflow) = a.addingReportingOverflow(b)
    return overflow ? Int.max : sum
}

/// What is left of a figure after the unsynced spends, never below 0: held at the ends of `Int` rather than
/// overflowing, since a state a custom storage adapter built in code may hold any figure and any count.
func remaining(_ left: Int, _ unsynced: Int) -> Int {
    max(0, difference(left, unsynced))
}

/// Uses this device spent that KeyGrant has not heard of: the `n` of a meter's `.offline` and
/// `.unanswered` entries, never a `.void`.
func unsyncedOf(_ spends: [SpendEntry], _ meter: String) -> Int {
    spends.reduce(0) { sum, entry in
        entry.kind != .void && entry.meter == meter ? saturatingSum(sum, entry.n) : sum
    }
}

/// The base figures of each meter: its stored figure (a `use` answer's) when that figure is at or
/// after the lease's own second (`iat`, seconds), else the lease's `met` member, else none, and the
/// meter is unknown on this device. A meter the newest lease no longer names, and no newer answer
/// names, is gone. A stored figure replaces the lease's whole member: its total, its allowance and
/// its `resets` too.
func figuresOf(met: [String: BaseFigure]?, iat: Double, stored: [String: MeterFigure]?) -> [String: BaseFigure] {
    var base: [String: BaseFigure] = [:]
    for code in Set((met ?? [:]).keys).union((stored ?? [:]).keys) {
        // From the lease's own second counts as newer: at worst a second's spends behind.
        if let answered = stored?[code], Double(answered.at) >= iat * 1000 {
            base[code] = BaseFigure(answered)
        } else if let leased = met?[code] {
            base[code] = leased
        }
    }
    return base
}

/// The base figures of the lease that licenses this device and the answers stored beside it.
func figuresFor(_ claims: LeaseClaims, _ state: StoredState) -> [String: BaseFigure] {
    figuresOf(met: claims.met, iat: claims.iat, stored: state.meterFigures)
}

/// What is left of `meter` by `state`: its base figure less the unsynced spends, never below 0; 0
/// for a meter with no figure.
func leftOf(_ claims: LeaseClaims, _ state: StoredState, _ meter: String) -> Int {
    guard let figure = figuresFor(claims, state)[meter] else { return 0 }
    return remaining(figure.left, unsyncedOf(state.spends ?? [], meter))
}

/// `status().meters`: each meter with base figures, its `left` net of this device's unsynced spends
/// and never below 0.
func meterStatusOf(_ figures: [String: BaseFigure], _ spends: [SpendEntry]) -> [String: MeterStatus] {
    var statuses: [String: MeterStatus] = [:]
    for (code, figure) in figures {
        let unsynced = unsyncedOf(spends, code)
        statuses[code] = MeterStatus(
            left: remaining(figure.left, unsynced), total: figure.total, offline: figure.offline, unsynced: unsynced,
            resets: figure.resets
        )
    }
    return statuses
}

/// A `.licensed` status from a key's lease with its meters (`meterStatusOf`); any other status, and a
/// lease with no meter, unchanged.
func meteredStatus(_ status: LicenseStatus, claims: LeaseClaims, state: StoredState) -> LicenseStatus {
    guard status.state == .licensed else { return status }
    var metered = status
    metered.meters = meterStatusOf(figuresFor(claims, state), state.spends ?? [])
    return metered
}

// MARK: - spending with no answer

/// What a spend with no answer comes to (`offlineSpend`).
enum OfflineVerdict: Sendable, Hashable {
    /// The allowance covers it. `left` is what is left after it; `limit` the most the meter's unsynced
    /// spends may come to with it (the smaller of the allowance and what the figure says is left),
    /// which the journal judges again where the spend lands.
    case allowed(left: Int, limit: Int)
    /// No base figure names the meter on this device.
    case noMeter
    /// Past the allowance, or past what is left. `left` is what is left now, never below 0.
    case offlineLimit(left: Int)

    var isAllowed: Bool {
        if case .allowed = self { return true }
        return false
    }
}

/// Whether a spend with no answer is allowed, from the meter's base figures and the journal: its
/// unsynced spends with this one at most the figure's `offline` allowance and at most its `left`. A
/// meter with no base figure is `.noMeter`; an allowance of 0 refuses every spend.
func offlineSpend(_ figures: [String: BaseFigure], _ spends: [SpendEntry], _ meter: String, _ n: Int) -> OfflineVerdict {
    guard let figure = figures[meter] else { return .noMeter }
    let unsynced = unsyncedOf(spends, meter)
    let left = remaining(figure.left, unsynced)
    if saturatingSum(unsynced, n) <= figure.offline && n <= left {
        return .allowed(left: left - n, limit: min(figure.offline, figure.left))
    }
    return .offlineLimit(left: left)
}
