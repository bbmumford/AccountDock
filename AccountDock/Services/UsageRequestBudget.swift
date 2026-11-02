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
        /// Periodic refresh of an idle account.
        case background = 2

        static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.rawValue < rhs.rawValue }

        /// Tokens that must remain after spending, so lower priorities can
        /// never consume the allowance reserved for higher ones.
        var reserve: Double {
            switch self {
            case .critical: 0
            case .candidate: 0.5
            case .background: 1.5
            }
        }
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

    /// Applies provider throttling to every account of the provider. A
    /// Retry-After header is honoured; without one the cool-down doubles from
    /// one minute up to fifteen so repeated 429s stop compounding.
    func recordThrottle(retryAfter: Date?, now: Date = Date()) {
        consecutiveThrottles += 1
        let backoff = min(15 * 60, 60 * pow(2, Double(consecutiveThrottles - 1)))
        let until = max(retryAfter ?? .distantPast, now.addingTimeInterval(backoff))
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
