import Foundation

/// Shared request allowance for one provider's usage endpoint.
///
/// Every account of a provider draws from the same bucket because providers
/// throttle the client as a whole: Anthropic answers a burst of per-account
/// polls from one Mac with 429s for all of them. Polls are ranked so that the
/// active account's failover-critical reading can always be taken, while
/// background refreshes of idle accounts only spend surplus allowance.
@MainActor
final class UsageRequestBudget {
    enum Priority: Int, Comparable {
        /// Active account reading needed for an imminent failover decision.
        case critical = 0
        /// Candidate verification immediately before switching to it.
        case candidate = 1
        /// The reading that confirms an account's passed reset, and the
        /// warm-up that starts its next window
        /// (`AppState.verifyPassedResets`, `performWindowWarmup`). Such an
        /// account takes no work until it is read, so its reading may
        /// spend the share background reads leave untouched.
        case verification = 2
        /// Periodic refresh of an idle account.
        case background = 3

        static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.rawValue < rhs.rawValue }

        /// Tokens that must remain after spending, so lower priorities can
        /// never consume the allowance reserved for higher ones. Background
        /// reads stop half a request above verification reads, which stop
        /// half a request above candidate reads.
        var reserve: Double {
            switch self {
            case .critical: 0
            case .candidate: 0.5
            case .verification: 1
            case .background: 1.5
            }
        }

        /// What a second request of one reading already admitted at this
        /// priority must leave (`spendFollowUp`): the reserve less the
        /// request the reading was admitted with, never below nothing.
        var followUpReserve: Double { max(0, reserve - 1) }
    }

    let capacity: Double
    let refillInterval: TimeInterval
    private(set) var tokens: Double
    private var lastRefill: Date
    private(set) var blockedUntil: Date?
    private var consecutiveThrottles = 0

    init(capacity: Double, refillInterval: TimeInterval, now: Date = Date()) {
        self.capacity = capacity
        self.refillInterval = refillInterval
        self.tokens = capacity
        self.lastRefill = now
    }

    func canSpend(_ priority: Priority, now: Date = Date()) -> Bool {
        refill(now: now)
        if let blockedUntil, blockedUntil > now { return false }
        return tokens - 1 >= priority.reserve - 0.0001
    }

    /// Reserves one request. Returns false when the caller must not send it.
    @discardableResult
    func spend(_ priority: Priority, now: Date = Date()) -> Bool {
        guard canSpend(priority, now: now) else { return false }
        tokens -= 1
        return true
    }

    /// Reserves the second request of a reading already admitted at
    /// `priority`, such as the check that a saved sign-in is the account's
    /// own (`AppState.savedCopyIsOwn`) before its usage is read. The
    /// reading's own admission left at least `priority.reserve`; a bucket
    /// of three cannot hold two requests above the background or
    /// verification reserve, so a second admission at the same reserve
    /// would drop those readings half made. It is held to
    /// `followUpReserve` instead, which dips into the allowance kept for
    /// higher priorities by that one request at most.
    @discardableResult
    func spendFollowUp(of priority: Priority, now: Date = Date()) -> Bool {
        refill(now: now)
        if let blockedUntil, blockedUntil > now { return false }
        guard tokens - 1 >= priority.followUpReserve - 0.0001 else { return false }
        tokens -= 1
        return true
    }

    /// Earliest time a request of `priority` could be sent.
    func nextAvailable(_ priority: Priority, now: Date = Date()) -> Date {
        refill(now: now)
        let blocked = blockedUntil.map { max($0, now) } ?? now
        let deficit = max(0, priority.reserve + 1 - tokens)
        return max(blocked, now.addingTimeInterval(deficit * refillInterval))
    }

    func recordSuccess() {
        consecutiveThrottles = 0
    }

    /// The longest any throttle holds back the provider's readings. The
    /// provider's Retry-After can run to an hour while a reading made
    /// minutes later is answered, and failover decides on these readings.
    static let longestCooldown: TimeInterval = 5 * 60

    /// Applies provider throttling to every account of the provider: the
    /// cool-down doubles from thirty seconds, or lasts as long as a
    /// Retry-After header asks, and never exceeds `longestCooldown`.
    func recordThrottle(retryAfter: Date?, now: Date = Date()) {
        consecutiveThrottles += 1
        let backoff = 30 * pow(2, Double(consecutiveThrottles - 1))
        let asked = max(retryAfter?.timeIntervalSince(now) ?? 0, backoff)
        let until = now.addingTimeInterval(min(Self.longestCooldown, asked))
        blockedUntil = max(blockedUntil ?? .distantPast, until)
        tokens = 0
        lastRefill = now
    }

    private func refill(now: Date) {
        let elapsed = now.timeIntervalSince(lastRefill)
        guard elapsed > 0 else { return }
        tokens = min(capacity, tokens + elapsed / refillInterval)
        lastRefill = now
        if let blockedUntil, blockedUntil <= now { self.blockedUntil = nil }
    }
}
