import Foundation

/// When a spend asks the server, and when the journal makes a status ask.

/// Whether the journal's wait is running at `now` (the guarded clock): with k `.unanswered` and `.void`
/// entries (k at least 1), until `min(askAgainMs, retryUnansweredMs x 2^(k-1))` after the newest of
/// them was opened: a minute after one, two after two, four, eight, and an hour from the seventh on.
/// A device out of reach asks less and less often, so a person is not kept waiting on a timeout at
/// every use. An entry from after `now` (a clock that jumped ahead and was corrected) is no wait that
/// can be measured, as a device clock set back ends the first wait: it is left out, of the count and
/// of the newest, and the others wait as they would alone, so a corrected clock never stops the asking
/// for days.
func journalWaiting(_ spends: [SpendEntry], now: Int) -> Bool {
    let opened = spends.filter { $0.kind != .offline && $0.at <= now }
    guard let newest = opened.map(\.at).max() else { return false }
    // The cap first: 2^(k-1) of a long journal overflows nothing, and from the seventh entry on it
    // is the hour.
    let wait = opened.count >= 7 ? Waits.askAgainMs : min(Waits.askAgainMs, Waits.retryUnansweredMs << (opened.count - 1))
    return now < saturatingSum(newest, wait)
}

/// Whether the wait of an uncovered spend runs at `now` (the guarded clock): a `.void`, the take-back
/// of an uncovered spend that was asked and got no answer, opened less than a minute ago. An outage
/// then costs such a spend one ask a minute, and the journal one void a minute at most. A void opened
/// after `now`, or after the device clock (`clockNow`), is no wait that can be measured, as a device
/// clock set back ends the first wait, and is left out: a clock that is behind the guard, which then
/// stands still, never refuses an online-only meter to a customer who is online.
func voidWaiting(_ spends: [SpendEntry], now: Int, clockNow: Int) -> Bool {
    spends.contains { entry in
        entry.kind == .void && entry.at <= now && entry.at <= clockNow
            && now < saturatingSum(entry.at, Waits.retryUnansweredMs)
    }
}

/// Whether `use` asks the server. A spend the offline allowance would refuse (`covered` false) asks
/// whatever the waits of an outage (an online customer is not refused for an outage that has passed),
/// but for a wait of its own: not while a void opened less than a minute ago stands (`voidWaiting`, by
/// both clocks). A spend the allowance covers asks every time, except while a no-answer wait runs
/// (`backoffSince` set, `backoffMs` equal to a minute, and the device clock at or after it and before
/// its end: a clock set back asks at once) and while the journal's wait runs (`journalWaiting`). An
/// answer of any kind ends both waits.
///
/// `clockNow` is the device clock, which the first wait is judged by; `now` the guarded clock, which the
/// journal's is.
func useAsksNow(_ state: StoredState, clockNow: Int, now: Int, covered: Bool) -> Bool {
    let spends = state.spends ?? []
    if !covered { return !voidWaiting(spends, now: now, clockNow: clockNow) }
    var waiting = false
    if let since = state.backoffSince, state.backoffMs == Waits.retryUnansweredMs {
        waiting = clockNow >= since && clockNow < saturatingSum(since, Waits.retryUnansweredMs)
    }
    return !waiting && !journalWaiting(spends, now: now)
}

/// Whether the journal makes `status()` ask a valid lease's server now: it holds an entry and its wait
/// is not running.
func journalAsks(_ spends: [SpendEntry], now: Int) -> Bool {
    !spends.isEmpty && !journalWaiting(spends, now: now)
}
