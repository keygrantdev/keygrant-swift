import Foundation

/// One meter of a key as `LicenseStatus.meters` shows it. Every figure is a whole number; the server
/// signs none past 1,000,000,000 (`maxMeterUses`).
public struct MeterStatus: Sendable, Hashable {
    /// What is left: the newest figure (the lease's, or the last answer to a spend), less what this
    /// device spent and has not reported. Never below 0.
    public var left: Int
    /// The uses the key holds, for good or for this billing period.
    public var total: Int
    /// How many uses this device may spend while KeyGrant cannot be reached.
    public var offline: Int
    /// Uses this device spent that KeyGrant has not heard of yet.
    public var unsynced: Int
    /// True for a meter that comes back to its full uses each billing period.
    public var resets: Bool

    public init(left: Int, total: Int, offline: Int, unsynced: Int, resets: Bool) {
        self.left = left
        self.total = total
        self.offline = offline
        self.unsynced = unsynced
        self.resets = resets
    }
}

/// Why `License.use(_:_:)` did not spend. A refusal is an answer, never a throw. The raw values are
/// the words every KeyGrant SDK uses.
public enum UseError: String, Error, Sendable, Hashable, CaseIterable {
    /// `n` is not a whole number from 1 to 1,000,000,000 (`maxMeterUses`): a bug in the app. Nothing
    /// was asked.
    case invalidAmount = "invalid-amount"
    /// The key has no meter of that code: the server's word; or, with no answer, no figure on this
    /// device names it; or a code no meter can have (empty, or longer than 32 UTF-16 units).
    case noMeter = "no-meter"
    /// Online: fewer left than asked. `UseResult.left` says how many, when the server did.
    case usedUp = "used-up"
    /// KeyGrant could not be reached, and the spend is past this device's offline allowance for the
    /// meter, or past what it knows is left (every spend, for an allowance of 0).
    /// `UseResult.left` says how many are left.
    case offlineLimit = "offline-limit"
    /// No key's lease licenses this build on this device (a device trial and an offline licence file
    /// have no meters). Nothing was asked: read `status()`.
    case notLicensed = "not-licensed"
    /// The state could not be read just now: try again shortly.
    case storage
    /// The server's verdict on the key (stored as a renewal's is): `LicenseReason.revoked`.
    case revoked
    /// The server's verdict on this build: the key does not cover it (`LicenseReason.upgrade`).
    case upgrade
    /// The server's verdict on this build: the key's lowest version is newer (`LicenseReason.outdated`).
    case outdated
    /// The server's verdict on this device: the seat is another device's (`LicenseReason.device`).
    case device
}

/// What `License.use(_:_:)` did: spent, or why not. Never a throw, whatever the outcome.
public struct UseResult: Sendable, Hashable {
    /// Whether the uses were spent: do the work they count.
    public var ok: Bool
    /// What is left of the meter now, net of this device's unsynced spends. Given when `ok`, and on a
    /// refusal for `.usedUp` (the server's word, when it gave one) and `.offlineLimit`; nil otherwise.
    public var left: Int?
    /// True when KeyGrant could not be asked and the spend came from this device's offline allowance
    /// (it is reported with the next request that can carry it).
    public var offline: Bool
    /// Why not, when `ok` is false.
    public var error: UseError?

    public init(ok: Bool, left: Int? = nil, offline: Bool = false, error: UseError? = nil) {
        self.ok = ok
        self.left = left
        self.offline = offline
        self.error = error
    }

    /// The uses were spent, `left` are left; `offline` when they came from the allowance.
    static func spent(left: Int, offline: Bool = false) -> UseResult {
        UseResult(ok: true, left: left, offline: offline)
    }

    /// The uses were not spent, for `error`; `left` where the error gives one.
    static func refused(_ error: UseError, left: Int? = nil) -> UseResult {
        UseResult(ok: false, left: left, error: error)
    }
}

/// Which kind of entry a `SpendEntry` is in the journal of unsynced spends.
public enum SpendKind: String, Sendable, Hashable, CaseIterable {
    /// Spends made with no request sent: one entry for each meter, its count growing with each later
    /// such spend.
    case offline
    /// One spend whose own request got no answer, made from the allowance. Its count never changes:
    /// the server may hold it.
    case unanswered
    /// One spend whose own request got no answer and that was refused offline, reported so that the
    /// server takes it back if it recorded it.
    case void
}

/// A spend this device made that KeyGrant has not confirmed (the journal, `StoredState.spends`):
/// kept in the stored state, reported with the next request, and dropped when the server says it
/// recorded it (or, unreported, after 180 days).
public struct SpendEntry: Sendable, Hashable {
    /// The spend's id: 16 random bytes in base64url (22 characters), never reused.
    public var id: String
    /// The meter's code.
    public var meter: String
    /// How many uses.
    public var n: Int
    /// When (the guarded device clock, ms since 1970) the entry was opened.
    public var at: Int
    /// Which kind of entry it is.
    public var kind: SpendKind

    public init(id: String, meter: String, n: Int, at: Int, kind: SpendKind) {
        self.id = id
        self.meter = meter
        self.n = n
        self.at = at
        self.kind = kind
    }
}

/// A meter's figures as the newest `use` answer gave them (`StoredState.meterFigures`): newer than
/// the stored lease's own until the lease is renewed.
public struct MeterFigure: Sendable, Hashable {
    /// What the key had left when the server answered, every device's reported spends counted.
    public var left: Int
    /// The uses the key holds.
    public var total: Int
    /// The allowance each of its devices may spend with no answer.
    public var offline: Int
    /// Whether the meter comes back each billing period.
    public var resets: Bool
    /// The server's time (ms since 1970).
    public var at: Int

    public init(left: Int, total: Int, offline: Int, resets: Bool, at: Int) {
        self.left = left
        self.total = total
        self.offline = offline
        self.resets = resets
        self.at = at
    }
}

/// A meter's figures as a lease signs them or an answer gives them, without the time of the answer:
/// the base of what a status shows.
struct BaseFigure: Sendable, Hashable {
    var left: Int
    var total: Int
    var offline: Int
    var resets: Bool

    init(left: Int, total: Int, offline: Int, resets: Bool) {
        self.left = left
        self.total = total
        self.offline = offline
        self.resets = resets
    }

    init(_ figure: MeterFigure) {
        self.init(left: figure.left, total: figure.total, offline: figure.offline, resets: figure.resets)
    }
}
