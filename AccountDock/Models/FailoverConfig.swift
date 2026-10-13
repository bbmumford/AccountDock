import Foundation
import Combine

enum CodexFailoverSwitchMode: String, Codable, CaseIterable, Identifiable {
    case safeRestart
    case forceRestart
    case withoutRestart

    var id: String { rawValue }

    var title: String {
        switch self {
        case .safeRestart: "Switch Safely"
        case .forceRestart: "Force Restart Sessions"
        case .withoutRestart: "Switch Without Restart"
        }
    }
}

struct ProviderFailoverPolicy: Codable, Equatable {
    var enabled = false
    var sessionEnabled = true
    var sessionThreshold = 90.0
    var weeklyEnabled = true
    var weeklyThreshold = 90.0
    var loops = true
    var resetAware = true
    var preferMostCapacity = false
    var waitForImminentReset = true
    var resetGraceMinutes = 5.0
    var keepWindowsWarm = true
    var intelligentBalancingEnabled = false
    var balancingMinimumAdvantage = 5.0
    var balancingMinimumDwellMinutes = 30.0
    var suspendAgentsWhenExhausted = false
    var codexSwitchMode = CodexFailoverSwitchMode.safeRestart
    var accountOrder: [UUID] = []
    var excludedAccountIDs: Set<UUID> = []

    enum CodingKeys: String, CodingKey {
        case enabled, sessionEnabled, sessionThreshold, weeklyEnabled, weeklyThreshold
        case loops, resetAware, preferMostCapacity, waitForImminentReset
        case resetGraceMinutes, keepWindowsWarm, intelligentBalancingEnabled
        case balancingMinimumAdvantage, balancingMinimumDwellMinutes
        case suspendAgentsWhenExhausted
        case codexSwitchMode, accountOrder, excludedAccountIDs
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
        preferMostCapacity = try values.decodeIfPresent(Bool.self, forKey: .preferMostCapacity) ?? false
        waitForImminentReset = try values.decodeIfPresent(Bool.self, forKey: .waitForImminentReset) ?? true
        resetGraceMinutes = try values.decodeIfPresent(Double.self, forKey: .resetGraceMinutes) ?? 5
        keepWindowsWarm = try values.decodeIfPresent(Bool.self, forKey: .keepWindowsWarm) ?? true
        intelligentBalancingEnabled = try values.decodeIfPresent(Bool.self, forKey: .intelligentBalancingEnabled) ?? false
        balancingMinimumAdvantage = try values.decodeIfPresent(Double.self, forKey: .balancingMinimumAdvantage) ?? 5
        balancingMinimumDwellMinutes = try values.decodeIfPresent(Double.self, forKey: .balancingMinimumDwellMinutes) ?? 30
        suspendAgentsWhenExhausted = try values.decodeIfPresent(Bool.self, forKey: .suspendAgentsWhenExhausted) ?? false
        codexSwitchMode = try values.decodeIfPresent(
            CodexFailoverSwitchMode.self,
            forKey: .codexSwitchMode
        ) ?? .safeRestart
        accountOrder = try values.decodeIfPresent([UUID].self, forKey: .accountOrder) ?? []
        excludedAccountIDs = try values.decodeIfPresent(Set<UUID>.self, forKey: .excludedAccountIDs) ?? []
    }

    static func defaults(for provider: AIProviderType) -> Self {
        var policy = Self()
        if !provider.capabilities.supportsSessionQuota {
            policy.sessionEnabled = false
        }
        if provider == .kimi {
            // Kimi's CLI does not yet expose a non-persistent probe contract.
            policy.keepWindowsWarm = false
        }
        return policy
    }
}

@MainActor
final class FailoverConfigStore: ObservableObject {
    static let shared = FailoverConfigStore()

    @Published private var policies: [AIProviderType: ProviderFailoverPolicy] = [:]

    private let defaults = UserDefaults.standard
    private let key = "app.accountdock.failover.policies.v1"
    private let strictLadderMigrationKey = "app.accountdock.failover.strict-ladder.v1"
    private let conditionalCodexSessionMigrationKey = "app.accountdock.failover.codex-session-window.v1"

    private struct StoredPolicies: Codable {
        var claude: ProviderFailoverPolicy
        var codex: ProviderFailoverPolicy
    }

    private struct ProviderPolicyStore: Codable {
        var policies: [AIProviderType: ProviderFailoverPolicy]
    }

    private init() {
        if let data = defaults.data(forKey: key) {
            if let stored = try? JSONDecoder().decode(ProviderPolicyStore.self, from: data) {
                policies = stored.policies
            } else if let legacy = try? JSONDecoder().decode(StoredPolicies.self, from: data) {
                policies[.claudeCode] = legacy.claude
                policies[.codex] = legacy.codex
            }
        }
        for provider in AIProviderType.implementedProviders where policies[provider] == nil {
            policies[provider] = .defaults(for: provider)
        }
        // Earlier builds silently defaulted to choosing the account with the
        // most headroom, which could jump over the user's ordered ladder. Move
        // existing installs once to predictable first-available ordering; the
        // user can still explicitly enable capacity preference afterwards.
        if !defaults.bool(forKey: strictLadderMigrationKey) {
            for provider in AIProviderType.implementedProviders {
                policies[provider]?.preferMostCapacity = false
            }
            defaults.set(true, forKey: strictLadderMigrationKey)
            save()
        }
        // Codex was previously treated as having no session window at all.
        // Lower plans now return a five-hour window, so enable its conditional
        // policy once while still allowing the user to disable it afterwards.
        if !defaults.bool(forKey: conditionalCodexSessionMigrationKey) {
            policies[.codex]?.sessionEnabled = true
            defaults.set(true, forKey: conditionalCodexSessionMigrationKey)
            save()
        }
    }

    func policy(for provider: AIProviderType) -> ProviderFailoverPolicy {
        policies[provider] ?? .defaults(for: provider)
    }

    func update(_ provider: AIProviderType, _ change: (inout ProviderFailoverPolicy) -> Void) {
        var policy = policies[provider] ?? .defaults(for: provider)
        change(&policy)
        if !provider.capabilities.supportsSessionQuota {
            policy.sessionEnabled = false
        }
        policies[provider] = policy
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
        let stored = ProviderPolicyStore(policies: policies)
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
        if provider.capabilities.supportsSessionQuota, policy.sessionEnabled,
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
        if provider.capabilities.supportsSessionQuota,
           let value = usage.fiveHour?.utilization,
           value >= 100 || (policy.sessionEnabled && value >= policy.sessionThreshold),
           let date = usage.fiveHour?.resetsAtDate {
            blockingDates.append(date)
        }
        if provider.capabilities.supportsWeeklyQuota,
           let value = usage.sevenDay?.utilization,
           value >= 100 || (policy.weeklyEnabled && value >= policy.weeklyThreshold),
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
        let sessionExceeded = provider.capabilities.supportsSessionQuota
            && usage.fiveHour?.utilization.map {
                $0 >= 100 || (policy.sessionEnabled && $0 >= policy.sessionThreshold)
            } == true
        let weeklyExceeded = provider.capabilities.supportsWeeklyQuota
            && usage.sevenDay?.utilization.map {
                $0 >= 100 || (policy.weeklyEnabled && $0 >= policy.weeklyThreshold)
            } == true
        return sessionExceeded || weeklyExceeded
    }

    static func hasCapacity(
        usage: UsageAPIResponse?,
        provider: AIProviderType,
        policy: ProviderFailoverPolicy
    ) -> Bool {
        guard let usage else { return false }
        // Destination safety is deliberately independent from trigger settings.
        // A disabled/90% trigger may permit continued use, but a provider-reported
        // exhausted window can never be selected as a destination.
        if provider.capabilities.supportsSessionQuota {
            if let value = usage.fiveHour?.utilization {
                guard value < 100 else { return false }
            } else if provider.capabilities.sessionQuotaMode == .required {
                return false
            }
        }
        if provider.capabilities.supportsWeeklyQuota {
            guard let value = usage.sevenDay?.utilization, value < 100 else {
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
        if provider.capabilities.supportsSessionQuota,
           let value = usage.fiveHour?.utilization {
            margins.append(100 - value)
        }
        if provider.capabilities.supportsWeeklyQuota, let value = usage.sevenDay?.utilization {
            margins.append(100 - value)
        }
        return margins.min() ?? -.infinity
    }

    /// Chooses the account whose long-window allowance is most at risk of being
    /// wasted before its reset. Equal reset dates reduce to ordinary least-used
    /// balancing; an earlier reset raises the utilization that account should
    /// carry, allowing it to consume more before capacity disappears.
    static func intelligentBalanceTarget(
        accountIDs: [UUID],
        currentID: UUID,
        usageByID: [UUID: UsageAPIResponse],
        provider: AIProviderType,
        policy: ProviderFailoverPolicy,
        unverifiedResetIDs: Set<UUID> = [],
        now: Date = Date()
    ) -> (id: UUID, advantage: Double)? {
        guard provider.capabilities.supportsWeeklyQuota,
              accountIDs.contains(currentID),
              let currentUsage = usageByID[currentID],
              hasCapacity(usage: currentUsage, provider: provider, policy: policy) else {
            return nil
        }
        let eligible = accountIDs.filter {
            !unverifiedResetIDs.contains($0)
                && hasCapacity(usage: usageByID[$0], provider: provider, policy: policy)
                && usageByID[$0]?.sevenDay?.utilization != nil
        }
        guard eligible.count > 1 else { return nil }

        let horizons = eligible.compactMap { id -> TimeInterval? in
            guard let reset = usageByID[id]?.sevenDay?.resetsAtDate else { return nil }
            return max(0, reset.timeIntervalSince(now))
        }
        let normalizationHorizon = max(horizons.max() ?? 0, 1)

        func score(_ id: UUID) -> Double {
            guard let window = usageByID[id]?.sevenDay,
                  let utilization = window.utilization else { return -.infinity }
            // Missing reset times get no urgency credit, but remain comparable
            // by utilization. A known imminent reset approaches the threshold.
            let horizon = window.resetsAtDate.map { max(0, $0.timeIntervalSince(now)) }
                ?? normalizationHorizon
            let urgency = max(0, min(1, 1 - horizon / normalizationHorizon))
            // Balancing consumes the complete allowance. The configured
            // threshold is a failover trigger, not a quota ceiling.
            let desiredUtilization = 100 * urgency
            return desiredUtilization - utilization
        }

        let currentScore = score(currentID)
        guard let best = eligible.max(by: { score($0) < score($1) }), best != currentID else {
            return nil
        }
        let advantage = score(best) - currentScore
        guard advantage >= policy.balancingMinimumAdvantage else { return nil }
        return (best, advantage)
    }

    static func shouldWaitForImminentReset(
        usage: UsageAPIResponse?,
        provider: AIProviderType,
        policy: ProviderFailoverPolicy,
        now: Date = Date()
    ) -> Bool {
        guard policy.waitForImminentReset, let usage else { return false }
        var breached: [UsageWindow] = []
        if provider.capabilities.supportsSessionQuota, policy.sessionEnabled,
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
        policy: ProviderFailoverPolicy,
        unverifiedResetIDs: Set<UUID> = []
    ) -> [UUID] {
        candidateIDs.filter {
            !unverifiedResetIDs.contains($0) &&
            hasCapacity(usage: usageByID[$0], provider: provider, policy: policy)
        }
    }
}
