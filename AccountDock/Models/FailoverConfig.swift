import Foundation
import Combine

struct ProviderFailoverPolicy: Codable, Equatable {
    var enabled = false
    var sessionEnabled = true
    var sessionThreshold = 90.0
    var weeklyEnabled = true
    var weeklyThreshold = 90.0
    var loops = true
    var resetAware = true
    var preferMostCapacity = true
    var waitForImminentReset = true
    var resetGraceMinutes = 5.0
    var accountOrder: [UUID] = []
    var excludedAccountIDs: Set<UUID> = []

    enum CodingKeys: String, CodingKey {
        case enabled, sessionEnabled, sessionThreshold, weeklyEnabled, weeklyThreshold
        case loops, resetAware, preferMostCapacity, waitForImminentReset
        case resetGraceMinutes, accountOrder, excludedAccountIDs
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        sessionEnabled = try values.decodeIfPresent(Bool.self, forKey: .sessionEnabled) ?? true
        sessionThreshold = try values.decodeIfPresent(Double.self, forKey: .sessionThreshold) ?? 90
        weeklyEnabled = try values.decodeIfPresent(Bool.self, forKey: .weeklyEnabled) ?? true
        weeklyThreshold = try values.decodeIfPresent(Double.self, forKey: .weeklyThreshold) ?? 90
        loops = try values.decodeIfPresent(Bool.self, forKey: .loops) ?? true
        resetAware = try values.decodeIfPresent(Bool.self, forKey: .resetAware) ?? true
        preferMostCapacity = try values.decodeIfPresent(Bool.self, forKey: .preferMostCapacity) ?? true
        waitForImminentReset = try values.decodeIfPresent(Bool.self, forKey: .waitForImminentReset) ?? true
        resetGraceMinutes = try values.decodeIfPresent(Double.self, forKey: .resetGraceMinutes) ?? 5
        accountOrder = try values.decodeIfPresent([UUID].self, forKey: .accountOrder) ?? []
        excludedAccountIDs = try values.decodeIfPresent(Set<UUID>.self, forKey: .excludedAccountIDs) ?? []
    }

    static func defaults(for provider: AIProviderType) -> Self {
        var policy = Self()
        if provider == .codex {
            policy.sessionEnabled = false
        }
        return policy
    }
}

@MainActor
final class FailoverConfigStore: ObservableObject {
    static let shared = FailoverConfigStore()

    @Published private(set) var claude = ProviderFailoverPolicy.defaults(for: .claudeCode)
    @Published private(set) var codex = ProviderFailoverPolicy.defaults(for: .codex)

    private let defaults = UserDefaults.standard
    private let key = "app.accountdock.failover.policies.v1"

    private struct StoredPolicies: Codable {
        var claude: ProviderFailoverPolicy
        var codex: ProviderFailoverPolicy
    }

    private init() {
        guard let data = defaults.data(forKey: key),
              let stored = try? JSONDecoder().decode(StoredPolicies.self, from: data) else { return }
        claude = stored.claude
        codex = stored.codex
    }

    func policy(for provider: AIProviderType) -> ProviderFailoverPolicy {
        provider == .codex ? codex : claude
    }

    func update(_ provider: AIProviderType, _ change: (inout ProviderFailoverPolicy) -> Void) {
        if provider == .codex {
            change(&codex)
            codex.sessionEnabled = false
        } else {
            change(&claude)
        }
        save()
    }

    func synchronizeOrder(provider: AIProviderType, accountIDs: [UUID]) {
        update(provider) { policy in
            policy.accountOrder.removeAll { !accountIDs.contains($0) }
            policy.excludedAccountIDs = policy.excludedAccountIDs.filter { accountIDs.contains($0) }
            for id in accountIDs where !policy.accountOrder.contains(id) {
                policy.accountOrder.append(id)
            }
        }
    }

    private func save() {
        let stored = StoredPolicies(claude: claude, codex: codex)
        if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: key)
        }
    }
}

enum FailoverDecision {
    /// Adaptive active-account polling. Approaching a threshold increases
    /// awareness, while an exhausted account with nowhere to fail over is
    /// checked only when its reset or provider retry window becomes relevant.
    static func pollInterval(
        usage: UsageAPIResponse?,
        provider: AIProviderType,
        policy: ProviderFailoverPolicy,
        noFailoverAvailable: Bool,
        blockingReset: Date?,
        retryAfter: Date?,
        now: Date = Date()
    ) -> TimeInterval {
        if let retryAfter, retryAfter > now {
            return max(60, retryAfter.timeIntervalSince(now) + 5)
        }

        if noFailoverAvailable && exceedsThreshold(
            usage: usage,
            provider: provider,
            policy: policy
        ) {
            guard let reset = blockingReset, reset > now else { return 15 * 60 }
            let remaining = reset.timeIntervalSince(now)
            if remaining > 60 * 60 { return min(15 * 60, max(5 * 60, remaining - 10 * 60)) }
            if remaining > 15 * 60 { return 5 * 60 }
            if remaining > 5 * 60 { return 2 * 60 }
            return 30
        }

        guard let usage else { return 5 * 60 }
        var margins: [Double] = []
        if provider == .claudeCode, policy.sessionEnabled,
           let value = usage.fiveHour?.utilization {
            margins.append(policy.sessionThreshold - value)
        }
        if policy.weeklyEnabled, let value = usage.sevenDay?.utilization {
            margins.append(policy.weeklyThreshold - value)
        }
        guard let closest = margins.min() else { return 5 * 60 }
        if closest <= 5 { return 15 }
        if closest <= 10 { return 30 }
        if closest <= 20 { return 60 }
        if closest <= 40 { return 2 * 60 }
        return 5 * 60
    }

    static func blockingResetDate(
        usage: UsageAPIResponse?,
        provider: AIProviderType,
        policy: ProviderFailoverPolicy
    ) -> Date? {
        guard let usage else { return nil }
        var blockingDates: [Date] = []
        if provider == .claudeCode, policy.sessionEnabled,
           let value = usage.fiveHour?.utilization,
           value >= policy.sessionThreshold,
           let date = usage.fiveHour?.resetsAtDate {
            blockingDates.append(date)
        }
        if policy.weeklyEnabled,
           let value = usage.sevenDay?.utilization,
           value >= policy.weeklyThreshold,
           let date = usage.sevenDay?.resetsAtDate {
            blockingDates.append(date)
        }
        // Capacity returns only when every breached constraint has reset.
        return blockingDates.max()
    }

    static func exceedsThreshold(
        usage: UsageAPIResponse?,
        provider: AIProviderType,
        policy: ProviderFailoverPolicy
    ) -> Bool {
        guard let usage else { return false }
        let sessionExceeded = provider == .claudeCode
            && policy.sessionEnabled
            && usage.fiveHour?.utilization.map { $0 >= policy.sessionThreshold } == true
        let weeklyExceeded = policy.weeklyEnabled
            && usage.sevenDay?.utilization.map { $0 >= policy.weeklyThreshold } == true
        return sessionExceeded || weeklyExceeded
    }

    static func hasCapacity(
        usage: UsageAPIResponse?,
        provider: AIProviderType,
        policy: ProviderFailoverPolicy
    ) -> Bool {
        guard let usage else { return false }
        if provider == .claudeCode && policy.sessionEnabled {
            guard let value = usage.fiveHour?.utilization, value < policy.sessionThreshold else {
                return false
            }
        }
        if policy.weeklyEnabled {
            guard let value = usage.sevenDay?.utilization, value < policy.weeklyThreshold else {
                return false
            }
        }
        return true
    }

    static func capacityScore(
        usage: UsageAPIResponse?,
        provider: AIProviderType,
        policy: ProviderFailoverPolicy
    ) -> Double {
        guard let usage else { return -.infinity }
        var margins: [Double] = []
        if provider == .claudeCode && policy.sessionEnabled,
           let value = usage.fiveHour?.utilization {
            margins.append(policy.sessionThreshold - value)
        }
        if policy.weeklyEnabled, let value = usage.sevenDay?.utilization {
            margins.append(policy.weeklyThreshold - value)
        }
        return margins.min() ?? -.infinity
    }

    static func shouldWaitForImminentReset(
        usage: UsageAPIResponse?,
        provider: AIProviderType,
        policy: ProviderFailoverPolicy,
        now: Date = Date()
    ) -> Bool {
        guard policy.waitForImminentReset, let usage else { return false }
        var breached: [UsageWindow] = []
        if provider == .claudeCode, policy.sessionEnabled,
           let window = usage.fiveHour,
           let value = window.utilization,
           value >= policy.sessionThreshold {
            if value >= 100 { return false }
            breached.append(window)
        }
        if policy.weeklyEnabled,
           let window = usage.sevenDay,
           let value = window.utilization,
           value >= policy.weeklyThreshold {
            if value >= 100 { return false }
            breached.append(window)
        }
        guard !breached.isEmpty else { return false }
        let grace = policy.resetGraceMinutes * 60
        return breached.allSatisfy { window in
            guard let reset = window.resetsAtDate else { return false }
            let remaining = reset.timeIntervalSince(now)
            return remaining > 0 && remaining <= grace
        }
    }

    static func candidates(
        orderedIDs: [UUID],
        currentID: UUID,
        loops: Bool
    ) -> [UUID] {
        guard let currentIndex = orderedIDs.firstIndex(of: currentID) else {
            return orderedIDs.filter { $0 != currentID }
        }
        let after = Array(orderedIDs.dropFirst(currentIndex + 1))
        guard loops else { return after }
        return after + Array(orderedIDs.prefix(currentIndex))
    }

    /// Filters destinations by quota only. Authentication probe errors are not
    /// accepted here because a Claude switch verifies and refreshes the target
    /// credential transactionally; callers may therefore use last-good quota.
    static func eligibleCandidates(
        _ candidateIDs: [UUID],
        usageByID: [UUID: UsageAPIResponse],
        provider: AIProviderType,
        policy: ProviderFailoverPolicy
    ) -> [UUID] {
        candidateIDs.filter {
            hasCapacity(usage: usageByID[$0], provider: provider, policy: policy)
        }
    }
}
