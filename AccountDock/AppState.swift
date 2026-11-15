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

    @Published var accounts: [Account] = [] {
        didSet {
            credentialAuditAccountsChanged(from: oldValue)
            refreshAccountStatuses()
        }
    }
    /// What each account's card and account-list row show
    /// (`AccountStatus.make`), set only by `refreshAccountStatuses`
    /// whenever the accounts, their readings, their reading errors or the
    /// rejected sign-ins change; the views only draw it.
    @Published var accountStatuses: [UUID: AccountStatus] = [:]
    /// Processes whose own evidence names another account than the one
    /// AccountDock believes they read, by session (`noteProcessCredential`).
    @Published var flaggedCredentialProcesses: [String: FlaggedCredentialProcess] = [:]
    @Published var accountUsage: [UUID: UsageAPIResponse] = [:] {
        didSet { refreshAccountStatuses() }
    }
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
    
    @Published var accountUsageErrors: [UUID: UsageErrorState] = [:] {
        didSet { refreshAccountStatuses() }
    }

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
    @Published var rejectedCredentialAccounts: Set<UUID> = [] {
        didSet { refreshAccountStatuses() }
    }
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
    /// Each isolated provider's slot state (`SessionSlotState`), kept by
    /// `maintainSessionSlots` and `refreshSlotProcesses`; read across
    /// providers through `slotDirectoryByProcess`, `slotDirectoryServing`,
    /// `slotServedAccounts` and `slotCredentialAccounts`.
    var sessionSlotStates: [AIProviderType: SessionSlotState] = [:]
    /// Sessions `handleExternalRequests` was asked to move, by destination;
    /// `serveSessionSlots` moves each at once and forgets it.
    var requestedSlotMoves: [String: UUID] = [:]
    /// Sessions the user moved by hand that are pinned once their slot
    /// serves the destination (`settleMovePins`): a move by restarting
    /// lands later, and a pinned session is never restarted.
    var movePins: [String: MovePin] = [:]
    /// Moves of sessions whose CLI moves only by restarting
    /// (`ProviderSessionIsolation.movesNeedRestart`), chosen by
    /// `serveSessionSlots` while each was idle, by session ID; applied by
    /// `applySlotRestarts` once the pass is over.
    var pendingSlotRestarts: [String: PendingSlotRestart] = [:]
    /// Sessions restarted on another account, by session ID, until the
    /// resumed run has started: `maintainSessionSlots` keeps a spare slot of
    /// that account and names it in the resume file for them.
    var slotRestartResumes: [String: SlotRestartResume] = [:]
    /// Sessions a restart could not reach, recorded once each until one
    /// succeeds.
    var slotRestartsNoted: Set<String> = []
    /// Guards `maintainSessionSlots` against running twice at once, and
    /// records a call that arrived meanwhile, which is then run after.
    var slotMaintenanceRunning = false
    var slotMaintenanceRequested = false
    /// What `serveSlot` last wrote to each slot directory and when it last
    /// read the slot's item back, so a slot already holding the credential
    /// is not read from the Keychain again on every quota cycle.
    var slotCredentialWritten: [String: (digest: String, at: Date)] = [:]
    /// The renewal of the active account's live credential in progress, so
    /// concurrent callers of `claudeCredential` share one: a second renewal
    /// would present the refresh token the first has just replaced.
    var liveCredentialRenewal: Task<String?, Never>?
    /// When each one-session slot last moved to another account.
    var slotDirectoryMovedAt: [String: Date] = [:]
    /// The accounts each one-session slot was assigned, oldest first, so a
    /// request is attributed to the account serving it at its own time
    /// (`servingSlotAccount`).
    var slotAccountHistory: [String: [SlotAssignment]] = [:]
    /// When each session's transcript last showed its cache rebuilt whole
    /// (`CredentialAudit.noteRequest`), which shows a slot move took effect.
    var sessionCacheRebuiltAt: [String: Date] = [:]
    /// Accounts a threshold or balancing switch left, whose running sessions
    /// stay on them until `moveSessionsOffLimitedAccounts` moves them.
    var sessionsLeftOn: [AIProviderType: Set<UUID>] = [:]
    /// Accounts a threshold switch left while they still had room, with
    /// when: `buildPool` keeps a share of new sessions on each, and its
    /// sessions where they are, until a reading or a refusal shows its limit.
    var drainingAccounts: [UUID: Date] = [:]
    /// When each account's newest reading a running session reported with
    /// a response (`PassiveUsageObservation.Source.reportsWithEachResponse`)
    /// was taken; `quotaState` passes it on while it is the newest reading.
    var liveReadingAt: [UUID: Date] = [:]
    /// When the router last recorded a refusal at the limit by each account,
    /// for `routerRefusedUntil`; a newer live reading with room answers it.
    var routerRefusedAt: [UUID: Date] = [:]
    /// When each provider's standing status becomes an event (`updateStatus`).
    var statusEventGates: [AIProviderType: StatusEventGate] = [:]
    /// Types into the terminals sessions run in (`SessionTerminalActions`).
    var sessionTerminal: SessionTerminalInput = AgtermTerminalInput()
    /// Sessions without allowance for their model anywhere, by session ID,
    /// with the model `applyModelFallbacks` switches each to once it is idle.
    var pendingModelFallbacks: [String: String] = [:]
    /// The refusal each session was last resumed from a CLI wait for
    /// (`resumeSessionsLeftWaiting`), by its time, so one refusal resumes a
    /// session once.
    var leftWaitingResumed: [String: Date] = [:]
    /// Running sessions that read no slot of their own, by provider
    /// (`noteUnisolatedSessions`), for the usage tab.
    @Published var unisolatedSessions: [AIProviderType: [AgentSession]] = [:]
    /// The terminal session each of those runs in, when
    /// `sessionTerminal` can reach it.
    @Published var unisolatedTerminals: [String: String] = [:]
    /// Unisolated sessions already recorded as an event.
    var unisolatedNoted: Set<String> = []
    /// The unisolated sessions that run in a background worker, with what
    /// decides whether each can be restarted in a slot of its own
    /// (`noteUnisolatedSessions`), for the usage tab.
    @Published var backgroundSessionStates: [String: BackgroundSessionState] = [:]
    /// Ends background sessions (`restartBackgroundSession`).
    var backgroundSessionControl: BackgroundSessionControl = CLIBackgroundSessionControl()
    /// Background sessions on an account that can no longer serve them,
    /// by session ID, with that account (`handleStuckBackgroundSessions`),
    /// for the usage tab.
    @Published var stuckBackgroundSessions: [String: StuckBackgroundSession] = [:]
    /// Stuck background sessions already offered in an event, until they
    /// are no longer stuck.
    var stuckBackgroundNoted: Set<String> = []
    /// When each stuck background session was last restarted without being
    /// asked, so a restart that did not take is tried again only after
    /// `stuckRestartSpacing`.
    var stuckBackgroundRestartedAt: [String: Date] = [:]

    /// The session each slot directory serves, as its status line reported
    /// it (`PassiveUsageObservation.slotDirectory`): `serveSessionSlots`
    /// finds a slot's model by it when the slot's process left no session
    /// record.
    var slotSessionsByDirectory: [String: String] = [:]
    /// When each provider's sessions were last rebalanced (`applyRebalance`).
    var lastRebalance: [AIProviderType: Date] = [:]
    /// When a slot session last moved to each account to spend an allowance
    /// that would otherwise expire (`serveSessionSlots`);
    /// `remainderSpending` offers that account again only
    /// `balanceMoveInterval` later.
    var remainderMovedAt: [UUID: Date] = [:]
    /// Where each account's token cost last came from (`accountRatio`),
    /// so the log records each change of seed once.
    var ratioSources: [UUID: TurnCostModel.RatioSource] = [:]
    /// Sessions pinned to one subscription, kept across launches
    /// (`SessionPins`); read by every path that moves a slot session.
    @Published var sessionPins = SessionPins.load()
    /// Pinned sessions recorded as kept on an account that can no longer
    /// serve them, until it can again or they are unpinned.
    var pinnedKeptAtLimit: Set<String> = []
    /// The account each provider's shared group was last projected to move
    /// to, so `noteSharedGroup` records each change once.
    var sharedGroupDestination: [AIProviderType: UUID] = [:]
    /// A locally elapsed reset is useful for clearing a stale 100% display,
    /// but it is not proof that the provider has opened a new quota window.
    /// Never fail over to one of these accounts until a fresh API response
    /// confirms its post-reset capacity. Kept in the usage snapshots, so a
    /// cleared reading saved before a relaunch is not taken for a reading
    /// of 0% after it; `verifyPassedResets` reads these accounts.
    var accountsAwaitingPostResetVerification: Set<UUID> = []
    /// When each account in `accountsAwaitingPostResetVerification` was
    /// last cleared at a reset, so its reading waits `postResetSettle` for
    /// the provider to open the new window.
    var passedResetAt: [UUID: Date] = [:]
    /// When `verifyPassedResets` last read each such account and the reading
    /// confirmed nothing, so an account whose readings keep failing is read
    /// again only after `postResetRetrySpacing`.
    var postResetReadFailedAt: [UUID: Date] = [:]
    /// Windows of one account to start (`performWindowWarmup`).
    struct PendingWindowWarmup: Equatable {
        var session = false
        var weekly = false
        /// When the provider said the window whose reset armed this would
        /// reset; nil when a reading armed it.
        var resetAt: Date? = nil

        var isEmpty: Bool { !session && !weekly }
    }
    /// The windows a passed reset left to start on each account, until a
    /// reading of it settles them or the warm-up runs.
    private var pendingWindowWarmups: [UUID: PendingWindowWarmup] = [:]
    /// Consecutive warm-ups of each account that failed for a reason other
    /// than the request allowance or a cool-down (`warmupRetryDelay`).
    private var warmupRetryAttempts: [UUID: Int] = [:]
    /// The retry waiting for each account; a reading arriving meanwhile
    /// leaves the warm-up to it unless the probe can run at once.
    private var warmupRetries: [UUID: Task<Void, Never>] = [:]
    /// Accounts whose warm-up failed past `warmupFailureDelays`; tried
    /// again only once another reset passes.
    private var warmupGivenUp: Set<UUID> = []
    /// When a probe last started a window on each account, so a provider
    /// still reporting the window unstarted does not start a second probe.
    private var lastWarmupProbeAt: [UUID: Date] = [:]
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
    var routerEventCursor: RouterEventCursor?
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
    /// Pinned sessions the user played while a pause held them for their
    /// account's threshold or limit, with that account. `limitPauseScope`
    /// and `holdPinnedSessionsAtLimit` leave each running until the account
    /// has room again or the session is no longer pinned to it.
    var pinnedHoldsPlayed: [String: UUID] = [:]
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
        syncCredentialAuditAccounts()
        installCredentialAuditEvents()
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
        // Codex sessions write rollouts in Codex's own home and in each
        // account's managed home.
        let codexHomes = accounts.filter { $0.provider == .codex }.compactMap(\.credentialLocation)
        async let usageIndexRefresh: Void = UsageIndex.shared.refreshFromFilesystem(codexHomes: codexHomes)

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
                AgentHookInstaller.refreshInstalledShellHookScripts()
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
        /// Makes the copy at a location live; the second argument is the audit reason.
        let activate: (String, String) throws -> Void
        /// Deletes the copy at a location; the second argument is the audit reason.
        let remove: (String, String) throws -> Void
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
                activate: { [codexService] in try codexService.promoteToSystem(homePath: $0, reason: $1) },
                remove: { [codexService] in try codexService.removeManagedAccount(homePath: $0, reason: $1) }
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
                activate: { [kimiService] in try kimiService.promoteToSystem(location: $0, reason: $1) },
                remove: { [kimiService] in try kimiService.removeManagedAccount(location: $0, reason: $1) }
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
            try? adapter.remove(identity.credentialLocation, "registerManagedAccount.duplicate")
            throw ManagedProviderError.duplicate(adapter.provider.capabilities.displayName)
        }
        if makeActive {
            try adapter.activate(identity.credentialLocation, "registerManagedAccount.first")
            for index in accounts.indices where accounts[index].provider == adapter.provider {
                accounts[index].isActive = false
            }
        }
        let added = Account(
            email: identity.identifier,
            displayName: identity.displayName,
            provider: adapter.provider,
            orgName: identity.accountMetadata,
            subscriptionType: identity.planType,
            isActive: makeActive,
            credentialLocation: identity.credentialLocation
        )
        accounts.append(added)
        excludeAddedAccountFromFailover(added)
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
            // The login is isolated from the live credential, so the account
            // active before stays active; the first of a provider becomes it.
            let first = activeAccount(for: provider) == nil
            try registerManagedAccount(identity, using: adapter, makeActive: first)
        } catch {
            guard loginAttemptID == loginID else { return }
            errorMessage = error.localizedDescription
            log.error("[provider-auth] \(provider.rawValue) login failed: \(error.localizedDescription)")
        }
    }

    private func captureCurrentManagedAccount(provider: AIProviderType) async {
        guard let adapter = managedProviderAdapter(for: provider) else { return }
        do {
            // The live credential is the captured account's. The account active
            // before is put back live and stays active; the first of a
            // provider becomes it.
            let previous = activeAccount(for: provider)
            try registerManagedAccount(try await adapter.captureCurrent(), using: adapter, makeActive: previous == nil)
            if let location = previous?.credentialLocation { try adapter.activate(location, "captureCurrentManagedAccount.restorePrevious") }
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
                try? adapter.remove(identity.credentialLocation, "reauthenticateManagedAccount.wrongAccount")
                throw KimiServiceError.requestFailed(
                    "Logged in as \(identity.identifier), expected \(account.email)."
                )
            }
            guard let index = accounts.firstIndex(where: { $0.id == account.id }) else {
                try? adapter.remove(identity.credentialLocation, "reauthenticateManagedAccount.accountGone")
                return
            }
            let oldLocation = accounts[index].credentialLocation
            accounts[index].credentialLocation = identity.credentialLocation
            accounts[index].displayName = identity.displayName
            accounts[index].orgName = identity.accountMetadata
            accounts[index].subscriptionType = identity.planType
            if account.isActive { try adapter.activate(identity.credentialLocation, "reauthenticateManagedAccount.active") }
            credentialQuarantine[account.id] = nil
            rejectedCredentialAccounts.remove(account.id)
            saveAccounts(refreshWidget: true)
            if let oldLocation, oldLocation != identity.credentialLocation {
                try? adapter.remove(oldLocation, "reauthenticateManagedAccount.replaced")
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

    /// Leaves an account just added out of automatic failover and balancing:
    /// the user includes it in the provider's failover settings when it
    /// should take work. The first account of a provider is included, since
    /// it is the one the provider's sessions run on.
    func excludeAddedAccountFromFailover(_ account: Account) {
        guard accounts.contains(where: { $0.provider == account.provider && $0.id != account.id }) else { return }
        failoverConfig.update(account.provider) { $0.excludedAccountIDs.insert(account.id) }
        failoverEvents.record(account.provider, "\(messageName(account)) was added with failover off; include it under Failover in Settings when it should take work.")
    }

    /// Keeps `previous` the active account after a sign-in left the CLI
    /// signed in to `added`, an account just added: the sign-in is captured
    /// for `added`, then `previous` is switched back, so adding an account
    /// moves no session. The first account of a provider has no `previous`
    /// and becomes the active one. When `previous` cannot be put back,
    /// `added` stays active and an event says so.
    func keepActiveAfterAdding(_ added: UUID, previous: Account?) async {
        guard let account = accounts.first(where: { $0.id == added }) else { return }
        // `performSwitch` starts from the account the CLI is signed in to.
        accounts.makeActive(added)
        saveAccounts(refreshWidget: true)
        noteLiveCredentialOwner(account.provider, account: added)
        guard let previous, previous.id != added else { return }
        await performSwitch(to: previous, refreshAfter: false)
        if activeAccount(for: account.provider)?.id == previous.id {
            // Sessions that read the sign-in while it was `added`'s read it again.
            moveRunningSessions(account.provider, from: added, reason: "keepActiveAfterAdding")
            log.info("[addAccount] Kept the account that was active")
        } else {
            failoverEvents.record(account.provider, "\(messageName(account)) was added and is now the active account, because \(messageName(previous)) could not be put back; sessions on the shared sign-in follow it.")
        }
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

            let account = Account(
                email: email,
                displayName: status.orgName ?? email,
                provider: .claudeCode,
                orgName: status.orgName,
                subscriptionType: status.subscriptionType
            )
            log.info("[addAccount] Created account model, id=\(account.id)")

            log.info("[addAccount] Capturing token from keychain...")
            let captured = await captureOwnCredential(of: account, reason: "addAccount")
            if captured != .saved {
                errorMessage = Self.captureFailure(captured, account: account)
                log.error("[addAccount] Token capture failed!")
                return
            }
            log.info("[addAccount] Token captured successfully")

            let previous = activeAccount(for: .claudeCode)
            accounts.append(account)
            excludeAddedAccountFromFailover(account)
            await keepActiveAfterAdding(account.id, previous: previous)
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
            // The sign-in runs isolated (`ClaudeIsolatedLogin`): the live
            // sign-in and every session on it are left as they are.
            log.info("[loginNewAccount] Running isolated `claude auth login`...")
            let (signIn, outcome) = try await isolatedClaudeSignIn(reauthenticating: nil, reason: "loginNewAccount.isolated")
            switch outcome {
            case .wrongAccount:
                return
            case .refresh(let id):
                log.info("[loginNewAccount] Account already exists, refreshing its saved sign-in")
                guard let existing = accounts.first(where: { $0.id == id }) else { return }
                saveIsolatedSignIn(signIn, for: existing, reason: "loginNewAccount.refresh")
                errorMessage = String(localized: "Account already exists - credentials refreshed", bundle: L10n.bundle)
                return
            case .add(let email):
                let orgName = signIn.identity["organizationName"]?.value as? String
                // The first account of the provider becomes the active one;
                // any other is added beside the account in use.
                let first = !accounts.contains { $0.provider == .claudeCode }
                let account = Account(
                    email: email,
                    displayName: orgName ?? email,
                    provider: .claudeCode,
                    orgName: orgName,
                    subscriptionType: ClaudeIsolatedLogin.subscriptionType(of: signIn.token),
                    isActive: first
                )
                accounts.append(account)
                excludeAddedAccountFromFailover(account)
                saveIsolatedSignIn(signIn, for: account, reason: "loginNewAccount.add")
                saveAccounts(refreshWidget: true)
                log.info("[loginNewAccount] Added \(account.id) (active: \(first)). Total: \(self.accounts.count)")
            }

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
            if let location = account.credentialLocation { try? adapter.remove(location, "removeAccount") }
        } else {
            keychain.removeAccountBackup(forAccountId: account.id.uuidString, reason: "removeAccount")
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
        warmupRetries.removeValue(forKey: id)?.cancel()
        warmupGivenUp.remove(id)
        lastWarmupProbeAt[id] = nil
        passedResetAt[id] = nil
        postResetReadFailedAt[id] = nil
        routedSessions[id] = nil
        accountSessions[id] = nil
        rejectedCredentialAccounts.remove(id)
        for provider in Array(sessionSlotStates.keys) { sessionSlotStates[provider]?.forget(id) }
        accountsAwaitingPostResetVerification.remove(id)
        accountWarmupsInFlight.remove(id)
        pacingShedding.remove(id)
        pacingScopedShedding = pacingScopedShedding.filter { !$0.hasPrefix(id.uuidString + "|") }
        for provider in exhaustedFailoverAccounts.keys { exhaustedFailoverAccounts[provider]?.remove(id) }
        for provider in sessionsLeftOn.keys { sessionsLeftOn[provider]?.remove(id) }
        drainingAccounts[id] = nil
        liveReadingAt[id] = nil
        routerRefusedAt[id] = nil
        liveCredentialOwners = liveCredentialOwners.filter { $0.value.account != id }
        lockedSwitchNoted = lockedSwitchNoted.filter { $0.value != id }
        pendingResetRecovery = pendingResetRecovery.filter { $0.value.accountID != id }
        suspensionContexts = suspensionContexts.filter { $0.value.accountID != id }
        userResumes = userResumes.mapValues { $0.filter { $0.value != id } }
        sessionAdmissions = sessionAdmissions.mapValues { $0.filter { $0.value.account != id } }
        requestedSlotMoves = requestedSlotMoves.filter { $0.value != id }
        remainderMovedAt[id] = nil
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
        guard keychain.hasAccountBackup(forAccountId: account.id.uuidString) else {
            log.error("[switchTo] ABORT: no backup for target account")
            errorMessage = String(localized: "No stored credentials for \(account.email). Use re-authenticate to fix.", bundle: L10n.bundle)
            return
        }

        // The outgoing account's live credential is saved as its copy only
        // when the provider says it is that account's: sessions on the
        // shared sign-in rewrite the slot and the identity file at any time.
        if currentActive.id != account.id {
            let backup = await captureOwnCredential(of: currentActive, reason: "switchTo.backupCurrent")
            log.info("[switchTo] Backup of the outgoing account: \(String(describing: backup))")
        }

        do {
            let status = try await claudeService.switchAccount(from: currentActive, to: account)
            credentialAudit.record(.switch, .claudeCode, account: account.id, outcome: "ok", reason: "switchTo",
                                   detail: "from \(currentActive.id.uuidString)")
            rejectedCredentialAccounts.remove(account.id)
            credentialQuarantine[account.id] = nil
            // Claude processes keep the credential they hold until signalled,
            // so the previous account can go on being consumed after this
            // switch. A switch the user asks for moves them at once.
            lastSwitchedAway[currentActive.id] = Date()
            noteLiveCredentialOwner(.claudeCode, account: account.id)
            if refreshAfter { moveRunningSessions(.claudeCode, from: currentActive.id, reason: "switchTo") }

            var verifiedSubscription = status.subscriptionType
            if let tokenJSON = keychain.readClaudeToken(reason: "switchTo.livePlan", account: account.id),
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
            _ = await captureOwnCredential(of: account, reason: "switchTo.keepRenewed")
            saveAccounts()
            await routerFollowActiveAccount()

            if refreshAfter {
                await refresh()
                await warmSelectedAccountIfNeeded(account.id)
            }
            log.info("[switchTo] ===== Switch completed =====")
        } catch {
            credentialAudit.record(.switch, .claudeCode, account: account.id, outcome: "failed", reason: "switchTo",
                                   detail: "from \(currentActive.id.uuidString): \(error.localizedDescription)")
            errorMessage = error.localizedDescription
            if Self.switchFailureQuarantines(error) {
                quarantineCredentials(of: account, reason: error.localizedDescription)
            }
            log.error("[switchTo] Switch failed: \(error.localizedDescription)")
        }
    }

    /// Whether a failed Claude switch (`ClaudeService.switchAccount`) shows
    /// the target's saved credential unusable, so the target is kept from
    /// automatic switching until it signs in again: no saved credential,
    /// the provider rejecting it, or the provider naming another account
    /// as its owner. A switch nothing confirmed or refuted quarantines
    /// nothing.
    nonisolated static func switchFailureQuarantines(_ error: Error) -> Bool {
        switch error {
        case ClaudeServiceError.switchVerificationFailed, ClaudeServiceError.switchWrongAccount,
             ClaudeServiceError.noTokenForAccount:
            true
        default:
            false
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

        do {
            // The sign-in runs isolated (`ClaudeIsolatedLogin`): the active
            // account and every session on the shared sign-in stay as they
            // are, so nothing needs putting back.
            log.info("[reauth] Running isolated `claude auth login`...")
            let (signIn, outcome) = try await isolatedClaudeSignIn(reauthenticating: account, reason: "reauthenticate.isolated")
            guard case .refresh = outcome else { return }
            saveIsolatedSignIn(signIn, for: account, reason: "reauthenticate.save")
            if let index = accounts.firstIndex(where: { $0.id == account.id }) {
                if let orgName = signIn.identity["organizationName"]?.value as? String { accounts[index].orgName = orgName }
                if let plan = ClaudeIsolatedLogin.subscriptionType(of: signIn.token) { accounts[index].subscriptionType = plan }
                saveAccounts()
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
                let outcome = await readUsage(account, forced: forceUnavailablePlanCheck, includeMetadata: true,
                                              priority: priority)
                applyUsageRead(outcome, for: account)
            }
        }
    }

    /// Reads `account`'s usage with its provider's reader. With
    /// `includeMetadata`, the reader also refreshes the plan and identity
    /// the provider reports, which costs some providers another request.
    /// `resetDetails` asks a provider whose usage reply only counts the
    /// account's limit resets for their details too; Claude's reply always
    /// holds them. `priority` is the one the caller spent the reading's
    /// request at, which a second request the reading needs is charged
    /// against (`savedCopyIsOwn`).
    func readUsage(_ account: Account, forced: Bool, includeMetadata: Bool,
                   resetDetails: Bool = false, priority: UsageRequestBudget.Priority = .background) async -> UsageReadOutcome {
        switch account.provider {
        case .claudeCode: await readClaudeUsage(account, forced: forced, includeMetadata: includeMetadata, priority: priority)
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
            // A reply still naming a reset that has passed describes the
            // window before it, taken before the provider opened the next.
            recordUsage(usage, for: account.id, confirmsReset: !usage.hasPassedReset(at: Date()), whole: true)
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
            if includeMetadata, let identity = try? await kimiService.identity(location: location, reason: "readKimiUsage.metadata"),
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
    private func readClaudeUsage(_ account: Account, forced: Bool, includeMetadata: Bool,
                                 priority: UsageRequestBudget.Priority) async -> UsageReadOutcome {
        var tokenJSON: String?
        var usesSavedCopy = false
        if readsLiveCredential(account) {
            tokenJSON = keychain.readClaudeToken(reason: "readClaudeUsage.live", account: account.id)
        } else {
            usesSavedCopy = true
            tokenJSON = keychain.getAccountBackup(forAccountId: account.id.uuidString, reason: "readClaudeUsage.saved")?.token
            // An idle account's token is renewed before it expires, which
            // saves the rejected request a stale token would cost.
            if let stored = tokenJSON, ClaudeCredentialModule.expires(stored, within: 2 * 60),
               await renewSavedCredential(account, reason: "readClaudeUsage.expiring") == .renewed {
                tokenJSON = keychain.getAccountBackup(forAccountId: account.id.uuidString, reason: "readClaudeUsage.renewed")?.token
            }
        }
        guard let tokenJSON, let accessToken = ClaudeService.extractAccessToken(from: tokenJSON) else {
            log.warning("[fetchUsage] No token for \(account.email), skipping")
            return .skipped
        }
        if usesSavedCopy {
            let check = await savedCopyIsOwn(account, tokenJSON: tokenJSON, accessToken: accessToken, forced: forced,
                                             priority: priority)
            if check == .notOwn {
                return .credentialRejected("This account's saved sign-in was another account's. Sign it in again.")
            }
            // A copy not yet checked may be another account's, whose usage
            // its reading would show as this account's.
            guard Self.recordsReading(after: check) else { return .skipped }
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
                guard let refreshed = keychain.readClaudeToken(reason: "readClaudeUsage.liveRenewed", account: account.id).flatMap(ClaudeService.extractAccessToken(from:)) else {
                    throw ClaudeService.UsageError.expired
                }
                accessToken = refreshed
            } catch {
                log.error("[fetchUsage] Delegated refresh failed for active account: \(error.localizedDescription)")
                return .credentialUnrenewed(String(localized: "Token expired. Switch to refresh.", bundle: L10n.bundle))
            }
        } else {
            switch await renewSavedCredential(account, reason: "readClaudeUsage.rejected") {
            case .renewed:
                let stored = keychain.getAccountBackup(forAccountId: account.id.uuidString, reason: "readClaudeUsage.renewed")?.token
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

    // Usage snapshots are saved as `PersistedUsageSnapshot`, which holds the
    // neutral `UsageReading` and still loads a snapshot saved in the reply's
    // form.

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

    /// A provider's accounts in the order their usage is read
    /// (`readUrgencyOrder`). Every account of a provider shares one request
    /// budget, so a fixed order would leave the accounts at the end of the
    /// list unread whenever the budget runs short.
    func accountsByReadUrgency(_ provider: AIProviderType) -> [Account] {
        let serving = Set(accounts.filter { account in
            account.provider == provider
                && (slotServedAccounts.contains(account.id) || accountSessions[account.id]?.isEmpty == false)
        }.map(\.id))
        return Self.readUrgencyOrder(accounts.filter { $0.provider == provider }, serving: serving,
                                     updatedAt: accountUsageUpdatedAt)
    }

    /// The active account, then the accounts sessions run on (`serving`),
    /// then the idle ones, each oldest reading first. Sessions consume a
    /// serving account unseen, and `buildPool` trusts its reading less as
    /// it ages (`FailoverPlanner.poolReadingConfidence`); an idle account
    /// changes only at its resets, so the idle accounts at their limits,
    /// read every `idleAtLimitReadingInterval`, would otherwise spend the
    /// budget first whenever a passive reading has made a serving
    /// account's reading look newer.
    nonisolated static func readUrgencyOrder(_ accounts: [Account], serving: Set<UUID>,
                                             updatedAt: [UUID: Date]) -> [Account] {
        accounts.sorted { a, b in
            if a.isActive != b.isActive { return a.isActive }
            let (aServes, bServes) = (serving.contains(a.id), serving.contains(b.id))
            if aServes != bServes { return aServes }
            return (updatedAt[a.id] ?? .distantPast) < (updatedAt[b.id] ?? .distantPast)
        }
    }

    /// Stores a reading of `accountID`. `confirmsReset` says the reading
    /// shows the account's windows as the provider holds them now, which
    /// ends `accountsAwaitingPostResetVerification`; `whole` says it came
    /// from the provider's own endpoint just now (`applyUsageRead`), so a
    /// warm-up may start a window it shows unstarted without reading the
    /// account again (`warmWindowsIfUnstarted`).
    func recordUsage(
        _ usage: UsageAPIResponse,
        for accountID: UUID,
        observedAt: Date = Date(),
        confirmsReset: Bool = true,
        whole: Bool = false
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
        if confirmsReset {
            accountsAwaitingPostResetVerification.remove(accountID)
            passedResetAt[accountID] = nil
            postResetReadFailedAt[accountID] = nil
        }
        if let account = accounts.first(where: { $0.id == accountID }) {
            learnFromReading(reconciled, previous: previousUsage, account: account, at: observedAt)
        }
        saveUsageSnapshots()
        scheduleNextUsageReset()
        warmWindowsIfUnstarted(accountID, verified: whole && confirmsReset)
    }

    /// Starts a warm-up for the windows the account's newest reading shows
    /// unused and unstarted (`windowsToWarm`): those a passed reset left
    /// pending (`pendingWindowWarmups`), or any such window. A `verified`
    /// reading settles the pending windows and lets the probe run at once
    /// (`warmupStep`); any other reading leaves the warm-up to read the
    /// account first, and to a retry already waiting. Called by
    /// `recordUsage` for every reading; a warm-up under way records its
    /// own readings and is not started again by them.
    private func warmWindowsIfUnstarted(_ accountID: UUID, verified: Bool) {
        guard !accountWarmupsInFlight.contains(accountID),
              let account = accounts.first(where: { $0.id == accountID }),
              failoverConfig.policy(for: account.provider).keepWindowsWarm else { return }
        let pending = pendingWindowWarmups[accountID]
        if verified { pendingWindowWarmups[accountID] = nil }
        guard verified || warmupRetries[accountID] == nil,
              pending != nil || !warmupGivenUp.contains(accountID) else { return }
        let requested = pending ?? PendingWindowWarmup(session: true, weekly: true)
        let step = Self.warmupStep(requested: requested, stored: accountUsage[accountID], verifiedAt: verified ? Date() : nil,
                                   unusedSinceReset: false, sessionQuota: account.provider.capabilities.supportsSessionQuota,
                                   lastProbeAt: lastWarmupProbeAt[accountID], now: Date())
        guard step != .none else { return }
        if pending == nil { log.info("[warmup] Scheduled one-time bootstrap for \(accountID.uuidString)") }
        Task { await performWindowWarmup(accountID: accountID, windows: requested) }
    }

    /// The windows of `requested` a reading shows unused and unstarted
    /// (`UsageWindow.isUnusedUnstartedWindow`), and so worth one probe. A
    /// session window only on a provider that has one (`sessionQuota`), in
    /// a reading that carries one (an account whose plan has none never
    /// gets a session warm-up), and while the long window has room, since
    /// a session window that cannot be used gains nothing from starting.
    /// Consumed by `warmWindowsIfUnstarted`, `warmupStep` and
    /// `warmSelectedAccountIfNeeded`.
    nonisolated static func windowsToWarm(_ usage: UsageAPIResponse?, requested: PendingWindowWarmup,
                                          sessionQuota: Bool) -> PendingWindowWarmup {
        guard let usage else { return PendingWindowWarmup() }
        let longRoom = usage.sevenDay?.utilization.map { $0 < 100 } == true
        return PendingWindowWarmup(
            session: requested.session && sessionQuota && longRoom && usage.fiveHour?.isUnusedUnstartedWindow == true,
            weekly: requested.weekly && usage.sevenDay?.isUnusedUnstartedWindow == true
        )
    }

    /// What a warm-up does next (`performWindowWarmup`).
    enum WarmupStep: Equatable {
        /// No requested window is unstarted, or one was just started.
        case none
        /// Start these windows now.
        case probe(PendingWindowWarmup)
        /// Read the account first and decide from that reading.
        case readFirst
    }

    /// How long a whole reading shows an unstarted window well enough for
    /// a probe to start it without another reading.
    nonisolated static let warmupEvidenceLifetime: TimeInterval = 60
    /// How long after the provider's reset time a warm-up may start the new
    /// window from the reset alone, so the probe never lands in the window
    /// that is ending.
    nonisolated static let warmupResetMargin: TimeInterval = 60
    /// How soon after a probe another one may start a window of the same
    /// account, unless a reset has passed since: a provider can keep
    /// reporting a started window as unstarted for a while.
    nonisolated static let warmupRepeatSpacing: TimeInterval = 30 * 60

    /// The warm-up's next step for `requested` on the stored reading
    /// `stored`. The probe runs at once when a whole reading confirmed the
    /// windows unstarted within `warmupEvidenceLifetime` (`verifiedAt`),
    /// or when the provider's reset time (`requested.resetAt`) passed at
    /// least `warmupResetMargin` ago on an account nothing has used since
    /// (`unusedSinceReset`) whose credential is known to be its own: the
    /// window then cannot have started. Otherwise the account is read
    /// first. A window started by a probe within `warmupRepeatSpacing`
    /// (`lastProbeAt`) is not probed again before another reset.
    nonisolated static func warmupStep(requested: PendingWindowWarmup, stored: UsageAPIResponse?, verifiedAt: Date?,
                                       unusedSinceReset: Bool, sessionQuota: Bool, lastProbeAt: Date?,
                                       now: Date) -> WarmupStep {
        let windows = windowsToWarm(stored, requested: requested, sessionQuota: sessionQuota)
        guard !windows.isEmpty else { return .none }
        if let probed = lastProbeAt, now.timeIntervalSince(probed) < warmupRepeatSpacing,
           requested.resetAt.map({ $0 <= probed }) ?? true {
            return .none
        }
        if let verifiedAt, now.timeIntervalSince(verifiedAt) < warmupEvidenceLifetime { return .probe(windows) }
        if let reset = requested.resetAt, now.timeIntervalSince(reset) >= warmupResetMargin, unusedSinceReset {
            return .probe(windows)
        }
        return .readFirst
    }

    /// Why a warm-up did not run, which sets when it is tried again
    /// (`warmupRetryDelay`).
    enum WarmupDeferral: Equatable {
        /// The usage endpoint's cool-down or the request allowance holds
        /// the warm-up's reading back until then.
        case heldUntil(Date)
        /// The reading or the probe failed for another reason.
        case failed
    }

    /// The waits after one, two, three and four failed warm-ups in a row.
    nonisolated static let warmupFailureDelays: [TimeInterval] = [2 * 60, 5 * 60, 15 * 60, 30 * 60]

    /// Seconds until a deferred warm-up is tried again: just after the
    /// cool-down or the allowance lets its reading through, or along
    /// `warmupFailureDelays` after `failures` failures; nil once those are
    /// spent, when it waits for the next reset.
    nonisolated static func warmupRetryDelay(_ deferral: WarmupDeferral, failures: Int, now: Date) -> TimeInterval? {
        switch deferral {
        case .heldUntil(let until):
            return max(1, until.timeIntervalSince(now) + 1)
        case .failed:
            guard failures >= 1, failures <= warmupFailureDelays.count else { return nil }
            return warmupFailureDelays[failures - 1]
        }
    }

    /// The deferral a probe's error asks for: a provider's rate limit holds
    /// it until the time it names, a minute when it names none.
    nonisolated static func warmupDeferral(for error: Error, now: Date) -> WarmupDeferral {
        switch error {
        case ClaudeService.UsageError.rateLimited(let retryAt): .heldUntil(retryAt ?? now.addingTimeInterval(60))
        case CodexServiceError.rateLimited(let retryAt): .heldUntil(retryAt ?? now.addingTimeInterval(60))
        case KimiServiceError.rateLimited: .heldUntil(now.addingTimeInterval(60))
        default: .failed
        }
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
            if Self.snapshotAwaitsVerification(snapshot.usage, resetUnverified: snapshot.resetUnverified) {
                accountsAwaitingPostResetVerification.insert(id)
            }
        }
        scheduleNextUsageReset()
    }

    /// Whether a saved reading loads as awaiting a verifying reading
    /// (`accountsAwaitingPostResetVerification`), and so counts as unknown
    /// rather than as the 0% it shows: it was saved so
    /// (`resetUnverified`), or it holds a window with no use and no
    /// countdown. Such a window is as old as its reading, since anything
    /// that used the account since started it unseen, and a snapshot saved
    /// without `resetUnverified` cannot tell it from one cleared at a reset.
    nonisolated static func snapshotAwaitsVerification(_ usage: UsageAPIResponse, resetUnverified: Bool?) -> Bool {
        resetUnverified == true || usage.fiveHour?.isUnusedUnstartedWindow == true
            || usage.sevenDay?.isUnusedUnstartedWindow == true
    }

    /// Applies provider-confirmed reset timestamps locally. This is deliberately
    /// independent of token validity and network availability. Each account
    /// cleared here awaits a reading that confirms the reset
    /// (`verifyPassedResets`, which the next quota cycle runs once
    /// `postResetSettle` has passed), and the windows that reset are left
    /// for a warm-up (`pendingWindowWarmups`).
    private func reconcilePassedUsageResets(now: Date = Date()) {
        var changed = false
        for id in accountUsage.keys {
            guard let usage = accountUsage[id], usage.hasPassedReset(at: now) else { continue }
            if let account = accounts.first(where: { $0.id == id }),
               failoverConfig.policy(for: account.provider).keepWindowsWarm {
                let passed = Self.passedResetWindows(usage, sessionQuota: account.provider.capabilities.supportsSessionQuota,
                                                     now: now)
                if !passed.isEmpty {
                    var pending = pendingWindowWarmups[id] ?? PendingWindowWarmup()
                    pending.session = pending.session || passed.session
                    pending.weekly = pending.weekly || passed.weekly
                    pending.resetAt = passed.resetAt
                    pendingWindowWarmups[id] = pending
                    warmupGivenUp.remove(id)
                    warmupRetryAttempts[id] = nil
                }
            }
            accountUsage[id] = usage.expiringPassedResets(at: now)
            accountsAwaitingPostResetVerification.insert(id)
            passedResetAt[id] = now
            changed = true
            log.info("[usage-reset] Cleared cached utilization for \(id.uuidString); awaiting fresh post-reset verification")
        }
        if changed {
            saveUsageSnapshots()
            updateWidgetData()
            bringQuotaCycleForward(to: now.addingTimeInterval(Self.postResetSettle + 1))
        }
        scheduleNextUsageReset(now: now)
    }

    /// The windows of `usage` whose reset has passed by `now`, which a
    /// warm-up may start: the session window only on a provider that has
    /// one, and only when the reading carries one. `resetAt` is the latest
    /// of those resets.
    nonisolated static func passedResetWindows(_ usage: UsageAPIResponse, sessionQuota: Bool, now: Date) -> PendingWindowWarmup {
        let session = sessionQuota ? usage.fiveHour?.resetsAtDate.flatMap { $0 <= now ? $0 : nil } : nil
        let weekly = usage.sevenDay?.resetsAtDate.flatMap { $0 <= now ? $0 : nil }
        return PendingWindowWarmup(session: session != nil, weekly: weekly != nil,
                                   resetAt: [session, weekly].compactMap { $0 }.max())
    }

    /// How long after clearing an account at its reset `verifyPassedResets`
    /// waits to read it, so the provider has opened the new window and the
    /// reading does not describe the one that ended.
    nonisolated static let postResetSettle: TimeInterval = 30
    /// How soon after the provider's reset time the reset must have been
    /// cleared for AccountDock to have watched the account since
    /// (`unusedSinceReset`); a reset found at launch passed unwatched.
    nonisolated static let postResetWatched: TimeInterval = 5 * 60

    /// Moves the next quota cycle forward to `date` when it is due later,
    /// so the work a reset leaves (`verifyPassedResets`) does not wait a
    /// whole cycle. Does nothing before monitoring has started
    /// (`startAutoRefresh` schedules the first cycle) or while a cycle
    /// runs, whose next one `nextQuotaCycleInterval` times.
    private func bringQuotaCycleForward(to date: Date) {
        guard let timer = failoverMonitorTimer, timer.fireDate > date else { return }
        scheduleQuotaCycle(after: max(1, date.timeIntervalSinceNow))
    }

    /// How long after a verification reading that confirmed nothing its
    /// account is read again.
    nonisolated static let postResetRetrySpacing: TimeInterval = 60

    /// When an account awaiting verification may next be read for it:
    /// `postResetSettle` after it was cleared at its reset (`clearedAt`; at
    /// once for one loaded so), `postResetRetrySpacing` after a reading of
    /// it that confirmed nothing (`failedAt`), and after its cool-down
    /// (`retryAfter`).
    nonisolated static func postResetReadAllowed(clearedAt: Date?, failedAt: Date?, retryAfter: Date?) -> Date {
        [clearedAt?.addingTimeInterval(postResetSettle), failedAt?.addingTimeInterval(postResetRetrySpacing), retryAfter]
            .compactMap { $0 }.max() ?? .distantPast
    }

    /// The accounts `verifyPassedResets` reads now, in order: each awaiting
    /// verification (`awaiting`) whose `postResetReadAllowed` has come.
    /// Accounts with a window left to warm (`warming`) come first, since
    /// their next window starts only once they are read; then the oldest
    /// reading first.
    nonisolated static func postResetVerificationOrder(_ accounts: [Account], awaiting: Set<UUID>, warming: Set<UUID>,
                                                       clearedAt: [UUID: Date], failedAt: [UUID: Date] = [:],
                                                       retryAfter: [UUID: Date], updatedAt: [UUID: Date],
                                                       now: Date) -> [Account] {
        accounts
            .filter { account in
                awaiting.contains(account.id)
                    && postResetReadAllowed(clearedAt: clearedAt[account.id], failedAt: failedAt[account.id],
                                            retryAfter: retryAfter[account.id]) <= now
            }
            .sorted { a, b in
                let (aWarms, bWarms) = (warming.contains(a.id), warming.contains(b.id))
                if aWarms != bWarms { return aWarms }
                return (updatedAt[a.id] ?? .distantPast) < (updatedAt[b.id] ?? .distantPast)
            }
    }

    /// Confirms each passed reset with a reading of its account
    /// (`accountsAwaitingPostResetVerification`), which takes no work until
    /// then. The reading spends the verification allowance
    /// (`UsageRequestBudget.Priority.verification`), which background
    /// reads of idle accounts and accounts in use cannot spend, and an
    /// account with a window to warm is handed to its warm-up, which reads
    /// it the same way, or starts the window from the reset alone where
    /// nothing can have used the account since (`warmupStep`), so the
    /// probe does not wait behind the usage endpoint. A reading held back
    /// is taken at the next cycle, which `nextQuotaCycleInterval` brings
    /// forward to the moment it can be (`passedResetWorkDue`). Called by
    /// `runQuotaCycle` after the passive readings, which confirm the reset
    /// of an account sessions are using without a request.
    func verifyPassedResets(now: Date = Date()) async {
        guard !accountsAwaitingPostResetVerification.isEmpty else { return }
        for provider in AIProviderType.implementedProviders {
            let due = Self.postResetVerificationOrder(
                accounts.filter { $0.provider == provider && !needsSignIn($0) },
                awaiting: accountsAwaitingPostResetVerification, warming: Set(pendingWindowWarmups.keys),
                clearedAt: passedResetAt, failedAt: postResetReadFailedAt, retryAfter: usageRetryAfter,
                updatedAt: accountUsageUpdatedAt, now: now
            )
            for account in due where accountsAwaitingPostResetVerification.contains(account.id) {
                if accountWarmupsInFlight.contains(account.id) || warmupRetries[account.id] != nil { continue }
                if let pending = pendingWindowWarmups[account.id], !warmupGivenUp.contains(account.id),
                   await performWindowWarmup(accountID: account.id, windows: pending) {
                    continue
                }
                guard usageBudgets[provider]?.canSpend(.verification) ?? true else { break }
                await fetchUsageNow(account, priority: .verification)
                // A reading that confirmed nothing waits
                // `postResetRetrySpacing` for the next; a throttled one waits
                // for its cool-down instead.
                if accountsAwaitingPostResetVerification.contains(account.id),
                   usageRetryAfter[account.id].map({ $0 <= Date() }) ?? true {
                    postResetReadFailedAt[account.id] = Date()
                }
            }
        }
    }

    /// When `verifyPassedResets` can next act: the earliest moment an
    /// account awaiting verification, with no warm-up retry of its own
    /// waiting, may be read (`postResetReadAllowed`) and its reading would
    /// be let through (`usageRequestAvailable`). Nil when none awaits one.
    /// Read by `nextQuotaCycleInterval`.
    func passedResetWorkDue(now: Date = Date()) -> Date? {
        accounts
            .filter { accountsAwaitingPostResetVerification.contains($0.id) && !needsSignIn($0) && warmupRetries[$0.id] == nil }
            .map { account in
                let allowed = Self.postResetReadAllowed(clearedAt: passedResetAt[account.id],
                                                        failedAt: postResetReadFailedAt[account.id], retryAfter: nil)
                return max(allowed, usageRequestAvailable(account, .verification, now: now))
            }
            .min()
    }

    /// Starts the unstarted windows of `requested` on an account with one
    /// non-persistent probe request (`QuotaWindowProbe.startWindow`), so
    /// each resets as early as its provider allows. The probe acts on the
    /// evidence `warmupStep` asks for: a whole reading just taken, the
    /// reset itself on an account nothing has used since, or else a
    /// reading taken now through the ordinary reader (`readUsage`, which
    /// checks that a saved sign-in is the account's own and records the
    /// read in the credential audit) from the verification allowance. A
    /// reading or probe the allowance or a cool-down holds back is tried
    /// again just after it ends (`scheduleWarmupRetry`). Returns whether
    /// the warm-up took the account on; false when warming is off or the
    /// provider has no probe, and `verifyPassedResets` then reads it.
    @discardableResult
    private func performWindowWarmup(accountID: UUID, windows requested: PendingWindowWarmup) async -> Bool {
        guard let account = accounts.first(where: { $0.id == accountID }) else { return false }
        let policy = failoverConfig.policy(for: account.provider)
        guard policy.keepWindowsWarm,
              let probe = quotaWindowProbe(for: account, readsLive: readsLiveCredential(account)) else { return false }

        guard accountWarmupsInFlight.insert(accountID).inserted else {
            log.info("[warmup] Skipped duplicate in-flight probe for \(accountID.uuidString)")
            return true
        }
        defer { accountWarmupsInFlight.remove(accountID) }
        warmupRetries.removeValue(forKey: accountID)?.cancel()
        let sessionQuota = account.provider.capabilities.supportsSessionQuota
        var now = Date()
        var step = Self.warmupStep(requested: requested, stored: accountUsage[accountID], verifiedAt: verifiedReadingAt(accountID),
                                   unusedSinceReset: unusedSinceReset(account, requested), sessionQuota: sessionQuota,
                                   lastProbeAt: lastWarmupProbeAt[accountID], now: now)
        if step == .readFirst {
            let available = usageRequestAvailable(account, .verification, now: now)
            guard available <= now, spendUsageRequest(account.provider, .verification) else {
                scheduleWarmupRetry(accountID: accountID, windows: requested,
                                    after: .heldUntil(warmupResumesAt(account, requested, held: max(available, now), now: now)))
                return true
            }
            let outcome = await readUsage(account, forced: false, includeMetadata: false, priority: .verification)
            applyUsageRead(outcome, for: account)
            now = Date()
            switch outcome {
            case .reading:
                break
            case .throttled:
                scheduleWarmupRetry(accountID: accountID, windows: requested,
                                    after: .heldUntil(usageRequestAvailable(account, .verification, now: now)))
                return true
            default:
                scheduleWarmupRetry(accountID: accountID, windows: requested, after: .failed)
                return true
            }
            step = Self.warmupStep(requested: requested, stored: accountUsage[accountID], verifiedAt: verifiedReadingAt(accountID),
                                   unusedSinceReset: false, sessionQuota: sessionQuota,
                                   lastProbeAt: lastWarmupProbeAt[accountID], now: now)
            if step == .readFirst {
                // The reply still described the window before the reset,
                // `postResetSettle` after it: the provider is lagging.
                scheduleWarmupRetry(accountID: accountID, windows: requested, after: .failed)
                return true
            }
        }
        guard case .probe(let windows) = step else {
            pendingWindowWarmups[accountID] = nil
            warmupRetryAttempts[accountID] = nil
            log.info("[warmup] Skipped probe for \(accountID.uuidString); requested window is already active or unavailable")
            return true
        }

        let labels = [windows.session ? "session" : nil, windows.weekly ? "weekly" : nil]
            .compactMap { $0 }
            .joined(separator: " + ")
        do {
            try await probe.startWindow()
            lastWarmupProbeAt[accountID] = Date()
            pendingWindowWarmups[accountID] = nil
            warmupRetryAttempts[accountID] = nil
            warmupGivenUp.remove(accountID)
            try await forceRefreshWarmup(account: account, windows: windows, fetch: probe.liveUsage)
            failoverEvents.record(
                account.provider,
                "Started the \(labels) reset countdown for \(messageName(account)); the probe session was non-persistent."
            )
            log.info("[warmup] \(account.provider.rawValue) \(labels) window started for \(account.id.uuidString)")
        } catch {
            failoverEvents.record(
                account.provider,
                "Could not start the \(labels) reset countdown for \(messageName(account)): \(error.localizedDescription)"
            )
            log.warning("[warmup] Probe failed for \(account.id.uuidString): \(error.localizedDescription)")
            scheduleWarmupRetry(accountID: accountID, windows: requested, after: Self.warmupDeferral(for: error, now: Date()))
        }
        return true
    }

    /// When the account's newest whole reading was taken, while it shows
    /// the account's windows as they are (no reset awaits verification):
    /// the evidence `warmupStep` lets a probe act on without reading again.
    private func verifiedReadingAt(_ accountID: UUID) -> Date? {
        guard !accountsAwaitingPostResetVerification.contains(accountID) else { return nil }
        return accountWholeReadings[accountID]?.at
    }

    /// Whether nothing can have started `account`'s windows since the
    /// reset that armed `requested`, for `warmupStep`: the reset was
    /// cleared while AccountDock ran (`postResetWatched`), the account is
    /// not the active one or a slot's, no session runs on it and none of
    /// its requests was seen since the reset, and its sign-in is known to
    /// be its own (`savedCopyIsKnownOwn`), so the probe spends this
    /// account's window and no other's.
    private func unusedSinceReset(_ account: Account, _ requested: PendingWindowWarmup) -> Bool {
        guard let reset = requested.resetAt, let cleared = passedResetAt[account.id],
              cleared.timeIntervalSince(reset) < Self.postResetWatched,
              !account.isActive, accountSessions[account.id]?.isEmpty != false,
              !slotServedAccounts.contains(account.id) else { return false }
        let lastRequest = sessionRates.entries.values.filter { $0.account == account.id }.map(\.lastSeen).max()
        guard lastRequest.map({ $0 < reset }) ?? true else { return false }
        return savedCopyIsKnownOwn(account)
    }

    /// Whether the credential a probe of `account` would spend is known to
    /// be the account's: Claude's saved copy only once the provider
    /// confirmed it (`savedCopyVerified`, set by `savedCopyIsOwn`); other
    /// providers' probes run in the account's own credential location.
    private func savedCopyIsKnownOwn(_ account: Account) -> Bool {
        guard account.provider == .claudeCode, !readsLiveCredential(account) else { return true }
        guard let verified = savedCopyVerified[account.id],
              let token = keychain.getAccountBackup(forAccountId: account.id.uuidString,
                                                    reason: "performWindowWarmup.owner")?.token else { return false }
        return Self.credentialDigest(token) == verified
    }

    /// When a warm-up whose reading is held until `held` can go on: then,
    /// or sooner when the reset alone will let it start the window
    /// (`warmupResetMargin` after it, on an account `unusedSinceReset`).
    private func warmupResumesAt(_ account: Account, _ requested: PendingWindowWarmup, held: Date, now: Date) -> Date {
        guard let reset = requested.resetAt?.addingTimeInterval(Self.warmupResetMargin), reset > now, reset < held,
              unusedSinceReset(account, requested) else { return held }
        return reset
    }

    /// After a switch, starts the windows the newly active account's stored
    /// reading shows unused and unstarted; an account whose reading shows
    /// them started, or that has no session window, costs no request.
    private func warmSelectedAccountIfNeeded(_ accountID: UUID) async {
        guard let account = accounts.first(where: { $0.id == accountID }),
              failoverConfig.policy(for: account.provider).keepWindowsWarm else { return }
        let requested = pendingWindowWarmups[accountID] ?? PendingWindowWarmup(session: true, weekly: true)
        guard !Self.windowsToWarm(accountUsage[accountID], requested: requested,
                                  sessionQuota: account.provider.capabilities.supportsSessionQuota).isEmpty else { return }
        await performWindowWarmup(accountID: accountID, windows: requested)
    }

    /// Tries the warm-up of `windows` again after `deferral`
    /// (`warmupRetryDelay`). One retry waits per account; when it wakes it
    /// starts the warm-up only while the stored reading still shows a
    /// requested window unstarted. Failures past `warmupFailureDelays`
    /// give the account up until its next reset (`warmupGivenUp`).
    private func scheduleWarmupRetry(accountID: UUID, windows: PendingWindowWarmup, after deferral: WarmupDeferral) {
        if deferral == .failed { warmupRetryAttempts[accountID, default: 0] += 1 }
        let failures = warmupRetryAttempts[accountID, default: 0]
        guard let delay = Self.warmupRetryDelay(deferral, failures: failures, now: Date()) else {
            warmupGivenUp.insert(accountID)
            warmupRetryAttempts[accountID] = nil
            log.warning("[warmup] Retry limit reached for \(accountID.uuidString); the next reset arms it again")
            return
        }
        let why = deferral == .failed ? "after failure \(failures)" : "when the provider takes requests again"
        log.info("[warmup] Retry for \(accountID.uuidString) scheduled in \(Int(delay))s, \(why)")
        warmupRetries.removeValue(forKey: accountID)?.cancel()
        warmupRetries[accountID] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.warmupRetries[accountID] = nil
            guard let account = self.accounts.first(where: { $0.id == accountID }) else { return }
            let requested = self.pendingWindowWarmups[accountID] ?? windows
            guard !AppState.windowsToWarm(self.accountUsage[accountID], requested: requested,
                                          sessionQuota: account.provider.capabilities.supportsSessionQuota).isEmpty else {
                self.warmupRetryAttempts[accountID] = nil
                return
            }
            await self.performWindowWarmup(accountID: accountID, windows: requested)
        }
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
        // The pin is no provider reading: it keeps the time of the last one
        // and leaves a reset it has not confirmed to `verifyPassedResets`.
        recordUsage(pinned, for: account.id, observedAt: accountUsageUpdatedAt[account.id] ?? Date(), confirmsReset: false)
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
                wholeLongUtilization: accountWholeReadings[item.key]?.longUtilization,
                resetUnverified: accountsAwaitingPostResetVerification.contains(item.key) ? true : nil
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
            saveAccounts()
            Task { _ = await self.captureOwnCredential(of: account, reason: "updateActiveAccount") }
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
                    expectedEmail: current.email,
                    reason: "switchToCodex.saveCurrent"
                )
            }
            if let current = activeAccount(for: .codex), liveProcesses.isEmpty, processes.isEmpty {
                lastSwitchedAway[current.id] = Date()
            }
            try codexService.promoteToSystem(homePath: location, reason: "switchToCodex")
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
                try kimiService.syncSystemCredentials(toManagedLocation: currentLocation, reason: "switchToKimi.saveCurrent")
            }
            try kimiService.promoteToSystem(location: location, reason: "switchToKimi")
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
