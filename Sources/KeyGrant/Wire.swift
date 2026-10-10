import Foundation

/// What the SDK sends and reads on the wire: the server's error words, the bounds the endpoints
/// hold strings to, and the shapes of their answers.

/// What `/activate` accepts for a device name. Longer is cut, not refused.
let maxDeviceName = 120
/// What it accepts for a licence key. A longer one is not a key it could hold.
let maxKey = 120

/// The app's error for an activation's error word.
func mapServerError(_ error: String?) -> LicenseError {
    switch error {
    case "invalid-key": .invalidKey
    case "limit": .limit
    case "revoked", "expired": .revoked
    case "upgrade-required": .upgrade
    case "update-required": .outdated
    default: .network
    }
}

/// The definitive refusal a validate's error word is, or nil for any other word, which is never
/// taken as a verdict (a proxy's 4xx, an unknown product, a body the server could not read).
func refusalOf(_ error: String?) -> Refusal? {
    switch error {
    case "upgrade-required": .upgrade
    case "update-required": .outdated
    case "revoked", "expired", "deactivated": .revoked
    case "device": .device
    default: nil
    }
}

/// Whether a response is no answer at all: an outage (5xx) or a refusal to serve now (429).
func noAnswer(_ status: Int) -> Bool {
    status >= 500 || status == 429
}

/// The key a person entered, normalised (trimmed as JavaScript trims, then upper-cased), which is
/// the key that is sent and stored; or nil when it cannot be a key: empty, or longer than
/// `maxKey` UTF-16 units.
func enteredKey(_ key: String) -> String? {
    let entered = jsTrim(key).uppercased()
    return !entered.isEmpty && entered.utf16.count <= maxKey ? entered : nil
}

/// `value` cut to `max` UTF-16 units without splitting a character: a high surrogate left alone
/// at the end has lost its pair, and goes too.
func trimToLength(_ value: String?, _ max: Int) -> String? {
    guard let value, value.utf16.count > max else { return value }
    var units = Array(value.utf16.prefix(Swift.max(0, max)))
    if let last = units.last, (0xD800...0xDBFF).contains(last) { units.removeLast() }
    return String(decoding: units, as: UTF16.self)
}

/// The error word of a server body, when it has one.
func errorOf(_ json: LicenseJSON?) -> String? {
    json?["error"]?.stringValue
}

/// The lease and activation id of a server body, keeping only string values.
func parseLeaseBody(_ json: LicenseJSON?) -> (lease: String?, activationId: String?) {
    (json?["lease"]?.stringValue, json?["activationId"]?.stringValue)
}

/// A trial answer's body.
struct TrialBody: Sendable, Hashable {
    var trialStart: Int
    var trialEndsAt: Int
    var lease: String?
}

/// The (unsigned) trial answer, or nil when its start and end are not numbers.
func parseTrialBody(_ json: LicenseJSON?) -> TrialBody? {
    guard let start = json?["trialStart"]?.intValue, let end = json?["trialEndsAt"]?.intValue else { return nil }
    return TrialBody(trialStart: start, trialEndsAt: end, lease: json?["lease"]?.stringValue)
}

/// The smallest of the times given, or nil when none is.
func earliest(_ values: Int?...) -> Int? {
    values.compactMap { $0 }.min()
}

/// A string as JavaScript's truthiness reads it: nil when absent or empty.
func nonEmpty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
}

/// What JavaScript's `String.prototype.trim` removes, as V8 removes it.
private let jsWhitespace: Set<Unicode.Scalar> = {
    var scalars: Set<Unicode.Scalar> = []
    let values: [UInt32] =
        [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF]
        + Array(0x2000...0x200A)
    for value in values {
        if let scalar = Unicode.Scalar(value) { scalars.insert(scalar) }
    }
    return scalars
}()

/// `text` trimmed as JavaScript trims it (its whitespace set differs from Foundation's).
func jsTrim(_ text: String) -> String {
    let scalars = text.unicodeScalars
    guard let first = scalars.firstIndex(where: { !jsWhitespace.contains($0) }),
        let last = scalars.lastIndex(where: { !jsWhitespace.contains($0) })
    else { return "" }
    return String(String.UnicodeScalarView(scalars[first...last]))
}

/// How long a check `status()` makes on a valid lease may hold it up.
let statusCheckTimeout: TimeInterval = 5
