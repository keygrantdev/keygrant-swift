import Foundation

/// Metered values read leniently from JSON, as the reference reads them: a lease's `met`, the
/// figures a `use` answer gives, and the journal and figures a state file holds. A value of another
/// shape is left out, never the lease, the answer or the state it rides in.

/// A figure of a meter: a JSON number that is a non-negative whole number a double holds exactly,
/// however it is written (`4.0` is 4, `1e1` is 10, `-0` is 0). A number out of a double's range
/// (`1e400` reads as infinity), a fraction, a negative, or one past 2^53 - 1 is none, as is any
/// value that is not a number.
func figureOf(_ json: LicenseJSON?) -> Int? {
    guard case .number(let number)? = json, isWhole(number), number >= 0, number <= Double(maxSafeInteger) else { return nil }
    return Int(exactly: number)
}

/// A whole number from 1 to 2^53 - 1, however written: the count of a spend or of a confirmation.
func countOf(_ json: LicenseJSON?) -> Int? {
    figureOf(json).flatMap { $0 >= 1 ? $0 : nil }
}

/// A meter as a lease or an answer gives it: an object whose `left`, `total` and `offline` are each
/// a figure. `resets` is true only for JSON `true`.
private func meterOf(_ json: LicenseJSON) -> BaseFigure? {
    guard case .object(let meter) = json, let left = figureOf(meter["left"]), let total = figureOf(meter["total"]),
        let offline = figureOf(meter["offline"])
    else { return nil }
    return BaseFigure(left: left, total: total, offline: offline, resets: meter["resets"] == .bool(true))
}

/// A lease's `met` (or the `meters` of a `use` answer) read leniently: every member that is an
/// object whose `left`, `total` and `offline` are each a figure; any other member is dropped, never
/// the lease and never the meters beside it. Anything but an object (a list, a text, a number, a
/// flag, `null`) is no meters. Names are kept as they are, `__proto__` included, and a meter's other
/// members are ignored. The server's caps (how many, how large, `left` at most `total`) are not
/// enforced: the signature is the server's word, and a later server may raise them without locking
/// out a build made before.
func metersOf(_ json: LicenseJSON?) -> [String: BaseFigure] {
    guard case .object(let members)? = json else { return [:] }
    return members.compactMapValues(meterOf)
}

/// A stored journal entry: an object with a text `id` and `meter`, an `n` that is a count, an `at`
/// that is a figure, and one of the three kinds. Any other is left out, and an entry's unknown
/// members are not kept.
private func spendOf(_ json: LicenseJSON) -> SpendEntry? {
    guard case .object(let entry) = json, let id = entry["id"]?.stringValue, let meter = entry["meter"]?.stringValue,
        let n = countOf(entry["n"]), let at = figureOf(entry["at"]),
        let kind = entry["kind"]?.stringValue.flatMap(SpendKind.init(rawValue:))
    else { return nil }
    return SpendEntry(id: id, meter: meter, n: n, at: at, kind: kind)
}

/// The journal a stored `spends` is: its entries in order; anything that is not a list is an empty
/// journal, and an entry of another shape is left out. The state is the device's own, never the
/// server's word.
func spendsOf(_ json: LicenseJSON?) -> [SpendEntry] {
    guard case .array(let entries)? = json else { return [] }
    return entries.compactMap(spendOf)
}

/// The figures a stored `meterFigures` holds, by code: a member that is not an object of three
/// figures and a time is left out.
func storedFigures(_ json: LicenseJSON?) -> [String: MeterFigure] {
    guard case .object(let members)? = json else { return [:] }
    return members.compactMapValues { member in
        guard case .object(let figure) = member, let base = meterOf(member), let at = figureOf(figure["at"]) else { return nil }
        return MeterFigure(left: base.left, total: base.total, offline: base.offline, resets: base.resets, at: at)
    }
}

// MARK: - writing

/// A journal entry as the state file writes it.
func spendJSON(_ entry: SpendEntry) -> LicenseJSON {
    [
        "id": .string(entry.id), "meter": .string(entry.meter), "n": .number(Double(entry.n)), "at": .number(Double(entry.at)),
        "kind": .string(entry.kind.rawValue),
    ]
}

/// A figure as the state file writes it, `at` included.
func storedFigureJSON(_ figure: MeterFigure) -> LicenseJSON {
    [
        "left": .number(Double(figure.left)), "total": .number(Double(figure.total)),
        "offline": .number(Double(figure.offline)), "resets": .bool(figure.resets), "at": .number(Double(figure.at)),
    ]
}

/// A lease's meters as the conformance vectors write them: `resets` always there.
func metersJSON(_ meters: [String: BaseFigure]) -> LicenseJSON {
    .object(
        meters.mapValues { figure in
            [
                "left": .number(Double(figure.left)), "total": .number(Double(figure.total)),
                "offline": .number(Double(figure.offline)), "resets": .bool(figure.resets),
            ]
        }
    )
}
