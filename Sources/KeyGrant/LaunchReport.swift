import Foundation

/// A running trial's launch, reported at most once a day in the background: a running trial reaches
/// the server only when it asks, and the server's trial funnel counts a trial seen a day after it
/// started. So an app need not call `startTrial()` on every launch for the server to see its trial
/// come back.
extension Waits {
    /// How often, at most, a running trial reports its launch (`trialReportDue`), a trial answer
    /// (`trialAt`) counting as one.
    static let trialReportMs = dayMs
}

/// Whether a running trial reports its launch at `now` (the guarded clock): neither its last trial
/// answer (`trialAt`, a `startTrial()` or a heal) nor its last report (`trialReportedAt`) is within
/// `Waits.trialReportMs` before `now`. A stamp that is absent, or at least that long before `now`,
/// is not within it; one ahead of `now` is.
func trialReportDue(_ state: StoredState, now: Int) -> Bool {
    func recent(_ at: Int?) -> Bool { at.map { difference(now, $0) < Waits.trialReportMs } ?? false }
    return !recent(state.trialAt) && !recent(state.trialReportedAt)
}

extension License {
    /// Reports a running trial's launch (`status()` answering `trial` from a valid trial lease,
    /// not read-only), with no key held, at most once a day (`trialReportDue`). The stamp
    /// (`trialReportedAt`) is saved first, and nothing is sent when it cannot be, so "once a day"
    /// holds; then `trial` is POSTed IN THE BACKGROUND, in a task of its own that nothing awaits,
    /// so a launch never waits on it and never fails for it offline (`sendLaunch`). Its answer is
    /// not read: a change to the trial reaches the device at `startTrial()`.
    func reportLaunch(_ state: StoredState, now: Int) async {
        guard nonEmpty(state.key) == nil, trialReportDue(state, now: now) else { return }
        guard await saveBestEffort([.trialReportedAt: .int(now)]) else { return }
        let report = Task { await self.sendLaunch(state) }
        launchReport.withValue { $0 = report }
    }

    /// The report itself: the device read for a status's time, then `trial` with the body
    /// `startTrial()` sends (the stored start as `clientStart`, no stash read), bounded as a status
    /// check is. A device that cannot be told sends nothing; every failure is ignored.
    private func sendLaunch(_ state: StoredState) async {
        let device = await self.device(timing.machineId, installKind: state.deviceKind)
        guard let own = device.own else { return }
        var body: [String: LicenseJSON] = ["fingerprint": .string(own)]
        if let kind = device.kind { body["fingerprintKind"] = .string(kind.rawValue) }
        if let start = state.trialStart { body["clientStart"] = .number(Double(start)) }
        _ = try? await post("trial", .object(body), timeout: timing.statusCheck)
    }

    /// Returns once the launch report in flight, if any, has settled. Test support: the SDK itself
    /// never waits for a report, and this is not public API.
    func launchReportSettled() async {
        await launchReport.current?.value
    }
}
