import Foundation

@testable import KeyGrant

/// A case of the property test of `use(_:_:)`: plain data, so a failing one can be shrunk and kept as a
/// named test. The generator is the reference's, line for line (the same seeded generator and the draws
/// in the same order), so a seed means the same case in every KeyGrant SDK. Test support only.

private let minute = 60_000
private let hour = 3_600_000

/// A meter the key holds.
struct MeterSpec: Sendable, Hashable {
    var total: Int
    var offline: Int
    var resets: Bool
}

/// One `use` of a process.
struct Call: Sendable, Hashable {
    var p: Int
    var meter: String
    var n: Int

    var json: LicenseJSON { ["p": .number(Double(p)), "meter": .string(meter), "n": .number(Double(n))] }

    init(p: Int, meter: String, n: Int) {
        self.p = p
        self.meter = meter
        self.n = n
    }

    init?(json: LicenseJSON?) {
        guard let p = json?["p"]?.intValue, let meter = json?["meter"]?.stringValue, let n = json?["n"]?.intValue else { return nil }
        self.init(p: p, meter: meter, n: n)
    }
}

/// An entry the journal already holds when the case begins. `recorded`: the server holds the spend (or the
/// report) already.
struct Preloaded: Sendable, Hashable {
    var meter: String
    var n: Int
    var kind: SpendKind
    var agoMs: Int
    var recorded: Bool
}

/// What a step does; `r` are the random numbers its requests draw their fates from, so a case replays whole.
enum Step: Sendable, Hashable {
    case use(calls: [Call], status: StatusCall?, r: [Double])
    case status(p: Int, force: Bool, r: [Double])
    case `repeat`(call: Call, times: Int, gapMs: Int, r: [Double])
    case deactivate(p: Int, r: [Double])
    case restart(p: Int)
    case wait(ms: Int)
    case jump(ms: Int)
    case net(mode: String)
    case disk(failing: Bool)

    /// A status called beside a step's calls.
    struct StatusCall: Sendable, Hashable {
        var p: Int
        var force: Bool
    }

    /// The step's kind, as the file writes it.
    var kind: String {
        switch self {
        case .use: "use"
        case .status: "status"
        case .repeat: "repeat"
        case .deactivate: "deactivate"
        case .restart: "restart"
        case .wait: "wait"
        case .jump: "jump"
        case .net: "net"
        case .disk: "disk"
        }
    }

    /// The draws the step carries, if it has any.
    var draws: [Double] {
        switch self {
        case .use(_, _, let r), .status(_, _, let r), .repeat(_, _, _, let r), .deactivate(_, let r): r
        default: []
        }
    }

    var json: LicenseJSON {
        var out: [String: LicenseJSON] = ["t": .string(kind)]
        switch self {
        case .use(let calls, let status, _):
            out["calls"] = .array(calls.map(\.json))
            if let status { out["status"] = ["p": .number(Double(status.p)), "force": .bool(status.force)] }
        case .status(let p, let force, _):
            out["p"] = .number(Double(p))
            out["force"] = .bool(force)
        case .repeat(let call, let times, let gapMs, _):
            out["call"] = call.json
            out["times"] = .number(Double(times))
            out["gapMs"] = .number(Double(gapMs))
        case .deactivate(let p, _), .restart(let p):
            out["p"] = .number(Double(p))
        case .wait(let ms), .jump(let ms):
            out["ms"] = .number(Double(ms))
        case .net(let mode):
            out["mode"] = .string(mode)
        case .disk(let failing):
            out["failing"] = .bool(failing)
        }
        if !draws.isEmpty { out["r"] = .array(draws.map { .number($0) }) }
        return .object(out)
    }

    init?(json: LicenseJSON) {
        let r = json["r"]?.arrayValue?.compactMap(\.numberValue) ?? []
        let p = json["p"]?.intValue ?? 0
        switch json["t"]?.stringValue {
        case "use":
            guard let calls = json["calls"]?.arrayValue?.compactMap({ Call(json: $0) }) else { return nil }
            var status: StatusCall?
            if let given = json["status"], case .object = given, let p = given["p"]?.intValue, let force = given["force"]?.boolValue {
                status = StatusCall(p: p, force: force)
            }
            self = .use(calls: calls, status: status, r: r)
        case "status":
            guard let force = json["force"]?.boolValue else { return nil }
            self = .status(p: p, force: force, r: r)
        case "repeat":
            guard let call = Call(json: json["call"]), let times = json["times"]?.intValue, let gap = json["gapMs"]?.intValue else { return nil }
            self = .repeat(call: call, times: times, gapMs: gap, r: r)
        case "deactivate": self = .deactivate(p: p, r: r)
        case "restart": self = .restart(p: p)
        case "wait":
            guard let ms = json["ms"]?.intValue else { return nil }
            self = .wait(ms: ms)
        case "jump":
            guard let ms = json["ms"]?.intValue else { return nil }
            self = .jump(ms: ms)
        case "net":
            guard let mode = json["mode"]?.stringValue else { return nil }
            self = .net(mode: mode)
        case "disk":
            guard let failing = json["failing"]?.boolValue else { return nil }
            self = .disk(failing: failing)
        default: return nil
        }
    }
}

/// JSON text that is not a case, or has a step that is not one.
struct MalformedCase: Error, Sendable {
    var text: String
}

/// A case: the meters, the journal it begins with, and the steps.
struct Case: Sendable, Hashable {
    var seed: Int
    var meters: [String: MeterSpec]
    var preload: [Preloaded]
    var steps: [Step]

    var json: LicenseJSON {
        .object([
            "seed": .number(Double(seed)),
            "meters": .object(
                meters.mapValues { ["total": .number(Double($0.total)), "offline": .number(Double($0.offline)), "resets": .bool($0.resets)] }
            ),
            "preload": .array(
                preload.map { p in
                    [
                        "meter": .string(p.meter), "n": .number(Double(p.n)), "kind": .string(p.kind.rawValue),
                        "agoMs": .number(Double(p.agoMs)), "recorded": .bool(p.recorded),
                    ]
                }
            ),
            "steps": .array(steps.map(\.json)),
        ])
    }

    /// A case from its JSON text; it is test data, so one that is not a case throws, and fails the test that asked.
    static func from(json text: String) throws -> Case {
        guard let value = JSONText.parse(text), let seed = value["seed"]?.intValue, let meters = value["meters"]?.objectValue,
            let preload = value["preload"]?.arrayValue, let steps = value["steps"]?.arrayValue
        else { throw MalformedCase(text: String(text.prefix(80))) }
        return Case(
            seed: seed,
            meters: meters.mapValues { MeterSpec(total: $0["total"]?.intValue ?? 0, offline: $0["offline"]?.intValue ?? 0, resets: $0["resets"] == true) },
            preload: preload.map { p in
                Preloaded(
                    meter: p["meter"]?.stringValue ?? "", n: p["n"]?.intValue ?? 0,
                    kind: p["kind"]?.stringValue.flatMap(SpendKind.init(rawValue:)) ?? .offline, agoMs: p["agoMs"]?.intValue ?? 0,
                    recorded: p["recorded"] == true
                )
            },
            steps: try steps.map { json in
                guard let step = Step(json: json) else { throw MalformedCase(text: "a step: \(JSONText.text(json).prefix(80))") }
                return step
            }
        )
    }

    var text: String { JSONText.text(json) }

    func with(steps: [Step]) -> Case {
        var next = self
        next.steps = steps
        return next
    }
}

/// The reference's seeded generator (mulberry32): the same seed, the same sequence.
struct Rng {
    private var state: UInt32

    init(_ seed: UInt32) {
        state = seed
    }

    mutating func next() -> Double {
        state = state &+ 0x6d2b_79f5
        let a = state
        var t = (a ^ (a >> 15)) &* (1 | a)
        t = (t &+ ((t ^ (t >> 7)) &* (61 | t))) ^ t
        return Double(t ^ (t >> 14)) / 4_294_967_296.0
    }
}

private struct Gen {
    var rng: Rng

    mutating func rand() -> Double { rng.next() }

    mutating func int(_ lo: Int, _ hi: Int) -> Int { lo + Int((rand() * Double(hi - lo + 1)).rounded(.down)) }

    mutating func pick<T>(_ xs: [T]) -> T { xs[Int((rand() * Double(xs.count)).rounded(.down))] }

    mutating func code() -> String {
        if rand() < 0.1 { return "ghost" }
        return pick(["exports", "exports", "renders", "credits"])
    }

    mutating func amount() -> Int {
        if rand() < 0.7 { return 1 }
        if rand() < 0.8 { return int(2, 5) }
        if rand() < 0.7 { return int(6, 14) }
        return 500
    }

    mutating func draws() -> [Double] { (0..<6).map { _ in rand() } }

    mutating func call(p: Int? = nil, not: String? = nil) -> Call {
        let process = p ?? int(0, 1)
        var meter = code()
        while meter == not { meter = code() }
        return Call(p: process, meter: meter, n: amount())
    }
}

/// The case a seed makes: the reference's generator, line for line.
func generate(_ seed: Int) -> Case {
    var g = Gen(rng: Rng(UInt32(truncatingIfNeeded: seed)))
    var meters: [String: MeterSpec] = [:]
    meters["exports"] = MeterSpec(total: g.int(8, 150), offline: g.int(1, 12), resets: false)
    meters["renders"] = MeterSpec(total: g.int(3, 40), offline: 0, resets: true)
    meters["credits"] = MeterSpec(total: g.int(4, 60), offline: g.int(0, 6), resets: false)
    let all = ["exports", "renders", "credits"]
    // A storm: sixteen voids or one short of it, an outage, and spends the allowance cannot cover a minute apart: the cap is reached.
    let storm = g.rand() < 0.12
    // A journal past the cap, which a release reports 64 of.
    let overfull = !storm && g.rand() < 0.06
    var preload: [Preloaded] = []
    if storm || overfull || g.rand() < 0.4 {
        let offline = all.filter { _ in g.rand() < 0.3 }
        // How many of the entries are voids is drawn once: sixteen or one short of it in a storm, else none to sixteen.
        let voids = storm ? g.int(14, 16) : overfull ? g.int(0, 13) : g.int(0, 16)
        let count: Int
        if overfull {
            count = g.int(65, 70)
        } else {
            let wanted = storm ? voids + g.int(0, 6) : g.pick([1, 2, 3, 5, 8, 20, 40, 55, 62, 64])
            count = min(wanted, 64 - offline.count)
        }
        for i in 0..<count {
            let kind: SpendKind = i < voids ? .void : .unanswered
            let meter = g.pick(all)
            let n = g.int(1, 2)
            let ago = storm ? g.pick([5 * minute, 2 * hour, 20 * hour]) : g.pick([1_000, 30_000, 5 * minute, 2 * hour, 20 * hour])
            let recorded = g.rand() < 0.5
            preload.append(Preloaded(meter: meter, n: n, kind: kind, agoMs: ago, recorded: recorded))
        }
        for meter in offline {
            let n = g.int(1, 3)
            let ago = g.pick([5 * minute, 2 * hour])
            let recorded = g.rand() < 0.5
            preload.append(Preloaded(meter: meter, n: n, kind: .offline, agoMs: ago, recorded: recorded))
        }
        // Stable, as Array.prototype.sort is: the oldest first.
        preload = stableSorted(preload) { $0.agoMs > $1.agoMs }
        // Past the cap, the newest entries are voids: the release carries 64 and leaves these behind.
        if overfull {
            for _ in 0..<g.int(1, 3) {
                let meter = g.pick(all)
                let recorded = g.rand() < 0.7
                preload.append(Preloaded(meter: meter, n: 1, kind: .void, agoMs: 500, recorded: recorded))
            }
        }
    }

    var steps: [Step] = []
    if storm {
        steps.append(.net(mode: "down"))
        let p = g.int(0, 1)
        let times = g.int(3, 8)
        steps.append(.repeat(call: Call(p: p, meter: "renders", n: 1), times: times, gapMs: 61_000, r: g.draws()))
    } else if overfull {
        steps.append(.net(mode: "good"))
        let p = g.int(0, 1)
        steps.append(.deactivate(p: p, r: g.draws()))
    }
    for _ in 0..<g.int(8, 26) {
        let x = g.rand()
        if x < 0.3 {
            let c = g.call()
            steps.append(.use(calls: [c], status: nil, r: g.draws()))
        } else if x < 0.34 {
            let call = g.call()
            let times = g.int(2, 14)
            let gapMs = g.pick([10_000, 61_000, 5 * minute, 70 * minute])
            steps.append(.repeat(call: call, times: times, gapMs: gapMs, r: g.draws()))
        } else if x < 0.42 {
            let a = g.call(p: 0)
            let b = g.call(p: 1)
            steps.append(.use(calls: [a, b], status: nil, r: g.draws()))
        } else if x < 0.48 {
            let first = g.call()
            let second = g.call(p: first.p, not: first.meter)
            steps.append(.use(calls: [first, second], status: nil, r: g.draws()))
        } else if x < 0.53 {
            let c = g.call()
            let p = g.int(0, 1)
            let force = g.rand() < 0.7
            steps.append(.use(calls: [c], status: Step.StatusCall(p: p, force: force), r: g.draws()))
        } else if x < 0.64 {
            let p = g.int(0, 1)
            let force = g.rand() < 0.5
            steps.append(.status(p: p, force: force, r: g.draws()))
        } else if x < 0.78 {
            let ms = g.pick([1_000, 20_000, 59_000, 61_000, 5 * minute, 70 * minute, 3 * hour, 26 * hour])
            steps.append(.wait(ms: ms))
        } else if x < 0.84 {
            let ms = g.pick([30_000, 10 * minute, 2 * hour, 30 * hour, -30_000, -10 * minute, -2 * hour, -30 * hour])
            steps.append(.jump(ms: ms))
        } else if x < 0.92 {
            steps.append(.net(mode: g.pick(["good", "down", "down", "flaky", "flaky"])))
        } else if x < 0.97 {
            steps.append(.disk(failing: g.rand() < 0.6))
        } else if x < 0.985 {
            steps.append(.restart(p: g.int(0, 1)))
        } else {
            let p = g.int(0, 1)
            steps.append(.deactivate(p: p, r: g.draws()))
        }
    }
    // A release after an outage: spends made while the disk refused, the disk back, and a deactivate, which must carry them.
    if g.rand() < 0.1 {
        let p = g.int(0, 1)
        steps.append(.net(mode: "down"))
        steps.append(.disk(failing: true))
        let meter = g.pick(["exports", "credits"])
        steps.append(.use(calls: [Call(p: p, meter: meter, n: 1)], status: nil, r: g.draws()))
        steps.append(.use(calls: [Call(p: p, meter: "exports", n: 1)], status: nil, r: g.draws()))
        steps.append(.disk(failing: false))
        steps.append(.net(mode: "good"))
        steps.append(.deactivate(p: p, r: g.draws()))
    }
    return Case(seed: seed, meters: meters, preload: preload, steps: steps)
}

/// `values` sorted by `before`, keeping the order of those it does not put before each other.
private func stableSorted<T>(_ values: [T], by before: (T, T) -> Bool) -> [T] {
    values.enumerated().sorted { a, b in
        if before(a.element, b.element) { return true }
        if before(b.element, a.element) { return false }
        return a.offset < b.offset
    }.map(\.element)
}
