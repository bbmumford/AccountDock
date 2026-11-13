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
    /// Model names the CLI reports that differ from the published model id
    /// LiteLLM prices, mapped to that id.
    var pricingAliases: [String: String] = [:]
    /// How the provider's sessions wait between model requests while a pause
    /// holds them; nil when its CLI has no hook that waits, so AccountDock
    /// cannot pause it without stopping the process.
    var pauseGate: PauseGateSupport?
    /// How the CLI's model requests can be sent through AccountDock's router,
    /// which holds them for a whole pause; nil when its endpoint cannot be
    /// changed. Used when the pause gate cannot wait long enough on its own.
    var requestHold: RequestHoldSupport?
    /// The CLI's session lifecycle hooks, which record which process runs
    /// which session; nil when it has none.
    var lifecycleHooks: LifecycleHookSupport?
    /// Requests its usage endpoint takes before throttling: a burst size and
    /// the seconds to earn one more. Nil when the provider has no endpoint.
    var usageRequestBudget: (capacity: Double, refillInterval: TimeInterval)?
    /// Whether a minimal request can start an account's next quota window
    /// right after a reset, through its `QuotaWindowProbe`.
    var supportsWindowWarming = false
    /// Whether switching the account reaches the CLI's running sessions
    /// (restarting or reloading them), so a switch waits for a reset rather
    /// than moving sessions onto a destination that is still exhausted, and
    /// paused sessions must be running to receive it.
    var switchReachesRunningSessions = false
    /// Whether a switched-away account's credential stays live in the CLI's
    /// running sessions, so its usage can keep moving after the switch and a
    /// stored copy can expire unseen.
    var credentialSharedAcrossSessions = false
    /// Where the CLI keeps account credentials; the Keychain needs the user
    /// to allow access before saved accounts can be switched to.
    var credentialStore: CredentialStore = .files
    /// A source the CLI writes usage to with every response, read instead of
    /// polling the usage endpoint.
    var liveUsageFeed: LiveUsageFeed?
    /// How AccountDock's request router serves the CLI's requests; nil when
    /// its requests cannot pass through the router.
    var requestRouter: RequestRouterSupport?
    /// How each launch of the CLI can run on an account of its own, chosen
    /// by `SessionSlots`' launcher; nil when the CLI has no per-launch
    /// credential location.
    var sessionSlots: SessionSlotSupport?
    /// The service this provider's accounts offer as a route target for
    /// another provider's routed requests.
    var routeTarget: RouteTarget?
    /// Whether an account can keep serving past its plan limit on paid
    /// extra usage.
    var supportsExtraUsage = false
    /// Whether the provider's usage reply lists the limit resets an account
    /// holds, which its module reads into `LimitResets`; such accounts are
    /// read for them hourly (`AppState.refreshLimitResetsIfDue`).
    var reportsLimitResets = false
    /// The CLI's executable name, for finding its running processes.
    var cliExecutableName: String?
    /// Window percent a request is assumed to cost while the provider has no
    /// per-request usage to learn from.
    var defaultRequestCostPercent: Double = 2
    /// Prefix of the provider's stored menu-bar module names.
    var storageKey = ""
    /// The long window's name in stored module names, such as `Weekly`.
    var longWindowStorageName = "Weekly"
    /// Short uppercase labels of the session and long windows in the menu
    /// bar.
    var sessionShortLabel = "5H"
    var longShortLabel = "7D"
    /// One-letter badge for compact provider labels.
    var shortBadge: String = "?"
    /// What the provider's local records report about today's work.
    var activityMetrics: Set<ActivityMetric> = [.turns, .cost]
    /// Whether the long window's length comes with each reading, so it is
    /// labelled by its length rather than `weeklyQuotaLabel`.
    var longWindowReportsLength = false
    /// Plan names the provider uses where its stored plan and rate-limit
    /// tier don't say them, keyed `<plan>:<tier>`; read by
    /// `Account.displaySubscriptionType`.
    var planNames: [String: String] = [:]

    var supportsSessionQuota: Bool { sessionQuotaMode != .unsupported }
    /// Directory under the config directory holding the CLI's session
    /// transcripts, read by `TranscriptRequestFeed`.
    var transcriptDirectory: String? { requestRouter?.transcriptDirectory }
}

enum CredentialStore: Sendable { case keychain, files }

enum ActivityMetric: Sendable, Hashable {
    case turns, activeTime, linesChanged, cost
}

enum LiveUsageFeed: Sendable {
    /// The CLI's status-line command, wrapped to record each reading.
    case statusLine
}

/// A client protocol AccountDock's request router serves.
enum RouterProtocol: Sendable { case anthropicMessages }

/// How the router serves a provider's CLI.
struct RequestRouterSupport: Sendable {
    let clientProtocol: RouterProtocol
    /// The CLI's JSON settings file, relative to the home directory, whose
    /// `env` object gains `baseURLVariable` while the router serves it.
    let settingsFile: String
    /// The environment variable the CLI reads its API base URL from.
    let baseURLVariable: String
    /// Directory under the provider's config directory where the CLI keeps
    /// one `<session>.jsonl` transcript per session, inside per-project
    /// directories; sessions without one are background requests.
    let transcriptDirectory: String
}

/// A per-launch credential location of a CLI whose credential is a Keychain
/// item, used by `SessionSlots`.
struct SessionSlotSupport: Sendable {
    /// The environment variable naming a directory; the CLI then uses the
    /// Keychain item `keychainService` followed by `-` and the first eight
    /// hexadecimal digits of the SHA-256 of that directory's path.
    let directoryVariable: String
    /// The service of the CLI's default credential item.
    let keychainService: String
    /// Variables that already decide the CLI's credential; a launch that
    /// sets any of them runs the CLI unchanged.
    let credentialVariables: [String]
    /// First arguments of the CLI's sign-in and sign-out commands, which run
    /// unchanged so they act on the default credential.
    let accountCommands: [String]
}

/// Where a CLI keeps the base URL of its model requests, so
/// `ProviderRequestHold` can point it at `ProviderPassthrough` in the router
/// and restore it.
struct RequestHoldSupport: Sendable {
    /// The CLI's config file, relative to the home directory; a TOML file.
    let settingsFile: String
    /// The table holding the base URL, as written in its header, such as
    /// `providers."managed:kimi-code"`.
    let table: String
    let key: String
    /// The request-body field carrying the session ID, so a resumed session
    /// is released on its own.
    let sessionField: String
    /// The base URL to restore when none was recorded.
    let defaultUpstream: String
    /// Whether the CLI still signs its requests when the base URL points
    /// at the router. When it does not, `ProviderRequestHold` never points
    /// it there and only writes back a base URL it finds pointed there.
    var keepsCredentialAtRouter = true
    /// Whether the CLI's config has no such key until one is set, so
    /// restoring `defaultUpstream` removes the key instead of writing it.
    var keyAbsentByDefault = false
    /// Whether the router holds the CLI's requests while its pause holds
    /// the session (`ProviderPassthrough.Entry.holdsRequests`). False for a
    /// CLI whose gate hook waits for a whole pause by itself.
    var holdsPausedRequests = true
    /// The protocol of the route targets that can serve the CLI's model
    /// requests through the router's `ResponsesBridge`; nil when the router
    /// only forwards them. A bridged hold is installed by the provider's
    /// `ProviderFailoverPolicy.routeThroughBridge` and not by its pause.
    var bridgedProtocol: RouterProtocol?
}

/// A provider CLI's session lifecycle hooks, installed by
/// `AgentHookInstaller`.
struct LifecycleHookSupport: Sendable {
    let events: [String]
    /// The hook configuration file, relative to the home directory.
    let hookFile: String
    let format: PauseGateSupport.ConfigFormat
    /// Seconds the CLI waits for the hook; 0 leaves its default.
    let timeout: Int
    /// The bundled shell script a JSON hook runs; a TOML-hook CLI runs hooks
    /// through a shell and gets a generated wrapper instead.
    let bundledScript: String?
}

/// A provider CLI's hook that `AgentPauseGate` installs to hold sessions.
struct PauseGateSupport: Sendable {
    enum ConfigFormat: Sendable {
        /// `hooks` in a JSON settings file, as Claude Code and Codex use.
        case jsonHooks
        /// `[[hooks]]` tables in a TOML config, as Kimi Code uses.
        case tomlHooks
    }

    /// Name used by the gate script, the session records and the pause file.
    let key: String
    /// The hook configuration file, relative to the home directory.
    let hookFile: String
    let format: ConfigFormat
    /// The event the CLI waits for after a model response, where a held
    /// session waits before its next request.
    let gateEvent: String
    /// Further events after which the CLI sends a model request with no tool
    /// call or prompt in between, where a held session waits too. Claude
    /// Code compacts a conversation (`PreCompact`) and then continues it
    /// (`SessionStart` with source `compact`); the gate script lets every
    /// other `SessionStart` through.
    var continuationEvents: [String] = []
    /// How the CLI reads the gate's reply, so a resumed session reports the
    /// pause and its agent is told to check the background work it started;
    /// nil when the CLI ignores the reply.
    let reply: HookReply?
    /// The longest hook timeout the CLI accepts, in seconds; nil when it
    /// takes any. Kimi Code drops its whole `[[hooks]]` section when one
    /// entry exceeds its limit, so the gate is installed within it.
    var maximumHookTimeout: Int? = nil

    enum HookReply: Sendable {
        /// `systemMessage` shown to the user and
        /// `hookSpecificOutput.additionalContext` given to the agent, as
        /// Claude Code reads them.
        case systemMessageAndContext
        /// `message`, which Kimi Code adds to a new turn's context.
        case message
    }
}

enum ProviderQuotaMode: Sendable, Equatable {
    /// Every viable account is expected to return this quota window.
    case required
    /// Enforce and display the window when the account's live plan returns
    /// it. An account without it is limited only by its long window, as a
    /// plan may drop the session window account by account.
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
                sessionQuotaMode: .whenPresent,
                sessionQuotaLabel: "Session",
                supportsWeeklyQuota: true,
                weeklyQuotaLabel: "Weekly limit",
                unavailableLabel: "Claude Code unavailable",
                supportsSelectableSwitchMode: false,
                pricingPrefixes: ["anthropic/", "anthropic."],
                pauseGate: PauseGateSupport(key: "claude", hookFile: ".claude/settings.json", format: .jsonHooks,
                                            gateEvent: "PostToolUse", continuationEvents: ["PreCompact", "SessionStart"],
                                            reply: .systemMessageAndContext),
                lifecycleHooks: LifecycleHookSupport(events: ["SessionStart", "UserPromptSubmit", "Stop", "SessionEnd"],
                                                     hookFile: ".claude/settings.json", format: .jsonHooks,
                                                     timeout: 0, bundledScript: "accountdock-claude-hook"),
                usageRequestBudget: (capacity: 3, refillInterval: 30),
                supportsWindowWarming: true,
                credentialSharedAcrossSessions: true,
                credentialStore: .keychain,
                liveUsageFeed: .statusLine,
                requestRouter: RequestRouterSupport(
                    clientProtocol: .anthropicMessages,
                    settingsFile: ".claude/settings.json",
                    baseURLVariable: "ANTHROPIC_BASE_URL",
                    transcriptDirectory: "projects"
                ),
                sessionSlots: SessionSlotSupport(
                    directoryVariable: "CLAUDE_SECURESTORAGE_CONFIG_DIR",
                    keychainService: "Claude Code-credentials",
                    credentialVariables: ["CLAUDE_SECURESTORAGE_CONFIG_DIR", "CLAUDE_CONFIG_DIR",
                                          "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY"],
                    accountCommands: ["auth", "login", "logout", "setup-token"]
                ),
                supportsExtraUsage: true,
                reportsLimitResets: true,
                cliExecutableName: "claude",
                storageKey: "claude",
                shortBadge: "C",
                activityMetrics: [.turns, .activeTime, .linesChanged, .cost],
                planNames: ["max:default_claude_max_20x": "Ultra", "max:default_claude_max_5x": "Max"]
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
                pricingPrefixes: ["openai/"],
                pauseGate: PauseGateSupport(key: "codex", hookFile: ".codex/hooks.json", format: .jsonHooks,
                                            gateEvent: "PostToolUse", reply: nil),
                // Codex reads `openai_base_url`, a key before any table, as
                // the base URL of its built-in provider and sends its sign-in
                // there; its requests carry the session as
                // `prompt_cache_key`. Its gate hook has no timeout limit, so
                // the router need not hold its requests.
                requestHold: RequestHoldSupport(settingsFile: ".codex/config.toml", table: "",
                                                key: "openai_base_url", sessionField: "prompt_cache_key",
                                                defaultUpstream: "https://chatgpt.com/backend-api/codex",
                                                keyAbsentByDefault: true, holdsPausedRequests: false,
                                                bridgedProtocol: .anthropicMessages),
                lifecycleHooks: LifecycleHookSupport(events: ["SessionStart", "UserPromptSubmit", "Stop"],
                                                     hookFile: ".codex/hooks.json", format: .jsonHooks,
                                                     timeout: 5, bundledScript: "accountdock-codex-hook"),
                usageRequestBudget: (capacity: 3, refillInterval: 20),
                supportsWindowWarming: true,
                switchReachesRunningSessions: true,
                reportsLimitResets: true,
                cliExecutableName: "codex",
                storageKey: "codex",
                shortBadge: "X",
                activityMetrics: [.turns, .linesChanged, .cost],
                longWindowReportsLength: true
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
                pricingPrefixes: ["moonshot/", "kimi/"],
                // Kimi Code reports subscription model aliases. Its K2.8
                // preview has no published price yet, so it uses the K2.7
                // code model's rate, and K3.1 Pro uses K3's.
                pricingAliases: [
                    "k3": "moonshot/kimi-k3",
                    "k3.1-pro": "moonshot/kimi-k3",
                    "k3.1-pro-highspeed": "moonshot/kimi-k3",
                    "kimi-for-coding": "moonshot/kimi-k2.7-code",
                    "kimi-for-coding-highspeed": "moonshot/kimi-k2.7-code",
                ],
                // Kimi Code fires `PostToolUse` without waiting for it, but
                // waits for `PreToolUse`. It reads `message` only from a new
                // turn's hook, and refuses hook timeouts over 600 seconds.
                pauseGate: PauseGateSupport(key: "kimi", hookFile: ".kimi-code/config.toml", format: .tomlHooks,
                                            gateEvent: "PreToolUse", reply: .message, maximumHookTimeout: 600),
                // Kimi Code sends `prompt_cache_key` = its session ID, and
                // retries a timed-out or dropped request but not a spent quota.
                // It attaches its sign-in to the managed provider's requests
                // only while `base_url` names one of its own hosts.
                requestHold: RequestHoldSupport(settingsFile: ".kimi-code/config.toml", table: #"providers."managed:kimi-code""#,
                                                key: "base_url", sessionField: "prompt_cache_key",
                                                defaultUpstream: "https://api.kimi.ai/coding/v1",
                                                keepsCredentialAtRouter: false),
                lifecycleHooks: LifecycleHookSupport(events: ["UserPromptSubmit", "Stop"],
                                                     hookFile: ".kimi-code/config.toml", format: .tomlHooks,
                                                     timeout: 5, bundledScript: nil),
                usageRequestBudget: (capacity: 4, refillInterval: 15),
                supportsWindowWarming: true,
                routeTarget: .kimi,
                cliExecutableName: "kimi",
                storageKey: "kimi",
                longWindowStorageName: "Monthly",
                longShortLabel: "MO",
                shortBadge: "K"
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
                pricingPrefixes: ["gemini/", "google/"],
                storageKey: "gemini",
                shortBadge: "G"
            )
        }
    }

    /// A model name from the provider's records, as shown in activity.
    func displayModelName(_ raw: String) -> String {
        switch self {
        case .codex:
            raw.split(separator: "-")
                .map { part in part.lowercased() == "gpt" ? "GPT" : part.prefix(1).uppercased() + part.dropFirst() }
                .joined(separator: " ")
        case .kimi:
            "Kimi \(raw)"
        case .claudeCode, .gemini:
            raw
        }
    }

    static var implementedProviders: [AIProviderType] {
        allCases.filter { $0.capabilities.isImplemented }
    }

    /// The implemented providers' names as a list in prose, such as
    /// "Claude Code, Codex and Kimi", with `conjunction` before the last.
    static func implementedNames(conjunction: String = "and", short: Bool = false) -> String {
        let names = implementedProviders.map { short ? $0.capabilities.displayName : $0.rawValue }
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " \(conjunction) " + names[names.count - 1]
    }

    /// The provider whose requests AccountDock's router serves. The router
    /// is one local endpoint speaking one client protocol, so it serves one
    /// provider's CLI.
    static var routedProvider: AIProviderType? {
        implementedProviders.first { $0.capabilities.requestRouter != nil }
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
