import Foundation
import Combine

enum FailoverSwitchMethod: String, Codable, CaseIterable, Identifiable {
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
    /// Hours by which another account's latest feasible start must precede the
    /// active account's before balancing moves the workload.
    var balancingMinimumAdvantageHours = 6.0
    var balancingMinimumDwellMinutes = 30.0
    var suspendAgentsWhenExhausted = false
    /// With `suspendAgentsWhenExhausted`, paused sessions continue a few at
    /// a time as capacity returns, each where its forecast use fits, rather
    /// than all at once on the first account that resets.
    var resumeAsCapacityAllows = true
    /// `RouteTarget` that serves this provider's requests, through
    /// `AccountDockRouter`, while every included account is exhausted;
    /// requests return once an account has capacity, and sessions keep
    /// running throughout. Nil pauses sessions instead.
    var routeTarget: String?
    /// Model of the route target that serves routed requests; nil uses the
    /// target's default.
    var routeModel: String?
    /// Sessions with more context than this stay on the provider's own
    /// accounts instead of being routed; nil uses `defaultRouteMaxContextTokens`.
    var routeMaxContextTokens: Int?
    /// Share of the route target's window kept for its own provider's
    /// sessions; routing stops before the window falls below it.
    var routeReservePercent: Double = 25
    /// Routing starts only when the target is expected to carry the current
    /// demand at least this long.
    var routeMinimumMinutes: Double = 15
    /// Sends the model requests of a CLI with a bridged request hold
    /// (`RequestHoldSupport.bridgedProtocol`) through `AccountDockRouter`,
    /// so `routeTarget` can serve them. While off, `ProviderRequestHold`
    /// leaves that CLI's base URL alone and `routeTarget` is not used.
    var routeThroughBridge = false
    /// Serves each session from its own account through the router, so
    /// several accounts' 5-hour windows are used at the same time.
    var distributeSessions = false
    /// The active account stays active: `AppState.performAutomaticSwitch`
    /// makes no switch away from it until the user unlocks it or switches
    /// themselves. Sessions with a slot of their own still move.
    var activeAccountLocked = false
    /// With `distributeSessions`, each account's sessions are paced to its
    /// 5-hour window: new sessions go to the accounts with the most unused
    /// rate, sessions keep their account while their prompt cache lasts, and
    /// leave it only when it would reach its limit for longer than that.
    var paceSessions = true
    /// The router asks for the one-hour prompt cache for large contexts in
    /// place of the client's five-minute one.
    var extendCacheLifetime = true
    /// Lets accounts with extra usage enabled keep serving past their plan
    /// limit when every account is exhausted, up to this much spend per
    /// month in the account's currency. Nil never uses extra usage.
    var extraUsageMonthlyLimit: Double?
    /// The model a session is switched to when no account has allowance
    /// left for the model it uses (`AppState.applyModelFallbacks`): one of
    /// the provider's `sessionModelChoices`. Nil leaves the session as it is.
    var noRoomModelFallback: String?
    var switchMethod = FailoverSwitchMethod.safeRestart
    var accountOrder: [UUID] = []
    var excludedAccountIDs: Set<UUID> = []

    /// Whether a setting needs the router: a route to another provider, or
    /// sessions served from several accounts at once by a CLI that cannot
    /// start each session on an account of its own (`SessionSlots`).
    /// Failover, balancing and pausing switch the CLI's own account and send
    /// no request through it, so with neither set the CLI reaches its
    /// provider directly and the router does not run.
    func usesRouter(for provider: AIProviderType) -> Bool {
        routeTarget != nil || (distributeSessions && provider.capabilities.sessionSlots == nil)
    }

    /// Whether the provider's CLI is to reach the router through its bridged
    /// request hold: the user turned it on and chose a target to serve it.
    func usesBridge(for provider: AIProviderType) -> Bool {
        routeThroughBridge && routeTarget != nil && provider.capabilities.requestRouter == nil
            && provider.capabilities.requestHold?.bridgedProtocol != nil
    }

    enum CodingKeys: String, CodingKey {
        case enabled, sessionEnabled, sessionThreshold, weeklyEnabled, weeklyThreshold
        case loops, resetAware, preferMostCapacity, waitForImminentReset
        case resetGraceMinutes, keepWindowsWarm, intelligentBalancingEnabled
        case balancingMinimumAdvantageHours, balancingMinimumDwellMinutes
        case suspendAgentsWhenExhausted, resumeAsCapacityAllows, routeTarget, routeModel, distributeSessions, paceSessions, extendCacheLifetime, extraUsageMonthlyLimit
        case routeMaxContextTokens, routeReservePercent, routeMinimumMinutes, routeThroughBridge
        case routeToKimiWhenExhausted, routeKimiModel
        case switchMethod, accountOrder, excludedAccountIDs, activeAccountLocked
        case codexSwitchMode
        case noRoomModelFallback
    }

    init() {}

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(enabled, forKey: .enabled)
        try values.encode(sessionEnabled, forKey: .sessionEnabled)
        try values.encode(sessionThreshold, forKey: .sessionThreshold)
        try values.encode(weeklyEnabled, forKey: .weeklyEnabled)
        try values.encode(weeklyThreshold, forKey: .weeklyThreshold)
        try values.encode(loops, forKey: .loops)
        try values.encode(resetAware, forKey: .resetAware)
        try values.encode(preferMostCapacity, forKey: .preferMostCapacity)
        try values.encode(waitForImminentReset, forKey: .waitForImminentReset)
        try values.encode(resetGraceMinutes, forKey: .resetGraceMinutes)
        try values.encode(keepWindowsWarm, forKey: .keepWindowsWarm)
        try values.encode(intelligentBalancingEnabled, forKey: .intelligentBalancingEnabled)
        try values.encode(balancingMinimumAdvantageHours, forKey: .balancingMinimumAdvantageHours)
        try values.encode(balancingMinimumDwellMinutes, forKey: .balancingMinimumDwellMinutes)
        try values.encode(suspendAgentsWhenExhausted, forKey: .suspendAgentsWhenExhausted)
        try values.encode(resumeAsCapacityAllows, forKey: .resumeAsCapacityAllows)
        try values.encodeIfPresent(routeTarget, forKey: .routeTarget)
        try values.encodeIfPresent(routeModel, forKey: .routeModel)
        try values.encodeIfPresent(routeMaxContextTokens, forKey: .routeMaxContextTokens)
        try values.encode(routeReservePercent, forKey: .routeReservePercent)
        try values.encode(routeMinimumMinutes, forKey: .routeMinimumMinutes)
        try values.encode(routeThroughBridge, forKey: .routeThroughBridge)
        try values.encode(distributeSessions, forKey: .distributeSessions)
        try values.encode(activeAccountLocked, forKey: .activeAccountLocked)
        try values.encode(paceSessions, forKey: .paceSessions)
        try values.encode(extendCacheLifetime, forKey: .extendCacheLifetime)
        try values.encodeIfPresent(extraUsageMonthlyLimit, forKey: .extraUsageMonthlyLimit)
        try values.encodeIfPresent(noRoomModelFallback, forKey: .noRoomModelFallback)
        try values.encode(switchMethod, forKey: .switchMethod)
        try values.encode(accountOrder, forKey: .accountOrder)
        try values.encode(excludedAccountIDs, forKey: .excludedAccountIDs)
    }

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
        balancingMinimumAdvantageHours = try values.decodeIfPresent(Double.self, forKey: .balancingMinimumAdvantageHours) ?? 6
        balancingMinimumDwellMinutes = try values.decodeIfPresent(Double.self, forKey: .balancingMinimumDwellMinutes) ?? 30
        suspendAgentsWhenExhausted = try values.decodeIfPresent(Bool.self, forKey: .suspendAgentsWhenExhausted) ?? false
        resumeAsCapacityAllows = try values.decodeIfPresent(Bool.self, forKey: .resumeAsCapacityAllows) ?? true
        routeTarget = try values.decodeIfPresent(String.self, forKey: .routeTarget)
        routeModel = try values.decodeIfPresent(String.self, forKey: .routeModel)
        routeMaxContextTokens = try values.decodeIfPresent(Int.self, forKey: .routeMaxContextTokens)
        routeReservePercent = try values.decodeIfPresent(Double.self, forKey: .routeReservePercent) ?? 25
        routeMinimumMinutes = try values.decodeIfPresent(Double.self, forKey: .routeMinimumMinutes) ?? 15
        routeThroughBridge = try values.decodeIfPresent(Bool.self, forKey: .routeThroughBridge) ?? false
        distributeSessions = try values.decodeIfPresent(Bool.self, forKey: .distributeSessions) ?? false
        activeAccountLocked = try values.decodeIfPresent(Bool.self, forKey: .activeAccountLocked) ?? false
        paceSessions = try values.decodeIfPresent(Bool.self, forKey: .paceSessions) ?? true
        extendCacheLifetime = try values.decodeIfPresent(Bool.self, forKey: .extendCacheLifetime) ?? true
        extraUsageMonthlyLimit = try values.decodeIfPresent(Double.self, forKey: .extraUsageMonthlyLimit)
        noRoomModelFallback = try values.decodeIfPresent(String.self, forKey: .noRoomModelFallback)
        // Settings saved when routing could only target Kimi.
        if routeTarget == nil, try values.decodeIfPresent(Bool.self, forKey: .routeToKimiWhenExhausted) == true {
            routeTarget = "kimi"
            routeModel = try values.decodeIfPresent(String.self, forKey: .routeKimiModel)
        }
        // Settings saved when only Codex offered a switch method.
        switchMethod = try values.decodeIfPresent(FailoverSwitchMethod.self, forKey: .switchMethod)
            ?? values.decodeIfPresent(FailoverSwitchMethod.self, forKey: .codexSwitchMode)
            ?? .safeRestart
        accountOrder = try values.decodeIfPresent([UUID].self, forKey: .accountOrder) ?? []
        excludedAccountIDs = try values.decodeIfPresent(Set<UUID>.self, forKey: .excludedAccountIDs) ?? []
    }

    static func defaults(for provider: AIProviderType) -> Self {
        var policy = Self()
        if !provider.capabilities.supportsSessionQuota {
            policy.sessionEnabled = false
        }
        if !provider.capabilities.supportsWindowWarming {
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

    /// The saved policy, read without the main actor for background work
    /// such as hook installation.
    nonisolated static func storedPolicy(for provider: AIProviderType) -> ProviderFailoverPolicy {
        guard let data = UserDefaults.standard.data(forKey: "app.accountdock.failover.policies.v1"),
              let stored = try? JSONDecoder().decode(ProviderPolicyStore.self, from: data),
              let policy = stored.policies[provider] else { return .defaults(for: provider) }
        return policy
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
