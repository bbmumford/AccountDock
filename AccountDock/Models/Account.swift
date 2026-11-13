import Foundation

// MARK: - Provider Type (extensible for Gemini, Codex, etc.)

enum AIProviderType: String, Codable, CaseIterable, Identifiable {
    case claudeCode = "Claude Code"
    case gemini = "Gemini"
    case codex = "Codex"
    case kimi = "Kimi"

    var id: String { rawValue }

    var iconName: String {
        capabilities.iconName
    }

    var configDirectory: String {
        capabilities.configDirectory
    }
}

// MARK: - Account Model

struct Account: Identifiable, Codable, Hashable {
    let id: UUID
    var email: String
    var displayName: String
    var provider: AIProviderType
    var orgName: String?
    var subscriptionType: String?
    var isActive: Bool
    var lastUsed: Date?
    var customLabel: String?
    /// Provider-scoped credential location. Codex accounts use an isolated CODEX_HOME.
    var credentialLocation: String?
    /// The provider's rate-limit tier from the account's credential, which
    /// tells apart plans sharing one stored plan name.
    var rateLimitTier: String?

    /// The plan's name: the provider's name for its plan and tier, or else
    /// the subscription type with first letter capitalized ("pro" → "Pro").
    var displaySubscriptionType: String? {
        if let plan = subscriptionType, let tier = rateLimitTier,
           let name = provider.capabilities.planNames["\(plan):\(tier)"] { return name }
        return subscriptionType?.prefix(1).uppercased().appending(subscriptionType?.dropFirst() ?? "")
    }

    /// Whether this profile is a viable destination for provider workloads.
    /// A ChatGPT Free login remains a valid identity, but does not provide the
    /// Codex subscription capacity needed for account switching/failover.
    var supportsProviderWorkloads: Bool {
        workloadAvailability.isAvailable
    }

    var workloadAvailability: ProviderWorkloadAvailability {
        Self.workloadAvailability(provider: provider, subscriptionType: subscriptionType)
    }

    static func supportsProviderWorkloads(
        provider: AIProviderType,
        subscriptionType: String?
    ) -> Bool {
        workloadAvailability(provider: provider, subscriptionType: subscriptionType).isAvailable
    }

    static func workloadAvailability(
        provider: AIProviderType,
        subscriptionType: String?
    ) -> ProviderWorkloadAvailability {
        let tier = subscriptionType?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let isUnavailable = tier == "inactive" || (
            provider.capabilities.requiresPaidPlanForWorkloads && tier == "free"
        )
        return isUnavailable
            ? .unavailable(label: provider.capabilities.unavailableLabel)
            : .available
    }

    var providerUnavailableLabel: String? {
        guard case let .unavailable(label) = workloadAvailability else { return nil }
        return label
    }

    var obfuscatedEmail: String {
        return email.obfuscatedEmail()
    }

    var obfuscatedDisplayName: String {
        return displayName.obfuscatedEmail()
    }

    /// Returns customLabel if set and non-empty, otherwise falls back to obfuscatedDisplayName.
    var effectiveDisplayName: String {
        if let label = customLabel, !label.isEmpty {
            return label
        }
        return obfuscatedDisplayName
    }

    /// Returns the email, optionally obfuscated.
    func displayEmail(obfuscated: Bool) -> String {
        obfuscated ? obfuscatedEmail : email
    }

    /// Whether `other`, an address a provider or its CLI reported, names this
    /// account. Providers return an address in the case it was entered in,
    /// so case and surrounding whitespace are ignored; nil matches nothing.
    func matches(email other: String?) -> Bool {
        guard let other else { return false }
        let trimmed = other.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.caseInsensitiveCompare(
            email.trimmingCharacters(in: .whitespacesAndNewlines)
        ) == .orderedSame
    }

    /// Returns the effective display name, optionally obfuscating the fallback.
    func effectiveDisplayName(obfuscated: Bool) -> String {
        if let label = customLabel, !label.isEmpty {
            return label
        }
        return obfuscated ? obfuscatedDisplayName : displayName
    }

    /// The name failover events, alerts and logs call the account by. The
    /// display name is only a label the user chose, so when another account
    /// of the same provider shows the same name the obfuscated email is
    /// added and every message still names one account; the full email only
    /// when the obfuscated forms collide too.
    func messageName(among accounts: [Account]) -> String {
        let name = effectiveDisplayName(obfuscated: true)
        let namesakes = accounts.filter {
            $0.id != id && $0.provider == provider && $0.effectiveDisplayName(obfuscated: true) == name
        }
        guard !namesakes.isEmpty || name.isEmpty else { return name }
        let email = namesakes.contains { $0.obfuscatedEmail == obfuscatedEmail } ? self.email : obfuscatedEmail
        return name.isEmpty ? email : "\(name) (\(email))"
    }

    init(
        id: UUID = UUID(),
        email: String,
        displayName: String,
        provider: AIProviderType = .claudeCode,
        orgName: String? = nil,
        subscriptionType: String? = nil,
        isActive: Bool = false,
        lastUsed: Date? = nil,
        customLabel: String? = nil,
        credentialLocation: String? = nil
    ) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.provider = provider
        self.orgName = orgName
        self.subscriptionType = subscriptionType
        self.isActive = isActive
        self.lastUsed = lastUsed
        self.customLabel = customLabel
        self.credentialLocation = credentialLocation
    }
}

// MARK: - Auth Status (from `claude auth status`)

struct AuthStatus: Codable {
    let loggedIn: Bool
    let authMethod: String?
    let apiProvider: String?
    let email: String?
    let orgId: String?
    let orgName: String?
    let subscriptionType: String?
}
