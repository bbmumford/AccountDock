import Foundation

/// Plays forecast demand forward over a provider's accounts in fixed steps,
/// following each account's 5-hour and long windows, to compare strategies
/// by how much work they serve and how much allowance they leave to expire.
///
/// Model, per step of `step` seconds:
/// - demand is long-window percent of work, from `DemandForecast`;
/// - an account serves at most what its session window and long window
///   still hold, where one long-window percent costs `sessionPerWeekly`
///   session percent;
/// - a session window starts at the first work after it was free and resets
///   five hours later; a long window resets at its reset time and repeats
///   with its period;
/// - accounts are tried in the strategy's order, and work an account cannot
///   take moves to the next, as the router and failover would move it.
struct QuotaSimulator {
    struct Account: Equatable {
        let id: UUID
        var session: Double
        var sessionReset: Date?
        var weekly: Double
        var weeklyReset: Date?
        var weeklyPeriod: TimeInterval = 7 * 24 * 60 * 60
        var sessionPerWeekly: Double
        var usable = true
        /// False for an account limited only by its long window.
        var hasSessionWindow = true
    }

    enum Strategy: Equatable {
        /// The listed accounts first, in order, then the rest by deadline.
        case preferring([UUID])
        /// Always the account whose allowance must start being used soonest.
        case earliestDeadline
        /// Demand split across every account with room, as when sessions
        /// are distributed.
        case parallel
    }

    struct Outcome: Equatable {
        /// Long-window percent of demand served and not served.
        var served = 0.0
        var unmet = 0.0
        /// Long-window percent left unused when windows reset.
        var expired = 0.0
        /// When demand first went unmet.
        var firstShortfall: Date?
    }

    var step: TimeInterval = 15 * 60
    var horizon: TimeInterval = 7 * 24 * 60 * 60
    static let sessionWindow: TimeInterval = 5 * 60 * 60

    func run(
        accounts initial: [Account],
        strategy: Strategy,
        demand: (Date) -> Double,
        start: Date
    ) -> Outcome {
        var accounts = initial
        var outcome = Outcome()
        var time = start
        let end = start.addingTimeInterval(horizon)
        while time < end {
            let next = time.addingTimeInterval(step)
            for index in accounts.indices { reset(&accounts[index], before: next, outcome: &outcome, countExpiry: true) }
            let wanted = max(0, demand(time)) * step / 3600
            var remaining = wanted
            let order = self.order(accounts, strategy: strategy, now: time)
            if strategy == .parallel {
                // Equal shares, with what one account cannot take passed on.
                var open = order
                while remaining > 1e-9, !open.isEmpty {
                    let share = remaining / Double(open.count)
                    var still: [Int] = []
                    for index in open {
                        let taken = serve(&accounts[index], amount: share, at: time)
                        remaining -= taken
                        if taken >= share - 1e-9 { still.append(index) }
                    }
                    if still.count == open.count { break }
                    open = still
                }
            } else {
                for index in order where remaining > 1e-9 {
                    remaining -= serve(&accounts[index], amount: remaining, at: time)
                }
            }
            outcome.served += wanted - max(0, remaining)
            if remaining > 1e-6 {
                outcome.unmet += remaining
                if outcome.firstShortfall == nil { outcome.firstShortfall = time }
            }
            time = next
        }
        // Allowance still unused at the horizon is not counted as expired:
        // it remains available after the simulated period.
        return outcome
    }

    private func reset(_ account: inout Account, before time: Date, outcome: inout Outcome, countExpiry: Bool) {
        if let reset = account.sessionReset, reset <= time {
            account.session = 0
            account.sessionReset = nil
        }
        while let reset = account.weeklyReset, reset <= time {
            if countExpiry, account.usable { outcome.expired += max(0, 100 - account.weekly) }
            account.weekly = 0
            account.weeklyReset = reset.addingTimeInterval(account.weeklyPeriod)
        }
    }

    /// Serves up to `amount` long-window percent; returns what it served.
    private func serve(_ account: inout Account, amount: Double, at time: Date) -> Double {
        guard account.usable, amount > 0 else { return 0 }
        let k = max(1, account.sessionPerWeekly)
        guard account.hasSessionWindow else {
            let taken = min(amount, max(0, 100 - account.weekly))
            account.weekly += taken
            return taken
        }
        let room = min(max(0, 100 - account.weekly), max(0, 100 - account.session) / k)
        let taken = min(amount, room)
        guard taken > 0 else { return 0 }
        if account.sessionReset == nil { account.sessionReset = time.addingTimeInterval(Self.sessionWindow) }
        account.weekly += taken
        account.session += taken * k
        return taken
    }

    private func latestStart(_ account: Account) -> Date {
        guard let reset = account.weeklyReset else { return .distantFuture }
        guard account.hasSessionWindow else { return reset }
        let rate = (100 / max(1, account.sessionPerWeekly)) / (Self.sessionWindow / 3600)
        return reset.addingTimeInterval(-(100 - account.weekly) / rate * 3600)
    }

    private func order(_ accounts: [Account], strategy: Strategy, now: Date) -> [Int] {
        let byDeadline = accounts.indices.sorted { latestStart(accounts[$0]) < latestStart(accounts[$1]) }
        switch strategy {
        case .earliestDeadline, .parallel:
            return byDeadline
        case .preferring(let ids):
            let preferred = ids.compactMap { id in accounts.firstIndex { $0.id == id } }
            return preferred + byDeadline.filter { !preferred.contains($0) }
        }
    }
}
