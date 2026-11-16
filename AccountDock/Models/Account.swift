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
    /// When the provider last refused the account's CLI because its
    /// organisation has turned off subscription access, as a team admin
    /// does by removing a seat or licence; nil while it has not. The account
    /// then serves no workload (`workloadAvailability`) until a re-check
    /// (`AppState.recheckCLIAccessIfDue`) is served again.
    var cliAccessRefusedAt: Date?
    /// The plan the provider's plan authority last named
    /// (`ProviderCapabilities.planAuthority`: Claude's account profile,
    /// Kimi's `/me`, Codex's usage reply), or "free" once it or a usage
    /// reply shows the plan ended; nil until one answered. A credential
    /// keeps the plan it was issued under through an upgrade or a
    /// downgrade, so once this is known it is the account's plan
    /// (`currentPlan`): `applyProfilePlan` writes it, and the credential,
    /// CLI status and sign-in writers go through `applyCredentialPlan`,
    /// which leaves the plan alone.
    var profilePlan: String?
    /// The rate-limit tier the plan authority last named (Claude's
    /// `organization.rate_limit_tier`), which sizes the plan; nil until one
    /// named one. Wins over the credential's (`currentRateLimitTier`).
    var profileRateLimitTier: String?
    /// When the plan authority last answered for the account, kept across
    /// launches so `AppState.planCheckDue` checks it again only every
    /// `AppState.profileRecheckInterval`.
    var profileCheckedAt: Date?

    /// The account's plan: the profile's when a profile check named one,
    /// otherwise the stored one. Read by every plan-dependent property
    /// here and by `AppState.learnedPlan`.
    var currentPlan: String? { profilePlan ?? subscriptionType }
    /// The account's rate-limit tier: the profile's when a profile check
    /// named one, otherwise the credential's.
    var currentRateLimitTier: String? { profileRateLimitTier ?? rateLimitTier }

    /// The plan's name: the provider's name for its plan and tier, or else
    /// the subscription type with first letter capitalized ("pro" → "Pro").
    var displaySubscriptionType: String? {
        let current = currentPlan
        if let plan = current, let tier = currentRateLimitTier,
           let name = provider.capabilities.planNames["\(plan):\(tier)"] { return name }
        return current?.prefix(1).uppercased().appending(current?.dropFirst() ?? "")
    }

    /// The plan's allowance relative to the provider's other plans
    /// (`ProviderCapabilities.planSizes`), by its plan and tier or its plan
    /// alone, the profile's first (`currentPlan`, `currentRateLimitTier`);
    /// nil when the provider's table does not know it.
    var planSize: Double? {
        guard let plan = currentPlan?.lowercased() else { return nil }
        let sizes = provider.capabilities.planSizes
        if let tier = currentRateLimitTier, let size = sizes["\(plan):\(tier)"] { return size }
        return sizes[plan]
    }

    /// Writes the plan and tier a credential, `claude auth status` or a
    /// sign-in's identity names, each only while the account profile has
    /// not named its own (`profilePlan`, `profileRateLimitTier`): a
    /// credential still names the plan it was issued under after the plan
    /// changed. A nil value leaves the stored one. Returns whether anything
    /// changed, so the caller saves the accounts.
    @discardableResult
    mutating func applyCredentialPlan(_ plan: String?, tier: String? = nil) -> Bool {
        var changed = false
        if profilePlan == nil, let plan, subscriptionType != plan {
            subscriptionType = plan
            changed = true
        }
        if profileRateLimitTier == nil, let tier, rateLimitTier != tier {
            rateLimitTier = tier
            changed = true
        }
        return changed
    }

    /// A change of plan a profile check found, in the words the failover
    /// events and the log use (`displaySubscriptionType`, and the stored
    /// plan and tier).
    struct PlanChange: Equatable {
        var before: String
        var after: String
        var detail: String
    }

    /// Takes the plan and tier the account profile names now: `plan`, or
    /// "free" when the profile shows the plan ended (`inactive`), and
    /// `tier`; a plan or tier the profile does not name keeps the one
    /// known. They become the profile's (`profilePlan`,
    /// `profileRateLimitTier`) and the stored ones, so every reader agrees.
    /// `checkedAt` is when the profile answered (`profileCheckedAt`).
    /// Returns the change when the plan or tier differs from what the
    /// account was taken to be on, nil when it is the same.
    mutating func applyProfilePlan(_ plan: String?, inactive: Bool, tier: String?, checkedAt: Date) -> PlanChange? {
        let before = (name: displaySubscriptionType ?? "none", plan: currentPlan, tier: currentRateLimitTier)
        profileCheckedAt = checkedAt
        if let named = inactive ? "free" : plan {
            profilePlan = named
            subscriptionType = named
        }
        if let tier, !inactive {
            profileRateLimitTier = tier
            rateLimitTier = tier
        }
        guard before.plan != currentPlan || before.tier != currentRateLimitTier else { return nil }
        func raw(_ plan: String?, _ tier: String?) -> String { [plan ?? "none", tier].compactMap { $0 }.joined(separator: ":") }
        var names = (before: before.name, after: displaySubscriptionType ?? "none")
        // Plans the provider names alike (a Max plan on another tier) are
        // told apart by their tiers.
        if names.before == names.after {
            names = ("\(names.before) (\(before.tier ?? "no tier"))", "\(names.after) (\(currentRateLimitTier ?? "no tier"))")
        }
        return PlanChange(before: names.before, after: names.after,
                          detail: "\(raw(before.plan, before.tier)) -> \(raw(currentPlan, currentRateLimitTier))")
    }

    /// Makes the stored plan and tier the profile's where a profile check
    /// named them, so every reader of the stored fields sees the plan the
    /// account is on from launch. Applied by `AppState.loadAccounts` to
    /// every decoded account.
    mutating func adoptProfilePlan() {
        if let profilePlan { subscriptionType = profilePlan }
        if let profileRateLimitTier { rateLimitTier = profileRateLimitTier }
    }

    /// Whether the account's plan has a session window: always where the
    /// provider requires one, never where it has none, and where its plans
    /// differ, when the plan, with its tier or alone, is one it lists
    /// (`ProviderCapabilities.sessionWindowPlans`). Nil when the plan does
    /// not say, and the replies decide. Read by `AppState.recordUsage` and
    /// the account cards.
    var planHasSessionWindow: Bool? {
        switch provider.capabilities.sessionQuotaMode {
        case .required: return true
        case .unsupported: return false
        case .whenPresent:
            guard let plan = currentPlan?.lowercased() else { return nil }
            let plans = provider.capabilities.sessionWindowPlans
            if let tier = currentRateLimitTier, plans.contains("\(plan):\(tier)") { return true }
            return plans.contains(plan) ? true : nil
        }
    }

    /// Whether this profile is a viable destination for provider workloads.
    /// A ChatGPT Free login remains a valid identity, but does not provide the
    /// Codex subscription capacity needed for account switching/failover.
    var supportsProviderWorkloads: Bool {
        workloadAvailability.isAvailable
    }

    var workloadAvailability: ProviderWorkloadAvailability {
        if cliAccessRefusedAt != nil { return .unavailable(label: "\(provider.rawValue) disabled by organisation") }
        if hasUnassignedSeat { return .unavailable(label: "No seat assigned") }
        return Self.workloadAvailability(provider: provider, subscriptionType: currentPlan)
    }

    /// Ends a plan name (`ClaudeService.liveSubscription`) when the account
    /// belongs to a team or enterprise organisation but has no seat in it:
    /// "team (no seat)".
    static let unassignedSeatSuffix = " (no seat)"

    /// The account is a member of an organisation that has assigned it no
    /// seat (licence), so it has no subscription to run the CLI with.
    var hasUnassignedSeat: Bool {
        currentPlan?.lowercased().hasSuffix(Self.unassignedSeatSuffix) == true
    }

    /// What the account card says while the organisation refuses the CLI
    /// (`cliAccessRefusedAt`) or has assigned the account no seat. Its seat
    /// or licence may have been removed, so it says where to look, and that
    /// AccountDock checks again.
    var cliAccessNotice: String? {
        if hasUnassignedSeat {
            return "In a team, but no seat (licence) is assigned to this account, so it cannot use \(provider.rawValue). Ask the team's admin to assign one; AccountDock checks again when you refresh."
        }
        guard cliAccessRefusedAt != nil else { return nil }
        return "Organisation has disabled \(provider.rawValue) subscription access. Check this account's seat or licence with its organisation's admin; AccountDock checks again daily and when you refresh."
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

    /// Why the account cannot serve the provider's CLI at all, in the words
    /// a move menu shows beside it (`SessionMoveRules.blocker`); nil when
    /// it can.
    var cliUnavailableReason: String? {
        if cliAccessRefusedAt != nil { return "its organisation has disabled \(provider.rawValue) subscription access" }
        if hasUnassignedSeat { return "it has no seat in its team" }
        guard !supportsProviderWorkloads else { return nil }
        return "its plan does not include \(provider.rawValue)"
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

extension Array where Element == Account {
    /// The provider's active account; `AppState.activeAccount(for:)` reads
    /// it, so no copy of it can disagree with the accounts' flags.
    func active(for provider: AIProviderType) -> Account? {
        first { $0.provider == provider && $0.isActive }
    }

    /// Makes `id` its provider's active account and that provider's other
    /// accounts inactive; other providers' accounts keep theirs.
    mutating func makeActive(_ id: UUID) {
        guard let provider = first(where: { $0.id == id })?.provider else { return }
        for index in indices where self[index].provider == provider {
            self[index].isActive = self[index].id == id
        }
    }
}
