import Foundation

/// The provider registration point for behavior shared by accounts, usage,
/// failover, and presentation. Provider-specific network/authentication code
/// remains in its service adapter, but consumers should ask these capabilities
/// instead of comparing provider identities.
struct ProviderCapabilities: Sendable {
    let displayName: String
    let iconName: String
    let configDirectory: String
    let isImplemented: Bool
    let requiresPaidPlanForWorkloads: Bool
    let sessionQuotaMode: ProviderQuotaMode
    let sessionQuotaLabel: String
    let supportsWeeklyQuota: Bool
    let weeklyQuotaLabel: String
    let unavailableLabel: String
    let supportsSelectableSwitchMode: Bool
    let pricingPrefixes: [String]

    var supportsSessionQuota: Bool { sessionQuotaMode != .unsupported }
}

enum ProviderQuotaMode: Sendable, Equatable {
    /// Every viable account is expected to return this quota window.
    case required
    /// Enforce and display the window when the account's live plan returns it.
    case whenPresent
    case unsupported
}

extension AIProviderType {
    var capabilities: ProviderCapabilities {
        switch self {
        case .claudeCode:
            ProviderCapabilities(
                displayName: "Claude",
                iconName: "brain.head.profile",
                configDirectory: "~/.claude",
                isImplemented: true,
                requiresPaidPlanForWorkloads: true,
                sessionQuotaMode: .required,
                sessionQuotaLabel: "Session",
                supportsWeeklyQuota: true,
                weeklyQuotaLabel: "Weekly limit",
                unavailableLabel: "Claude Code unavailable",
                supportsSelectableSwitchMode: false,
                pricingPrefixes: ["anthropic/", "anthropic."]
            )
        case .codex:
            ProviderCapabilities(
                displayName: "Codex",
                iconName: "chevron.left.forwardslash.chevron.right",
                configDirectory: "~/.codex",
                isImplemented: true,
                requiresPaidPlanForWorkloads: true,
                sessionQuotaMode: .whenPresent,
                sessionQuotaLabel: "Session",
                supportsWeeklyQuota: true,
                weeklyQuotaLabel: "Quota limit",
                unavailableLabel: "Codex unavailable",
                supportsSelectableSwitchMode: true,
                pricingPrefixes: ["openai/"]
            )
        case .kimi:
            ProviderCapabilities(
                displayName: "Kimi",
                iconName: "moon.stars",
                configDirectory: "~/.kimi-code",
                isImplemented: true,
                requiresPaidPlanForWorkloads: false,
                sessionQuotaMode: .required,
                sessionQuotaLabel: "5-hour",
                supportsWeeklyQuota: true,
                weeklyQuotaLabel: "Monthly limit",
                unavailableLabel: "Kimi Code unavailable",
                supportsSelectableSwitchMode: false,
                pricingPrefixes: ["moonshot/", "kimi/"]
            )
        case .gemini:
            ProviderCapabilities(
                displayName: "Gemini",
                iconName: "sparkles",
                configDirectory: "~/.gemini",
                isImplemented: false,
                requiresPaidPlanForWorkloads: false,
                sessionQuotaMode: .unsupported,
                sessionQuotaLabel: "Session",
                supportsWeeklyQuota: false,
                weeklyQuotaLabel: "Quota limit",
                unavailableLabel: "Gemini unavailable",
                supportsSelectableSwitchMode: false,
                pricingPrefixes: ["gemini/", "google/"]
            )
        }
    }

    static var implementedProviders: [AIProviderType] {
        allCases.filter { $0.capabilities.isImplemented }
    }
}

enum ProviderWorkloadAvailability: Equatable {
    case available
    case unavailable(label: String)

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}
