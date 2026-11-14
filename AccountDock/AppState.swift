import SwiftUI
import Combine
import WidgetKit

private extension DateFormatter {
    static let accountDockDay: DateFormatter = {
        let formatter = DayKey.makeFormatter()
        return formatter
    }()
}

private let log = FileLog("AppState")

/// Central app state managing accounts, usage data, and active sessions.
@MainActor
final class AppState: ObservableObject {
    // MARK: - Published State

    @Published var accounts: [Account] = []
    @Published var accountUsage: [UUID: UsageAPIResponse] = [:]
    @Published private(set) var accountUsageUpdatedAt: [UUID: Date] = [:]
    /// When each account's usage was last read whole from its provider's own
    /// endpoint, and the long-window use it showed then. A passive reading
    /// carries the session and long windows only, so a model's own limit is
    /// as old as this however recent `accountUsageUpdatedAt` is;
    /// `wholeReadingIsDue` and `usageReadPriority` read it.
    var accountWholeReadings: [UUID: WholeReading] = [:]
    /// When each account's limit resets were last asked for, by
    /// `refreshLimitResetsIfDue`.
    var limitResetsCheckedAt: [UUID: Date] = [:]
    /// When `refreshLimitResetsIfDue` last read any account.
    var limitResetsLastReadAt: Date?
    @Published var usageSummary: UsageSummary = .empty
    @Published var recentActivity: [DailyActivity] = []
    @Published var activeSessions: [SessionInfo] = []
    /// Shows credential work under way (`credentialGate`); for the UI only.
    @Published var isLoading = false
    @Published var isLoggingIn = false
    @Published private(set) var loginDeadline: Date?
    @Published var errorMessage: String?
    @Published var claudeAvailable = false
    @Published var codexAvailable = false
    @Published var kimiAvailable = false
    @Published var lastUsageRefresh: Date?
    @Published var costSummary: CostSummary = .empty
    @Published var combinedTodayCost: Double = 0
    /// Cost and today's activity of every provider, in one shape; Claude
    /// Code's is built from `costSummary` and `activityStats`.
    @Published var providerCosts: [AIProviderType: CostParser.ProviderCostHistory] = [:]
    @Published var activityStats: ActivityStats = .empty
    @Published var failoverStatus: [AIProviderType: String] = [:]

    // Store errors as special struct to surface in UI
    struct UsageErrorState {
        let isExpired: Bool
        let isRateLimited: Bool
        let message: String
        let cachedAt: Date?

        init(isExpired: Bool, isRateLimited: Bool, message: String, cachedAt: Date? = nil) {
            self.isExpired = isExpired
            self.isRateLimited = isRateLimited
            self.message = message
            self.cachedAt = cachedAt
        }
    }
    
    @Published var accountUsageErrors: [UUID: UsageErrorState] = [:]

    // MARK: - Services

    let claudeService = ClaudeService.shared
    let codexService = CodexService.shared
    let kimiService = KimiService.shared
    private let statsParser = StatsParser.shared
    private let costParser = CostParser.shared
    private let activityParser = ActivityParser.shared
    let keychain = KeychainService.shared
    let failoverConfig = FailoverConfigStore.shared
    let failoverEvents = FailoverEventLog.shared
    let agentSuspension = AgentSuspensionService.shared

    private let accountsKey = "app.accountdock.accounts"
    private let usageSnapshotsKey = "app.accountdock.usageSnapshots"
    private let failoverRuntimeKey = "app.accountdock.failover.runtime"
    private var refreshTimer: Timer?
    var isRefreshing = false
    private var unavailablePlanCheckedAt: [UUID: Date] = [:]
    private let unavailablePlanCheckInterval: TimeInterval = 15 * 60
    var failoverMonitorTimer: Timer?
    private var usageResetTimer: Timer?
    var isMonitoringFailover = false
    /// Busy while a refresh, a switch, a sign-in or the adoption of a
    /// renewed live credential runs; `runQuotaCycle` and
    /// `adoptRenewedCredentials` do not start meanwhile.
    let credentialGate = CredentialOperationGate()
    /// Learned consumption rates per account, used to time readings and to
    /// project usage while a provider throttles its usage endpoint.
    var quotaTrends: [UUID: QuotaTrend] = [:]
    /// One shared request allowance per provider usage endpoint.
    let usageBudgets: [AIProviderType: UsageRequestBudget] = Dictionary(uniqueKeysWithValues:
        AIProviderType.allCases.compactMap { provider in
            provider.capabilities.usageRequestBudget.map {
                (provider, UsageRequestBudget(capacity: $0.capacity, refillInterval: $0.refillInterval))
            }
        }
    )
    /// Accounts whose stored credentials failed verification, and until when
    /// automatic failover must not choose them.
    var credentialQuarantine: [UUID: Date] = [:]
    /// When automatic or manual switching last moved work off an account.
    var lastSwitchedAway: [UUID: Date] = [:]
    /// Accounts whose usage endpoint asked to wait, and until when; any
    /// provider.
    var usageRetryAfter: [UUID: Date] = [:]
    var lastProfileCheck: [UUID: Date] = [:]
    /// Set while one failover evaluation, including any switch it performs,
    /// is in progress; a second evaluation would plan from the half-switched
    /// state and could start a competing switch.
    var isEvaluatingFailover = false
    /// Destinations whose automatic switch just failed, and until when they
    /// are not tried again.
    var switchFailureCooldown: [UUID: Date] = [:]
    private var loginAttemptID: UUID?
    var exhaustedFailoverAccounts: [AIProviderType: Set<UUID>] = [:]
    var lastAutomaticFailover: [AIProviderType: Date] = [:]
    /// Accounts that need signing in again: the provider rejected the
    /// sign-in AccountDock holds for them even after renewal. Failover
    /// leaves them out, and the account views show the re-authenticate
    /// prompt, until a reading or re-authentication succeeds.
    @Published var rejectedCredentialAccounts: Set<UUID> = []
    /// When each account's saved sign-in last passed the switch check,
    /// which renews it; read by `credentialIsUsable`.
    var credentialVerifiedAt: [UUID: Date] = [:]
    /// Each provider's live credential last seen, as a digest, and when it
    /// was last read; used by `adoptRenewedCredentials`.
    var liveCredentialDigests: [AIProviderType: String] = [:]
    var liveCredentialCheckedAt: [AIProviderType: Date] = [:]
    /// The account each provider's live credential belongs to, with the
    /// digest of the credential its owner was read for; read through
    /// `liveCredentialOwner`.
    var liveCredentialOwners: [AIProviderType: (digest: String, account: UUID)] = [:]
    /// Accounts whose slot a running session reads, kept by
    /// `maintainSessionSlots`; they are read and planned as in use.
    var slotServedAccounts: Set<UUID> = []
    /// Accounts whose access token a session slot holds, for running or new
    /// sessions; kept by `maintainSessionSlots` and read by
    /// `credentialIsUsable` and `renewSavedCredential`, because renewing
    /// such an account's saved copy revokes the token those slots hold.
    var slotCredentialAccounts: Set<UUID> = []
    /// The slot directory each running process reads, and the account
    /// serving each slot that has running sessions; read by
    /// `sessionAttribution` and `slotAccount(forSession:)`.
    var slotDirectoryByProcess: [Int32: String] = [:]
    var slotDirectoryServing: [String: UUID] = [:]
    /// Sessions `SessionPacer` moves to another account to balance load,
    /// applied to one-session slots by `maintainSessionSlots`.
    var slotSessionMoves: [String: UUID] = [:]
    /// Sessions `handleExternalRequests` was asked to move, by destination;
    /// `serveSessionSlots` moves each at once and forgets it.
    var requestedSlotMoves: [String: UUID] = [:]
    /// Guards `maintainSessionSlots` against running twice at once, and
    /// records a call that arrived meanwhile, which is then run after.
    var slotMaintenanceRunning = false
    var slotMaintenanceRequested = false
    /// What `serveSlot` last wrote to each slot directory and when it last
    /// read the slot's item back, so a slot already holding the credential
    /// is not read from the Keychain again on every quota cycle.
    var slotCredentialWritten: [String: (digest: String, at: Date)] = [:]
    /// Watches the one-session slot directory for a launcher's request for a
    /// spare; installed by `watchSpareRequests`.
    var spareRequestWatcher: DispatchSourceFileSystemObject?
    /// The renewal of the active account's live credential in progress, so
    /// concurrent callers of `claudeCredential` share one: a second renewal
    /// would present the refresh token the first has just replaced.
    var liveCredentialRenewal: Task<String?, Never>?
    /// When each one-session slot last moved to another account.
    var slotDirectoryMovedAt: [String: Date] = [:]
    /// Accounts a threshold or balancing switch left, whose running sessions
    /// stay on them until `moveSessionsOffLimitedAccounts` moves them.
    var sessionsLeftOn: [AIProviderType: Set<UUID>] = [:]
    /// A locally elapsed reset is useful for clearing a stale 100% display,
    /// but it is not proof that the provider has opened a new quota window.
    /// Never fail over to one of these accounts until a fresh API response
    /// confirms its post-reset capacity.
    var accountsAwaitingPostResetVerification: Set<UUID> = []
    private struct PendingWindowWarmup {
        var session = false
        var weekly = false
    }
    private var pendingWindowWarmups: [UUID: PendingWindowWarmup] = [:]
    private var warmupBootstrapsInFlight: Set<String> = []
    private var warmupRetryAttempts: [UUID: Int] = [:]
    private var accountWarmupsInFlight: Set<UUID> = []
    struct PendingResetRecovery {
        let accountID: UUID
        let resetDate: Date
    }
    var pendingResetRecovery: [AIProviderType: PendingResetRecovery] = [:]
    /// The account that was active when a provider's agents were paused, its
    /// usage at that moment and the burn rate that justified the pause.
    struct SuspensionContext {
        let accountID: UUID
        let usage: UsageAPIResponse?
        let sessionBurnPerHour: Double
        let weeklyBurnPerHour: Double
    }
    var suspensionContexts: [AIProviderType: SuspensionContext] = [:]
    /// Sessions paused because every account reached its limit, as shown in
    /// the usage view.
    struct AgentPauseStatus: Equatable {
        var sessions: Int
        /// Paused sessions currently waiting inside the pause hook.
        var waiting: Int
        /// Processes stopped because they cannot be paused through a hook.
        var stoppedProcesses: Int
        var since: Date
        var resumeAt: Date?
        var reason: String
        /// Started by the user rather than at a limit.
        var manual = false
    }
    @Published var agentPauseStatus: [AIProviderType: AgentPauseStatus] = [:]
    /// Set when the user resumes paused sessions themselves; no new pause
    /// starts for the provider before this time.
    var pauseOverrideUntil: [AIProviderType: Date] = [:]
    var pauseGateSynchronizedAt: Date?
    var hookCheckDone = false
    /// Set once the user has been told the saved accounts wait on a
    /// Keychain access prompt.
    var keychainWaitNoted = false
    let launchedAt = Date()
    /// Claude Code requests currently served by Kimi through the router.
    struct RoutedStatus: Equatable {
        var since: Date
        var target: String
        var model: String
        var backingAccount: String
        var resumeAt: Date?
        var turns = 0
    }
    /// Sessions each account served through the router in the last ten
    /// minutes; one input to `accountSessions`.
    @Published var routedSessions: [UUID: Set<String>] = [:]
    /// Every provider's running sessions, from their lifecycle records.
    @Published var liveSessions: [AIProviderType: [AgentSession]] = [:]
    /// The running sessions each account serves, shown on the account cards.
    @Published var accountSessions: [UUID: Set<String>] = [:]
    /// The name each session shows for itself, from its status line
    /// (`ingestPassiveTelemetry`); `sessionSummary` lists them when the
    /// pointer rests on an account card's session count.
    @Published var sessionNames: [String: String] = [:]
    /// Sessions whose last request the provider refused at a usage limit,
    /// from their transcripts (`ingestTranscriptRequests`), until a later
    /// request of theirs is served. The account cards mark them, since such
    /// a session stops until someone tells it to go on.
    @Published var sessionRefusals: [String: SessionRefusal] = [:]
    var routedSessionSeen: [String: (account: UUID, at: Date)] = [:]
    /// The account each session's own status line last named by its reset
    /// times, kept by `ingestPassiveTelemetry` for `sessionAttribution`.
    var sessionServedBy: [String: SessionAttribution.Observation] = [:]
    /// When each provider's running sessions were last told to read the
    /// live credential again, for `sessionAttribution`.
    var sessionsSignalledAt: [AIProviderType: Date] = [:]
    /// Credential fingerprint to account, for usage the router observed.
    var credentialFingerprints: [String: UUID] = [:]
    /// When each credential fingerprint was last seen as an account's token.
    var credentialFingerprintSeen: [String: Date] = [:]
    /// Accounts the router found refused at their plan limit, and until when.
    var routerRefusedUntil: [UUID: Date] = [:]
    /// Route targets the router found refusing at their plan limit, by
    /// target id, until when; `routeTargetAccount` treats them as full.
    var routeTargetRefusedUntil: [String: Date] = [:]
    /// What routed tokens cost each route target, by target id.
    var routeTargetCosts: [String: RouteTargetCostModel] = [:]
    /// Requests the router served in the last hour, any backend.
    var recentRouterRequests: [RecentRouterRequest] = []
    /// Why each route target was last judged unable to take the demand.
    @Published var routeTargetVerdicts: [String: RouteCapacity.Verdict] = [:]
    var routerUsageApplied: [String: Date] = [:]
    @Published var routedStatus: [AIProviderType: RoutedStatus] = [:]
    /// Set when the user returns requests to Claude themselves.
    var routeOverrideUntil: [AIProviderType: Date] = [:]
    var routerEventOffset: UInt64 = 0
    var routerCheckedAt: Date?
    var lastRouterFailureNote: Date?
    var lastRouterHoldNote: Date?
    var routerPoolMembers: [RouterPoolMember] = []
    /// Recent token use of each routed session, for pacing sessions.
    var sessionRates = SessionRates()
    /// What the one-hour prompt cache the router asks for saved and cost.
    @Published var cacheExtension = CacheExtensionLedger()
    /// Sessions the router moves at their next turn, from `SessionPacer`.
    var routerSessionMoves: [String: UUID] = [:]
    /// Accounts currently giving sessions up to stay within their windows.
    var pacingShedding: Set<UUID> = []
    /// The same for one model's allowance, as "account|model", so
    /// `AppState.paced` reports each once.
    var pacingScopedShedding: Set<String> = []
    /// Paused sessions AccountDock let continue during the current pause,
    /// by provider and session.
    var sessionAdmissions: [AIProviderType: [String: SessionAdmission]] = [:]
    /// Sessions the user resumed during the current pause while the account
    /// serving them had room: the account each was on, by provider and
    /// session. Each is held again when that account nears its limit.
    var userResumes: [AIProviderType: [String: UUID]] = [:]
    /// The reset each provider's last account hold waited for, so one reset
    /// holds its account's sessions once.
    var accountHoldResets: [AIProviderType: Date] = [:]

    struct SessionAdmission: Equatable {
        let session: String
        /// The account the session was placed on.
        let account: UUID
        let at: Date
        /// It runs on what its account would leave unused by the reset
        /// (`SessionPacer.Placement.surplus`).
        var surplus = false
    }
    /// Why the router could not be installed, shown in Failover settings.
    @Published var routerProblem: String?
    var credentialFingerprintsBuiltAt: Date?
    var turnCostModel = TurnCostModel()
    var demandForecasts: [AIProviderType: DemandForecast] = [:]
    var learningSavedAt: Date?
    /// Model the provider's sessions were last seen using, from the Claude
    /// Code status line; selects which model-scoped weekly limit applies.
    var workloadModels: [AIProviderType: (model: String, seenAt: Date)] = [:]
    /// The model each session last asked, from its status line and its
    /// transcript; kept by `noteSessionModel` and read by `sessionModel`, so
    /// a session is judged against the limits of the model it uses.
    var sessionModels: [String: (model: String, seenAt: Date)] = [:]
    /// Sessions already reported as having no account left with allowance
    /// for their model, so `serveSessionSlots` says it once per session.
    var sessionsWithoutModelRoom: Set<String> = []
    /// The destination of the switch last withheld for a locked active
    /// account, so `performAutomaticSwitch` reports each once.
    var lockedSwitchNoted: [AIProviderType: UUID] = [:]
    /// The digest of each account's saved sign-in the provider confirmed as
    /// that account's (`savedCopyIsOwn`).
    var savedCopyVerified: [UUID: String] = [:]
    /// Providers with a switch in progress; `switchTo` runs one at a time
    /// for each, since two at once write the CLI's credential over each
    /// other.
    var switchesInFlight: Set<AIProviderType> = []
    /// When the user last switched each provider's account themselves;
    /// `performAutomaticSwitch` leaves that choice alone for
    /// `userSwitchHold`.
    var userSwitchedAt: [AIProviderType: Date] = [:]
    /// When failover switched away from each account, for
    /// `FailoverPlanner.isSwitchLoop`.
    var automaticSwitchesAway: [UUID: [Date]] = [:]

    // MARK: - Initialization

    init() {
        ProviderVisibility.migrate()
        log.info("[init] Loading accounts from UserDefaults...")
        keychain.preloadBackupStore()
        loadAccounts()
        loadUsageSnapshots()
        loadLearning()
        // Older builds stored permanent per-account warm-up markers. They
        // incorrectly suppressed every later reset, so the countdown snapshot
        // is now the durable duplicate guard and these markers are retired.
        UserDefaults.standard.removeObject(forKey: "app.accountdock.warmup.bootstrap")
        reconcilePassedUsageResets()
        loadFailoverRuntime()
        credentialGate.onBusyChange = { [weak self] busy in self?.isLoading = busy }
        log.info("[init] Loaded \(self.accounts.count) accounts, active: \(self.accounts.filter(\.isActive).count)")
    }

    // MARK: - Refresh

    /// Today's API-equivalent cost of one provider.
    func todayCost(for provider: AIProviderType) -> Double {
        providerCosts[provider]?.dailyCosts[DateFormatter.accountDockDay.string(from: Date())] ?? 0
    }

    /// Per-day API-equivalent cost of one provider, keyed by `yyyy-MM-dd`.
    func dailyCosts(for provider: AIProviderType) -> [String: Double] {
        providerCosts[provider]?.dailyCosts ?? [:]
    }

    /// Today's cost per model for one provider.
    func todayModelCosts(for provider: AIProviderType) -> [String: Double] {
        providerCosts[provider]?.todayModelCosts ?? [:]
    }

    /// Today's model responses (Claude Code: turns) per model.
    func todayModelActivity(for provider: AIProviderType) -> [String: Int] {
        providerCosts[provider]?.todayModelActivity ?? [:]
    }

    /// Today's turns: Claude Code's conversation turns, and the model
    /// responses other providers record.
    func todayTurns(for provider: AIProviderType) -> Int {
        providerCosts[provider]?.todayTurns ?? 0
    }

    /// Lines the provider's sessions changed today.
    func todayLinesChanged(for provider: AIProviderType) -> Int {
        providerCosts[provider]?.todayLinesChanged ?? 0
    }

    /// Input, output and cache tokens the provider's sessions used today.
    func todayTokens(for provider: AIProviderType) -> Int {
        providerCosts[provider]?.todayTokens ?? 0
    }

    /// Per-day input, output and cache tokens of one provider, keyed by
    /// `yyyy-MM-dd`.
    func dailyTokens(for provider: AIProviderType) -> [String: Int] {
        providerCosts[provider]?.dailyTokens ?? [:]
    }

    /// Today's input, output and cache tokens per model for one provider.
    func todayModelTokens(for provider: AIProviderType) -> [String: Int] {
        providerCosts[provider]?.todayModelTokens ?? [:]
    }

    /// Today's totals across the providers not in `hidden`: the figures the
    /// usage dashboard, the cost tab, the menu bar and the widget show.
    func todaySummary(hidden: Set<AIProviderType> = ProviderVisibility.storedHidden()) -> TodaySummary {
        var days: [AIProviderType: TodaySummary.ProviderDay] = [:]
        for (provider, history) in providerCosts {
            days[provider] = TodaySummary.ProviderDay(
                cost: todayCost(for: provider),
                tokens: history.todayTokens,
                turns: history.todayTurns,
                linesChanged: history.todayLinesChanged,
                activeMinutes: history.todayActiveMinutes ?? 0,
                modelActivity: history.todayModelActivity
            )
        }
        return TodaySummary.make(days: days, hidden: hidden)
    }

    /// Sessions with activity today: the usage records' count, or the
    /// sessions the provider's lifecycle hooks recorded today.
    func todaySessions(for provider: AIProviderType) -> Int {
        let startOfDay = Calendar.current.startOfDay(for: Date())
        let recorded = AgentSessions.records(provider).values.filter { ($0.observedAt ?? .distantPast) >= startOfDay }.count
        return max(providerCosts[provider]?.todaySessions ?? 0, recorded)
    }

    func refresh(forceUnavailablePlanCheck: Bool = false) async {
        guard !isLoggingIn else {
            log.info("[refresh] Skipping: login in progress")
            return
        }
        guard !isRefreshing else {
            log.debug("[refresh] Skipping: refresh already in progress")
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        await credentialGate.run { await self.performRefresh(forceUnavailablePlanCheck: forceUnavailablePlanCheck) }
    }

    private func performRefresh(forceUnavailablePlanCheck: Bool) async {
        errorMessage = nil

        // Index local usage concurrently with provider refreshes. SQLite writes
        // are isolated in UsageIndex, so a slow network or Keychain prompt
        // cannot prevent local history from becoming available.
        async let usageIndexRefresh: Void = UsageIndex.shared.refreshFromFilesystem()

        claudeAvailable = await claudeService.isClaudeAvailable()
        codexAvailable = await codexService.isAvailable()
        kimiAvailable = kimiService.isAvailable()
        log.info("[refresh] Claude available: \(self.claudeAvailable)")

        if claudeAvailable {
            do {
                var status = try await claudeService.getAuthStatus()
                if !status.loggedIn,
                   let expected = activeAccount(for: .claudeCode) {
                    log.warning("[refresh] Live Claude credentials are rejected; restoring the selected profile from AccountDock")
                    status = try await claudeService.switchAccount(from: expected, to: expected)
                }
                updateActiveAccount(from: status)
            } catch {
                log.error("[refresh] getAuthStatus failed: \(error.localizedDescription)")
                errorMessage = error.localizedDescription
            }
        }
        updateActiveCodexAccount()

        // Readings the agents already recorded locally come first; endpoint
        // requests are then only made for accounts those readings do not cover.
        await ingestPassiveTelemetry()
        await fetchAllAccountUsage(forceUnavailablePlanCheck: forceUnavailablePlanCheck)
        await evaluateFailover()
        lastUsageRefresh = Date()

        usageSummary = statsParser.getUsageSummary()
        recentActivity = statsParser.getRecentActivity(days: 7)
        activeSessions = statsParser.getActiveSessions()

        await usageIndexRefresh
        let cost = await costParser.getCostSummary()
        var histories: [AIProviderType: CostParser.ProviderCostHistory] = [:]
        for provider in AIProviderType.implementedProviders {
            if let history = await costParser.costHistory(for: provider) { histories[provider] = history }
        }
        let activity = await activityParser.getTodayStats()
        histories[.claudeCode] = CostParser.ProviderCostHistory(
            claude: cost, activity: activity, today: DateFormatter.accountDockDay.string(from: Date())
        )
        costSummary = cost
        activityStats = activity
        providerCosts = histories
        combinedTodayCost = AIProviderType.implementedProviders.reduce(0) { $0 + todayCost(for: $1) }

        log.info("[refresh] Usage: weekly=\(self.usageSummary.weeklyMessages) msgs, \(self.activeSessions.count) active sessions, today=$\(String(format: "%.2f", self.combinedTodayCost)) turns=\(activity.conversationTurns)")

        updateWidgetData()
    }

    func startAutoRefresh(interval: TimeInterval = 300) {
        stopAutoRefresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.refresh()
            }
        }
        // Full refreshes read only the accounts whose readings are due. The
        // quota cycle is a one-shot adaptive timer that follows the active
        // accounts more closely as they approach a limit.
        scheduleQuotaCycle(after: 5)
        Task.detached(priority: .utility) { ClaudeStatusLineTelemetry.synchronize() }
        // Offered once per launch, after the status line has been applied.
        if !hookCheckDone {
            hookCheckDone = true
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard let self else { return }
                AgentHookInstaller.promptIfMissing(pausingProviders: self.pausingProviders)
            }
        }
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        failoverMonitorTimer?.invalidate()
        failoverMonitorTimer = nil
        usageResetTimer?.invalidate()
        usageResetTimer = nil
    }

    // MARK: - Account Management

    private func beginLoginAttempt() -> UUID? {
        guard !isLoggingIn else {
            errorMessage = "Another browser login is already in progress."
            return nil
        }
        let id = UUID()
        loginAttemptID = id
        loginDeadline = Date().addingTimeInterval(LoginProcessRunner.timeout)
        isLoggingIn = true
        errorMessage = nil
        return id
    }

    private func finishLoginAttempt(_ id: UUID) {
        guard loginAttemptID == id else { return }
        loginAttemptID = nil
        loginDeadline = nil
        isLoggingIn = false
    }

    /// Type-erased boundary for providers whose CLI credentials can live in a
    /// managed location. AppState owns the lifecycle once; each service only
    /// supplies its storage/authentication mechanics.
    private struct ManagedProviderIdentity {
        let identifier: String
        let displayName: String
        let accountMetadata: String?
        let planType: String?
        let credentialLocation: String
    }

    private enum ManagedProviderError: LocalizedError {
        case duplicate(String)

        var errorDescription: String? {
            switch self {
            case .duplicate(let providerName):
                "This \(providerName) account is already managed."
            }
        }
    }

    private struct ManagedProviderAdapter {
        let provider: AIProviderType
        let isAvailable: Bool
        let unavailableError: Error
        let login: () async throws -> ManagedProviderIdentity
        let captureCurrent: () async throws -> ManagedProviderIdentity
        let activate: (String) throws -> Void
        let remove: (String) throws -> Void
    }

    private func managedProviderAdapter(for provider: AIProviderType) -> ManagedProviderAdapter? {
        switch provider {
        case .codex:
            return ManagedProviderAdapter(
                provider: .codex,
                isAvailable: codexAvailable,
                unavailableError: CodexServiceError.binaryNotFound,
                login: { [codexService] in
                    let (identity, location) = try await codexService.loginManagedAccount()
                    return ManagedProviderIdentity(
                        identifier: identity.email,
                        displayName: identity.displayName,
                        accountMetadata: identity.accountID,
                        planType: identity.planType,
                        credentialLocation: location
                    )
                },
                captureCurrent: { [codexService] in
                    let (identity, location) = try codexService.captureSystemAccount()
                    return ManagedProviderIdentity(
                        identifier: identity.email,
                        displayName: identity.displayName,
                        accountMetadata: identity.accountID,
                        planType: identity.planType,
                        credentialLocation: location
                    )
                },
                activate: { [codexService] in try codexService.promoteToSystem(homePath: $0) },
                remove: { [codexService] in try codexService.removeManagedAccount(homePath: $0) }
            )
        case .kimi:
            return ManagedProviderAdapter(
                provider: .kimi,
                isAvailable: kimiAvailable,
                unavailableError: KimiServiceError.binaryNotFound,
                login: { [kimiService] in
                    let (identity, location) = try await kimiService.loginManagedAccount()
                    return ManagedProviderIdentity(
                        identifier: identity.identifier,
                        displayName: identity.displayName,
                        accountMetadata: nil,
                        planType: identity.planType,
                        credentialLocation: location
                    )
                },
                captureCurrent: { [kimiService] in
                    let (identity, location) = try await kimiService.captureCurrentAccount()
                    return ManagedProviderIdentity(
                        identifier: identity.identifier,
                        displayName: identity.displayName,
                        accountMetadata: nil,
                        planType: identity.planType,
                        credentialLocation: location
                    )
                },
                activate: { [kimiService] in try kimiService.promoteToSystem(location: $0) },
                remove: { [kimiService] in try kimiService.removeManagedAccount(location: $0) }
            )
        default:
            return nil
        }
    }

    private func registerManagedAccount(
        _ identity: ManagedProviderIdentity,
        using adapter: ManagedProviderAdapter,
        makeActive: Bool
    ) throws {
        if accounts.contains(where: {
            $0.provider == adapter.provider &&
                $0.email.caseInsensitiveCompare(identity.identifier) == .orderedSame
        }) {
            try? adapter.remove(identity.credentialLocation)
            throw ManagedProviderError.duplicate(adapter.provider.capabilities.displayName)
        }
        if makeActive {
            try adapter.activate(identity.credentialLocation)
            for index in accounts.indices where accounts[index].provider == adapter.provider {
                accounts[index].isActive = false
            }
        }
        accounts.append(Account(
            email: identity.identifier,
            displayName: identity.displayName,
            provider: adapter.provider,
            orgName: identity.accountMetadata,
            subscriptionType: identity.planType,
            isActive: makeActive,
            credentialLocation: identity.credentialLocation
        ))
        saveAccounts(refreshWidget: true)
        log.info("[provider-auth] Imported \(adapter.provider.rawValue) account; total=\(accounts.count)")
    }

    private func loginNewManagedAccount(provider: AIProviderType) async {
        guard let adapter = managedProviderAdapter(for: provider) else { return }
        guard adapter.isAvailable else {
            errorMessage = adapter.unavailableError.localizedDescription
            return
        }
        guard let loginID = beginLoginAttempt() else { return }
        defer { finishLoginAttempt(loginID) }
        do {
            log.info("[provider-auth] Starting isolated \(provider.rawValue) login")
            let identity = try await adapter.login()
            try registerManagedAccount(identity, using: adapter, makeActive: true)
        } catch {
            guard loginAttemptID == loginID else { return }
            errorMessage = error.localizedDescription
            log.error("[provider-auth] \(provider.rawValue) login failed: \(error.localizedDescription)")
        }
    }

    private func captureCurrentManagedAccount(provider: AIProviderType) async {
        guard let adapter = managedProviderAdapter(for: provider) else { return }
        do {
            try registerManagedAccount(try await adapter.captureCurrent(), using: adapter, makeActive: true)
        } catch {
            errorMessage = error.localizedDescription
            log.error("[provider-auth] \(provider.rawValue) capture failed: \(error.localizedDescription)")
        }
    }

    private func reauthenticateManagedAccount(_ account: Account) async {
        guard let adapter = managedProviderAdapter(for: account.provider),
              let loginID = beginLoginAttempt() else { return }
        defer { finishLoginAttempt(loginID) }
        do {
            let identity = try await adapter.login()
            guard identity.identifier.caseInsensitiveCompare(account.email) == .orderedSame else {
                try? adapter.remove(identity.credentialLocation)
                throw KimiServiceError.requestFailed(
                    "Logged in as \(identity.identifier), expected \(account.email)."
                )
            }
            guard let index = accounts.firstIndex(where: { $0.id == account.id }) else {
                try? adapter.remove(identity.credentialLocation)
                return
            }
            let oldLocation = accounts[index].credentialLocation
            accounts[index].credentialLocation = identity.credentialLocation
            accounts[index].displayName = identity.displayName
            accounts[index].orgName = identity.accountMetadata
            accounts[index].subscriptionType = identity.planType
            if account.isActive { try adapter.activate(identity.credentialLocation) }
            credentialQuarantine[account.id] = nil
            rejectedCredentialAccounts.remove(account.id)
            saveAccounts(refreshWidget: true)
            if let oldLocation, oldLocation != identity.credentialLocation {
                try? adapter.remove(oldLocation)
            }
            log.info("[provider-auth] Re-authenticated \(account.provider.rawValue) account")
        } catch {
            guard loginAttemptID == loginID else { return }
            errorMessage = error.localizedDescription
            log.error("[provider-auth] \(account.provider.rawValue) re-authentication failed: \(error.localizedDescription)")
        }
    }

    func cancelLogin() {
        guard isLoggingIn else { return }
        loginAttemptID = nil
        loginDeadline = nil
        isLoggingIn = false
        claudeService.cancelLogin()
        codexService.cancelLogin()
        kimiService.cancelLogin()
        errorMessage = "Browser login cancelled. You can try again."
        log.info("[login] User cancelled browser login")
    }

    /// The provider's active account, read from the accounts' own flags.
    func activeAccount(for provider: AIProviderType) -> Account? {
        accounts.active(for: provider)
    }

    func addAccount() async {
        log.info("[addAccount] Starting add current account flow...")
        guard claudeAvailable else {
            errorMessage = String(localized: "Claude CLI not found", bundle: L10n.bundle)
            log.error("[addAccount] Aborted: Claude CLI not found")
            return
        }

        do {
            let status = try await claudeService.getAuthStatus()
            guard status.loggedIn, let email = status.email else {
                errorMessage = String(localized: "Not logged in to Claude. Run 'claude auth login' first.", bundle: L10n.bundle)
                log.error("[addAccount] Aborted: not logged in")
                return
            }
            log.info("[addAccount] Current auth: logged in, sub=\(status.subscriptionType ?? "nil")")

            if accounts.contains(where: { $0.provider == .claudeCode && $0.matches(email: email) }) {
                errorMessage = String(localized: "Account already exists", bundle: L10n.bundle)
                log.warning("[addAccount] Aborted: duplicate account")
                return
            }

            var account = Account(
                email: email,
                displayName: status.orgName ?? email,
                provider: .claudeCode,
                orgName: status.orgName,
                subscriptionType: status.subscriptionType,
                isActive: !accounts.contains { $0.provider == .claudeCode }
            )
            log.info("[addAccount] Created account model, id=\(account.id)")

            log.info("[addAccount] Capturing token from keychain...")
            let captured = claudeService.captureCurrentCredentials(
                forAccountId: account.id.uuidString,
                expectedEmail: account.email
            )
            if !captured {
                errorMessage = String(localized: "Could not capture auth token from keychain", bundle: L10n.bundle)
                log.error("[addAccount] Token capture failed!")
                return
            }
            log.info("[addAccount] Token captured successfully")

            if !accounts.contains(where: { $0.provider == .claudeCode }) {
                account.isActive = true
                log.info("[addAccount] First account, setting as active")
            }

            accounts.append(account)
            saveAccounts()
            log.info("[addAccount] Account saved. Total accounts: \(self.accounts.count)")
        } catch {
            errorMessage = error.localizedDescription
            log.error("[addAccount] Error: \(error.localizedDescription)")
        }
    }

    func loginNewAccount() async {
        log.info("[loginNewAccount] ===== Starting login new account flow =====")
        guard claudeAvailable else {
            errorMessage = String(localized: "Claude CLI not found", bundle: L10n.bundle)
            log.error("[loginNewAccount] Aborted: Claude CLI not found")
            return
        }

        guard let loginID = beginLoginAttempt() else { return }
        defer { finishLoginAttempt(loginID) }

        do {
            // 1. Back up current account (token + oauthAccount) before login overwrites them
            if let current = activeAccount(for: .claudeCode) {
                log.info("[loginNewAccount] Step 1: Backing up current account (\(current.email))...")
                let backed = claudeService.captureCurrentCredentials(
                    forAccountId: current.id.uuidString,
                    expectedEmail: current.email
                )
                log.info("[loginNewAccount] Step 1: Backup result: \(backed)")
            } else {
                log.info("[loginNewAccount] Step 1: No active account, skipping backup")
            }

            // 2. Run `claude auth login` — this overwrites both keychain and ~/.claude.json
            log.info("[loginNewAccount] Step 2: Running `claude auth login`...")
            try await claudeService.login()
            log.info("[loginNewAccount] Step 2: Login process completed")

            // 3. Read the new identity from ~/.claude.json
            log.info("[loginNewAccount] Step 3: Reading post-login state...")
            let status = try await claudeService.getAuthStatus()
            guard status.loggedIn, let email = status.email else {
                errorMessage = String(localized: "Login did not complete", bundle: L10n.bundle)
                log.error("[loginNewAccount] Step 3: Not logged in after login!")
                return
            }
            log.info("[loginNewAccount] Step 3: Logged in as \(email)")

            // 4. Check for duplicate — if exists, just refresh its backup
            if let existing = accounts.firstIndex(where: { $0.provider == .claudeCode && $0.matches(email: email) }) {
                log.info("[loginNewAccount] Step 4: Account already exists, refreshing backup")
                _ = claudeService.captureCurrentCredentials(
                    forAccountId: accounts[existing].id.uuidString,
                    expectedEmail: accounts[existing].email
                )
                errorMessage = String(localized: "Account already exists - credentials refreshed", bundle: L10n.bundle)
                return
            }

            // 5. Create new account and capture credentials (token + oauthAccount)
            let account = Account(
                email: email,
                displayName: status.orgName ?? email,
                provider: .claudeCode,
                orgName: status.orgName,
                subscriptionType: status.subscriptionType,
                isActive: true
            )
            log.info("[loginNewAccount] Step 5: Created account, id=\(account.id)")

            let captured = claudeService.captureCurrentCredentials(
                forAccountId: account.id.uuidString,
                expectedEmail: account.email
            )
            if !captured {
                errorMessage = String(localized: "Could not capture credentials", bundle: L10n.bundle)
                log.error("[loginNewAccount] Step 5: Capture failed!")
                return
            }

            // 6. Mark new account as active
            accounts.append(account)
            accounts.makeActive(account.id)
            saveAccounts()
            log.info("[loginNewAccount] Step 6: New account active. Total: \(self.accounts.count)")

            finishLoginAttempt(loginID)
            await refresh()
            log.info("[loginNewAccount] ===== Login completed =====")
        } catch {
            guard loginAttemptID == loginID else { return }
            errorMessage = error.localizedDescription
            log.error("[loginNewAccount] Error: \(error.localizedDescription)")
        }
    }

    func updateAccountLabel(_ account: Account, label: String?) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        let trimmed = label?.trimmingCharacters(in: .whitespaces)
        accounts[index].customLabel = (trimmed?.isEmpty == true) ? nil : trimmed
        saveAccounts()
        updateWidgetData()
        log.info("[updateAccountLabel] Set label for \(account.email): \(trimmed ?? "nil")")
    }

    /// Changes display order only. Failover maintains its own independent
    /// account order in `FailoverConfigStore`.
    func moveAccount(from sourceID: UUID, to destinationID: UUID) {
        guard sourceID != destinationID,
              let sourceIndex = accounts.firstIndex(where: { $0.id == sourceID }),
              let destinationIndex = accounts.firstIndex(where: { $0.id == destinationID }),
              accounts[sourceIndex].provider == accounts[destinationIndex].provider
        else { return }

        let account = accounts.remove(at: sourceIndex)
        let insertionIndex = destinationIndex
        accounts.insert(account, at: insertionIndex)
        saveAccounts(refreshWidget: true)
        log.info("[account-order] Moved account \(sourceID.uuidString) to display index \(insertionIndex)")
    }

    /// Moves an entire provider section while preserving account order inside each section.
    func moveProvider(from source: AIProviderType, to destination: AIProviderType) {
        guard source != destination else { return }

        var order: [AIProviderType] = []
        for account in accounts where !order.contains(account.provider) {
            order.append(account.provider)
        }
        guard let sourceIndex = order.firstIndex(of: source),
              let destinationIndex = order.firstIndex(of: destination)
        else { return }

        let provider = order.remove(at: sourceIndex)
        order.insert(provider, at: destinationIndex)
        accounts = order.flatMap { provider in
            accounts.filter { $0.provider == provider }
        }
        saveAccounts(refreshWidget: true)
        log.info("[account-order] Moved provider \(source.rawValue) to section index \(destinationIndex)")
    }

    /// Removes an account. An active one first hands its provider's sign-in
    /// to `successor(of:)` through `switchTo`, while it is still there to be
    /// switched away from. When no account can take over, or the switch does
    /// not complete, the provider is left with no active account: the CLI
    /// stays signed in to the account removed, and `updateActiveAccount`
    /// names an active account again once the CLI is signed in to one held
    /// here.
    func removeAccount(_ account: Account) {
        guard account.isActive,
              let next = Self.successor(of: account, among: accounts, needsSignIn: needsSignIn) else {
            finishRemoving(account)
            return
        }
        log.info("[removeAccount] Removing the active account; switching to another first")
        Task {
            await switchTo(next)
            finishRemoving(account)
        }
    }

    /// The account that becomes active when `account` is removed: another
    /// of its provider that can run the provider's workloads and does not
    /// need signing in, in the order the accounts are kept.
    nonisolated static func successor(of account: Account, among accounts: [Account],
                                      needsSignIn: (Account) -> Bool) -> Account? {
        accounts.first {
            $0.provider == account.provider && $0.id != account.id && $0.supportsProviderWorkloads && !needsSignIn($0)
        }
    }

    private func finishRemoving(_ account: Account) {
        log.info("[removeAccount] Removing account \(account.id)")
        if let adapter = managedProviderAdapter(for: account.provider) {
            if let location = account.credentialLocation { try? adapter.remove(location) }
        } else {
            keychain.removeAccountBackup(forAccountId: account.id.uuidString)
        }
        accounts.removeAll { $0.id == account.id }
        forgetAccount(account.id)
        saveUsageSnapshots()
        saveFailoverRuntime()
        saveAccounts()
        log.info("[removeAccount] Done. Remaining accounts: \(self.accounts.count)")
    }

    /// Drops everything AccountDock keeps per account for `id`, for
    /// `removeAccount`: readings, learning, credential state, failover and
    /// pause state, slots, router and session maps. Entries keyed by
    /// session or slot that name the account go too.
    func forgetAccount(_ id: UUID) {
        accountUsage[id] = nil
        accountUsageUpdatedAt[id] = nil
        accountWholeReadings[id] = nil
        accountUsageErrors[id] = nil
        limitResetsCheckedAt[id] = nil
        unavailablePlanCheckedAt[id] = nil
        quotaTrends[id] = nil
        credentialQuarantine[id] = nil
        lastSwitchedAway[id] = nil
        usageRetryAfter[id] = nil
        lastProfileCheck[id] = nil
        switchFailureCooldown[id] = nil
        credentialVerifiedAt[id] = nil
        routerRefusedUntil[id] = nil
        savedCopyVerified[id] = nil
        automaticSwitchesAway[id] = nil
        pendingWindowWarmups[id] = nil
        warmupRetryAttempts[id] = nil
        routedSessions[id] = nil
        accountSessions[id] = nil
        rejectedCredentialAccounts.remove(id)
        slotServedAccounts.remove(id)
        slotCredentialAccounts.remove(id)
        accountsAwaitingPostResetVerification.remove(id)
        accountWarmupsInFlight.remove(id)
        pacingShedding.remove(id)
        pacingScopedShedding = pacingScopedShedding.filter { !$0.hasPrefix(id.uuidString + "|") }
        for provider in exhaustedFailoverAccounts.keys { exhaustedFailoverAccounts[provider]?.remove(id) }
        for provider in sessionsLeftOn.keys { sessionsLeftOn[provider]?.remove(id) }
        liveCredentialOwners = liveCredentialOwners.filter { $0.value.account != id }
        lockedSwitchNoted = lockedSwitchNoted.filter { $0.value != id }
        pendingResetRecovery = pendingResetRecovery.filter { $0.value.accountID != id }
        suspensionContexts = suspensionContexts.filter { $0.value.accountID != id }
        userResumes = userResumes.mapValues { $0.filter { $0.value != id } }
        sessionAdmissions = sessionAdmissions.mapValues { $0.filter { $0.value.account != id } }
        slotDirectoryServing = slotDirectoryServing.filter { $0.value != id }
        slotSessionMoves = slotSessionMoves.filter { $0.value != id }
        requestedSlotMoves = requestedSlotMoves.filter { $0.value != id }
        routerSessionMoves = routerSessionMoves.filter { $0.value != id }
        routedSessionSeen = routedSessionSeen.filter { $0.value.account != id }
        sessionServedBy = sessionServedBy.filter { $0.value.account != id }
        routerPoolMembers.removeAll { $0.accountID == id.uuidString }
        sessionRates.entries = sessionRates.entries.filter { $0.value.account != id }
        let fingerprints = credentialFingerprints.filter { $0.value == id }.keys
        for fingerprint in fingerprints {
            credentialFingerprints[fingerprint] = nil
            credentialFingerprintSeen[fingerprint] = nil
        }
        turnCostModel.accountPercentPerMillion?[id] = nil
        turnCostModel.pending[id] = nil
        turnCostModel.lastSession[id] = nil
        turnCostModel.sessionAccount = turnCostModel.sessionAccount.filter { $0.value != id }
    }

    func switchTo(_ account: Account, refreshAfter: Bool = true) async {
        guard switchesInFlight.insert(account.provider).inserted else {
            log.info("[switchTo] A \(account.provider.rawValue) switch is in progress; this one is not started")
            return
        }
        defer { switchesInFlight.remove(account.provider) }
        if refreshAfter { userSwitchedAt[account.provider] = Date() }
        await performSwitch(to: account, refreshAfter: refreshAfter)
        // A switch the user made shows the account as the provider reports
        // it now, whatever was last known of it.
        if refreshAfter, let active = activeAccount(for: account.provider), active.id == account.id {
            await readUsageNow(active)
        }
    }

    func runningCodexProcesses() -> [RunningCodexProcess] {
        codexService.recoverableRunningProcesses()
    }

    func forceRestartCodexSessions() async {
        let processes = codexService.recoverableRunningProcesses()
        guard !processes.isEmpty else {
            errorMessage = "No running Codex terminal sessions were detected."
            return
        }
        let stopped: CodexService.StoppedSessions
        do {
            stopped = try await codexService.stopForRestart(
                processes,
                codexHome: activeAccount(for: .codex)?.credentialLocation,
                shouldCloseTerminalTabs: true
            )
        } catch {
            errorMessage = error.localizedDescription
            failoverEvents.record(.codex, "Force restart not started: \(error.localizedDescription)")
            return
        }
        let reopened = stopped.resume()
        guard stopped.survivors.isEmpty else {
            errorMessage = "\(stopped.survivors.count) Codex process(es) did not close and were left running."
            failoverEvents.record(
                .codex,
                "Force restart reopened \(reopened) session(s); \(stopped.survivors.count) Codex process(es) remained active."
            )
            return
        }
        let skipped = processes.count - reopened
        failoverEvents.record(
            .codex,
            "Force restart reopened \(reopened) terminal session(s)"
                + (skipped == 0 ? "." : "; \(skipped) session(s) had no recoverable ID or are host-managed.")
        )
        if reopened == 0 {
            errorMessage = "Codex processes were closed, but no active terminal session IDs were available to resume."
        }
    }

    func switchTo(
        _ account: Account,
        refreshAfter: Bool = true,
        safelyRestartingCodex processes: [RunningCodexProcess],
        closeCodexTerminalTabs: Bool = false
    ) async {
        guard account.provider == .codex else {
            await switchTo(account, refreshAfter: refreshAfter)
            return
        }
        await switchToCodex(
            account,
            refreshAfter: refreshAfter,
            safelyRestarting: processes,
            closeTerminalTabs: closeCodexTerminalTabs
        )
    }

    func switchTo(
        _ account: Account,
        refreshAfter: Bool = true,
        safelyRestartingCodex processes: [RunningCodexProcess],
        liveReloadingCodex liveProcesses: [RunningCodexProcess],
        closeCodexTerminalTabs: Bool = false
    ) async {
        guard account.provider == .codex else {
            await switchTo(account, refreshAfter: refreshAfter)
            return
        }
        await switchToCodex(
            account,
            refreshAfter: refreshAfter,
            safelyRestarting: processes,
            closeTerminalTabs: closeCodexTerminalTabs,
            liveReloading: liveProcesses
        )
    }

    func switchTo(
        _ account: Account,
        refreshAfter: Bool = true,
        liveReloadingCodex processes: [RunningCodexProcess]
    ) async {
        guard account.provider == .codex else {
            await switchTo(account, refreshAfter: refreshAfter)
            return
        }
        await switchToCodex(
            account,
            refreshAfter: refreshAfter,
            safelyRestarting: [],
            liveReloading: processes
        )
    }

    /// Makes `account` its provider's active account with the provider's
    /// switch method, inside `credentialGate`. A Claude switch stops no
    /// session; a switch the user made moves the running ones with
    /// `moveRunningSessions`.
    private func performSwitch(to account: Account, refreshAfter: Bool) async {
        await credentialGate.run { await self.performSwitchNow(to: account, refreshAfter: refreshAfter) }
    }

    private func performSwitchNow(to account: Account, refreshAfter: Bool) async {
        guard account.supportsProviderWorkloads else {
            errorMessage = account.providerUnavailableLabel ?? "This account is unavailable."
            return
        }
        switch account.provider {
        case .codex: return await switchToCodex(account, refreshAfter: refreshAfter, safelyRestarting: [])
        case .kimi: return await switchToKimi(account, refreshAfter: refreshAfter)
        case .gemini: return
        case .claudeCode: break
        }
        guard let currentActive = activeAccount(for: account.provider), currentActive.id != account.id else {
            log.info("[switchTo] No switch needed (same account or no active account)")
            return
        }

        log.info("[switchTo] ===== Switching from \(currentActive.email) to \(account.email) =====")

        // Pre-switch: verify target has a backup
        guard keychain.backupStoreAvailable else {
            log.error("[switchTo] ABORT: saved accounts not read yet")
            errorMessage = Self.keychainWaitMessage
            return
        }
        guard keychain.getAccountBackup(forAccountId: account.id.uuidString) != nil else {
            log.error("[switchTo] ABORT: no backup for target account")
            errorMessage = String(localized: "No stored credentials for \(account.email). Use re-authenticate to fix.", bundle: L10n.bundle)
            return
        }

        do {
            let status = try await claudeService.switchAccount(from: currentActive, to: account)
            rejectedCredentialAccounts.remove(account.id)
            credentialQuarantine[account.id] = nil
            // Claude processes keep the credential they hold until signalled,
            // so the previous account can go on being consumed after this
            // switch. A switch the user asks for moves them at once.
            lastSwitchedAway[currentActive.id] = Date()
            noteLiveCredentialOwner(.claudeCode, account: account.id)
            if refreshAfter { moveRunningSessions(.claudeCode, from: currentActive.id) }

            var verifiedSubscription = status.subscriptionType
            if let tokenJSON = keychain.readClaudeToken(),
               let accessToken = ClaudeService.extractAccessToken(from: tokenJSON) {
                do {
                    // A successful profile response is authoritative even when
                    // it returns no plan because the former subscription expired.
                    let liveSubscription = try await claudeService.getLiveSubscription(
                        accessToken: accessToken
                    )
                    verifiedSubscription = liveSubscription.isInactive
                        ? "free"
                        : (liveSubscription.planType ?? status.subscriptionType)
                } catch {
                    log.warning("[switchTo] Live Claude plan refresh failed; using auth status: \(error.localizedDescription)")
                }
            }

            for i in accounts.indices where accounts[i].provider == account.provider {
                accounts[i].isActive = (accounts[i].id == account.id)
                if accounts[i].id == account.id {
                    accounts[i].lastUsed = Date()
                    accounts[i].orgName = status.orgName
                    accounts[i].subscriptionType = verifiedSubscription
                }
            }
            // Preserve any token rotation performed while validating the newly
            // active profile so the managed copy is current on the next switch.
            _ = claudeService.captureCurrentCredentials(
                forAccountId: account.id.uuidString,
                expectedEmail: account.email
            )
            saveAccounts()
            await routerFollowActiveAccount()

            if refreshAfter {
                await refresh()
                await warmSelectedAccountIfNeeded(account.id)
            }
            log.info("[switchTo] ===== Switch completed =====")
        } catch {
            errorMessage = error.localizedDescription
            switch error {
            case ClaudeServiceError.switchVerificationFailed, ClaudeServiceError.switchWrongAccount,
                 ClaudeServiceError.noTokenForAccount:
                quarantineCredentials(of: account, reason: error.localizedDescription)
            default:
                break
            }
            log.error("[switchTo] Switch failed: \(error.localizedDescription)")
        }
    }

    /// Re-authenticate an account by running `claude auth login` and capturing fresh credentials.
    func reauthenticateAccount(_ account: Account) async {
        await credentialGate.run { await self.reauthenticateAccountNow(account) }
    }

    private func reauthenticateAccountNow(_ account: Account) async {
        switch account.provider {
        case .codex: return await reauthenticateCodexAccount(account)
        case .kimi: return await reauthenticateKimiAccount(account)
        case .gemini: return
        case .claudeCode: break
        }
        log.info("[reauth] ===== Re-authenticating account \(account.id) (\(account.email)) =====")
        guard claudeAvailable else {
            errorMessage = String(localized: "Claude CLI not found", bundle: L10n.bundle)
            return
        }

        guard let loginID = beginLoginAttempt() else { return }
        defer { finishLoginAttempt(loginID) }

        // The account to put back once `account` has signed in, when its
        // live sign-in could be saved first.
        var displaced: Account?
        do {
            // 1. Back up current active account before login overwrites it
            if let current = activeAccount(for: .claudeCode), current.id != account.id {
                log.info("[reauth] Backing up current account before login...")
                let preserved = claudeService.captureCurrentCredentials(
                    forAccountId: current.id.uuidString,
                    expectedEmail: current.email
                )
                if preserved { displaced = current }
                if !preserved {
                    log.warning("[reauth] Skipped pre-login backup because the live identity does not match the selected account")
                }
            }

            // 2. Run login
            log.info("[reauth] Running `claude auth login`...")
            try await claudeService.login()

            // 3. Verify the login result matches the target account
            let status = try await claudeService.getAuthStatus()
            guard status.loggedIn, let email = status.email else {
                errorMessage = String(localized: "Login did not complete", bundle: L10n.bundle)
                return
            }

            guard account.matches(email: email) else {
                errorMessage = String(localized: "Logged in as \(email), but expected \(account.email). Credentials not updated.", bundle: L10n.bundle)
                log.error("[reauth] Email mismatch: got \(email), expected \(account.email)")
                return
            }

            // 4. Capture the fresh token
            let captured = claudeService.captureCurrentCredentials(
                forAccountId: account.id.uuidString,
                expectedEmail: account.email
            )
            log.info("[reauth] Token capture result: \(captured)")
            if captured { noteLiveCredentialOwner(.claudeCode, account: account.id) }
            rejectedCredentialAccounts.remove(account.id)
            credentialQuarantine[account.id] = nil

            // 5. Update account metadata
            if let index = accounts.firstIndex(where: { $0.id == account.id }) {
                accounts[index].orgName = status.orgName
                accounts[index].subscriptionType = status.subscriptionType

                // Mark this account as active (it's what the CLI is now using)
                accounts.makeActive(account.id)
                saveAccounts()
            }

            // The login left the CLI signed in as `account`, and every
            // session on the CLI's own credential follows that sign-in. The
            // account that was active is put back, so renewing one account's
            // sign-in moves no session; sessions that read the credential
            // meanwhile are told to read it again.
            if let displaced {
                await performSwitch(to: displaced, refreshAfter: false)
                if activeAccount(for: .claudeCode)?.id == displaced.id {
                    moveRunningSessions(.claudeCode, from: account.id)
                    log.info("[reauth] Put the account that was active back")
                } else {
                    failoverEvents.record(.claudeCode, "\(messageName(account)) signed in again and is now the active account, because \(messageName(displaced)) could not be put back; sessions on the shared sign-in follow it.")
                }
            }

            finishLoginAttempt(loginID)
            await refresh()
            log.info("[reauth] ===== Re-authentication completed =====")
        } catch {
            guard loginAttemptID == loginID else { return }
            errorMessage = error.localizedDescription
            log.error("[reauth] Error: \(error.localizedDescription)")
        }
    }

    // MARK: - Usage

    /// What one read of an account's usage found. Each provider's reader
    /// produces one; `applyUsageRead` records it the same way for every
    /// provider.
    enum UsageReadOutcome {
        case reading(UsageAPIResponse)
        /// The account's plan does not include the provider's workloads.
        case workloadUnavailable(String)
        case throttled(retryAt: Date?)
        /// The provider rejected the credential: the account cannot be used
        /// until it signs in again.
        case credentialRejected(String)
        /// The credential was refused and could not be renewed, for a
        /// reason that does not show whether the sign-in is dead.
        case credentialUnrenewed(String)
        /// Nothing could be read and nothing about the account changed: no
        /// credential yet, or a renewal failed on the network.
        case skipped
        case failed(Error)
    }

    /// Reads every account's usage, the active account of each provider
    /// first and then the account read longest ago, within each provider's
    /// request budget.
    private func fetchAllAccountUsage(forceUnavailablePlanCheck: Bool = false) async {
        // A failed or unavailable provider refresh must not leave a cached
        // pre-reset percentage on screen after its known reset time.
        reconcilePassedUsageResets()
        accountUsageErrors.removeAll()
        for provider in AIProviderType.implementedProviders {
            for account in accountsByReadUrgency(provider) {
                if shouldDeferUnavailablePlanCheck(account, forced: forceUnavailablePlanCheck) {
                    accountUsageErrors[account.id] = unavailableUsageState(for: account)
                    continue
                }
                if !account.supportsProviderWorkloads {
                    unavailablePlanCheckedAt[account.id] = Date()
                }
                if let retryAt = usageRetryAfter[account.id], retryAt > Date() {
                    accountUsageErrors[account.id] = UsageErrorState(
                        isExpired: false,
                        isRateLimited: true,
                        message: accountUsage[account.id] == nil
                            ? "Usage refresh is temporarily rate limited."
                            : "Usage refresh throttled. Showing the last known limits.",
                        cachedAt: accountUsageUpdatedAt[account.id]
                    )
                    continue
                }
                guard let priority = usageReadPriority(account, forced: forceUnavailablePlanCheck) else { continue }
                guard spendUsageRequest(provider, priority) else {
                    if accountUsageErrors[account.id] == nil, accountUsage[account.id] != nil,
                       let updatedAt = accountUsageUpdatedAt[account.id],
                       Date().timeIntervalSince(updatedAt) > 30 * 60 {
                        accountUsageErrors[account.id] = UsageErrorState(
                            isExpired: false,
                            isRateLimited: true,
                            message: "Usage refresh deferred to stay inside the provider rate limit.",
                            cachedAt: updatedAt
                        )
                    }
                    continue
                }
                let outcome = await readUsage(account, forced: forceUnavailablePlanCheck, includeMetadata: true)
                applyUsageRead(outcome, for: account)
            }
        }
    }

    /// Reads `account`'s usage with its provider's reader. With
    /// `includeMetadata`, the reader also refreshes the plan and identity
    /// the provider reports, which costs some providers another request.
    /// `resetDetails` asks a provider whose usage reply only counts the
    /// account's limit resets for their details too; Claude's reply always
    /// holds them.
    func readUsage(_ account: Account, forced: Bool, includeMetadata: Bool,
                   resetDetails: Bool = false) async -> UsageReadOutcome {
        switch account.provider {
        case .claudeCode: await readClaudeUsage(account, forced: forced, includeMetadata: includeMetadata)
        case .codex: await readCodexUsage(account, resetDetails: resetDetails)
        case .kimi: await readKimiUsage(account, includeMetadata: includeMetadata)
        case .gemini: .skipped
        }
    }

    /// Records a read's outcome. Returns whether a fresh reading was
    /// recorded.
    @discardableResult
    func applyUsageRead(_ outcome: UsageReadOutcome, for account: Account) -> Bool {
        let name = account.provider.capabilities.displayName
        switch outcome {
        case .reading(let usage):
            usageBudgets[account.provider]?.recordSuccess()
            // Before `recordUsage`, which saves the snapshot this goes into.
            accountWholeReadings[account.id] = WholeReading(at: Date(), longUtilization: usage.sevenDay?.utilization)
            recordUsage(usage, for: account.id)
            accountUsageErrors[account.id] = nil
            usageRetryAfter[account.id] = nil
            if !account.isActive { credentialQuarantine[account.id] = nil }
            // A reading made with the account's own credential proves its
            // sign-in works.
            clearNeedsSignIn(account)
            log.info("[fetchUsage] \(name) \(account.email): session=\(usage.fiveHour?.utilization ?? -1)%, long=\(usage.sevenDay?.utilization ?? -1)%")
            return true
        case .workloadUnavailable(let message):
            unavailablePlanCheckedAt[account.id] = Date()
            if accountUsage[account.id] != nil {
                accountUsage[account.id] = nil
                accountUsageUpdatedAt[account.id] = nil
                saveUsageSnapshots()
            }
            accountUsageErrors[account.id] = UsageErrorState(isExpired: true, isRateLimited: false, message: message, cachedAt: nil)
            log.info("[fetchUsage] \(name) \(account.email): \(message)")
        case .throttled(let retryAt):
            noteUsageThrottle(account, retryAt: retryAt)
        case .credentialRejected(let message):
            noteCredentialRejected(account)
            accountUsageErrors[account.id] = UsageErrorState(
                isExpired: true, isRateLimited: false, message: message, cachedAt: accountUsageUpdatedAt[account.id]
            )
        case .credentialUnrenewed(let message):
            accountUsageErrors[account.id] = UsageErrorState(
                isExpired: true, isRateLimited: false, message: message, cachedAt: accountUsageUpdatedAt[account.id]
            )
        case .skipped:
            break
        case .failed(let error):
            accountUsageErrors[account.id] = UsageErrorState(
                isExpired: false,
                isRateLimited: false,
                message: accountUsage[account.id] == nil
                    ? "Could not fetch \(name) usage: \(error.localizedDescription)"
                    : "Could not refresh \(name) usage. Showing the last known limits.",
                cachedAt: accountUsageUpdatedAt[account.id]
            )
            log.warning("[fetchUsage] \(name) \(account.email) failed: \(error.localizedDescription)")
        }
        return false
    }

    // MARK: Provider readers

    /// Codex reports the plan with every reading. The active account's live
    /// credential is the system copy the CLI refreshes; its managed copy can
    /// hold a rotated-out token.
    private func readCodexUsage(_ account: Account, resetDetails: Bool) async -> UsageReadOutcome {
        do {
            let snapshot = try await codexService.getUsageSnapshot(
                codexHome: account.isActive ? nil : account.credentialLocation,
                resetDetails: resetDetails
            )
            setSubscriptionType(snapshot.planType, for: account.id)
            guard Account.supportsProviderWorkloads(provider: .codex, subscriptionType: snapshot.planType) else {
                return .workloadUnavailable(unavailableMessage(for: account.provider))
            }
            return .reading(snapshot.usage)
        } catch CodexServiceError.subscriptionUnavailable {
            setSubscriptionType("inactive", for: account.id)
            return .workloadUnavailable(unavailableMessage(for: account.provider))
        } catch CodexServiceError.rateLimited(let retryAt) {
            return .throttled(retryAt: retryAt)
        } catch CodexServiceError.liveCredentialExpired {
            return .credentialUnrenewed(String(localized: "Token expired. Switch to refresh.", bundle: L10n.bundle))
        } catch CodexServiceError.credentialRejected {
            return .credentialRejected(CodexServiceError.credentialRejected.localizedDescription)
        } catch {
            return .failed(error)
        }
    }

    /// Kimi reports the signed-in identity and plan through a separate
    /// request, made only with `includeMetadata`.
    private func readKimiUsage(_ account: Account, includeMetadata: Bool) async -> UsageReadOutcome {
        guard let location = account.credentialLocation else { return .skipped }
        do {
            let usage = try await kimiService.getUsageLimits(location: location, isActive: readsLiveCredential(account))
            if includeMetadata, let identity = try? await kimiService.identity(location: location),
               let index = accounts.firstIndex(where: { $0.id == account.id }),
               accounts[index].email != identity.identifier
                || accounts[index].displayName != identity.displayName
                || accounts[index].subscriptionType != identity.planType {
                accounts[index].email = identity.identifier
                accounts[index].displayName = identity.displayName
                accounts[index].subscriptionType = identity.planType
                saveAccounts(refreshWidget: true)
            }
            return .reading(usage)
        } catch KimiServiceError.rateLimited {
            return .throttled(retryAt: nil)
        } catch KimiServiceError.liveCredentialExpired {
            return .credentialUnrenewed(String(localized: "Token expired. Switch to refresh.", bundle: L10n.bundle))
        } catch KimiServiceError.credentialRejected {
            return .credentialRejected(KimiServiceError.credentialRejected.localizedDescription)
        } catch {
            return .failed(error)
        }
    }

    /// Claude reads with the active account's live Keychain token, which
    /// Claude Code renews itself, or another account's stored copy, renewed
    /// here without ever entering Claude's shared Keychain slot, so running
    /// sessions keep consuming their own subscription.
    private func readClaudeUsage(_ account: Account, forced: Bool, includeMetadata: Bool) async -> UsageReadOutcome {
        var tokenJSON: String?
        var usesSavedCopy = false
        if readsLiveCredential(account) {
            tokenJSON = keychain.readClaudeToken()
        } else {
            usesSavedCopy = true
            tokenJSON = keychain.getAccountBackup(forAccountId: account.id.uuidString)?.token
            // An idle account's token is renewed before it expires, which
            // saves the rejected request a stale token would cost.
            if let stored = tokenJSON, ClaudeCredentialModule.expires(stored, within: 2 * 60),
               await renewSavedCredential(account) == .renewed {
                tokenJSON = keychain.getAccountBackup(forAccountId: account.id.uuidString)?.token
            }
        }
        guard let tokenJSON, let accessToken = ClaudeService.extractAccessToken(from: tokenJSON) else {
            log.warning("[fetchUsage] No token for \(account.email), skipping")
            return .skipped
        }
        if usesSavedCopy, !(await savedCopyIsOwn(account, tokenJSON: tokenJSON, accessToken: accessToken, forced: forced)) {
            return .credentialRejected("This account's saved sign-in was another account's. Sign it in again.")
        }
        setRateLimitTier(ClaudeService.rateLimitTier(from: tokenJSON), for: account.id)
        if includeMetadata, shouldCheckClaudeProfile(account, forced: forced),
           await refreshClaudeSubscriptionMetadata(accountID: account.id, accessToken: accessToken) {
            return .workloadUnavailable(unavailableMessage(for: account.provider))
        }
        do {
            return .reading(try await claudeService.getUsageLimits(accessToken: accessToken))
        } catch ClaudeService.UsageError.expired {
            log.warning("[fetchUsage] Token expired for \(account.email)")
            return await readClaudeUsageAfterRenewal(account, readsLive: !usesSavedCopy)
        } catch ClaudeService.UsageError.subscriptionUnavailable {
            markClaudeCodeUnavailable(accountID: account.id)
            return .workloadUnavailable(unavailableMessage(for: account.provider))
        } catch ClaudeService.UsageError.rateLimited(let retryAt) {
            return .throttled(retryAt: retryAt)
        } catch {
            return .failed(error)
        }
    }

    /// The read retried once the rejected token is renewed: by Claude Code
    /// itself for the live credential (`claude auth status`), and here for
    /// a stored copy. `readsLive` is `readClaudeUsage`'s
    /// `readsLiveCredential` answer.
    private func readClaudeUsageAfterRenewal(_ account: Account, readsLive: Bool) async -> UsageReadOutcome {
        let accessToken: String
        if readsLive {
            do {
                let status = try await claudeService.getAuthStatus()
                if !status.loggedIn {
                    return .credentialRejected("Claude Code is signed out. Reauthenticate this account.")
                }
                guard let refreshed = keychain.readClaudeToken().flatMap(ClaudeService.extractAccessToken(from:)) else {
                    throw ClaudeService.UsageError.expired
                }
                accessToken = refreshed
            } catch {
                log.error("[fetchUsage] Delegated refresh failed for active account: \(error.localizedDescription)")
                return .credentialUnrenewed(String(localized: "Token expired. Switch to refresh.", bundle: L10n.bundle))
            }
        } else {
            switch await renewSavedCredential(account) {
            case .renewed:
                let stored = keychain.getAccountBackup(forAccountId: account.id.uuidString)?.token
                guard let refreshed = stored.flatMap(ClaudeService.extractAccessToken(from:)) else { return .skipped }
                accessToken = refreshed
            case .rejected:
                log.warning("[fetchUsage] Isolated refresh rejected for \(account.email)")
                return .credentialRejected("Stored credentials expired. Reauthenticate this account.")
            case .unavailable:
                // A network or server failure, or a Keychain still waiting
                // for access, says nothing about the credential; the account
                // is read again later.
                return .skipped
            }
        }
        do {
            let usage = try await claudeService.getUsageLimits(accessToken: accessToken)
            _ = await refreshClaudeSubscriptionMetadata(accountID: account.id, accessToken: accessToken)
            log.info("[fetchUsage] Recovered \(account.email) after renewing its credential.")
            return .reading(usage)
        } catch ClaudeService.UsageError.rateLimited(let retryAt) {
            return .throttled(retryAt: retryAt)
        } catch ClaudeService.UsageError.expired {
            // `claude auth status` can report a login without renewing its
            // token, so a second refusal on the active account shows only
            // that no session has renewed it yet; the next one that sends a
            // request does.
            if readsLive {
                return .credentialUnrenewed(String(localized: "Token expired. Switch to refresh.", bundle: L10n.bundle))
            }
            return .credentialRejected("Stored credentials expired. Reauthenticate this account.")
        } catch {
            return .failed(error)
        }
    }

    func setRateLimitTier(_ tier: String?, for accountID: UUID) {
        guard let tier, let index = accounts.firstIndex(where: { $0.id == accountID }),
              accounts[index].rateLimitTier != tier else { return }
        accounts[index].rateLimitTier = tier
        saveAccounts(refreshWidget: true)
    }

    private func setSubscriptionType(_ type: String?, for accountID: UUID) {
        guard let index = accounts.firstIndex(where: { $0.id == accountID }),
              accounts[index].subscriptionType != type else { return }
        accounts[index].subscriptionType = type
        saveAccounts(refreshWidget: true)
    }

    private func shouldDeferUnavailablePlanCheck(_ account: Account, forced: Bool) -> Bool {
        guard !forced, !account.supportsProviderWorkloads,
              let checkedAt = unavailablePlanCheckedAt[account.id] else { return false }
        return Date().timeIntervalSince(checkedAt) < unavailablePlanCheckInterval
    }

    private func unavailableMessage(for provider: AIProviderType) -> String {
        "This account's plan does not currently include \(provider.rawValue)."
    }

    private func unavailableUsageState(for account: Account) -> UsageErrorState {
        UsageErrorState(isExpired: true, isRateLimited: false, message: unavailableMessage(for: account.provider), cachedAt: nil)
    }

    /// Returns true only when Anthropic explicitly reports an inactive plan.
    private func refreshClaudeSubscriptionMetadata(accountID: UUID, accessToken: String) async -> Bool {
        // Profile requests count against the same Anthropic allowance as
        // usage requests; a skipped check is retried on a later refresh.
        guard spendUsageRequest(.claudeCode, .background) else { return false }
        lastProfileCheck[accountID] = Date()
        do {
            let live = try await claudeService.getLiveSubscription(accessToken: accessToken)
            guard let index = accounts.firstIndex(where: { $0.id == accountID }) else { return false }
            let resolvedPlan = live.isInactive ? "free" : live.planType
            guard let resolvedPlan else { return false }
            if accounts[index].subscriptionType == resolvedPlan { return live.isInactive }
            let previous = accounts[index].subscriptionType ?? "none"
            accounts[index].subscriptionType = resolvedPlan
            if live.isInactive {
                accountUsage[accountID] = nil
                accountUsageUpdatedAt[accountID] = nil
                saveUsageSnapshots()
            }
            saveAccounts(refreshWidget: true)
            log.info("[fetchUsage] Claude plan changed for \(accounts[index].email): \(previous) -> \(resolvedPlan)")
            return live.isInactive
        } catch {
            // Usage remains independently useful. Preserve last verified plan
            // through transient profile/network failures instead of guessing.
            log.warning("[fetchUsage] Claude live plan refresh failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Drops an account's stored reading, as when it turns out not to
    /// describe the account.
    func forgetUsage(of accountID: UUID) {
        accountUsage[accountID] = nil
        accountUsageUpdatedAt[accountID] = nil
        accountWholeReadings[accountID] = nil
        saveUsageSnapshots()
    }

    private func markClaudeCodeUnavailable(accountID: UUID) {
        guard let index = accounts.firstIndex(where: { $0.id == accountID }) else { return }
        accounts[index].subscriptionType = "free"
        accountUsage[accountID] = nil
        accountUsageUpdatedAt[accountID] = nil
        saveUsageSnapshots()
        saveAccounts(refreshWidget: true)
    }

    // MARK: - Widget

    private func updateWidgetData() {
        let data = WidgetProjection.make(
            accounts: accounts,
            usage: accountUsage,
            errorMessages: accountUsageErrors.mapValues(\.message),
            summary: todaySummary(),
            obfuscated: !UserDefaults.standard.bool(forKey: "showFullEmail"),
            now: Date()
        )
        data.save()
        WidgetCenter.shared.reloadAllTimelines()
        log.debug("[updateWidgetData] Widget data saved and timelines reloaded")
    }

    // MARK: - Persistence

    private struct PersistedUsageSnapshot: Codable {
        let usage: UsageAPIResponse
        let updatedAt: Date
        /// `accountWholeReadings`; absent in a snapshot saved without one.
        var wholeAt: Date?
        var wholeLongUtilization: Double?
    }

    private func loadFailoverRuntime() {
        guard let data = UserDefaults.standard.data(forKey: failoverRuntimeKey),
              let stored = try? JSONDecoder().decode([String: [UUID]].self, from: data) else {
            return
        }
        let validIDs = Set(accounts.map(\.id))
        for provider in AIProviderType.implementedProviders {
            let ids = stored[provider.rawValue, default: []].filter { validIDs.contains($0) }
            exhaustedFailoverAccounts[provider] = Set(ids)
        }
    }

    func saveFailoverRuntime() {
        let stored = Dictionary(uniqueKeysWithValues:
            AIProviderType.implementedProviders.map { provider in
                (provider.rawValue, Array(exhaustedFailoverAccounts[provider, default: []]))
            }
        )
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: failoverRuntimeKey)
        }
    }

    /// A provider's accounts in the order their usage is read: the active
    /// account, then the oldest reading first. Every account of a provider
    /// shares one request budget, so a fixed order would leave the accounts
    /// at the end of the list unread whenever the budget runs short.
    func accountsByReadUrgency(_ provider: AIProviderType) -> [Account] {
        accounts.filter { $0.provider == provider }.sorted { a, b in
            if a.isActive != b.isActive { return a.isActive }
            return (accountUsageUpdatedAt[a.id] ?? .distantPast) < (accountUsageUpdatedAt[b.id] ?? .distantPast)
        }
    }

    func recordUsage(
        _ usage: UsageAPIResponse,
        for accountID: UUID,
        observedAt: Date = Date(),
        confirmsReset: Bool = true
    ) {
        let previousUsage = accountUsage[accountID]
        let reconciled = usage.preservingEstablishedCountdowns(from: accountUsage[accountID])
        accountUsage[accountID] = reconciled.expiringPassedResets()
        accountUsageUpdatedAt[accountID] = observedAt
        if let provider = accounts.first(where: { $0.id == accountID })?.provider,
           suspensionContexts[provider]?.accountID == accountID {
            quotaTrends[accountID, default: QuotaTrend()].rebase(reconciled, at: observedAt)
        } else {
            quotaTrends[accountID, default: QuotaTrend()].record(reconciled, at: observedAt)
        }
        if confirmsReset { accountsAwaitingPostResetVerification.remove(accountID) }
        if let account = accounts.first(where: { $0.id == accountID }) {
            learnFromReading(reconciled, previous: previousUsage, account: account, at: observedAt)
        }
        var warmup = pendingWindowWarmups.removeValue(forKey: accountID)
        if warmup == nil {
            warmup = bootstrapWarmupIfNeeded(for: accountID, usage: accountUsage[accountID] ?? usage)
        }
        saveUsageSnapshots()
        scheduleNextUsageReset()
        if let warmup, warmup.session || warmup.weekly {
            Task { await performWindowWarmup(accountID: accountID, windows: warmup) }
        }
    }

    private func bootstrapWarmupIfNeeded(
        for accountID: UUID,
        usage: UsageAPIResponse
    ) -> PendingWindowWarmup? {
        guard let account = accounts.first(where: { $0.id == accountID }) else { return nil }
        let policy = failoverConfig.policy(for: account.provider)
        guard policy.keepWindowsWarm else { return nil }

        var pending = PendingWindowWarmup()
        let sessionKey = "\(accountID.uuidString).session"
        if account.provider.capabilities.supportsSessionQuota,
           usage.sevenDay?.utilization.map({ $0 < 100 }) == true,
           usage.fiveHour?.isUnusedUnstartedWindow == true,
           !warmupBootstrapsInFlight.contains(sessionKey) {
            pending.session = true
            warmupBootstrapsInFlight.insert(sessionKey)
        }

        let weeklyKey = "\(accountID.uuidString).weekly"
        if usage.sevenDay?.isUnusedUnstartedWindow == true,
           !warmupBootstrapsInFlight.contains(weeklyKey) {
            pending.weekly = true
            warmupBootstrapsInFlight.insert(weeklyKey)
        }

        guard pending.session || pending.weekly else { return nil }
        log.info("[warmup] Scheduled one-time bootstrap for \(accountID.uuidString)")
        return pending
    }

    private func loadUsageSnapshots() {
        guard let data = UserDefaults.standard.data(forKey: usageSnapshotsKey),
              let snapshots = try? JSONDecoder().decode(
                [String: PersistedUsageSnapshot].self,
                from: data
              ) else { return }
        let validAccountIDs = Set(accounts.map(\.id))
        for (rawID, snapshot) in snapshots {
            guard let id = UUID(uuidString: rawID), validAccountIDs.contains(id) else { continue }
            // Load the provider's last-good value verbatim. The reconciliation
            // pass immediately after loading detects passed reset timestamps,
            // persists the corrected snapshot, and refreshes widget data.
            accountUsage[id] = snapshot.usage
            accountUsageUpdatedAt[id] = snapshot.updatedAt
            if let wholeAt = snapshot.wholeAt {
                accountWholeReadings[id] = WholeReading(at: wholeAt, longUtilization: snapshot.wholeLongUtilization)
            }
        }
        scheduleNextUsageReset()
    }

    /// Applies provider-confirmed reset timestamps locally. This is deliberately
    /// independent of token validity and network availability.
    private func reconcilePassedUsageResets(now: Date = Date()) {
        var changed = false
        var verifyNow: Set<UUID> = []
        for id in accountUsage.keys {
            guard let usage = accountUsage[id], usage.hasPassedReset(at: now) else { continue }
            if let account = accounts.first(where: { $0.id == id }) {
                let policy = failoverConfig.policy(for: account.provider)
                if policy.keepWindowsWarm {
                    var pending = pendingWindowWarmups[id] ?? PendingWindowWarmup()
                    if account.provider.capabilities.supportsSessionQuota,
                       usage.fiveHour?.resetsAtDate.map({ $0 <= now }) == true {
                        pending.session = true
                    }
                    if usage.sevenDay?.resetsAtDate.map({ $0 <= now }) == true {
                        pending.weekly = true
                    }
                    if pending.session || pending.weekly {
                        pendingWindowWarmups[id] = pending
                        verifyNow.insert(id)
                    }
                }
            }
            accountUsage[id] = usage.expiringPassedResets(at: now)
            accountsAwaitingPostResetVerification.insert(id)
            changed = true
            log.info("[usage-reset] Cleared cached utilization for \(id.uuidString); awaiting fresh post-reset verification")
        }
        if changed {
            saveUsageSnapshots()
            updateWidgetData()
        }
        scheduleNextUsageReset(now: now)
        if !verifyNow.isEmpty {
            Task { await verifyPostResetAccounts(verifyNow) }
        }
    }

    private func verifyPostResetAccounts(_ ids: Set<UUID>) async {
        // A failed or deferred read keeps the pending warm-up marker; the
        // ordinary refresh retries within the shared request budget.
        for account in accounts where ids.contains(account.id) {
            await fetchUsageNow(account, priority: .background)
        }
    }

    private func performWindowWarmup(accountID: UUID, windows: PendingWindowWarmup) async {
        guard let account = accounts.first(where: { $0.id == accountID }) else { return }
        let policy = failoverConfig.policy(for: account.provider)
        guard policy.keepWindowsWarm,
              let probe = quotaWindowProbe(for: account, readsLive: readsLiveCredential(account)) else { return }

        guard accountWarmupsInFlight.insert(accountID).inserted else {
            log.info("[warmup] Skipped duplicate in-flight probe for \(accountID.uuidString)")
            return
        }
        defer { accountWarmupsInFlight.remove(accountID) }
        let requestedLabels = [windows.session ? "session" : nil, windows.weekly ? "weekly" : nil]
            .compactMap { $0 }
            .joined(separator: " + ")

        guard spendUsageRequest(account.provider, .background) else {
            scheduleWarmupRetry(accountID: accountID, windows: windows)
            return
        }
        do {
            let liveUsage = try await probe.liveUsage()

            // A queued reset task may race with real user activity, a manual
            // refresh, or another reset task. Only an explicit provider state
            // of 0% with no running countdown authorizes a probe.
            let needed = PendingWindowWarmup(
                session: windows.session
                    && liveUsage.sevenDay?.utilization.map({ $0 < 100 }) == true
                    && liveUsage.fiveHour?.isUnusedUnstartedWindow == true,
                weekly: windows.weekly && liveUsage.sevenDay?.isUnusedUnstartedWindow == true
            )
            guard needed.session || needed.weekly else {
                recordUsage(liveUsage, for: account.id)
                completeWarmupBootstrap(accountID: accountID, windows: windows)
                warmupRetryAttempts[accountID] = nil
                log.info("[warmup] Skipped probe for \(accountID.uuidString); requested window is already active or unavailable")
                return
            }

            let labels = [needed.session ? "session" : nil, needed.weekly ? "weekly" : nil]
                .compactMap { $0 }
                .joined(separator: " + ")
            try await probe.startWindow()
            try await forceRefreshWarmup(account: account, windows: needed, fetch: probe.liveUsage)
            failoverEvents.record(
                account.provider,
                "Started the \(labels) reset countdown for \(messageName(account)); the probe session was non-persistent."
            )
            completeWarmupBootstrap(accountID: accountID, windows: needed)
            warmupRetryAttempts[accountID] = nil
            log.info("[warmup] \(account.provider.rawValue) \(labels) window started for \(account.id.uuidString)")
        } catch {
            releaseWarmupBootstrap(accountID: accountID, windows: windows)
            failoverEvents.record(
                account.provider,
                "Could not start the \(requestedLabels) reset countdown for \(messageName(account)): \(error.localizedDescription)"
            )
            log.warning("[warmup] Probe failed for \(account.id.uuidString): \(error.localizedDescription)")
            scheduleWarmupRetry(accountID: accountID, windows: windows)
        }
    }

    private func warmSelectedAccountIfNeeded(_ accountID: UUID) async {
        guard let account = accounts.first(where: { $0.id == accountID }),
              failoverConfig.policy(for: account.provider).keepWindowsWarm else { return }
        await performWindowWarmup(
            accountID: accountID,
            windows: PendingWindowWarmup(
                session: account.provider.capabilities.supportsSessionQuota,
                weekly: true
            )
        )
    }

    private func scheduleWarmupRetry(accountID: UUID, windows: PendingWindowWarmup) {
        let attempt = warmupRetryAttempts[accountID, default: 0] + 1
        warmupRetryAttempts[accountID] = attempt
        let delays: [TimeInterval] = [2 * 60, 5 * 60, 15 * 60, 30 * 60]
        guard attempt <= delays.count else {
            log.warning("[warmup] Retry limit reached for \(accountID.uuidString); the next usage refresh/reset can arm it again")
            return
        }
        let delay = delays[attempt - 1]
        log.info("[warmup] Retry \(attempt) for \(accountID.uuidString) scheduled in \(Int(delay))s")
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self,
                  let account = self.accounts.first(where: { $0.id == accountID }) else { return }
            let policy = self.failoverConfig.policy(for: account.provider)
            guard policy.keepWindowsWarm else { return }
            let usage = self.accountUsage[accountID]
            let sessionStillNeedsWarmup = windows.session
                && usage?.sevenDay?.utilization.map({ $0 < 100 }) == true
                && (usage == nil || usage?.fiveHour?.isUnusedUnstartedWindow == true)
            let weeklyStillNeedsWarmup = windows.weekly
                && usage?.sevenDay?.isUnusedUnstartedWindow != false
            guard sessionStillNeedsWarmup || weeklyStillNeedsWarmup else {
                self.warmupRetryAttempts[accountID] = nil
                return
            }
            await self.performWindowWarmup(
                accountID: accountID,
                windows: PendingWindowWarmup(
                    session: sessionStillNeedsWarmup,
                    weekly: weeklyStillNeedsWarmup
                )
            )
        }
    }

    private func completeWarmupBootstrap(accountID: UUID, windows: PendingWindowWarmup) {
        for key in warmupBootstrapKeys(accountID: accountID, windows: windows) {
            warmupBootstrapsInFlight.remove(key)
        }
    }

    private func releaseWarmupBootstrap(accountID: UUID, windows: PendingWindowWarmup) {
        for key in warmupBootstrapKeys(accountID: accountID, windows: windows) {
            warmupBootstrapsInFlight.remove(key)
        }
    }

    private func warmupBootstrapKeys(accountID: UUID, windows: PendingWindowWarmup) -> [String] {
        [
            windows.session ? "\(accountID.uuidString).session" : nil,
            windows.weekly ? "\(accountID.uuidString).weekly" : nil,
        ].compactMap { $0 }
    }

    /// Provider usage endpoints can lag behind a successful probe. Refresh the
    /// affected account immediately, then retry sparingly until the new reset
    /// timestamp is visible. Each response is recorded so the UI never waits
    /// for the ordinary application-wide refresh cycle.
    private func forceRefreshWarmup(
        account: Account,
        windows: PendingWindowWarmup,
        fetch: @escaping () async throws -> UsageAPIResponse
    ) async throws {
        var latestUsage: UsageAPIResponse?
        for delay in [2.0, 8.0, 20.0] {
            try? await Task.sleep(for: .seconds(delay))
            let usage: UsageAPIResponse
            guard spendUsageRequest(account.provider, .background) else { continue }
            do {
                usage = try await fetch()
            } catch {
                // The inference already succeeded, so a throttled verification
                // request must not turn the warm-up itself into a failure.
                log.warning("[warmup] Verification poll deferred for \(account.id.uuidString): \(error.localizedDescription)")
                continue
            }
            latestUsage = usage
            recordUsage(usage, for: account.id)

            let sessionConfirmed = !windows.session || usage.fiveHour == nil || usage.fiveHour?.resetsAtDate != nil
            let weeklyConfirmed = !windows.weekly || usage.sevenDay?.resetsAtDate != nil
            if sessionConfirmed && weeklyConfirmed {
                log.info("[warmup] Forced usage refresh confirmed countdown for \(account.id.uuidString)")
                return
            }
            log.info("[warmup] Forced usage refresh is awaiting provider propagation for \(account.id.uuidString)")
        }
        // A successful inference is authoritative. If every verification poll
        // was throttled, pin from the last known empty-window snapshot rather
        // than unnecessarily running another inference probe.
        guard let latestUsage = latestUsage ?? accountUsage[account.id] else { return }

        // A successful inference is authoritative evidence that use began even
        // when the provider continues returning its moving zero-percent
        // placeholder. Pin the countdown to the probe time so subsequent polls
        // cannot make the reset drift; a later real provider timestamp replaces it.
        let pinned = latestUsage.pinningWarmupCountdowns(
            session: windows.session,
            weekly: windows.weekly
        )
        recordUsage(pinned, for: account.id)
        log.info("[warmup] Provider still reports a moving placeholder; pinned countdown from the successful probe for \(account.id.uuidString)")
    }

    private func scheduleNextUsageReset(now: Date = Date()) {
        usageResetTimer?.invalidate()
        usageResetTimer = nil
        guard let next = accountUsage.values.compactMap(\.nextResetDate)
            .filter({ $0 > now })
            .min() else { return }
        usageResetTimer = Timer.scheduledTimer(
            withTimeInterval: max(next.timeIntervalSince(now), 1),
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reconcilePassedUsageResets()
            }
        }
    }

    private func saveUsageSnapshots() {
        let validAccountIDs = Set(accounts.map(\.id))
        let snapshots = accountUsage.reduce(into: [String: PersistedUsageSnapshot]()) { result, item in
            guard validAccountIDs.contains(item.key),
                  let updatedAt = accountUsageUpdatedAt[item.key] else { return }
            result[item.key.uuidString] = PersistedUsageSnapshot(
                usage: item.value,
                updatedAt: updatedAt,
                wholeAt: accountWholeReadings[item.key]?.at,
                wholeLongUtilization: accountWholeReadings[item.key]?.longUtilization
            )
        }
        if let data = try? JSONEncoder().encode(snapshots) {
            UserDefaults.standard.set(data, forKey: usageSnapshotsKey)
        }
    }

    private func loadAccounts() {
        guard let data = UserDefaults.standard.data(forKey: accountsKey),
              let decoded = try? JSONDecoder().decode([Account].self, from: data) else {
            log.info("[loadAccounts] No saved accounts found")
            return
        }
        accounts = decoded
        log.info("[loadAccounts] Loaded \(decoded.count) accounts")
    }

    func saveAccounts(refreshWidget: Bool = false) {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: accountsKey)
            log.debug("[saveAccounts] Saved \(self.accounts.count) accounts to UserDefaults")
        }
        if refreshWidget {
            updateWidgetData()
        }
    }

    private func updateActiveAccount(from status: AuthStatus) {
        guard status.loggedIn, let email = status.email else { return }

        // `claude auth status` reports the identity in `~/.claude.json`,
        // which a session `SessionSlots` started on another account rewrites
        // to its own. The live credential's owner decides instead.
        if let owner = liveCredentialOwner(.claudeCode),
           let ownerIndex = accounts.firstIndex(where: { $0.id == owner }),
           accounts[ownerIndex].email.caseInsensitiveCompare(email) != .orderedSame {
            let restored = credentialModule(for: .claudeCode)?.liveCredential?
                .restoreSignedInIdentity(of: accounts[ownerIndex]) ?? false
            if !accounts[ownerIndex].isActive {
                accounts.makeActive(owner)
                saveAccounts()
            }
            log.warning("[updateActiveAccount] Signed-in identity names another account than the live credential's owner; kept the owner active, identity restored: \(restored)")
            return
        }

        if let index = accounts.firstIndex(where: { $0.provider == .claudeCode && $0.matches(email: email) }) {
            accounts.makeActive(accounts[index].id)
            accounts[index].orgName = status.orgName
            accounts[index].subscriptionType = status.subscriptionType
            saveAccounts()
            log.info("[updateActiveAccount] Matched existing account at index \(index)")
        } else if !accounts.contains(where: { $0.provider == .claudeCode }) {
            let account = Account(
                email: email,
                displayName: status.orgName ?? email,
                provider: .claudeCode,
                orgName: status.orgName,
                subscriptionType: status.subscriptionType,
                isActive: true
            )
            accounts.append(account)
            _ = claudeService.captureCurrentCredentials(
                forAccountId: account.id.uuidString,
                expectedEmail: account.email
            )
            saveAccounts()
            log.info("[updateActiveAccount] Auto-created first account, id=\(account.id)")
        } else {
            log.info("[updateActiveAccount] Logged-in account not in our list (might be new)")
        }
    }

    // MARK: - Adding accounts

    /// Whether the provider's CLI is installed here, so a new account can
    /// sign in through it.
    func canLoginNewAccount(_ provider: AIProviderType) -> Bool {
        switch provider {
        case .claudeCode: true
        case .codex: codexAvailable
        case .kimi: kimiAvailable
        case .gemini: false
        }
    }

    /// Signs in a new account through the provider's CLI and adds it,
    /// inside `credentialGate`.
    func loginNewAccount(_ provider: AIProviderType) async {
        await credentialGate.run { await self.loginNewAccountNow(provider) }
    }

    private func loginNewAccountNow(_ provider: AIProviderType) async {
        switch provider {
        case .claudeCode: await loginNewAccount()
        case .codex, .kimi: await loginNewManagedAccount(provider: provider)
        case .gemini: break
        }
    }

    /// Adds the account the provider's CLI is signed in to now.
    func captureCurrentAccount(_ provider: AIProviderType) async {
        switch provider {
        case .claudeCode: await addAccount()
        case .codex, .kimi: await captureCurrentManagedAccount(provider: provider)
        case .gemini: break
        }
    }

    // MARK: - Codex Account Management

    func addCurrentCodexAccount() async {
        await captureCurrentManagedAccount(provider: .codex)
    }

    func loginNewCodexAccount() async {
        await loginNewManagedAccount(provider: .codex)
    }

    private func switchToCodex(
        _ account: Account,
        refreshAfter: Bool,
        safelyRestarting processes: [RunningCodexProcess],
        closeTerminalTabs: Bool = false,
        liveReloading liveProcesses: [RunningCodexProcess] = []
    ) async {
        await credentialGate.run {
            await self.switchToCodexNow(account, refreshAfter: refreshAfter, safelyRestarting: processes,
                                        closeTerminalTabs: closeTerminalTabs, liveReloading: liveProcesses)
        }
    }

    private func switchToCodexNow(
        _ account: Account,
        refreshAfter: Bool,
        safelyRestarting processes: [RunningCodexProcess],
        closeTerminalTabs: Bool,
        liveReloading liveProcesses: [RunningCodexProcess]
    ) async {
        guard account.supportsProviderWorkloads else {
            errorMessage = account.providerUnavailableLabel ?? "This Codex account is unavailable."
            return
        }
        guard !account.isActive, let location = account.credentialLocation else { return }
        // Sessions stopped for the switch are reopened however it ends: once
        // the credential is promoted, or when a step fails.
        var stopped: CodexService.StoppedSessions?
        func resumeStopped() {
            guard let sessions = stopped else { return }
            stopped = nil
            let reopened = sessions.resume()
            failoverEvents.record(.codex, "Restarted \(reopened) of \(processes.count) Codex process(es) against the selected account.")
        }
        do {
            // Stop captured clients before touching ~/.codex/auth.json. A live
            // Codex process can refresh and rewrite that file, racing the
            // credential promotion and effectively undoing a safe switch.
            if !processes.isEmpty {
                let stoppedNow = try await codexService.stopForRestart(
                    processes,
                    codexHome: location,
                    shouldCloseTerminalTabs: closeTerminalTabs
                )
                stopped = stoppedNow
                guard stoppedNow.survivors.isEmpty else {
                    throw CodexServiceError.loginFailed(
                        "\(stoppedNow.survivors.count) Codex session(s) did not close; credentials were not switched."
                    )
                }
                log.info("[switchToCodex] Safely stopped \(processes.count) pre-switch Codex process(es)")
            }
            if let current = activeAccount(for: .codex),
               let currentLocation = current.credentialLocation {
                try codexService.syncSystemCredentials(
                    toManagedHome: currentLocation,
                    expectedEmail: current.email
                )
            }
            if let current = activeAccount(for: .codex), liveProcesses.isEmpty, processes.isEmpty {
                lastSwitchedAway[current.id] = Date()
            }
            try codexService.promoteToSystem(homePath: location)
            guard codexService.systemIdentity()?.email.caseInsensitiveCompare(account.email) == .orderedSame else {
                throw CodexServiceError.loginFailed("The promoted credentials did not match \(account.email).")
            }
            for index in accounts.indices where accounts[index].provider == .codex {
                accounts[index].isActive = accounts[index].id == account.id
                if accounts[index].id == account.id {
                    accounts[index].lastUsed = Date()
                }
            }
            saveAccounts(refreshWidget: true)
            resumeStopped()

            if !liveProcesses.isEmpty {
                let failures = codexService.requestCredentialReload(liveProcesses)
                guard failures.isEmpty else {
                    throw CodexServiceError.loginFailed(
                        "\(failures.count) running Codex session(s) could not reload credentials."
                    )
                }
                failoverEvents.record(
                    .codex,
                    "Signalled \(liveProcesses.count) running Codex session(s) to adopt the selected account without restarting."
                )
            }

            if refreshAfter {
                await refresh()
            }
        } catch {
            resumeStopped()
            errorMessage = error.localizedDescription
        }
    }

    private func reauthenticateCodexAccount(_ account: Account) async {
        await reauthenticateManagedAccount(account)
    }

    private func updateActiveCodexAccount() {
        let systemIdentity = codexService.systemIdentity()
        let activeIndex = systemIdentity.flatMap { identity in
            accounts.firstIndex(where: {
                  $0.provider == .codex &&
                      $0.email.caseInsensitiveCompare(identity.email) == .orderedSame
            })
        }
        for accountIndex in accounts.indices where accounts[accountIndex].provider == .codex {
            accounts[accountIndex].isActive = accountIndex == activeIndex
            if let location = accounts[accountIndex].credentialLocation,
               let identity = try? codexService.identity(codexHome: location) {
                accounts[accountIndex].displayName = identity.displayName
                accounts[accountIndex].orgName = identity.accountID
                // The login JWT can outlive a plan change. Use it only until
                // the first successful live usage response supplies plan_type.
                if accounts[accountIndex].subscriptionType == nil {
                    accounts[accountIndex].subscriptionType = identity.planType
                }
            }
        }
        saveAccounts()
    }

    // MARK: - Kimi Account Management

    func addCurrentKimiAccount() async {
        await captureCurrentManagedAccount(provider: .kimi)
    }

    func loginNewKimiAccount() async {
        await loginNewManagedAccount(provider: .kimi)
    }

    private func switchToKimi(_ account: Account, refreshAfter: Bool) async {
        await credentialGate.run { await self.switchToKimiNow(account, refreshAfter: refreshAfter) }
    }

    private func switchToKimiNow(_ account: Account, refreshAfter: Bool) async {
        guard !account.isActive, let location = account.credentialLocation else { return }
        do {
            if let current = activeAccount(for: .kimi), let currentLocation = current.credentialLocation {
                try kimiService.syncSystemCredentials(toManagedLocation: currentLocation)
            }
            try kimiService.promoteToSystem(location: location)
            for index in accounts.indices where accounts[index].provider == .kimi {
                accounts[index].isActive = accounts[index].id == account.id
                if accounts[index].id == account.id { accounts[index].lastUsed = Date() }
            }
            saveAccounts(refreshWidget: true)
            if refreshAfter { await refresh() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reauthenticateKimiAccount(_ account: Account) async {
        await reauthenticateManagedAccount(account)
    }
}
