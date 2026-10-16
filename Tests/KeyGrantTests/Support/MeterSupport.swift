import Foundation

@testable import KeyGrant

/// What the metered-uses suites share: a key's lease carrying meters, a harness holding it, and the
/// server's answers to a `use`.

let MINUTE = 60_000
/// A month of a lease's life, in seconds.
let MONTH_SECONDS = 30 * 24 * 3600
/// Long enough ago that the journal's wait for an entry is over.
let LONG_AGO = NOW - 2 * HOUR

/// A key with 100 exports, 90 of them left, a device allowance of 10, and 5 renders a billing period.
func meters() -> LicenseJSON {
    [
        "exports": ["left": 90, "total": 100, "offline": 10],
        "renders": ["left": 5, "total": 5, "offline": 0, "resets": true],
    ]
}

func figure(_ left: Int, _ total: Int, _ offline: Int, _ resets: Bool = false) -> BaseFigure {
    BaseFigure(left: left, total: total, offline: offline, resets: resets)
}

/// The usual meter's base figures: 90 of 100 left, 10 offline.
func usual() -> [String: BaseFigure] {
    ["exports": figure(90, 100, 10)]
}

/// A 22-character id made of one letter.
func spendId(_ letter: String) -> String {
    String(repeating: letter, count: 22)
}

/// The journal's entry for a spend of `exports`.
func entry(_ kind: SpendKind, _ n: Int, _ at: Int) -> SpendEntry {
    SpendEntry(id: "AAAAAAAAAAAAAAAAAAAAAA", meter: "exports", n: n, at: at, kind: kind)
}

/// `entry` under an id of its own.
func entry(id: String, _ kind: SpendKind, _ n: Int, _ at: Int, meter: String = "exports") -> SpendEntry {
    SpendEntry(id: id, meter: meter, n: n, at: at, kind: kind)
}

/// An id of 22 characters from a number: `0000...0007`, with a letter to tell families apart.
func numbered(_ i: Int, _ letter: String = "k") -> String {
    String(repeating: letter, count: 22 - String(i).count) + String(i)
}

extension Signer {
    /// `header.payload` signed, the payload being exactly this JSON text.
    func sign(text: String) -> String {
        let header = base64URLEncode(JSONText.data(["alg": "EdDSA", "typ": "JWT"]))
        return sign(input: "\(header).\(base64URLEncode(Data(text.utf8)))")
    }

    /// A licence lease for `KEY` on `act_1`, covering majors 1 to 3, with `met` (none for nil), signed
    /// at `at` (ms) for a month, `over` laid over its claims (a nil value removes the claim).
    func meteredLease(
        met: LicenseJSON? = meters(), at: Int = NOW, ttlSeconds: Int = MONTH_SECONDS, over: [String: LicenseJSON?] = [:]
    ) -> String {
        let iat = at / 1000
        var claims: [String: LicenseJSON] = [
            "iss": "keygrant", "sub": .string(KEY), "product": .string(PRODUCT), "aid": "act_1", "model": "subscription",
            "lim": 3, "major": 3, "ent": [:], "iat": .number(Double(iat)), "exp": .number(Double(iat + ttlSeconds)),
        ]
        if let met { claims["met"] = met }
        for (name, value) in over { claims[name] = value }
        return sign(payload: .object(claims))
    }

    /// A lease whose `met` is the JSON text given, written exactly as given (a figure `4.0`, `1e1` or
    /// `1e400` stays as it is), signed as the server signs.
    func rawLease(met: String) -> String {
        let iat = NOW / 1000
        return sign(
            text: #"{"iss":"keygrant","sub":"\#(KEY)","product":"\#(PRODUCT)","aid":"act_1","model":"subscription","lim":3,"major":3,"ent":{},"met":\#(met),"iat":\#(iat),"exp":\#(iat + MONTH_SECONDS)}"#
        )
    }
}

/// A stored state holding `KEY` activated on `act_1` with `lease`, seen at NOW.
func licensedState(with lease: String) -> StoredState {
    StoredState(key: KEY, activationId: "act_1", lease: lease, lastSeen: NOW)
}

/// The timings of a test whose call waits behind one that has not finished: it waits the HTTP bound and
/// the grace, then goes on read-only. The grace is short; the bound is also what the call's own request
/// may take, so it is long beside an answer in memory.
let behind = Timing(lockGrace: 0.05, statusCheck: 5, machineId: 0.2, activateMachineId: 0.6, identifySlack: 0.3)

extension Harness {
    /// A harness whose storage holds `KEY` activated on `act_1` with a lease carrying `met`, and
    /// `state` laid beside it.
    static func holding(
        met: LicenseJSON? = meters(), major: Int = 1, httpTimeout: TimeInterval = 15, timing: Timing = .standard,
        fingerprinter: (any Fingerprinter)? = nil, deviceHold: Bool = true, _ state: (inout StoredState) -> Void = { _ in }
    ) throws -> Harness {
        let h = try Harness(major: major, httpTimeout: httpTimeout, fingerprinter: fingerprinter, deviceHold: deviceHold, timing: timing)
        var held = licensedState(with: h.signer.meteredLease(met: met))
        state(&held)
        h.storage.set(held)
        return h
    }

    /// A harness holding the usual meters and `spends` in its journal.
    static func holdingJournal(
        _ spends: [SpendEntry], httpTimeout: TimeInterval = 15, timing: Timing = .standard
    ) throws -> Harness {
        try holding(httpTimeout: httpTimeout, timing: timing) { $0.spends = spends.isEmpty ? nil : spends }
    }

    /// The server's answer to a spend that landed: what is left of `exports` now, at `at`.
    static func spent(_ left: Int, at: Int) -> LicenseHTTPResponse {
        LicenseHTTPResponse(
            status: 200,
            json: ["spent": true, "meters": ["exports": ["left": .number(Double(left)), "total": 100, "offline": 10]], "at": .number(Double(at))]
        )
    }

    /// The body of the `nth` (from 0) `use` request.
    func useBody(_ nth: Int = 0) -> LicenseJSON {
        let bodies = http.calls.filter { $0.action == "use" }.map { $0.body }
        return bodies.indices.contains(nth) ? bodies[nth] : .null
    }

    /// The journal as stored now.
    var journal: [SpendEntry] { storage.stored?.spends ?? [] }
}

/// The journal as `[kind, n]`.
func kindsAndCounts(_ journal: [SpendEntry]) -> [String] {
    journal.map { "\($0.kind.rawValue) \($0.n)" }
}
