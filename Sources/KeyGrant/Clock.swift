import Foundation

/// The clock guard (anti clock-rollback), decided without I/O (the reference's `clock.ts`): the
/// time a lease is judged at, never earlier than the latest the device has seen (`guardedNow`);
/// where a lease the server has just signed brings the guard back to after a clock that jumped
/// ahead (`clockCorrection`, `serverNow`); and the latest time seen that a save writes
/// (`savedLastSeen`, `save`).

/// Now, by the clock guard: never earlier than the latest time the device has seen (`lastSeen`),
/// so a clock put back cannot bring an expired lease back.
func guardedNow(_ clockNow: Int, _ lastSeen: Int?) -> Int {
    max(clockNow, lastSeen ?? 0)
}

/// A fresh lease's claims as the clock guard reads them (`clockCorrection`).
struct SignedAt: Sendable, Hashable {
    var sub: String
    var aid: String
    /// Seconds.
    var iat: Double
}

/// Where the clock guard should be brought back to on a lease the server has just signed, or nil
/// to leave it. When the guard is MORE than `clockToleranceMs` past the lease's signing time, it
/// comes back to the device clock, never below the signing time. Only a lease signed for THIS key
/// (without regard to case) and activation, and no older than the lease the device holds
/// (`heldIat`), moves it; `claims` is nil when the fresh lease did not verify, which moves nothing.
func clockCorrection(
    clockNow: Int, lastSeen: Int?, claims: SignedAt?, heldIat: Double?, key: String, activationId: String
) -> Int? {
    guard let claims, sameKey(claims.sub, key), sameText(claims.aid, activationId) else { return nil }
    if Double(lastSeen ?? 0) - claims.iat * 1000 <= Double(Waits.clockToleranceMs) { return nil }
    if let heldIat, claims.iat < heldIat { return nil }
    return wholeNumber(max(Double(clockNow), claims.iat * 1000))
}

/// The latest time seen (`lastSeen`) that a save writes, onto the state as stored when it saves
/// (`stored`): the guard brought back on the server's evidence (`guard`, a `clockCorrection`)
/// exactly as given when the save carries one, a guard of 0 included; otherwise never earlier
/// than what is stored, nor than the device clock now, so the guard only ever moves forward on
/// its own.
func savedLastSeen(stored: Int?, clockNow: Int, guard correction: Int?) -> Int {
    correction ?? max(stored ?? 0, clockNow)
}
