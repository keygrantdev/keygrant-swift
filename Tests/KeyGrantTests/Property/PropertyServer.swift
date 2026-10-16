import Foundation

@testable import KeyGrant

/// The server a property test of `use(_:_:)` runs the real `License` against: what the KeyGrant API does
/// with a request that carries a spend or a report of unsynced ones, as the contract says: every report
/// lands once by its id, an entry that grew adds what it grew by, a void takes an online spend or a report
/// back and keeps its id from counting later, and an answer names the entries it holds. Test support only.

/// What the server did with one request.
struct Served: Sendable {
    var status: Int
    var json: LicenseJSON
    /// The id of a spend of its own that this request recorded: a `use` that landed.
    var spent: String?
}

/// What it holds by spend id: an online spend or a report, at the count it has.
struct Held: Sendable, Hashable {
    var meter: String
    var n: Int
}

struct PropServer: Sendable {
    var meters: [String: MeterSpec]
    let signer: Signer
    /// What it holds by spend id.
    var recorded: [String: Held] = [:]
    /// The ids a void took back, or was the first to name.
    var voided: Set<String> = []
    /// The server's time (ms): it moves on by a millisecond with each request, so no two answers carry one time.
    var now: Int
    private var activations = 0

    init(meters: [String: MeterSpec], signer: Signer, now: Int) {
        self.meters = meters
        self.signer = signer
        self.now = now
    }

    /// What a meter has used: its recorded spends, whatever the allowance.
    func used(_ code: String) -> Int {
        recorded.values.filter { $0.meter == code }.map(\.n).reduce(0, +)
    }

    func left(_ code: String) -> Int {
        meters[code].map { max(0, $0.total - used(code)) } ?? 0
    }

    private func figures() -> LicenseJSON {
        .object(
            meters.reduce(into: [:]) { out, entry in
                var figure: [String: LicenseJSON] = [
                    "left": .number(Double(left(entry.key))), "total": .number(Double(entry.value.total)),
                    "offline": .number(Double(entry.value.offline)),
                ]
                if entry.value.resets { figure["resets"] = true }
                out[entry.key] = .object(figure)
            }
        )
    }

    /// The lease the server signs now for an activation: the key's meters as they stand, valid for 60 days.
    func lease(_ aid: String) -> String {
        signer.meteredLease(met: figures(), at: now, ttlSeconds: 60 * 86_400, over: ["aid": .string(aid), "model": "subscription", "major": 3])
    }

    /// Take a request's reports, and name the entries held after (always accepted).
    private mutating func report(_ spends: LicenseJSON?) -> [LicenseJSON] {
        var confirmed: [LicenseJSON] = []
        for entry in spends?.arrayValue ?? [] {
            let id = entry["id"]?.stringValue ?? ""
            let isVoid = entry.has("void")
            let n = entry["n"]?.intValue ?? 0
            if voided.contains(id) {
                confirmed.append(isVoid ? ["id": .string(id), "void": true] : ["id": .string(id), "n": .number(Double(n))])
                continue
            }
            if isVoid {
                recorded[id] = nil
                voided.insert(id)
                confirmed.append(["id": .string(id), "void": true])
                continue
            }
            if let held = recorded[id] {
                if n > held.n { recorded[id]?.n = n }
            } else {
                recorded[id] = Held(meter: entry["meter"]?.stringValue ?? "", n: n)
            }
            confirmed.append(["id": .string(id), "n": .number(Double(n))])
        }
        return confirmed
    }

    /// What the server answers a request of `action`, and what it recorded.
    mutating func handle(_ action: String, _ body: LicenseJSON) -> Served {
        now += 1
        let confirmed = report(body["spends"])
        func named(_ json: LicenseJSON) -> LicenseJSON {
            guard !confirmed.isEmpty, case .object(var members) = json else { return json }
            members["spends"] = .array(confirmed)
            return .object(members)
        }
        switch action {
        case "use":
            return useMeter(body, named)
        case "validate":
            let aid = body["activationId"]?.stringValue ?? ""
            return Served(status: 200, json: named(["lease": .string(lease(aid))]))
        case "deactivate":
            return Served(status: 200, json: named(["released": true]))
        case "activate":
            activations += 1
            let aid = "act_\(activations + 1)"
            return Served(status: 200, json: ["lease": .string(lease(aid)), "activationId": .string(aid)])
        default:
            return Served(status: 404, json: ["error": "unknown"])
        }
    }

    private mutating func useMeter(_ body: LicenseJSON, _ named: (LicenseJSON) -> LicenseJSON) -> Served {
        let meter = body["meter"]?.stringValue ?? ""
        let n = body["n"]?.intValue ?? 0
        let id = body["id"]?.stringValue ?? ""
        guard meters[meter] != nil else { return Served(status: 404, json: named(["error": "unknown-meter"])) }
        if recorded[id] != nil {
            return Served(status: 200, json: named(["spent": true, "meters": figures(), "at": .number(Double(now))]))
        }
        if n > left(meter) {
            let json = named(["error": "used-up", "left": .number(Double(left(meter))), "meters": figures(), "at": .number(Double(now))])
            return Served(status: 409, json: json)
        }
        recorded[id] = Held(meter: meter, n: n)
        return Served(status: 200, json: named(["spent": true, "meters": figures(), "at": .number(Double(now))]), spent: id)
    }
}
