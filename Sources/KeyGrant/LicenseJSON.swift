import Foundation

/// A JSON value: what the KeyGrant API is sent and answers, and what a licence state file holds.
///
/// Numbers are `Double`, as JavaScript holds them, so whatever the reference SDK (or the server)
/// writes reads back the same here. Two values are equal when JavaScript would find them so:
/// strings, and object member names, unit for unit. Swift's `String` equality would also take two
/// spellings of the same text (an "é" composed, and one decomposed) as one; JSON does not.
///
/// Formerly `JSONValue`, a name that collides with the JSON types of many other modules.
public enum LicenseJSON: Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([LicenseJSON])
    case object([String: LicenseJSON])
}

/// The name `LicenseJSON` had before: kept so code written against it still builds. An app that
/// also imports a module with a `JSONValue` of its own names this one `LicenseJSON`.
@available(*, deprecated, renamed: "LicenseJSON")
public typealias JSONValue = LicenseJSON

extension LicenseJSON {
    /// The member named `key` of an object; nil when there is none, or for any value but an object.
    public subscript(key: String) -> LicenseJSON? {
        guard case .object(let members) = self else { return nil }
        return members[key]
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var arrayValue: [LicenseJSON]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: LicenseJSON]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// The number as a whole `Int`, a fraction cut toward zero; nil for anything but a number, or
    /// for one outside the range a JavaScript number holds exactly (`Number.MAX_SAFE_INTEGER`).
    var intValue: Int? {
        guard case .number(let value) = self else { return nil }
        return wholeNumber(value)
    }
}

// MARK: - equality

/// Equal as JavaScript compares JSON: strings and member names unit for unit (`===`), numbers as
/// numbers (`0` and `-0` alike, `NaN` equal to nothing), arrays in order, objects by their members
/// whatever their order. Compared, and hashed, without recursion: however deep a value nests,
/// neither takes more stack than a shallow one does. (Releasing a value does recurse, which is
/// why `JSONText` parses nothing nested deeper than `JSONText.maxDepth`.)
extension LicenseJSON: Hashable {
    public static func == (lhs: LicenseJSON, rhs: LicenseJSON) -> Bool {
        var pending = [(lhs, rhs)]
        while let (left, right) = pending.popLast() {
            switch (left, right) {
            case (.null, .null):
                continue
            case (.bool(let a), .bool(let b)):
                if a != b { return false }
            case (.number(let a), .number(let b)):
                if a != b { return false }
            case (.string(let a), .string(let b)):
                if !sameText(a, b) { return false }
            case (.array(let a), .array(let b)):
                guard a.count == b.count else { return false }
                pending.append(contentsOf: zip(a, b))
            case (.object(let a), .object(let b)):
                guard a.count == b.count else { return false }
                for (name, value) in a {
                    // A dictionary finds a member by a name that is only canonically equivalent:
                    // the name it holds must be the very same one.
                    guard let index = b.index(forKey: name), sameText(b[index].key, name) else { return false }
                    pending.append((value, b[index].value))
                }
            default:
                return false
            }
        }
        return true
    }

    /// Consistent with `==`: values it equates hash alike. An object hashes by its member names
    /// alone, so the order a dictionary keeps them in cannot change its hash.
    public func hash(into hasher: inout Hasher) {
        var pending = [self]
        while let value = pending.popLast() {
            switch value {
            case .null:
                hasher.combine(0 as UInt8)
            case .bool(let bool):
                hasher.combine(1 as UInt8)
                hasher.combine(bool)
            case .number(let number):
                hasher.combine(2 as UInt8)
                hasher.combine(number)
            case .string(let string):
                hasher.combine(3 as UInt8)
                hasher.combine(string)
            case .array(let items):
                hasher.combine(4 as UInt8)
                hasher.combine(items.count)
                pending.append(contentsOf: items.reversed())
            case .object(let members):
                hasher.combine(5 as UInt8)
                hasher.combine(members.count)
                hasher.combine(members.keys.reduce(0) { $0 ^ $1.hashValue })
            }
        }
    }
}

// MARK: - numbers

/// The largest whole number JavaScript holds exactly (2^53 - 1). Every time and count the SDK
/// keeps stays within it, so no arithmetic on two of them can overflow an `Int`.
let maxSafeInteger = 9_007_199_254_740_991

/// `value` as a whole number cut toward zero, or nil when it is not finite or not within
/// `maxSafeInteger` of zero.
func wholeNumber(_ value: Double) -> Int? {
    guard value.isFinite else { return nil }
    let whole = value.rounded(.towardZero)
    guard abs(whole) <= Double(maxSafeInteger) else { return nil }
    return Int(exactly: whole)
}

/// `value` held within `maxSafeInteger` of zero.
func clampToSafe(_ value: Int) -> Int {
    min(max(value, -maxSafeInteger), maxSafeInteger)
}

// MARK: - Codable

/// Through Foundation's coders, with their limits (`JSONDecoder` refuses nesting deeper than 512,
/// and a number past a `Double`). The SDK itself reads and writes JSON with `JSONText`, as
/// JavaScript's `JSON.parse` and `JSON.stringify` do.
extension LicenseJSON: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([LicenseJSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: LicenseJSON].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            // A whole number is written as one ("1790000000000", never "1.79e12"), as JavaScript writes it.
            if let whole = Int64(exactly: value) {
                try container.encode(whole)
            } else {
                try container.encode(value)
            }
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

extension LicenseJSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: LicenseJSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, LicenseJSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

// MARK: - JSON text

/// JSON text in and out, as JavaScript reads and writes it: `JSON.parse` and `JSON.stringify`.
///
/// Read: the grammar exactly (no trailing comma, no comment, no `NaN`, no leading zero, no raw
/// control character in a string, only the four JSON whitespace characters); a member named twice
/// keeps its LAST value; a number past a `Double` is `±Infinity` and one below its smallest is 0;
/// any value at the top. What Swift cannot hold as JavaScript does is listed in the README
/// (Parity): an escaped lone surrogate (`"\ud800"`) reads as U+FFFD, two member names that are
/// only canonically equivalent are one member, and nesting deeper than `maxDepth` does not parse.
///
/// Written: compact, members in a stable order, strings escaped as `JSON.stringify` escapes them,
/// numbers as JavaScript prints them, and a number that is not finite as `null`.
enum JSONText {
    /// How deeply arrays and objects may nest. `JSON.parse` takes any depth; a Swift value that
    /// deep is released recursively, and a thread's stack (512 KB for a secondary thread on macOS)
    /// holds about 2,000 levels of that. Half of it leaves room for the caller's own frames.
    static let maxDepth = 1_000

    /// `JSON.parse(text)`: the value, or nil where it throws. A byte-order mark is not whitespace:
    /// text read from a file with one (Node's `readFile(path, 'utf8')` keeps it) does not parse.
    static func parse(_ text: String) -> LicenseJSON? {
        var parser = JSONParser(text)
        return parser.document()
    }

    /// `JSON.parse(new TextDecoder().decode(data))`, as a fetch body's `json()` and a lease's
    /// payload are read: UTF-8, every malformed sequence replaced by U+FFFD, and a leading
    /// byte-order mark dropped.
    static func parse(decoding data: Data) -> LicenseJSON? {
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        let bytes = data.starts(with: bom) ? data.dropFirst(bom.count) : data[...]
        return parse(String(decoding: bytes, as: UTF8.self))
    }

    /// `value` as compact JSON text, UTF-8. Written without recursion.
    static func data(_ value: LicenseJSON) -> Data {
        Data(text(value).utf8)
    }

    /// `value` as compact JSON text, as `JSON.stringify` writes it (its members sorted).
    static func text(_ value: LicenseJSON) -> String {
        enum Step {
            case value(LicenseJSON)
            case punctuation(UInt8)
            case name(String)
        }
        var out: [UInt8] = []
        var steps: [Step] = [.value(value)]
        while let step = steps.popLast() {
            switch step {
            case .punctuation(let byte):
                out.append(byte)
            case .name(let name):
                appendQuoted(name, to: &out)
                out.append(UInt8(ascii: ":"))
            case .value(.null):
                out.append(contentsOf: "null".utf8)
            case .value(.bool(let bool)):
                out.append(contentsOf: (bool ? "true" : "false").utf8)
            case .value(.number(let number)):
                out.append(contentsOf: numberText(number).utf8)
            case .value(.string(let string)):
                appendQuoted(string, to: &out)
            case .value(.array(let items)):
                out.append(UInt8(ascii: "["))
                steps.append(.punctuation(UInt8(ascii: "]")))
                for (index, item) in items.enumerated().reversed() {
                    steps.append(.value(item))
                    if index > 0 { steps.append(.punctuation(UInt8(ascii: ","))) }
                }
            case .value(.object(let members)):
                out.append(UInt8(ascii: "{"))
                steps.append(.punctuation(UInt8(ascii: "}")))
                // By UTF-16 code unit, as JavaScript's default sort orders strings.
                let sorted = members.sorted { $0.key.utf16.lexicographicallyPrecedes($1.key.utf16) }
                for (index, member) in sorted.enumerated().reversed() {
                    steps.append(.value(member.value))
                    steps.append(.name(member.key))
                    if index > 0 { steps.append(.punctuation(UInt8(ascii: ","))) }
                }
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// A string as `JSON.stringify` quotes it: `"` and `\` escaped, the control characters as
    /// `\b \t \n \f \r` or `\u00xx` (lower-case hex), everything else as it is.
    static func appendQuoted(_ string: String, to out: inout [UInt8]) {
        let hex = Array("0123456789abcdef".utf8)
        out.append(UInt8(ascii: "\""))
        for byte in string.utf8 {
            switch byte {
            case UInt8(ascii: "\""): out.append(contentsOf: #"\""#.utf8)
            case UInt8(ascii: "\\"): out.append(contentsOf: #"\\"#.utf8)
            case 0x08: out.append(contentsOf: #"\b"#.utf8)
            case 0x09: out.append(contentsOf: #"\t"#.utf8)
            case 0x0A: out.append(contentsOf: #"\n"#.utf8)
            case 0x0C: out.append(contentsOf: #"\f"#.utf8)
            case 0x0D: out.append(contentsOf: #"\r"#.utf8)
            case 0x00..<0x20:
                out.append(contentsOf: #"\u00"#.utf8)
                out.append(hex[Int(byte >> 4)])
                out.append(hex[Int(byte & 0x0F)])
            default: out.append(byte)
            }
        }
        out.append(UInt8(ascii: "\""))
    }

    /// A number as JavaScript prints it (ECMA-262 `Number::toString`): the fewest digits that read
    /// back as the same number, in plain notation from 1e-6 up to 1e21 and in exponent notation
    /// (`1e+21`, `1.5e-7`) beyond; `-0` as `0`, and a number that is not finite as `null`, as
    /// `JSON.stringify` writes it.
    static func numberText(_ value: Double) -> String {
        guard value.isFinite else { return "null" }
        if value == 0 { return "0" }
        // Swift's description is the shortest that round-trips, as JavaScript's: its digits, and
        // where the decimal point falls among them (`n`: the value is 0.digits × 10^n).
        let description = value.magnitude.description
        let parts = description.split(separator: "e", maxSplits: 1)
        let mantissa = parts[0]
        let exponent = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        let point = mantissa.firstIndex(of: ".")
        let whole = point.map { mantissa[..<$0] } ?? mantissa
        let fraction = point.map { mantissa[mantissa.index(after: $0)...] } ?? ""
        var digits = Array((whole + fraction).utf8)
        var n = whole.count + exponent
        while digits.first == UInt8(ascii: "0") {
            digits.removeFirst()
            n -= 1
        }
        while digits.last == UInt8(ascii: "0") { digits.removeLast() }
        let k = digits.count
        let s = String(decoding: digits, as: UTF8.self)
        let sign = value < 0 ? "-" : ""
        if k <= n && n <= 21 { return sign + s + String(repeating: "0", count: n - k) }
        if 0 < n && n <= 21 { return sign + String(s.prefix(n)) + "." + String(s.dropFirst(n)) }
        if -6 < n && n <= 0 { return sign + "0." + String(repeating: "0", count: -n) + s }
        let e = n - 1
        let exponentText = (e < 0 ? "-" : "+") + String(e.magnitude)
        if k == 1 { return sign + s + "e" + exponentText }
        return sign + String(s.prefix(1)) + "." + String(s.dropFirst()) + "e" + exponentText
    }
}

/// `JSON.parse`, over the text's UTF-8, without recursion: what is open is kept on stacks of its
/// own, so only `JSONText.maxDepth` bounds the nesting.
private struct JSONParser {
    private let bytes: [UInt8]
    private var index = 0

    init(_ text: String) {
        bytes = Array(text.utf8)
    }

    /// An array or an object that is open.
    private enum Open {
        case array
        case object
    }

    mutating func document() -> LicenseJSON? {
        // What is open, innermost last; each array's items and each object's members so far, and
        // the name of the member whose value comes next.
        var open: [Open] = []
        var arrays: [[LicenseJSON]] = []
        var objects: [[String: LicenseJSON]] = []
        var names: [String] = []
        skipWhitespace()
        parsing: while true {
            // A value comes next.
            var value: LicenseJSON
            guard index < bytes.count else { return nil }
            switch bytes[index] {
            case UInt8(ascii: "["):
                // One more level of nesting, empty or not.
                guard open.count < JSONText.maxDepth else { return nil }
                index += 1
                skipWhitespace()
                if take(UInt8(ascii: "]")) {
                    value = .array([])
                } else {
                    open.append(.array)
                    arrays.append([])
                    continue parsing
                }
            case UInt8(ascii: "{"):
                guard open.count < JSONText.maxDepth else { return nil }
                index += 1
                skipWhitespace()
                if take(UInt8(ascii: "}")) {
                    value = .object([:])
                } else {
                    guard let name = memberName() else { return nil }
                    open.append(.object)
                    objects.append([:])
                    names.append(name)
                    continue parsing
                }
            case UInt8(ascii: "\""):
                guard let string = string() else { return nil }
                value = .string(string)
            case UInt8(ascii: "t"):
                guard literal("true") else { return nil }
                value = .bool(true)
            case UInt8(ascii: "f"):
                guard literal("false") else { return nil }
                value = .bool(false)
            case UInt8(ascii: "n"):
                guard literal("null") else { return nil }
                value = .null
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
                guard let number = number() else { return nil }
                value = .number(number)
            default:
                return nil
            }
            // A value is whole: it goes into what is open, which may close in turn.
            while true {
                skipWhitespace()
                guard let innermost = open.last else {
                    // The top: only whitespace may follow it.
                    return index == bytes.count ? value : nil
                }
                switch innermost {
                case .array:
                    arrays[arrays.count - 1].append(value)
                    if take(UInt8(ascii: ",")) {
                        skipWhitespace()
                        continue parsing
                    }
                    guard take(UInt8(ascii: "]")) else { return nil }
                    open.removeLast()
                    value = .array(arrays.removeLast())
                case .object:
                    // A member named twice keeps its last value.
                    objects[objects.count - 1][names.removeLast()] = value
                    if take(UInt8(ascii: ",")) {
                        skipWhitespace()
                        guard let name = memberName() else { return nil }
                        names.append(name)
                        continue parsing
                    }
                    guard take(UInt8(ascii: "}")) else { return nil }
                    open.removeLast()
                    value = .object(objects.removeLast())
                }
            }
        }
    }

    /// `"name"` and the `:` after it, with the whitespace around them.
    private mutating func memberName() -> String? {
        guard index < bytes.count, bytes[index] == UInt8(ascii: "\""), let name = string() else { return nil }
        skipWhitespace()
        guard take(UInt8(ascii: ":")) else { return nil }
        skipWhitespace()
        return name
    }

    /// Space, tab, line feed and carriage return: JSON's whitespace, and nothing else.
    private mutating func skipWhitespace() {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0A, 0x0D: index += 1
            default: return
            }
        }
    }

    private mutating func take(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    private mutating func literal(_ word: String) -> Bool {
        let expected = Array(word.utf8)
        guard bytes.count - index >= expected.count, bytes[index..<(index + expected.count)].elementsEqual(expected) else {
            return false
        }
        index += expected.count
        return true
    }

    private func isDigit(_ offset: Int) -> Bool {
        offset < bytes.count && (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[offset])
    }

    /// `-? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE] [+-]? [0-9]+)?`, read as JavaScript reads it.
    private mutating func number() -> Double? {
        let start = index
        _ = take(UInt8(ascii: "-"))
        if !take(UInt8(ascii: "0")) {
            // No leading zero: "01" is not a number.
            guard isDigit(index) else { return nil }
            while isDigit(index) { index += 1 }
        }
        if take(UInt8(ascii: ".")) {
            guard isDigit(index) else { return nil }
            while isDigit(index) { index += 1 }
        }
        if take(UInt8(ascii: "e")) || take(UInt8(ascii: "E")) {
            if !take(UInt8(ascii: "+")) { _ = take(UInt8(ascii: "-")) }
            guard isDigit(index) else { return nil }
            while isDigit(index) { index += 1 }
        }
        // Rounded to the nearest `Double`; past the largest it is infinite, as in JavaScript.
        return Double(String(decoding: bytes[start..<index], as: UTF8.self))
    }

    /// A string, from its opening quote: escapes read, a raw control character refused.
    private mutating func string() -> String? {
        guard take(UInt8(ascii: "\"")) else { return nil }
        var out: [UInt8] = []
        var run = index
        while index < bytes.count {
            switch bytes[index] {
            case UInt8(ascii: "\""):
                out.append(contentsOf: bytes[run..<index])
                index += 1
                return String(decoding: out, as: UTF8.self)
            case UInt8(ascii: "\\"):
                out.append(contentsOf: bytes[run..<index])
                index += 1
                guard escape(into: &out) else { return nil }
                run = index
            case 0x00..<0x20:
                return nil
            default:
                index += 1
            }
        }
        return nil
    }

    /// One escape, after its backslash.
    private mutating func escape(into out: inout [UInt8]) -> Bool {
        guard index < bytes.count else { return false }
        let byte = bytes[index]
        index += 1
        switch byte {
        case UInt8(ascii: "\""): out.append(UInt8(ascii: "\""))
        case UInt8(ascii: "\\"): out.append(UInt8(ascii: "\\"))
        case UInt8(ascii: "/"): out.append(UInt8(ascii: "/"))
        case UInt8(ascii: "b"): out.append(0x08)
        case UInt8(ascii: "f"): out.append(0x0C)
        case UInt8(ascii: "n"): out.append(0x0A)
        case UInt8(ascii: "r"): out.append(0x0D)
        case UInt8(ascii: "t"): out.append(0x09)
        case UInt8(ascii: "u"):
            guard let unit = hexUnit() else { return false }
            var scalar = Unicode.Scalar(unit)
            if (0xD800...0xDBFF).contains(unit) {
                // A high surrogate and the low one escaped after it are one character.
                let mark = index
                if take(UInt8(ascii: "\\")), take(UInt8(ascii: "u")), let low = hexUnit(), (0xDC00...0xDFFF).contains(low) {
                    scalar = Unicode.Scalar((UInt32(unit) - 0xD800) << 10 + (UInt32(low) - 0xDC00) + 0x10000)
                } else {
                    index = mark
                }
            }
            // A lone surrogate, which a Swift string cannot hold, is U+FFFD.
            let replacement: Unicode.Scalar = "\u{FFFD}"
            UTF8.encode(scalar ?? replacement) { out.append($0) }
        default:
            return false
        }
        return true
    }

    /// Four hex digits, either case.
    private mutating func hexUnit() -> UInt16? {
        guard bytes.count - index >= 4 else { return nil }
        var unit: UInt16 = 0
        for _ in 0..<4 {
            let byte = bytes[index]
            let digit: UInt8
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = byte - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = byte - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = byte - UInt8(ascii: "A") + 10
            default: return nil
            }
            unit = unit << 4 | UInt16(digit)
            index += 1
        }
        return unit
    }
}
