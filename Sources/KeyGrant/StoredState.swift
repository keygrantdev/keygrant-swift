import Foundation

/// The licence state a device keeps, between runs, one per product.
///
/// It is saved as a JSON object with the SAME field names every KeyGrant SDK uses (camelCase,
/// absent fields left out, times in milliseconds since 1970), so a state file is portable between
/// them. A field this SDK does not know is kept as it was (`otherFields`) and written back.
public struct StoredState: Sendable, Hashable {
    public var key: String?
    public var activationId: String?
    /// The signed JWT lease of a paid licence.
    public var lease: String?
    /// The earliest trial start ever seen. Only ever moves earlier.
    public var trialStart: Int?
    /// The server's trial end.
    public var trialEndsAt: Int?
    /// The signed JWT lease of a trial.
    public var trialLease: String?
    /// When (guarded device clock) the trial answer stored here was asked for.
    public var trialAt: Int?
    /// The highest device time ever seen: the guard against putting the clock back.
    public var lastSeen: Int?
    /// The app major sent with the last check-in the server answered.
    public var checkedMajor: Int?
    /// The newest app major run while holding a lease signed inside the key's upgrade window.
    public var keptMajor: Int?
    /// When the last ask came back without a lease, and how long to wait after it.
    public var backoffSince: Int?
    public var backoffMs: Int?
    /// The server's definitive refusal of this key on this device.
    public var refused: Refusal?
    /// The build major an `upgrade` or `outdated` refusal was given for.
    public var refusedMajor: Int?
    /// The device a `device` refusal was given for (its own claim hash, never a fingerprint).
    public var refusedFor: [String]?
    /// What this install is keyed by: the kind, never a fingerprint.
    public var deviceKind: DeviceKind?
    /// When (guarded device clock) the server's answer stored here was asked for.
    public var verdictAt: Int?
    /// The default storage's revision of this state, one more on every save.
    public var rev: Int?
    /// Fields this SDK does not know (a newer SDK's), kept as they were.
    public var otherFields: [String: LicenseJSON]

    public init(
        key: String? = nil,
        activationId: String? = nil,
        lease: String? = nil,
        trialStart: Int? = nil,
        trialEndsAt: Int? = nil,
        trialLease: String? = nil,
        trialAt: Int? = nil,
        lastSeen: Int? = nil,
        checkedMajor: Int? = nil,
        keptMajor: Int? = nil,
        backoffSince: Int? = nil,
        backoffMs: Int? = nil,
        refused: Refusal? = nil,
        refusedMajor: Int? = nil,
        refusedFor: [String]? = nil,
        deviceKind: DeviceKind? = nil,
        verdictAt: Int? = nil,
        rev: Int? = nil,
        otherFields: [String: LicenseJSON] = [:]
    ) {
        self.key = key
        self.activationId = activationId
        self.lease = lease
        self.trialStart = trialStart
        self.trialEndsAt = trialEndsAt
        self.trialLease = trialLease
        self.trialAt = trialAt
        self.lastSeen = lastSeen
        self.checkedMajor = checkedMajor
        self.keptMajor = keptMajor
        self.backoffSince = backoffSince
        self.backoffMs = backoffMs
        self.refused = refused
        self.refusedMajor = refusedMajor
        self.refusedFor = refusedFor
        self.deviceKind = deviceKind
        self.verdictAt = verdictAt
        self.rev = rev
        self.otherFields = otherFields
    }
}

extension StoredState {
    /// The state a JSON value holds. A field of the wrong type is left out (a number with a
    /// fraction is cut to a whole one), a field this SDK does not know is kept in `otherFields`,
    /// and a value that is no object holds no state at all.
    public init(json: LicenseJSON) {
        self.init()
        guard case .object(let members) = json else { return }
        for (name, value) in members {
            if let field = StateField(rawValue: name) {
                self[field] = field.value(from: value)
            } else {
                otherFields[name] = value
            }
        }
    }

    /// The state as a JSON object, under the field names every KeyGrant SDK uses.
    public var json: LicenseJSON {
        var members = otherFields.filter { StateField(rawValue: $0.key) == nil }
        for field in StateField.allCases {
            if let value = self[field] { members[field.rawValue] = value.json }
        }
        return .object(members)
    }
}

extension StoredState: Codable {
    public init(from decoder: Decoder) throws {
        self.init(json: try LicenseJSON(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        try json.encode(to: encoder)
    }
}

/// A field of the stored state, by the name every SDK writes it under.
enum StateField: String, CaseIterable, Sendable {
    case key, activationId, lease, trialStart, trialEndsAt, trialLease, trialAt, lastSeen, checkedMajor
    case keptMajor, backoffSince, backoffMs, refused, refusedMajor, refusedFor, deviceKind, verdictAt, rev

    /// What a JSON value says of this field: nil when it is not of the field's type.
    func value(from json: LicenseJSON) -> StateValue? {
        switch self {
        case .key, .activationId, .lease, .trialLease:
            return json.stringValue.map(StateValue.string)
        case .refused:
            return json.stringValue.flatMap(Refusal.init(rawValue:)).map { .string($0.rawValue) }
        case .deviceKind:
            return json.stringValue.flatMap(DeviceKind.init(rawValue:)).map { .string($0.rawValue) }
        case .refusedFor:
            // Claim hashes: anything else in the list is not one.
            return json.arrayValue.map { .strings($0.compactMap(\.stringValue)) }
        case .trialStart, .trialEndsAt, .trialAt, .lastSeen, .checkedMajor, .keptMajor, .backoffSince,
            .backoffMs, .refusedMajor, .verdictAt, .rev:
            return json.intValue.map(StateValue.int)
        }
    }
}

/// The value of one stored field.
enum StateValue: Sendable, Hashable {
    case string(String)
    case int(Int)
    case strings([String])

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var int: Int? {
        if case .int(let value) = self { return value }
        return nil
    }

    var strings: [String]? {
        if case .strings(let value) = self { return value }
        return nil
    }

    var json: LicenseJSON {
        switch self {
        case .string(let value): .string(value)
        case .int(let value): .number(Double(value))
        case .strings(let value): .array(value.map(LicenseJSON.string))
        }
    }
}

extension StoredState {
    /// One field, by name: what the reference's object spread and `delete` work on.
    subscript(field: StateField) -> StateValue? {
        get {
            switch field {
            case .key: key.map(StateValue.string)
            case .activationId: activationId.map(StateValue.string)
            case .lease: lease.map(StateValue.string)
            case .trialStart: trialStart.map(StateValue.int)
            case .trialEndsAt: trialEndsAt.map(StateValue.int)
            case .trialLease: trialLease.map(StateValue.string)
            case .trialAt: trialAt.map(StateValue.int)
            case .lastSeen: lastSeen.map(StateValue.int)
            case .checkedMajor: checkedMajor.map(StateValue.int)
            case .keptMajor: keptMajor.map(StateValue.int)
            case .backoffSince: backoffSince.map(StateValue.int)
            case .backoffMs: backoffMs.map(StateValue.int)
            case .refused: refused.map { .string($0.rawValue) }
            case .refusedMajor: refusedMajor.map(StateValue.int)
            case .refusedFor: refusedFor.map(StateValue.strings)
            case .deviceKind: deviceKind.map { .string($0.rawValue) }
            case .verdictAt: verdictAt.map(StateValue.int)
            case .rev: rev.map(StateValue.int)
            }
        }
        set {
            switch field {
            case .key: key = newValue?.string
            case .activationId: activationId = newValue?.string
            case .lease: lease = newValue?.string
            case .trialStart: trialStart = newValue?.int
            case .trialEndsAt: trialEndsAt = newValue?.int
            case .trialLease: trialLease = newValue?.string
            case .trialAt: trialAt = newValue?.int
            case .lastSeen: lastSeen = newValue?.int
            case .checkedMajor: checkedMajor = newValue?.int
            case .keptMajor: keptMajor = newValue?.int
            case .backoffSince: backoffSince = newValue?.int
            case .backoffMs: backoffMs = newValue?.int
            case .refused: refused = newValue?.string.flatMap(Refusal.init(rawValue:))
            case .refusedMajor: refusedMajor = newValue?.int
            case .refusedFor: refusedFor = newValue?.strings
            case .deviceKind: deviceKind = newValue?.string.flatMap(DeviceKind.init(rawValue:))
            case .verdictAt: verdictAt = newValue?.int
            case .rev: rev = newValue?.int
            }
        }
    }
}

/// A change to stored fields: each field it names is set, or cleared; a field it does not name is
/// left as stored. The reference's `Partial<StoredState>`, where a field present as `undefined`
/// clears it when spread.
struct StatePatch: Sendable, Hashable, ExpressibleByDictionaryLiteral {
    enum Change: Sendable, Hashable {
        case set(StateValue)
        case clear

        static func string(_ value: String) -> Change { .set(.string(value)) }
        static func int(_ value: Int) -> Change { .set(.int(value)) }
        static func strings(_ value: [String]) -> Change { .set(.strings(value)) }
        static func refusal(_ value: Refusal) -> Change { .set(.string(value.rawValue)) }
        static func deviceKind(_ value: DeviceKind) -> Change { .set(.string(value.rawValue)) }

        /// The value, or a clear when there is none: a field the reference patches with a value
        /// that may be `undefined`.
        static func int(orClear value: Int?) -> Change { value.map { .set(.int($0)) } ?? .clear }
        static func string(orClear value: String?) -> Change { value.map { .set(.string($0)) } ?? .clear }
        static func deviceKind(orClear value: DeviceKind?) -> Change {
            value.map { .set(.string($0.rawValue)) } ?? .clear
        }
    }

    private(set) var changes: [StateField: Change]

    init() {
        changes = [:]
    }

    init(dictionaryLiteral elements: (StateField, Change)...) {
        changes = Dictionary(elements, uniquingKeysWith: { _, last in last })
    }

    subscript(field: StateField) -> Change? {
        get { changes[field] }
        set { changes[field] = newValue }
    }

    /// What the patch sets `field` to, when it sets it to a whole number.
    func int(_ field: StateField) -> Int? {
        if case .set(.int(let value))? = changes[field] { return value }
        return nil
    }

    /// The patch without `fields`.
    func omitting(_ fields: Set<StateField>) -> StatePatch {
        var patch = self
        for field in fields { patch.changes[field] = nil }
        return patch
    }

    /// Only the changes to `fields`.
    func keepingOnly(_ fields: Set<StateField>) -> StatePatch {
        var patch = StatePatch()
        for (field, change) in changes where fields.contains(field) { patch.changes[field] = change }
        return patch
    }

    /// `lhs` with `rhs` over it (`{ ...lhs, ...rhs }`).
    static func + (lhs: StatePatch, rhs: StatePatch) -> StatePatch {
        var patch = lhs
        for (field, change) in rhs.changes { patch.changes[field] = change }
        return patch
    }

    /// `state` with this patch over it (`{ ...state, ...patch }`).
    func applied(to state: StoredState) -> StoredState {
        var next = state
        for (field, change) in changes {
            switch change {
            case .set(let value): next[field] = value
            case .clear: next[field] = nil
            }
        }
        return next
    }
}
