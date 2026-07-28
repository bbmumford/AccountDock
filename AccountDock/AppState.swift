import SwiftUI
import Combine
import WidgetKit

private extension DateFormatter {
    static let accountDockDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

private let log = FileLog("AppState")

/// Central app state managing accounts, usage data, and active sessions.
@MainActor
final class AppState: ObservableObject {
    // MARK: - Published State

    @Published var accounts: [Account] = []
    @Published var activeAccount: Account?
    @Published var accountUsage: [UUID: UsageAPIResponse] = [:]
    @Published private(set) var accountUsageUpdatedAt: [UUID: Date] = [:]
    @Published var usageSummary: UsageSummary = .empty
    @Published var recentActivity: [DailyActivity] = []
    @Published var activeSessions: [SessionInfo] = []
    @Published var isLoading = false
    @Published var isLoggingIn = false
    @Published private(set) var loginDeadline: Date?
    @Published var errorMessage: String?
    @Published var claudeAvailable = false
    @Published var codexAvailable = false
    @Published var lastUsageRefresh: Date?
    @Published var costSummary: CostSummary = .empty
    @Published var combinedTodayCost: Double = 0
    @Published var codexDailyCosts: [String: Double] = [:]
    @Published var codexTodayModelActivity: [String: Int] = [:]
    @Published var codexTodayModelCosts: [String: Double] = [:]
    @Published var activityStats: ActivityStats = .empty
    @Published private(set) var failoverStatus: [AIProviderType: String] = [:]

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

    private let claudeService = ClaudeService.shared
    private let codexService = CodexService.shared
    private let statsParser = StatsParser.shared
    private let costParser = CostParser.shared
    private let activityParser = ActivityParser.shared
    private let keychain = KeychainService.shared
    private let failoverConfig = FailoverConfigStore.shared
    private let failoverEvents = FailoverEventLog.shared

    private let accountsKey = "app.accountdock.accounts"
    private let usageSnapshotsKey = "app.accountdock.usageSnapshots.v1"
    private let failoverRuntimeKey = "app.accountdock.failover.runtime.v1"
    private var refreshTimer: Timer?
    private var failoverMonitorTimer: Timer?
    private var isMonitoringFailover = false
    private var loginAttemptID: UUID?
    private var exhaustedFailoverAccounts: [AIProviderType: Set<UUID>] = [:]
    private var lastAutomaticFailover: [AIProviderType: Date] = [:]
    private var claudeUsageRetryAfter: [UUID: Date] = [:]
    private var expiredClaudeAccounts: Set<UUID> = []
    private struct PendingResetRecovery {
        let accountID: UUID
        let resetDate: Date
        let processes: [RunningClaudeProcess]
    }
    private var pendingResetRecovery: [AIProviderType: PendingResetRecovery] = [:]

    // MARK: - Initialization

    init() {
        log.info("[init] Loading accounts from UserDefaults...")
        loadAccounts()
        loadUsageSnapshots()
        loadFailoverRuntime()
        log.info("[init] Loaded \(self.accounts.count) accounts, active: \(self.activeAccount?.id.uuidString ?? "none")")
    }

    // MARK: - Refresh

    func refresh() async {
        guard !isLoggingIn else {
            log.info("[refresh] Skipping: login in progress")
            return
        }
        isLoading = true
        errorMessage = nil

        claudeAvailable = await claudeService.isClaudeAvailable()
        codexAvailable = await codexService.isAvailable()
        log.info("[refresh] Claude available: \(self.claudeAvailable)")

        if claudeAvailable {
            do {
                let status = try await claudeService.getAuthStatus()
                updateActiveAccount(from: status)
            } catch {
                log.error("[refresh] getAuthStatus failed: \(error.localizedDescription)")
                errorMessage = error.localizedDescription
            }
        }
        updateActiveCodexAccount()

        // Passive token health check (no CLI calls, keychain reads only)
        diagnoseTokenHealth()

        // Fetch usage limits for all accounts
        await fetchAllAccountUsage()
        await evaluateFailover()
        lastUsageRefresh = Date()

        usageSummary = statsParser.getUsageSummary()
        recentActivity = statsParser.getRecentActivity(days: 7)
        activeSessions = statsParser.getActiveSessions()

        // JSONL parsing: walk filesystem once via the shared cache, then
        // pull aggregated outputs. The actor's executor is off the main
        // thread, so awaiting these does not block the UI.
        await SessionParseCacheV2.shared.refreshFromFilesystem()
        let cost = await costParser.getCostSummary()
        let codexHistory = await costParser.getCodexCostHistory()
        let activity = await activityParser.getTodayStats()
        costSummary = cost
        codexDailyCosts = codexHistory.dailyCosts
        codexTodayModelActivity = codexHistory.todayModelActivity
        codexTodayModelCosts = codexHistory.todayModelCosts
        let todayKey = DateFormatter.accountDockDay.string(from: Date())
        combinedTodayCost = cost.todayCost + (codexHistory.dailyCosts[todayKey] ?? 0)
        activityStats = activity

        log.info("[refresh] Usage: weekly=\(self.usageSummary.weeklyMessages) msgs, \(self.activeSessions.count) active sessions, claudeToday=$\(String(format: "%.2f", cost.todayCost)) codexToday=$\(String(format: "%.2f", codexHistory.dailyCosts[todayKey] ?? 0)) turns=\(activity.conversationTurns)")

        updateWidgetData()
        isLoading = false
    }

    func startAutoRefresh(interval: TimeInterval = 300) {
        stopAutoRefresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.refresh()
            }
        }
        // Full refreshes query every account. Failover monitoring is a one-shot,
        // adaptive timer: it tightens near a configured limit and backs away
        // from exhausted or rate-limited accounts until their next useful check.
        scheduleNextFailoverMonitor()
    }

    private func scheduleNextFailoverMonitor() {
        failoverMonitorTimer?.invalidate()
        let now = Date()
        let intervals = [AIProviderType.claudeCode, .codex].compactMap { provider -> TimeInterval? in
            let policy = failoverConfig.policy(for: provider)
            guard policy.enabled, let account = activeAccount(for: provider) else { return nil }
            let pendingReset = pendingResetRecovery[provider]?.resetDate
            let retryAfter = provider == .claudeCode ? claudeUsageRetryAfter[account.id] : nil
            return FailoverDecision.pollInterval(
                usage: accountUsage[account.id],
                provider: provider,
                policy: policy,
                noFailoverAvailable: pendingReset != nil
                    || (FailoverDecision.exceedsThreshold(
                        usage: accountUsage[account.id],
                        provider: provider,
                        policy: policy
                    ) && pendingResetRecovery[provider] == nil),
                blockingReset: pendingReset,
                retryAfter: retryAfter,
                now: now
            )
        }
        // Keep a low-frequency sentinel so enabling failover in Settings is
        // discovered without requiring an app restart.
        let interval = intervals.min() ?? 300
        failoverMonitorTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.failoverMonitorTimer = nil
                await self.monitorActiveFailoverUsage()
            }
        }
        log.debug("[failover-monitor] next active-account check in \(Int(interval))s")
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        failoverMonitorTimer?.invalidate()
        failoverMonitorTimer = nil
    }

    private func monitorActiveFailoverUsage() async {
        defer { scheduleNextFailoverMonitor() }
        guard !isMonitoringFailover, !isLoading, !isLoggingIn else { return }
        let enabledProviders = [AIProviderType.claudeCode, .codex]
            .filter { failoverConfig.policy(for: $0).enabled }
        guard !enabledProviders.isEmpty else { return }
        isMonitoringFailover = true
        defer { isMonitoringFailover = false }

        for provider in enabledProviders {
            guard let account = activeAccount(for: provider) else { continue }
            do {
                let usage: UsageAPIResponse
                if provider == .claudeCode {
                    if let retryAt = claudeUsageRetryAfter[account.id], retryAt > Date() {
                        continue
                    }
                    guard let tokenJSON = keychain.readClaudeToken(),
                          let token = ClaudeService.extractAccessToken(from: tokenJSON) else {
                        continue
                    }
                    usage = try await claudeService.getUsageLimits(accessToken: token)
                } else {
                    usage = try await codexService.getUsageLimits(
                        codexHome: account.credentialLocation
                    )
                }
                recordUsage(usage, for: account.id)
                accountUsageErrors[account.id] = nil
            } catch ClaudeService.UsageError.rateLimited(let retryAt) {
                noteClaudeRateLimit(accountID: account.id, retryAt: retryAt)
                continue
            } catch {
                // The normal full refresh owns user-facing diagnostics. A
                // transient monitor failure must not discard its last-good data.
                log.warning("[failover-monitor] \(provider.rawValue) poll failed: \(error.localizedDescription)")
                continue
            }
        }
        await evaluateFailover()
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

    func cancelLogin() {
        guard isLoggingIn else { return }
        loginAttemptID = nil
        loginDeadline = nil
        isLoggingIn = false
        claudeService.cancelLogin()
        codexService.cancelLogin()
        errorMessage = "Browser login cancelled. You can try again."
        log.info("[login] User cancelled browser login")
    }

    func activeAccount(for provider: AIProviderType) -> Account? {
        accounts.first { $0.provider == provider && $0.isActive }
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

            if accounts.contains(where: { $0.email == email }) {
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
            let captured = claudeService.captureCurrentCredentials(forAccountId: account.id.uuidString)
            if !captured {
                errorMessage = String(localized: "Could not capture auth token from keychain", bundle: L10n.bundle)
                log.error("[addAccount] Token capture failed!")
                return
            }
            log.info("[addAccount] Token captured successfully")

            if !accounts.contains(where: { $0.provider == .claudeCode }) {
                account.isActive = true
                activeAccount = account
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
            if let current = activeAccount {
                log.info("[loginNewAccount] Step 1: Backing up current account (\(current.email))...")
                let backed = claudeService.captureCurrentCredentials(forAccountId: current.id.uuidString)
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
            if let existing = accounts.firstIndex(where: { $0.email == email }) {
                log.info("[loginNewAccount] Step 4: Account already exists, refreshing backup")
                _ = claudeService.captureCurrentCredentials(forAccountId: accounts[existing].id.uuidString)
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

            let captured = claudeService.captureCurrentCredentials(forAccountId: account.id.uuidString)
            if !captured {
                errorMessage = String(localized: "Could not capture credentials", bundle: L10n.bundle)
                log.error("[loginNewAccount] Step 5: Capture failed!")
                return
            }

            // 6. Mark new account as active
            for i in accounts.indices where accounts[i].provider == .claudeCode {
                accounts[i].isActive = false
            }
            accounts.append(account)
            activeAccount = account
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
        if accounts[index].isActive {
            activeAccount = accounts[index]
        }
        saveAccounts()
        updateWidgetData()
        log.info("[updateAccountLabel] Set label for \(account.email): \(trimmed ?? "nil")")
    }

    func removeAccount(_ account: Account) {
        log.info("[removeAccount] Removing account \(account.id)")
        if account.provider == .codex {
            if let location = account.credentialLocation {
                try? codexService.removeManagedAccount(homePath: location)
            }
        } else {
            keychain.removeAccountBackup(forAccountId: account.id.uuidString)
        }
        accounts.removeAll { $0.id == account.id }
        accountUsage[account.id] = nil
        accountUsageUpdatedAt[account.id] = nil
        accountUsageErrors[account.id] = nil
        claudeUsageRetryAfter[account.id] = nil
        expiredClaudeAccounts.remove(account.id)
        exhaustedFailoverAccounts[account.provider]?.remove(account.id)
        saveUsageSnapshots()
        saveFailoverRuntime()
        if account.isActive,
           let firstIndex = accounts.firstIndex(where: { $0.provider == account.provider }) {
            accounts[firstIndex].isActive = true
            if account.provider == .claudeCode {
                activeAccount = accounts[firstIndex]
            }
            log.info("[removeAccount] Removed active account, switching to first remaining")
            Task { await switchTo(accounts[firstIndex]) }
        }
        saveAccounts()
        log.info("[removeAccount] Done. Remaining accounts: \(self.accounts.count)")
    }

    func switchTo(_ account: Account, refreshAfter: Bool = true) async {
        await switchTo(account, refreshAfter: refreshAfter, safelyRestarting: [])
    }

    func runningClaudeProcesses() -> [RunningClaudeProcess] {
        claudeService.recoverableRunningProcesses()
    }

    /// Switch credentials and then stop only the Claude processes that were
    /// captured before the switch. IDE integrations can respawn against the new
    /// credential; terminal sessions can be reopened by the user.
    func switchTo(
        _ account: Account,
        refreshAfter: Bool = true,
        safelyRestarting processes: [RunningClaudeProcess]
    ) async {
        if account.provider == .codex {
            await switchToCodex(account)
            return
        }
        guard let currentActive = activeAccount(for: account.provider), currentActive.id != account.id else {
            log.info("[switchTo] No switch needed (same account or no active account)")
            return
        }

        log.info("[switchTo] ===== Switching from \(currentActive.email) to \(account.email) =====")

        // Pre-switch: verify target has a backup
        guard keychain.getAccountBackup(forAccountId: account.id.uuidString) != nil else {
            log.error("[switchTo] ABORT: no backup for target account")
            errorMessage = String(localized: "No stored credentials for \(account.email). Use re-authenticate to fix.", bundle: L10n.bundle)
            return
        }

        isLoading = true
        do {
            try await claudeService.switchAccount(from: currentActive, to: account)
            expiredClaudeAccounts.remove(account.id)

            for i in accounts.indices where accounts[i].provider == account.provider {
                accounts[i].isActive = (accounts[i].id == account.id)
                if accounts[i].id == account.id {
                    accounts[i].lastUsed = Date()
                }
            }
            activeAccount = account
            saveAccounts()

            if !processes.isEmpty {
                let survivors = await claudeService.terminateForSafeRestart(processes)
                if survivors.isEmpty {
                    log.info("[switchTo] Safely stopped \(processes.count) pre-switch Claude process(es)")
                    claudeService.resumeAfterSafeRestart(processes)
                } else {
                    errorMessage = "\(survivors.count) Claude session(s) did not close. Quit them manually before continuing work."
                    log.warning("[switchTo] \(survivors.count) pre-switch Claude process(es) survived graceful termination")
                }
            }

            if refreshAfter {
                await refresh()
            } else {
                // Automatic failover deliberately skips the expensive full
                // refresh, but it must still release the UI loading state.
                isLoading = false
            }
            log.info("[switchTo] ===== Switch completed =====")
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
            log.error("[switchTo] Switch failed: \(error.localizedDescription)")
        }
    }

    /// Re-authenticate an account by running `claude auth login` and capturing fresh credentials.
    func reauthenticateAccount(_ account: Account) async {
        if account.provider == .codex {
            await reauthenticateCodexAccount(account)
            return
        }
        log.info("[reauth] ===== Re-authenticating account \(account.id) (\(account.email)) =====")
        guard claudeAvailable else {
            errorMessage = String(localized: "Claude CLI not found", bundle: L10n.bundle)
            return
        }

        guard let loginID = beginLoginAttempt() else { return }
        defer { finishLoginAttempt(loginID) }

        do {
            // 1. Back up current active account before login overwrites it
            if let current = activeAccount, current.id != account.id {
                log.info("[reauth] Backing up current account before login...")
                _ = claudeService.captureCurrentCredentials(forAccountId: current.id.uuidString)
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

            guard email == account.email else {
                errorMessage = String(localized: "Logged in as \(email), but expected \(account.email). Credentials not updated.", bundle: L10n.bundle)
                log.error("[reauth] Email mismatch: got \(email), expected \(account.email)")
                return
            }

            // 4. Capture the fresh token
            let captured = claudeService.captureCurrentCredentials(forAccountId: account.id.uuidString)
            log.info("[reauth] Token capture result: \(captured)")
            expiredClaudeAccounts.remove(account.id)

            // 5. Update account metadata
            if let index = accounts.firstIndex(where: { $0.id == account.id }) {
                accounts[index].orgName = status.orgName
                accounts[index].subscriptionType = status.subscriptionType

                // Mark this account as active (it's what the CLI is now using)
                for i in accounts.indices where accounts[i].provider == .claudeCode {
                    accounts[i].isActive = (i == index)
                }
                activeAccount = accounts[index]
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

    private func fetchAllAccountUsage() async {
        accountUsageErrors.removeAll()
        for account in accounts where account.provider == .codex {
            do {
                let usage = try await codexService.getUsageLimits(codexHome: account.credentialLocation)
                recordUsage(usage, for: account.id)
                accountUsageErrors[account.id] = nil
                log.info("[fetchUsage] Codex \(account.email): session=\(usage.fiveHour?.utilization ?? -1)%, weekly=\(usage.sevenDay?.utilization ?? -1)%")
            } catch {
                accountUsageErrors[account.id] = UsageErrorState(
                    isExpired: false,
                    isRateLimited: false,
                    message: accountUsage[account.id] == nil
                        ? "Could not fetch Codex usage: \(error.localizedDescription)"
                        : "Could not refresh Codex usage. Showing the last known limits.",
                    cachedAt: accountUsageUpdatedAt[account.id]
                )
                log.error("[fetchUsage] Codex \(account.email) failed: \(error.localizedDescription)")
            }
        }
        // For active account: use live keychain token (with delegated refresh on expiry)
        // For other accounts: use backup token (no silent swap — just mark expired)
        for account in accounts where account.provider == .claudeCode {
            if !account.isActive, expiredClaudeAccounts.contains(account.id) {
                accountUsageErrors[account.id] = UsageErrorState(
                    isExpired: true,
                    isRateLimited: false,
                    message: String(
                        localized: "Stored credentials expired. Switch to this account or reauthenticate it to refresh.",
                        bundle: L10n.bundle
                    ),
                    cachedAt: accountUsageUpdatedAt[account.id]
                )
                continue
            }
            if let retryAt = claudeUsageRetryAfter[account.id], retryAt > Date() {
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
            claudeUsageRetryAfter[account.id] = nil
            let tokenJSON: String?
            if account.isActive {
                tokenJSON = keychain.readClaudeToken()
            } else {
                tokenJSON = keychain.getAccountBackup(forAccountId: account.id.uuidString)?.token
            }
            guard let tokenJSON, let accessToken = ClaudeService.extractAccessToken(from: tokenJSON) else {
                log.warning("[fetchUsage] No token for \(account.email), skipping")
                continue
            }
            do {
                let usage = try await claudeService.getUsageLimits(accessToken: accessToken)
                recordUsage(usage, for: account.id)
                accountUsageErrors[account.id] = nil
                claudeUsageRetryAfter[account.id] = nil
                log.info("[fetchUsage] \(account.email): session=\(usage.fiveHour?.utilization ?? -1)%, weekly=\(usage.sevenDay?.utilization ?? -1)%")
            } catch ClaudeService.UsageError.expired {
                log.warning("[fetchUsage] Token expired for \(account.email)")
                if account.isActive {
                    // Active account: delegated refresh via `claude auth status` is safe (no keychain swap)
                    do {
                        _ = try await claudeService.getAuthStatus()
                        log.info("[fetchUsage] Delegated refresh completed for active account.")
                        // Re-read refreshed token and retry
                        guard let refreshedJSON = keychain.readClaudeToken(),
                              let refreshedToken = ClaudeService.extractAccessToken(from: refreshedJSON) else {
                            throw ClaudeService.UsageError.expired
                        }
                        do {
                            let usage = try await claudeService.getUsageLimits(accessToken: refreshedToken)
                            recordUsage(usage, for: account.id)
                            accountUsageErrors[account.id] = nil
                            log.info("[fetchUsage] Recovered \(account.email) via delegated refresh.")
                        } catch ClaudeService.UsageError.rateLimited(let retryAt) {
                            noteClaudeRateLimit(accountID: account.id, retryAt: retryAt)
                        }
                    } catch {
                        log.error("[fetchUsage] Delegated refresh failed for active account: \(error.localizedDescription)")
                        accountUsageErrors[account.id] = UsageErrorState(
                            isExpired: true,
                            isRateLimited: false,
                            message: String(localized: "Token expired. Switch to refresh.", bundle: L10n.bundle),
                            cachedAt: accountUsageUpdatedAt[account.id]
                        )
                    }
                } else {
                    // Non-active account: do NOT silent-swap keychain — just mark as expired.
                    // Token will be refreshed when the user explicitly switches to this account.
                    expiredClaudeAccounts.insert(account.id)
                    log.info("[fetchUsage] Non-active account \(account.email) token expired, skipping silent swap to avoid race condition with Claude Code CLI.")
                    accountUsageErrors[account.id] = UsageErrorState(
                        isExpired: true,
                        isRateLimited: false,
                        message: String(localized: "Token expired. Switch to this account to refresh.", bundle: L10n.bundle),
                        cachedAt: accountUsageUpdatedAt[account.id]
                    )
                }
            } catch ClaudeService.UsageError.rateLimited(let retryAt) {
                log.warning("[fetchUsage] Usage refresh rate limited for \(account.email)")
                noteClaudeRateLimit(accountID: account.id, retryAt: retryAt)
            } catch {
                log.error("[fetchUsage] Failed to get usage for \(account.email): \(error.localizedDescription)")
                accountUsageErrors[account.id] = UsageErrorState(
                    isExpired: false,
                    isRateLimited: false,
                    message: accountUsage[account.id] == nil
                        ? String(localized: "Could not fetch usage: \(error.localizedDescription)", bundle: L10n.bundle)
                        : "Could not refresh usage. Showing the last known limits.",
                    cachedAt: accountUsageUpdatedAt[account.id]
                )
            }
        }
    }

    private func noteClaudeRateLimit(accountID: UUID, retryAt: Date?) {
        claudeUsageRetryAfter[accountID] = retryAt ?? Date().addingTimeInterval(15 * 60)
        accountUsageErrors[accountID] = UsageErrorState(
            isExpired: false,
            isRateLimited: true,
            message: accountUsage[accountID] == nil
                ? String(localized: "API Rate Limited. Try again later.", bundle: L10n.bundle)
                : "Usage refresh throttled. Showing the last known limits.",
            cachedAt: accountUsageUpdatedAt[accountID]
        )
    }

    // MARK: - Automatic Failover

    private func evaluateFailover() async {
        guard !isLoggingIn else { return }

        for provider in [AIProviderType.claudeCode, .codex] {
            let policy = failoverConfig.policy(for: provider)
            let providerAccounts = accounts.filter { $0.provider == provider }
            guard policy.enabled, providerAccounts.count > 1,
                  let current = providerAccounts.first(where: \.isActive),
                  accountUsageErrors[current.id] == nil else { continue }

            if let pending = pendingResetRecovery[provider],
               pending.accountID == current.id,
               FailoverDecision.hasCapacity(
                    usage: accountUsage[current.id],
                    provider: provider,
                    policy: policy
               ) {
                if provider == .claudeCode, !pending.processes.isEmpty {
                    let survivors = await claudeService.terminateForSafeRestart(pending.processes)
                    if !survivors.isEmpty {
                        log.warning("[failover] \(survivors.count) recovery process(es) did not stop")
                    } else {
                        claudeService.resumeAfterSafeRestart(pending.processes)
                    }
                }
                pendingResetRecovery[provider] = nil
                exhaustedFailoverAccounts[provider, default: []].remove(current.id)
                saveFailoverRuntime()
                failoverStatus[provider] = "Capacity restored on \(current.effectiveDisplayName(obfuscated: true)); resuming tracked sessions."
                failoverEvents.record(provider, "Capacity restored on \(current.effectiveDisplayName(obfuscated: true)); released \(pending.processes.count) tracked session process(es).")
                log.info("[failover] \(provider.rawValue): reset capacity confirmed; recovery released")
                continue
            }

            let currentExceeded = FailoverDecision.exceedsThreshold(
                usage: accountUsage[current.id],
                provider: provider,
                policy: policy
            )
            if currentExceeded,
               FailoverDecision.shouldWaitForImminentReset(
                usage: accountUsage[current.id],
                provider: provider,
                policy: policy
               ) {
                failoverStatus[provider] = "Holding \(current.effectiveDisplayName(obfuscated: true)); its limiting window resets soon."
                continue
            }

            if let lastSwitch = lastAutomaticFailover[provider],
               Date().timeIntervalSince(lastSwitch) < 60 {
                continue
            }

            if currentExceeded {
                exhaustedFailoverAccounts[provider, default: []].insert(current.id)
                saveFailoverRuntime()
            }
            let availableIDs = Set(providerAccounts.map(\.id))
            let orderedIDs = policy.accountOrder.filter { availableIDs.contains($0) }
                + providerAccounts.map(\.id).filter { !policy.accountOrder.contains($0) }
            let candidateIDs = FailoverDecision.candidates(
                orderedIDs: orderedIDs,
                currentID: current.id,
                loops: policy.loops
            )
            let eligibleIDs = candidateIDs.filter { id in
                accountUsageErrors[id] == nil
                    && FailoverDecision.hasCapacity(
                        usage: accountUsage[id],
                        provider: provider,
                        policy: policy
                    )
            }

            let recoveredIDs = eligibleIDs.filter {
                exhaustedFailoverAccounts[provider, default: []].contains($0)
            }
            func bestCapacity(in ids: [UUID]) -> UUID? {
                guard policy.preferMostCapacity else { return ids.first }
                return ids.max { lhs, rhs in
                    FailoverDecision.capacityScore(
                        usage: accountUsage[lhs],
                        provider: provider,
                        policy: policy
                    ) < FailoverDecision.capacityScore(
                        usage: accountUsage[rhs],
                        provider: provider,
                        policy: policy
                    )
                }
            }
            let proposedID: UUID?
            if policy.resetAware, let recovered = bestCapacity(in: recoveredIDs) {
                proposedID = recovered
            } else if currentExceeded {
                proposedID = bestCapacity(in: eligibleIDs)
            } else {
                proposedID = nil
            }
            guard currentExceeded || proposedID != nil else { continue }
            var selectedID = proposedID
            var waitingForReset = false
            if selectedID == nil,
               let earliest = providerAccounts.compactMap({ account -> (UUID, Date)? in
                   guard let date = FailoverDecision.blockingResetDate(
                        usage: accountUsage[account.id],
                        provider: provider,
                        policy: policy
                   ) else { return nil }
                   return (account.id, date)
               }).min(by: { $0.1 < $1.1 }) {
                selectedID = earliest.0
                waitingForReset = true
                let tracked = provider == .claudeCode ? claudeService.recoverableRunningProcesses() : []
                pendingResetRecovery[provider] = PendingResetRecovery(
                    accountID: earliest.0,
                    resetDate: earliest.1,
                    processes: tracked
                )
            }
            guard let selectedID,
                  let target = providerAccounts.first(where: { $0.id == selectedID }) else {
                failoverStatus[provider] = "All configured accounts are at their limits; reset times are unavailable."
                failoverEvents.record(provider, "All accounts are exhausted, but no reliable reset timestamp is available.")
                log.warning("[failover] \(provider.rawValue): no eligible account or reset timestamp")
                continue
            }

            if waitingForReset, current.id == target.id {
                let resetText = pendingResetRecovery[provider]?.resetDate.formatted(date: .omitted, time: .shortened) ?? "soon"
                failoverStatus[provider] = "All accounts exhausted. Waiting on \(target.effectiveDisplayName(obfuscated: true)), resetting at \(resetText)."
                failoverEvents.record(provider, "All accounts exhausted. Waiting for \(target.effectiveDisplayName(obfuscated: true)) to reset at \(resetText).")
                continue
            }

            let sourceName = current.effectiveDisplayName(obfuscated: true)
            let targetName = target.effectiveDisplayName(obfuscated: true)
            failoverStatus[provider] = "Switching \(sourceName) → \(targetName)…"
            log.info("[failover] \(provider.rawValue): \(sourceName) -> \(targetName)")
            failoverEvents.record(provider, waitingForReset
                ? "Preparing \(targetName), the earliest-resetting account."
                : "Threshold reached; switching \(sourceName) → \(targetName).")
            // A running Claude process retains the OAuth credential it started
            // with. Merely updating the Keychain makes the UI look switched
            // while the workload continues consuming the exhausted account.
            // Automatic failover therefore captures and gracefully restarts
            // pre-switch Claude processes after the credential transaction.
            let runningProcesses = provider == .claudeCode && !waitingForReset
                ? claudeService.recoverableRunningProcesses()
                : []
            if !runningProcesses.isEmpty {
                log.info("[failover] Captured \(runningProcesses.count) Claude process(es) for safe restart")
            }
            await switchTo(
                target,
                refreshAfter: false,
                safelyRestarting: runningProcesses
            )

            if activeAccount(for: provider)?.id == target.id {
                exhaustedFailoverAccounts[provider, default: []].remove(target.id)
                saveFailoverRuntime()
                lastAutomaticFailover[provider] = Date()
                if waitingForReset {
                    let resetText = pendingResetRecovery[provider]?.resetDate.formatted(date: .omitted, time: .shortened) ?? "soon"
                    failoverStatus[provider] = "All accounts exhausted. Prepared \(targetName), resetting at \(resetText)."
                    failoverEvents.record(provider, "Prepared \(targetName); monitoring adaptively for restored capacity.")
                } else {
                    failoverStatus[provider] = "Switched to \(targetName)."
                    failoverEvents.record(provider, "Switch completed. \(runningProcesses.count) pre-switch process(es) were handed to safe restart.")
                }
            } else {
                failoverStatus[provider] = "Automatic switch failed. AccountDock will retry later."
                failoverEvents.record(provider, "Automatic credential switch failed; it will be retried.")
            }
        }
    }

    // MARK: - Diagnostics

    /// Passive health check — verifies backup existence and identity consistency.
    private func diagnoseTokenHealth() {
        guard !accounts.isEmpty else { return }

        log.info("[diagnose] === Health Check ===")
        log.info("[diagnose] Accounts: \(self.accounts.count), active: \(self.activeAccount?.email ?? "none")")

        // Check live oauthAccount identity
        if let liveOAuth = keychain.readOAuthAccount() {
            let liveEmail = (liveOAuth["emailAddress"]?.value as? String) ?? "?"
            log.info("[diagnose] Live oauthAccount: \(liveEmail)")
        } else {
            log.warning("[diagnose] Live oauthAccount: MISSING")
        }

        // Check each account has a backup
        for account in accounts where account.provider == .claudeCode {
            if let backup = keychain.getAccountBackup(forAccountId: account.id.uuidString) {
                let backupEmail = (backup.oauthAccount["emailAddress"]?.value as? String) ?? "?"
                log.info("[diagnose] Backup [\(account.email)]: OK (email=\(backupEmail))")
            } else {
                log.warning("[diagnose] Backup [\(account.email)]: MISSING — switch will fail")
            }
        }

        log.info("[diagnose] === End Health Check ===")
    }

    // MARK: - Widget

    private func updateWidgetData() {
        let widgetAccounts = accounts.map { account in
            let usage = accountUsage[account.id]
            let error = accountUsageErrors[account.id]
            return WidgetAccountData(
                provider: account.provider.rawValue,
                email: account.displayEmail(obfuscated: !UserDefaults.standard.bool(forKey: "showFullEmail")),
                displayName: account.effectiveDisplayName(obfuscated: !UserDefaults.standard.bool(forKey: "showFullEmail")),
                subscriptionType: account.displaySubscriptionType,
                isActive: account.isActive,
                sessionUtilization: usage?.fiveHour?.utilization,
                sessionResetTime: usage?.fiveHour?.resetTimeString,
                weeklyUtilization: usage?.sevenDay?.utilization,
                weeklyResetTime: usage?.sevenDay?.resetTimeString,
                extraUsageEnabled: usage?.extraUsage?.isEnabled,
                hasError: error != nil && usage == nil,
                errorMessage: error?.message
            )
        }

        var combinedModelUsage = activityStats.modelUsage
        for (model, count) in codexTodayModelActivity where count > 0 {
            combinedModelUsage[model, default: 0] += count
        }
        let data = WidgetData(
            selectedProvider: nil,
            accounts: widgetAccounts,
            todayCost: combinedTodayCost,
            conversationTurns: activityStats.conversationTurns,
            activeCodingTime: activityStats.activeCodingTimeString,
            linesWritten: activityStats.linesWritten,
            modelUsage: combinedModelUsage.filter { $0.value > 0 },
            lastUpdated: Date()
        )
        data.save()
        WidgetCenter.shared.reloadAllTimelines()
        log.debug("[updateWidgetData] Widget data saved and timelines reloaded")
    }

    // MARK: - Persistence

    private struct PersistedUsageSnapshot: Codable {
        let usage: UsageAPIResponse
        let updatedAt: Date
    }

    private func loadFailoverRuntime() {
        guard let data = UserDefaults.standard.data(forKey: failoverRuntimeKey),
              let stored = try? JSONDecoder().decode([String: [UUID]].self, from: data) else {
            return
        }
        let validIDs = Set(accounts.map(\.id))
        for provider in [AIProviderType.claudeCode, .codex] {
            let ids = stored[provider.rawValue, default: []].filter { validIDs.contains($0) }
            exhaustedFailoverAccounts[provider] = Set(ids)
        }
    }

    private func saveFailoverRuntime() {
        let stored = Dictionary(uniqueKeysWithValues:
            [AIProviderType.claudeCode, .codex].map { provider in
                (provider.rawValue, Array(exhaustedFailoverAccounts[provider, default: []]))
            }
        )
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: failoverRuntimeKey)
        }
    }

    private func recordUsage(_ usage: UsageAPIResponse, for accountID: UUID) {
        accountUsage[accountID] = usage
        accountUsageUpdatedAt[accountID] = Date()
        saveUsageSnapshots()
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
            accountUsage[id] = snapshot.usage
            accountUsageUpdatedAt[id] = snapshot.updatedAt
        }
    }

    private func saveUsageSnapshots() {
        let validAccountIDs = Set(accounts.map(\.id))
        let snapshots = accountUsage.reduce(into: [String: PersistedUsageSnapshot]()) { result, item in
            guard validAccountIDs.contains(item.key),
                  let updatedAt = accountUsageUpdatedAt[item.key] else { return }
            result[item.key.uuidString] = PersistedUsageSnapshot(
                usage: item.value,
                updatedAt: updatedAt
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
        activeAccount = accounts.first { $0.provider == .claudeCode && $0.isActive }
        log.info("[loadAccounts] Loaded \(decoded.count) accounts")
    }

    private func saveAccounts(refreshWidget: Bool = false) {
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

        if let index = accounts.firstIndex(where: { $0.provider == .claudeCode && $0.email == email }) {
            for i in accounts.indices where accounts[i].provider == .claudeCode {
                accounts[i].isActive = (i == index)
            }
            accounts[index].orgName = status.orgName
            accounts[index].subscriptionType = status.subscriptionType
            activeAccount = accounts[index]
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
            activeAccount = account
            _ = claudeService.captureCurrentCredentials(forAccountId: account.id.uuidString)
            saveAccounts()
            log.info("[updateActiveAccount] Auto-created first account, id=\(account.id)")
        } else {
            log.info("[updateActiveAccount] Logged-in account not in our list (might be new)")
        }
    }

    // MARK: - Codex Account Management

    func addCurrentCodexAccount() async {
        do {
            let (identity, location) = try codexService.captureSystemAccount()
            try addCodexIdentity(identity, location: location, makeActive: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loginNewCodexAccount() async {
        guard codexAvailable else {
            errorMessage = CodexServiceError.binaryNotFound.localizedDescription
            return
        }
        guard let loginID = beginLoginAttempt() else { return }
        defer { finishLoginAttempt(loginID) }
        do {
            let (identity, location) = try await codexService.loginManagedAccount()
            try addCodexIdentity(identity, location: location, makeActive: true)
        } catch {
            guard loginAttemptID == loginID else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func addCodexIdentity(_ identity: CodexIdentity, location: String, makeActive: Bool) throws {
        if accounts.contains(where: { $0.provider == .codex && $0.email.caseInsensitiveCompare(identity.email) == .orderedSame }) {
            try? codexService.removeManagedAccount(homePath: location)
            throw CodexServiceError.loginFailed("This Codex account is already managed.")
        }
        if makeActive {
            try codexService.promoteToSystem(homePath: location)
            for index in accounts.indices where accounts[index].provider == .codex {
                accounts[index].isActive = false
            }
        }
        accounts.append(Account(
            email: identity.email,
            displayName: identity.displayName,
            provider: .codex,
            orgName: identity.accountID,
            subscriptionType: identity.planType,
            isActive: makeActive,
            credentialLocation: location
        ))
        saveAccounts(refreshWidget: true)
    }

    private func switchToCodex(_ account: Account) async {
        guard !account.isActive, let location = account.credentialLocation else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            if let current = activeAccount(for: .codex),
               let currentLocation = current.credentialLocation {
                try codexService.syncSystemCredentials(
                    toManagedHome: currentLocation,
                    expectedEmail: current.email
                )
            }
            try codexService.promoteToSystem(homePath: location)
            for index in accounts.indices where accounts[index].provider == .codex {
                accounts[index].isActive = accounts[index].id == account.id
                if accounts[index].id == account.id {
                    accounts[index].lastUsed = Date()
                }
            }
            saveAccounts(refreshWidget: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reauthenticateCodexAccount(_ account: Account) async {
        guard let loginID = beginLoginAttempt() else { return }
        defer { finishLoginAttempt(loginID) }
        do {
            let (identity, newLocation) = try await codexService.loginManagedAccount()
            guard identity.email.caseInsensitiveCompare(account.email) == .orderedSame else {
                try? codexService.removeManagedAccount(homePath: newLocation)
                throw CodexServiceError.loginFailed("Logged in as \(identity.email), expected \(account.email).")
            }
            if let oldLocation = account.credentialLocation {
                try? codexService.removeManagedAccount(homePath: oldLocation)
            }
            guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
            accounts[index].credentialLocation = newLocation
            accounts[index].displayName = identity.displayName
            accounts[index].orgName = identity.accountID
            accounts[index].subscriptionType = identity.planType
            if account.isActive {
                try codexService.promoteToSystem(homePath: newLocation)
            }
            saveAccounts(refreshWidget: true)
        } catch {
            guard loginAttemptID == loginID else { return }
            errorMessage = error.localizedDescription
        }
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
                accounts[accountIndex].subscriptionType = identity.planType
            }
        }
        saveAccounts()
    }
}
