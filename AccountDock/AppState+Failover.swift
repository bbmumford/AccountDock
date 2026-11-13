import Foundation

private let failoverLog = FileLog("Failover")

/// Quota monitoring, failover planning and agent suspension.
///
/// One cycle runs on an adaptive timer: it ingests readings the agents already
/// recorded locally, spends the provider's shared request budget only on the
/// readings a decision needs, asks `FailoverPlanner` what to do, and executes
/// that plan.
extension AppState {
    /// Seconds before a projected exhaustion at which agents are paused when
    /// no other account can take the workload.
    static let suspensionLead: TimeInterval = 150

    // MARK: - Scheduling

    func scheduleQuotaCycle(after interval: TimeInterval? = nil) {
        failoverMonitorTimer?.invalidate()
        let delay = interval ?? nextQuotaCycleInterval()
        failoverMonitorTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.failoverMonitorTimer = nil
                await self.runQuotaCycle()
            }
        }
        failoverLog.debug("next quota cycle in \(Int(delay))s")
    }

    /// Cycles run often while any monitored account nears a limit; each cycle
    /// is cheap because endpoint requests are separately budgeted.
    func nextQuotaCycleInterval(now: Date = Date()) -> TimeInterval {
        // The router's Kimi token lasts minutes; it is renewed from the cycle.
        var interval: TimeInterval = (routerInUse || sessionSlotsInUse) ? 60 : 120
        for provider in monitoredProviders {
            guard let account = activeAccount(for: provider) else { continue }
            let planner = FailoverPlanner(settings: plannerSettings(provider))
            let state = quotaState(for: account, now: now)
            if planner.isTriggered(state, now: now) || hasPausedAgents(provider) {
                interval = min(interval, 20)
            } else if let seconds = planner.secondsUntilTrigger(state, now: now) {
                interval = min(interval, max(20, min(120, seconds / 3)))
            }
            if let pending = pendingResetRecovery[provider]?.resetDate {
                interval = min(interval, max(20, pending.timeIntervalSince(now) + 5))
            }
        }
        return interval
    }

    var monitoredProviders: [AIProviderType] {
        AIProviderType.implementedProviders.filter {
            let policy = failoverConfig.policy(for: $0)
            return policy.enabled || policy.intelligentBalancingEnabled || policy.suspendAgentsWhenExhausted
                || policy.routeTarget != nil || policy.distributeSessions
        }
    }

    func runQuotaCycle() async {
        defer { scheduleQuotaCycle() }
        guard !isMonitoringFailover, !isLoading, !isLoggingIn else { return }
        isMonitoringFailover = true
        defer { isMonitoringFailover = false }

        await ingestPassiveTelemetry()
        await adoptRenewedCredentials()
        moveSessionsOffLimitedAccounts()
        synchronizePauseGateIfDue()
        let now = Date()
        for provider in monitoredProviders {
            guard let account = activeAccount(for: provider) else { continue }
            if activeReadingIsDue(account, now: now) {
                await fetchUsageNow(account, priority: .critical)
            }
        }
        await refreshLimitResetsIfDue(now: now)
        if let routed = AIProviderType.routedProvider, routedStatus[routed] != nil {
            await refreshRouteTargetReading(maximumAge: 60)
        }
        await maintainRouter()
        // Before sessions are counted, so one started on a slot since the
        // last cycle is counted on the slot's account from its first cycle.
        await refreshSlotProcesses()
        refreshSessions()
        await ingestTranscriptRequests()
        await maintainSessionSlots(processesRead: true)
        await evaluateFailover()
        saveLearningIfDue()
        for provider in AgentPauseGate.providers { prunePausedSessions(provider) }
    }

    /// Keeps the pause hook installed exactly for the providers that pause
    /// agents. Reading the hook files is cheap; it is still limited to once
    /// every ten minutes because policy changes are rare.
    func synchronizePauseGateIfDue(now: Date = Date()) {
        if let last = pauseGateSynchronizedAt, now.timeIntervalSince(last) < 10 * 60 { return }
        pauseGateSynchronizedAt = now
        let enabled = pausingProviders
        let routerRunning = routerInUse
        // The request hold first: the gate's command depends on it.
        Task.detached(priority: .utility) {
            ProviderRequestHold.synchronize(enabledFor: enabled, routerRunning: routerRunning)
            AgentPauseGate.synchronize(enabledFor: enabled)
        }
    }

    /// Providers whose sessions AccountDock pauses at the limit.
    var pausingProviders: Set<AIProviderType> {
        Set(AgentPauseGate.providers.filter { failoverConfig.policy(for: $0).suspendAgentsWhenExhausted })
    }

    /// How often each account's limit resets are asked for, whatever its
    /// readings are otherwise due for.
    nonisolated static let limitResetsInterval: TimeInterval = 60 * 60

    /// Reads one account whose limit resets are due, of any provider that
    /// reports them, so every subscription tile shows them: a spent account's
    /// readings are otherwise taken rarely, yet a reset matters most there.
    /// Only the provider's own usage endpoint reports resets, so the reading
    /// is a full one; it spends only background allowance, never what the
    /// active account's readings need.
    func refreshLimitResetsIfDue(now: Date) async {
        // One reading at a time across all accounts: the provider throttles
        // the client as a whole, and a throttle stops every account's
        // readings, the active account's included.
        if let last = limitResetsLastReadAt, now.timeIntervalSince(last) < Self.limitResetsSpacing { return }
        let candidates = accounts.filter { $0.provider.capabilities.reportsLimitResets && !needsSignIn($0) }
        guard let account = Self.accountDueForLimitResets(candidates, checkedAt: limitResetsCheckedAt, now: now) else { return }
        // A reading not taken, as when the background allowance is spent or
        // the request fails, is tried again after `limitResetsRetry`.
        let read = await fetchUsageNow(account, priority: .background, resetDetails: true)
        limitResetsLastReadAt = now
        limitResetsCheckedAt[account.id] = read ? now : now.addingTimeInterval(Self.limitResetsRetry - Self.limitResetsInterval)
    }

    /// The least time between two readings `refreshLimitResetsIfDue` takes.
    nonisolated static let limitResetsSpacing: TimeInterval = 5 * 60

    /// How soon a reset reading that was not taken is tried again.
    nonisolated static let limitResetsRetry: TimeInterval = 5 * 60

    /// The account whose resets were asked for longest ago, once
    /// `limitResetsInterval` has passed; one never asked for comes first.
    nonisolated static func accountDueForLimitResets(_ accounts: [Account], checkedAt: [UUID: Date], now: Date) -> Account? {
        accounts
            .filter { checkedAt[$0.id].map { now.timeIntervalSince($0) >= limitResetsInterval } ?? true }
            .min { (checkedAt[$0.id] ?? .distantPast) < (checkedAt[$1.id] ?? .distantPast) }
    }

    /// The active account is read when its newest reading is older than half
    /// the time it is projected to take to cross the next limit.
    func activeReadingIsDue(_ account: Account, now: Date) -> Bool {
        guard let updatedAt = accountUsageUpdatedAt[account.id] else { return true }
        let age = now.timeIntervalSince(updatedAt)
        let planner = FailoverPlanner(settings: plannerSettings(account.provider))
        let state = quotaState(for: account, now: now)
        if let next = planner.nextUsefulReading(state, now: updatedAt) {
            return now >= next
        }
        return age >= planner.readingInterval(state, now: now)
    }

    // MARK: - Passive readings

    func ingestPassiveTelemetry() async {
        let codexHomes = accounts.filter { $0.provider == .codex }.compactMap(\.credentialLocation)
        // `~/.claude.json` can be megabytes; it is parsed off the main thread.
        let observations = await Task.detached(priority: .utility) {
            PassiveUsageTelemetry.shared.collect(codexHomes: codexHomes, now: Date())
        }.value
        let now = Date()
        for observation in observations {
            let noSessionWindow = observation.usage.reportsNoSessionWindow
            // A window whose reset has passed describes the window before it.
            let usage = observation.usage.droppingPassedWindows(at: now)
            guard usage.fiveHour != nil || usage.sevenDay != nil else { continue }
            let observation = observation.with(usage: usage)
            if let model = observation.model {
                workloadModels[observation.source.provider] = (model, observation.observedAt)
                if let session = observation.processKey { noteSessionModel(session, model: model, at: observation.observedAt) }
            }
            // A session in a slot reports its slot's account; others are
            // matched by their reset times.
            if sessionSlotIsSettling(observation.processKey, provider: observation.source.provider,
                                     reportedAt: observation.observedAt) { continue }
            guard let accountID = slotAccount(forSession: observation.processKey, provider: observation.source.provider)
                    ?? attribute(observation) else { continue }
            if let updatedAt = accountUsageUpdatedAt[accountID], observation.observedAt <= updatedAt { continue }
            if Self.describesSupersededWindow(observation.usage, stored: accountUsage[accountID]) { continue }
            let merged = accountUsage[accountID].map {
                $0.merged(withNewer: observation.usage, clearingSession: noSessionWindow)
            } ?? observation.usage
            // The reading only confirms a reset when it carries every window
            // the provider reports for the account, each with a reset still
            // ahead.
            let confirmsReset = usage.sevenDay != nil && (usage.fiveHour != nil || noSessionWindow)
            recordUsage(merged, for: accountID, observedAt: observation.observedAt, confirmsReset: confirmsReset)
            if accountUsageErrors[accountID]?.isRateLimited == true {
                accountUsageErrors[accountID] = nil
            }
            failoverLog.debug("passive \(observation.source.rawValue) reading applied to \(accountID.uuidString)")
        }
    }

    /// The account a passive reading belongs to: the one it names, or the
    /// one whose reset times it matches.
    private func attribute(_ observation: PassiveUsageObservation) -> UUID? {
        let provider = observation.source.provider
        switch observation.accountKey {
        case .providerAccountID(let id):
            return accountID(forProviderAccountID: id, provider: provider)
        case .credentialLocation(let location):
            return accounts.first { $0.provider == provider && $0.credentialLocation == location }?.id
        case nil:
            return observation.source.alwaysNamesAccount ? nil : matchByResets(observation.usage, provider: provider)
        }
    }

    /// The account the provider identifies by `id`.
    private func accountID(forProviderAccountID id: String, provider: AIProviderType) -> UUID? {
        switch provider {
        case .claudeCode: claudeAccountID(forUUID: id)
        case .codex, .kimi, .gemini: nil
        }
    }

    /// Every account's quota window resets at its own moment, so a reading
    /// whose reset times match exactly one known account belongs to it. When
    /// nothing matches, the reading is attributed to the active account only
    /// while that account has no established window of its own.
    private func matchByResets(_ usage: UsageAPIResponse, provider: AIProviderType) -> UUID? {
        func close(_ a: Date?, _ b: Date?) -> Bool {
            guard let a, let b else { return false }
            return abs(a.timeIntervalSince(b)) <= 120
        }
        let candidates = accounts.filter { $0.provider == provider }
        // A stored session reset that disagrees with the reading's rules the
        // account out even when its weekly reset happens to match.
        func sessionContradicts(_ account: Account) -> Bool {
            guard let stored = accountUsage[account.id]?.fiveHour?.resetsAtDate,
                  let observed = usage.fiveHour?.resetsAtDate else { return false }
            return abs(stored.timeIntervalSince(observed)) > 120
        }
        let weeklyMatches = candidates.filter {
            close(accountUsage[$0.id]?.sevenDay?.resetsAtDate, usage.sevenDay?.resetsAtDate)
                && !sessionContradicts($0)
        }
        if weeklyMatches.count == 1 { return weeklyMatches[0].id }
        let pool = weeklyMatches.isEmpty ? candidates : weeklyMatches
        let sessionMatches = pool.filter {
            close(accountUsage[$0.id]?.fiveHour?.resetsAtDate, usage.fiveHour?.resetsAtDate)
        }
        if sessionMatches.count == 1 { return sessionMatches[0].id }
        if weeklyMatches.isEmpty, sessionMatches.isEmpty,
           let active = activeAccount(for: provider),
           accountUsage[active.id]?.sevenDay?.resetsAtDate == nil {
            return active.id
        }
        return nil
    }

    private func claudeAccountID(forUUID uuid: String) -> UUID? {
        if let id = claudeAccountUUIDs[uuid] { return id }
        if let builtAt = claudeAccountUUIDsBuiltAt, Date().timeIntervalSince(builtAt) < 10 * 60 { return nil }
        var map: [String: UUID] = [:]
        for account in accounts where account.provider == .claudeCode {
            if let value = keychain.getAccountBackup(forAccountId: account.id.uuidString)?
                .oauthAccount["accountUuid"]?.value as? String {
                map[value] = account.id
            }
        }
        if let active = activeAccount(for: .claudeCode),
           let value = keychain.readOAuthAccount()?["accountUuid"]?.value as? String {
            map[value] = active.id
        }
        claudeAccountUUIDs = map
        // An incomplete map is rebuilt as soon as the saved accounts are read.
        claudeAccountUUIDsBuiltAt = keychain.backupStoreAvailable ? Date() : nil
        return map[uuid]
    }

    // MARK: - Request budget

    /// Whether the periodic refresh should read this account, and at which
    /// priority. Idle accounts do not change, so they are read rarely; an
    /// account that was just switched away from may still be consumed by
    /// sessions holding its credential, so it is read more often.
    func usageReadPriority(_ account: Account, forced: Bool, now: Date = Date()) -> UsageRequestBudget.Priority? {
        if let until = usageRetryAfter[account.id], until > now { return nil }
        if accountsAwaitingPostResetVerification.contains(account.id) { return .background }
        guard accountUsage[account.id] != nil, let updatedAt = accountUsageUpdatedAt[account.id] else {
            return forced ? .candidate : .background
        }
        let age = now.timeIntervalSince(updatedAt)
        if forced { return age > 60 ? .candidate : nil }
        // An account serving sessions is consumed as the active one is.
        if account.isActive || slotServedAccounts.contains(account.id) { return age > 120 ? .background : nil }
        let recentlyAway = lastSwitchedAway[account.id].map { now.timeIntervalSince($0) < FailoverPlanner.sessionWindow } ?? false
        return age >= (recentlyAway ? 10 * 60 : 30 * 60) ? .background : nil
    }

    func spendUsageRequest(_ provider: AIProviderType, _ priority: UsageRequestBudget.Priority) -> Bool {
        usageBudgets[provider]?.spend(priority) ?? true
    }

    func noteUsageThrottle(_ account: Account, retryAt: Date?) {
        guard let budget = usageBudgets[account.provider] else { return }
        budget.recordThrottle(retryAfter: retryAt)
        usageRetryAfter[account.id] = budget.blockedUntil ?? retryAt ?? Date().addingTimeInterval(60)
        accountUsageErrors[account.id] = UsageErrorState(
            isExpired: false,
            isRateLimited: true,
            message: accountUsage[account.id] == nil
                ? "Usage refresh is temporarily rate limited."
                : "Usage refresh throttled. Showing the last known limits.",
            cachedAt: accountUsageUpdatedAt[account.id]
        )
        failoverLog.warning("\(account.provider.rawValue) usage endpoint throttled; shared cool-down until \(budget.blockedUntil?.description ?? "unknown")")
    }

    /// Plan tiers change rarely; profile requests share the usage budget.
    func shouldCheckClaudeProfile(_ account: Account, forced: Bool, now: Date = Date()) -> Bool {
        if forced || !account.supportsProviderWorkloads { return true }
        guard let checked = lastProfileCheck[account.id] else { return true }
        return now.timeIntervalSince(checked) >= 6 * 60 * 60
    }

    /// Reads one account's usage immediately. Returns whether a fresh
    /// reading was recorded.
    @discardableResult
    func fetchUsageNow(_ account: Account, priority: UsageRequestBudget.Priority,
                       resetDetails: Bool = false) async -> Bool {
        if let retryAt = usageRetryAfter[account.id], retryAt > Date() {
            return false
        }
        guard spendUsageRequest(account.provider, priority) else { return false }
        return applyUsageRead(await readUsage(account, forced: false, includeMetadata: false,
                                              resetDetails: resetDetails), for: account)
    }

    /// Reads one account's usage from the provider at once, for an action
    /// the user just took on it: neither a throttle the provider answered
    /// an earlier reading with nor the request allowance holds it back, and
    /// what it returns replaces the stored reading whole.
    @discardableResult
    func readUsageNow(_ account: Account) async -> Bool {
        usageRetryAfter[account.id] = nil
        let outcome = await readUsage(account, forced: true, includeMetadata: false, resetDetails: true)
        if case .reading = outcome { accountUsage[account.id] = nil }
        return applyUsageRead(outcome, for: account)
    }

    /// `readUsageNow` for each provider's active account; the menu's Refresh
    /// button calls it before the ordinary refresh.
    func readActiveUsageNow() async {
        for provider in AIProviderType.implementedProviders {
            if let active = activeAccount(for: provider), !needsSignIn(active) { await readUsageNow(active) }
        }
    }

    /// Whether a passive reading describes a long window the stored reading
    /// has already left behind: its reset comes over an hour before the
    /// stored one. A session's status line repeats the limits of its last
    /// reply, so after the provider resets an account early its idle
    /// sessions keep reporting the window before the reset.
    nonisolated static func describesSupersededWindow(_ passive: UsageAPIResponse, stored: UsageAPIResponse?) -> Bool {
        guard let known = stored?.sevenDay?.resetsAtDate, let reported = passive.sevenDay?.resetsAtDate else { return false }
        return reported < known.addingTimeInterval(-60 * 60)
    }

    /// Checks the destinations the plan switches to until one's sign-in is
    /// usable, so a rejected destination costs no cycle: each rejection
    /// leaves that account out of the next plan. Only a switch `evaluate`
    /// acts on, per `actsOn`, is checked, because the check renews the
    /// destination's token. Returns the plan to act on.
    private func planWithUsableDestination(
        _ plan: FailoverPlan,
        actsOn: (FailoverPlan.SwitchReason) -> Bool,
        replan: () -> FailoverPlan
    ) async -> FailoverPlan {
        var plan = plan
        for _ in 0..<3 {
            guard case .switchTo(let id, let reason) = plan, actsOn(reason),
                  let target = accounts.first(where: { $0.id == id }),
                  !(await credentialIsUsable(target)) else { return plan }
            plan = replan()
        }
        return plan
    }

    // MARK: - Planner inputs

    func plannerSettings(_ provider: AIProviderType, canVerify: Bool = true) -> FailoverPlanner.Settings {
        let policy = failoverConfig.policy(for: provider)
        var settings = FailoverPlanner.Settings(
            policy: policy,
            provider: provider,
            canSwitchProactively: !provider.capabilities.supportsSelectableSwitchMode || policy.switchMethod != .safeRestart,
            canVerify: canVerify
        )
        settings.switchCostPercent = switchCostPercent(provider)
        settings.inFlightReservePercent = inFlightReservePercent(provider)
        settings.allowExtraUsage = policy.extraUsageMonthlyLimit != nil
        settings.demand = demandFunction(provider)
        // Without threshold failover only the provider's hard limit moves work.
        if !policy.enabled {
            settings.sessionTrigger = 100
            settings.weeklyTrigger = 100
        }
        return settings
    }

    func quotaState(for account: Account, now: Date = Date(), model: String? = nil) -> QuotaAccountState {
        let trend = quotaTrends[account.id] ?? QuotaTrend()
        let rates = trend.currentRates(now: now)
        let uncertainty = trend.currentUncertainty(now: now)
        let quarantined = (credentialQuarantine[account.id].map { $0 > now } ?? false)
            || (switchFailureCooldown[account.id].map { $0 > now } ?? false)
        let shared = account.provider.capabilities.credentialSharedAcrossSessions
        let consumedElsewhere = !account.isActive && shared
            && ((lastSwitchedAway[account.id].map { now.timeIntervalSince($0) < FailoverPlanner.sessionWindow } ?? false)
                || slotServedAccounts.contains(account.id))
        let expired = !account.isActive && rejectedCredentialAccounts.contains(account.id)
        return QuotaAccountState(
            id: account.id,
            usage: plannedUsage(account, now: now, model: model),
            observedAt: accountUsageUpdatedAt[account.id],
            sessionBurnPerHour: rates.session,
            weeklyBurnPerHour: rates.weekly,
            sessionPerWeekly: sharedSessionPerWeekly(account.provider),
            isActive: account.isActive,
            mayBeConsumedElsewhere: consumedElsewhere,
            credentialsUsable: !quarantined && !expired,
            workloadAvailable: account.supportsProviderWorkloads,
            resetUnverified: accountsAwaitingPostResetVerification.contains(account.id),
            sessionBurnStdDev: uncertainty.session,
            weeklyBurnStdDev: uncertainty.weekly,
            extraUsageAvailable: extraUsageAvailable(account),
            refusedAtLimit: routerRefusedUntil[account.id].map { $0 > now } ?? false
        )
    }

    /// The account's usage with its weekly window narrowed to what work on
    /// a model may still use, when that model's own weekly limit leaves less
    /// room than the whole weekly allowance.
    ///
    /// With `model`, the account is judged for one session using it, as
    /// `serveSessionSlots` judges each session that has a slot of its own.
    /// Without, it is judged for the sessions that share one credential and
    /// so move together: the window is narrowed by the tightest limit among
    /// the models those sessions use, and left whole when none uses a
    /// limited model, so one session on a spent model moves alone.
    func plannedUsage(_ account: Account, now: Date = Date(), model: String? = nil) -> UsageAPIResponse? {
        guard let usage = accountUsage[account.id] else { return nil }
        guard !usage.modelWeeklyLimits.isEmpty else { return usage }
        let models = model.map { [$0] } ?? sharedSessionModels(account.provider, now: now)
        return usage.replacingSevenDay(usage.weeklyWindow(forModels: models))
    }

    /// How long a session's last reported model is taken as the one it uses.
    static let sessionModelLifetime: TimeInterval = 24 * 60 * 60

    func noteSessionModel(_ session: String, model: String, at: Date) {
        if let known = sessionModels[session], known.seenAt > at { return }
        sessionModels[session] = (model, at)
        if sessionModels.count > 512 {
            sessionModels = sessionModels.filter { at.timeIntervalSince($0.value.seenAt) < Self.sessionModelLifetime }
        }
    }

    /// The model `session` uses, when it reported one within
    /// `sessionModelLifetime`.
    func sessionModel(_ session: String?, now: Date) -> String? {
        guard let session, let known = sessionModels[session],
              now.timeIntervalSince(known.seenAt) < Self.sessionModelLifetime else { return nil }
        return known.model
    }

    /// The models used by the provider's running sessions that read no slot
    /// of their own: they share the CLI's credential or the router, and are
    /// served by whichever account that is.
    func sharedSessionModels(_ provider: AIProviderType, now: Date) -> [String] {
        let models = (liveSessions[provider] ?? []).compactMap { session -> String? in
            if let pid = session.processID, slotDirectoryByProcess[pid] != nil { return nil }
            return sessionModel(session.sessionID, now: now)
        }
        return Array(Set(models))
    }

    /// Session percentage per weekly percent, shared by every account of the
    /// provider. The ratio belongs to the plan and the workload rather than to
    /// one account, and `FailoverPlanner.latestStart` compares accounts
    /// against each other, so all of them must use the same value; a ratio
    /// learned on one account and a default on another would rank them on a
    /// difference that is not real.
    func sharedSessionPerWeekly(_ provider: AIProviderType) -> Double? {
        let learned = accounts
            .filter { $0.provider == provider }
            .compactMap { quotaTrends[$0.id]?.sessionPerWeekly }
        guard !learned.isEmpty else { return nil }
        return learned.reduce(0, +) / Double(learned.count)
    }

    private func ladder(for provider: AIProviderType, policy: ProviderFailoverPolicy) -> [Account] {
        let providerAccounts = accounts.filter {
            $0.provider == provider && !policy.excludedAccountIDs.contains($0.id)
        }
        let byID = Dictionary(uniqueKeysWithValues: providerAccounts.map { ($0.id, $0) })
        return policy.accountOrder.compactMap { byID[$0] }
            + providerAccounts.filter { !policy.accountOrder.contains($0.id) }
    }

    // MARK: - Evaluation

    func evaluateFailover() async {
        guard !isLoggingIn, !isEvaluatingFailover else { return }
        noteKeychainWaitIfNeeded()
        isEvaluatingFailover = true
        defer { isEvaluatingFailover = false }
        let monitored = monitoredProviders
        for provider in AIProviderType.implementedProviders {
            let policy = failoverConfig.policy(for: provider)
            let ladder = ladder(for: provider, policy: policy)
            let current = ladder.first(where: \.isActive)
            // Paused agents of a provider AccountDock no longer manages or
            // that no longer pauses agents are never left paused. An active
            // account that failover excludes, chosen by hand, resumes nothing:
            // the sessions wait for the user or for capacity in the order.
            if !monitored.contains(provider) || !policy.suspendAgentsWhenExhausted {
                await releaseSuspendedAgents(provider, reason: "AccountDock no longer pauses this provider's agents")
            }
            guard monitored.contains(provider), let current else { continue }
            await evaluate(provider: provider, policy: policy, ladder: ladder, current: current)
        }
    }

    /// Tells the user when the saved accounts are still waiting on a macOS
    /// Keychain prompt: until it is answered, AccountDock cannot switch to,
    /// read or renew any account other than the active one.
    private func noteKeychainWaitIfNeeded() {
        if keychain.backupStoreAvailable {
            if keychainWaitNoted {
                keychainWaitNoted = false
                if errorMessage == Self.keychainWaitMessage { errorMessage = nil }
            }
            return
        }
        guard !keychainWaitNoted, Date().timeIntervalSince(launchedAt) > 15 else { return }
        keychainWaitNoted = true
        errorMessage = Self.keychainWaitMessage
        for provider in AIProviderType.implementedProviders where provider.capabilities.credentialStore == .keychain {
            failoverEvents.record(provider, "Waiting for macOS Keychain access to the saved accounts; until it is allowed, only the active account can be used.")
        }
    }

    static let keychainWaitMessage = "AccountDock is waiting for Keychain access to your saved accounts. Choose Always Allow in the macOS prompt so it can switch accounts."

    private func releaseSuspendedAgents(_ provider: AIProviderType, reason: String) async {
        guard hasPausedAgents(provider) || suspensionContexts[provider] != nil else { return }
        let resumed = await releasePausedAgents(provider)
        if resumed > 0 {
            failoverEvents.record(provider, "Resumed \(resumed) paused session(s): \(reason).")
        }
    }

    private func plan(
        provider: AIProviderType,
        ladder: [Account],
        current: Account,
        canVerify: Bool
    ) -> (FailoverPlan, FailoverPlanner) {
        let now = Date()
        let planner = FailoverPlanner(settings: plannerSettings(provider, canVerify: canVerify))
        let recovered = exhaustedFailoverAccounts[provider, default: []]
        let plan = planner.plan(
            current: quotaState(for: current, now: now),
            ladder: ladder.map { quotaState(for: $0, now: now) },
            recoveredIDs: recovered,
            lastSwitch: lastAutomaticFailover[provider],
            now: now
        )
        return (plan, planner)
    }

    private func evaluate(
        provider: AIProviderType,
        policy: ProviderFailoverPolicy,
        ladder: [Account],
        current: Account
    ) async {
        var canVerify = usageBudgets[provider]?.canSpend(.candidate) ?? true
        var (plan, planner) = plan(provider: provider, ladder: ladder, current: current, canVerify: canVerify)
        // Destinations whose data may be out of date are read before use,
        // within the shared request budget.
        for _ in 0..<3 {
            guard case .verify(let ids) = plan else { break }
            var verified = false
            for id in ids {
                guard let account = accounts.first(where: { $0.id == id }) else { continue }
                if await fetchUsageNow(account, priority: .candidate) { verified = true }
            }
            if !verified { canVerify = false }
            (plan, planner) = self.plan(provider: provider, ladder: ladder, current: current, canVerify: canVerify)
        }
        plan = await planWithUsableDestination(plan, actsOn: { reason in
            switch reason {
            case .balance: policy.intelligentBalancingEnabled
            case .threshold: policy.enabled
            default: policy.enabled || policy.intelligentBalancingEnabled
            }
        }) {
            self.plan(provider: provider, ladder: ladder, current: current, canVerify: false).0
        }

        let now = Date()
        reholdSessionsNearLimit(provider, planner: planner)
        let currentState = quotaState(for: current, now: now)
        // Sessions served from several accounts keep running on each account
        // with room, and the router moves a refused request to the next, so
        // any other account that is neither at its limit nor about to be
        // keeps work going without a switch.
        let pooled = provider == AIProviderType.routedProvider && policy.distributeSessions && routerInUse
        let poolHasRoom = pooled && ladder.contains { account in
            guard account.id != current.id else { return false }
            let state = quotaState(for: account, now: now)
            return planner.tier(state, now: now) <= .usable
                && (planner.secondsUntilExhaustion(state, now: now) ?? .infinity) >= Self.suspensionLead
        }
        if pooled {
            await holdSessionsForImminentReset(provider, policy: policy, ladder: ladder, planner: planner)
        }
        let fallbackAvailable = poolHasRoom || (policy.enabled || policy.intelligentBalancingEnabled)
            && planner.hasFallback(
                current: currentState,
                ladder: ladder.map { quotaState(for: $0, now: now) },
                now: now
            )
        let exhaustionSoon = (planner.secondsUntilExhaustion(currentState, now: now) ?? .infinity) < Self.suspensionLead
            || planner.tier(currentState, now: now) == .exhausted

        switch plan {
        case .waitForReset, .noCapacity, .verify: break
        default:
            if pendingResetRecovery[provider] != nil {
                pendingResetRecovery[provider] = nil
                saveFailoverRuntime()
            }
        }

        switch plan {
        case .stay(let reason):
            if reason == .drainingToLimit {
                updateStatus(provider, "Using \(messageName(current)) up to its limit; no other account is below its failover threshold.")
            } else if reason == .holdingForImminentReset {
                updateStatus(provider, "Holding \(messageName(current)); its limiting window resets soon.")
            }
            // On extra usage the account keeps serving past its limit, so its
            // sessions are not paused for reaching it.
            if exhaustionSoon && !fallbackAvailable && reason != .usingExtraUsage {
                await holdWork(provider, policy: policy, current: current, because: "every included account is at or near its limit")
            } else if reason == .usingExtraUsage {
                await releaseSuspendedAgents(provider, reason: "\(messageName(current)) serves them on extra usage")
            } else {
                await resumeAgentsIfCapacityReturned(provider, current: current, planner: planner)
            }

        case .switchTo(let targetID, let reason):
            guard let target = accounts.first(where: { $0.id == targetID }) else { return }
            if case .balance = reason, !policy.intelligentBalancingEnabled { return }
            if case .threshold = reason, !policy.enabled { return }
            guard policy.enabled || policy.intelligentBalancingEnabled else {
                if exhaustionSoon { await holdWork(provider, policy: policy, current: current, because: "automatic switching is disabled") }
                return
            }
            await performAutomaticSwitch(provider: provider, policy: policy, from: current, to: target, reason: reason)

        case .waitForReset(let accountID, let date):
            pendingResetRecovery[provider] = PendingResetRecovery(accountID: accountID, resetDate: date)
            // Sources report the same reset a few seconds apart; the minute is
            // rounded so the status does not alternate between two times.
            let rounded = Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 60).rounded() * 60)
            // A reset on another day names the day, so one days away does not
            // read as later today.
            let resetText = Calendar.current.isDateInToday(rounded)
                ? rounded.formatted(date: .omitted, time: .shortened)
                : rounded.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
            await holdWork(provider, policy: policy, current: current, because: "every included account is exhausted until \(resetText)")
            // A switch that reaches running sessions would restart or reload
            // the paused sessions, and one that moves them to a live
            // credential (`moveRunningSessions`) would send the requests no
            // gate holds, such as one already under way or one a teammate's
            // message starts, to a destination that refuses them, while the
            // current account may still serve them from its in-flight
            // reserve. Such a destination is only switched to once its reset
            // has happened, when `plan` moves to it.
            let target = accounts.first(where: { $0.id == accountID })
            if accountID != current.id, !provider.capabilities.switchReachesRunningSessions,
               credentialModule(for: provider)?.liveCredential == nil,
               policy.enabled || policy.intelligentBalancingEnabled, let target {
                updateStatus(provider, "All accounts exhausted. Preparing \(messageName(target)), which resets at \(resetText).\(signInNote(ladder))")
                await performAutomaticSwitch(provider: provider, policy: policy, from: current, to: target, reason: .exhausted)
            } else {
                updateStatus(provider, "All accounts exhausted. Waiting for \(messageName(target ?? current)) to reset at \(resetText).\(signInNote(ladder))")
            }

        case .noCapacity:
            updateStatus(provider, "All configured accounts are at their limits; reset times are unavailable.\(signInNote(ladder))")
            await holdWork(provider, policy: policy, current: current, because: "every included account is exhausted")

        case .verify:
            // Destination readings could not be refreshed within the request
            // budget; the next cycle plans again. Agents about to run out are
            // paused meanwhile, because no destination is confirmed.
            if exhaustionSoon {
                await holdWork(provider, policy: policy, current: current, because: "other accounts' capacity cannot be confirmed yet")
            }
        }
    }

    /// Names the included accounts that need signing in again, for the
    /// statuses that report every account exhausted: those accounts are
    /// left out for their sign-in, not their usage.
    private func signInNote(_ ladder: [Account]) -> String {
        let names = ladder.filter { needsSignIn($0) }.map { messageName($0) }
        guard !names.isEmpty else { return "" }
        return " \(names.joined(separator: ", ")) \(names.count == 1 ? "needs" : "need") signing in again."
    }

    private func updateStatus(_ provider: AIProviderType, _ message: String) {
        guard failoverStatus[provider] != message else { return }
        failoverStatus[provider] = message
        failoverEvents.record(provider, message)
    }

    // MARK: - Suspension

    func suspendAgents(
        _ provider: AIProviderType,
        policy: ProviderFailoverPolicy,
        current: Account,
        because reason: String
    ) async {
        guard policy.suspendAgentsWhenExhausted else { return }
        // One pause per limit: only the sessions that are mid-turn when the
        // limit is reached are paused. Sessions or turns started afterwards
        // were started knowingly and are left alone.
        guard suspensionContexts[provider] == nil else { return }
        if let until = pauseOverrideUntil[provider], until > Date() { return }
        let state = quotaState(for: current)
        suspensionContexts[provider] = SuspensionContext(
            accountID: current.id,
            usage: accountUsage[current.id],
            sessionBurnPerHour: state.sessionBurnPerHour,
            weeklyBurnPerHour: state.weeklyBurnPerHour
        )
        // An account hold's sessions stay listed under the wider pause.
        let sessions = Array(Set(AgentPauseGate.turningSessions(provider))
            .union(AgentPauseGate.read(provider)?.sessions ?? [])).sorted()
        // A resume lasts for the pause it was given in; a pause file left
        // from before this limit, as after a restart, keeps its markers.
        AgentPauseGate.clearResumed(provider, sessions: sessions)
        userResumes[provider] = nil
        // Turns that start during the pause wait at their start too, so no
        // request is sent to an account known to refuse it.
        AgentPauseGate.write(
            .init(sessions: sessions, reason: reason, pausedAt: Date(),
                  resumeAt: pendingResetRecovery[provider]?.resetDate, holdsNewTurns: true),
            for: provider
        )
        // Agents without the pause hook are stopped, except jobs of an
        // interactive shell, which a stop would detach from their terminal.
        let stopped = AgentPauseGate.key(provider) == nil ? await agentSuspension.suspend(provider: provider) : 0
        refreshPauseStatus(provider)
        let ungated = sessionsWithoutGate(provider).count
        if ungated > 0 {
            failoverEvents.record(provider, "\(ungated) running session(s) started before the pause hook was installed cannot be held by this pause; restart them so later pauses reach them.")
        }
        if sessions.count + stopped > 0 {
            failoverEvents.record(provider, "Paused \(sessions.count + stopped) running session(s) before they reached a usage limit: \(reason). New turns wait until capacity returns.")
        } else {
            failoverEvents.record(provider, "Every account reached its limit (\(reason)); new turns wait until capacity returns.")
        }
    }

    /// Ends the provider's pause: every session waiting in the gate goes on,
    /// and the gate tells each agent to check the background work it started.
    /// Every way out of a pause comes through here, whether capacity returned,
    /// a route target took the requests or the user resumed. Returns the
    /// number of listed sessions.
    ///
    /// `continuation` names where the sessions go on; by default the route
    /// target serving the provider's requests, or else its active account.
    @discardableResult
    func endPause(_ provider: AIProviderType, continuation: String? = nil) -> Int {
        let held = AgentPauseGate.read(provider)?.sessions.count ?? 0
        AgentPauseGate.release(provider, continuation: continuation ?? continuationDescription(provider))
        agentPauseStatus[provider] = nil
        sessionAdmissions[provider] = nil
        userResumes[provider] = nil
        return held
    }

    /// Where the provider's sessions continue now, for the gate's message.
    func continuationDescription(_ provider: AIProviderType) -> String? {
        if let routed = routedStatus[provider] { return "on \(routed.target) \(routed.model)" }
        guard let account = activeAccount(for: provider) else { return nil }
        return "on \(provider.capabilities.displayName) account \(messageName(account))"
    }

    func hasPausedAgents(_ provider: AIProviderType) -> Bool {
        AgentPauseGate.isActive(provider) || agentSuspension.hasSuspendedAgents(provider: provider)
    }

    /// Releases every paused session of the provider and ends the pause.
    /// Returns the number of sessions and processes released.
    @discardableResult
    func releasePausedAgents(_ provider: AIProviderType) async -> Int {
        let held = endPause(provider)
        let continued = agentSuspension.hasSuspendedAgents(provider: provider)
            ? await agentSuspension.resume(provider: provider) : 0
        suspensionContexts[provider] = nil
        agentPauseStatus[provider] = nil
        let routedBack = routeBack(provider) ? 1 : 0
        return held + continued + routedBack
    }

    /// The user's own pause, taken before moving work onto accounts that are
    /// at or near their limits: every session waits at its next tool call
    /// and every new turn at its start. It ends when the user resumes, or
    /// when an account in the failover order shows capacity; the account
    /// active now must first reset to count. An active account that failover
    /// excludes does not end it.
    func pauseSessionsNow(_ provider: AIProviderType) {
        guard pausingProviders.contains(provider) else { return }
        // The hook may not be installed yet when the setting was just turned on.
        pauseGateSynchronizedAt = nil
        synchronizePauseGateIfDue()
        pauseOverrideUntil[provider] = nil
        if let active = accounts.first(where: { $0.provider == provider && $0.isActive }) {
            let state = quotaState(for: active)
            suspensionContexts[provider] = SuspensionContext(
                accountID: active.id,
                usage: accountUsage[active.id],
                sessionBurnPerHour: state.sessionBurnPerHour,
                weeklyBurnPerHour: state.weeklyBurnPerHour
            )
        }
        let existing = AgentPauseGate.read(provider)
        let sessions = Array(Set(existing?.sessions ?? []).union(AgentPauseGate.turningSessions(provider))).sorted()
        AgentPauseGate.clearResumed(provider, sessions: Array(AgentPauseGate.resumedSessions(provider)))
        userResumes[provider] = nil
        AgentPauseGate.write(
            .init(sessions: sessions, reason: "paused by you", pausedAt: existing?.pausedAt ?? Date(),
                  resumeAt: pendingResetRecovery[provider]?.resetDate, holdsNewTurns: true, manual: true),
            for: provider
        )
        refreshPauseStatus(provider)
        failoverEvents.record(provider, "Paused sessions at the user's request: each waits at its next tool call and new turns wait at their start, until you resume them or an account in the failover order has capacity.")
    }

    /// The user's own override: paused sessions continue now, and no new
    /// pause starts for this provider until the limiting reset has passed.
    func resumePausedAgentsNow(_ provider: AIProviderType) async {
        let resumed = await releasePausedAgents(provider)
        pauseOverrideUntil[provider] = pendingResetRecovery[provider]?.resetDate ?? Date().addingTimeInterval(30 * 60)
        failoverEvents.record(provider, "Resumed \(resumed) paused session(s) at the user's request.")
    }

    /// Drops sessions that ended after the pause started, and refreshes the
    /// paused-session display.
    func prunePausedSessions(_ provider: AIProviderType) {
        if var pause = AgentPauseGate.read(provider) {
            let held = AgentPauseGate.stillHeld(pause, records: AgentSessions.records(provider))
            if held != pause.sessions {
                pause.sessions = held
                if held.isEmpty, pause.holdsNewTurns != true {
                    AgentPauseGate.release(provider)
                } else {
                    AgentPauseGate.write(pause, for: provider)
                }
            }
            // Resuming as capacity allows already uses what is left before a
            // reset, with whole sessions.
            if AgentPauseGate.isActive(provider), !resumesAsCapacityAllows(provider) {
                releaseStepsWithinHeadroom(provider, pause: pause)
            }
        }
        refreshPauseStatus(provider)
    }

    /// Uses what the active account still holds: waiting sessions take one
    /// more step each, oldest first, while the expected cost of those steps
    /// leaves a margin before the limit. Each is held again at its next
    /// tool call, so the account approaches its limit without reaching it.
    private func releaseStepsWithinHeadroom(_ provider: AIProviderType, pause: AgentPauseGate.PauseFile) {
        guard pause.manual != true, pause.account == nil, let current = activeAccount(for: provider) else { return }
        let now = Date()
        let planner = FailoverPlanner(settings: plannerSettings(provider))
        let state = quotaState(for: current, now: now)
        guard planner.isFresh(state, now: now), planner.tier(state, now: now) != .exhausted,
              let projection = planner.projection(state, now: now) else { return }
        var available = planner.headroom(state, projection) - FailoverPlanner.minimumUsableHeadroom - 1
        let waiting = AgentPauseGate.waitingSessions(provider)
        let order = pause.sessions.filter(waiting.contains) + waiting.subtracting(pause.sessions).sorted()
        for session in order {
            if AgentPauseGate.hasPendingStep(provider, session: session) { continue }
            let cost = learnsRequestCost(provider)
                ? max(0.5, turnCostModel.expectedRequestCost(session: session))
                : provider.capabilities.defaultRequestCostPercent
            guard cost <= available else { break }
            available -= cost
            AgentPauseGate.allowStep(provider, session: session)
        }
    }

    func refreshPauseStatus(_ provider: AIProviderType) {
        let pause = AgentPauseGate.read(provider)
        let stopped = agentSuspension.suspendedCount(provider: provider)
        guard AgentPauseGate.isActive(provider) || stopped > 0 else {
            if agentPauseStatus[provider] != nil { agentPauseStatus[provider] = nil }
            return
        }
        // A session the user resumed on its own no longer counts as paused.
        let resumed = AgentPauseGate.resumedSessions(provider)
        let waiting = AgentPauseGate.waitingSessions(provider).subtracting(resumed)
        let status = AgentPauseStatus(
            sessions: Set(pause?.sessions ?? []).union(waiting).subtracting(resumed).count,
            waiting: waiting.count,
            stoppedProcesses: stopped,
            since: pause?.pausedAt ?? Date(),
            resumeAt: pendingResetRecovery[provider]?.resetDate ?? pause?.resumeAt,
            reason: pause?.reason ?? "",
            manual: pause?.manual == true
        )
        if agentPauseStatus[provider] != status { agentPauseStatus[provider] = status }
    }

    // MARK: - Resuming as capacity allows

    /// Whether the provider's paused sessions continue a few at a time as
    /// capacity returns. Forecasts need the request token counts only the
    /// router reports; the user's own pause ends whole, as they asked.
    func resumesAsCapacityAllows(_ provider: AIProviderType) -> Bool {
        failoverConfig.policy(for: provider).resumeAsCapacityAllows && learnsRequestCost(provider)
            && AgentPauseGate.read(provider)?.manual != true
    }

    /// Typical weighted tokens per hour of a session with no history, such
    /// as one started during the pause, when no paused session has one.
    static let defaultSessionDemand = 20_000_000.0

    /// Lets paused sessions continue where their forecast use fits
    /// (`SessionPacer.admit`): on the router's pool accounts while sessions
    /// are served from several accounts, otherwise on the active account.
    /// The pause ends once it holds no session.
    func admitPausedSessions(_ provider: AIProviderType, planner: FailoverPlanner) async {
        guard let pause = AgentPauseGate.read(provider) else { return }
        let held = heldSessions(provider)
        guard !held.isEmpty else {
            let resumed = await releasePausedAgents(provider)
            if resumed > 0 { failoverEvents.record(provider, "Every paused session has continued; the pause is over.") }
            return
        }
        let now = Date()
        // An account hold places its sessions back on their own account
        // until a while after its reset; a reading that never shows the
        // reset then lets them go wherever capacity is.
        let holdAccount = pause.account.flatMap { id in
            (pause.resumeAt ?? now).addingTimeInterval(Self.accountHoldGrace) > now ? id : nil
        }
        let candidatesAccounts = admissionAccounts(provider, planner: planner, now: now)
            .filter { holdAccount == nil || $0.id == holdAccount }
        guard !candidatesAccounts.isEmpty else { return }
        // An account can serve again, so routed requests return to it while
        // the sessions too large for the route target resume as they fit.
        if routedStatus[provider] != nil { routeBack(provider) }
        let accountIDs = Set(candidatesAccounts.map(\.id))
        let demands = held.reduce(into: [String: Double]()) { result, id in
            result[id] = sessionRates.heldDemand(id, pausedAt: pause.pausedAt)
        }
        let known = demands.values.filter { $0 > 0 }.sorted()
        let typical = known.isEmpty ? Self.defaultSessionDemand : known[known.count / 2]
        let candidates = held.map { id in
            let entry = sessionRates.entries[id]
            return SessionPacer.Candidate(
                id: id, tokensPerHour: demands[id] ?? typical, contextTokens: entry?.contextTokens ?? 0,
                account: entry.flatMap { accountIDs.contains($0.account) ? $0.account : nil }
            )
        }
        let admitted = SessionPacer().admit(candidates, accounts: candidatesAccounts,
                                            running: pacerSessions(provider, now: now), now: now)
        guard !admitted.isEmpty else { return }
        for (id, placement) in admitted {
            AgentPauseGate.resume(provider, session: id)
            sessionRates.resume(id, tokensPerHour: demands[id] ?? typical, at: now)
            sessionAdmissions[provider, default: [:]][id] = SessionAdmission(
                session: id, account: placement.account, at: now, surplus: placement.surplus)
        }
        refreshPauseStatus(provider)
        if provider == AIProviderType.routedProvider, routerInUse {
            for (id, placement) in admitted { routerSessionMoves[id] = placement.account }
            applyRouterState()
        }
        let names = Dictionary(grouping: admitted.values.map(\.account), by: { $0 }).map { id, sessions in
            "\(sessions.count) on \(accounts.first { $0.id == id }.map { messageName($0) } ?? "an account")"
        }.sorted().joined(separator: ", ")
        let waiting = held.count - admitted.count
        failoverEvents.record(provider, "Resumed \(admitted.count) of \(held.count) paused session(s) where their forecast use fits: \(names)." + (waiting > 0 ? " \(waiting) wait for more capacity." : ""))
        if waiting == 0 {
            await releasePausedAgents(provider)
        }
    }

    /// The accounts paused sessions may continue on: any that is not at a
    /// limit and not about to reach one, read recently enough to trust.
    private func admissionAccounts(_ provider: AIProviderType, planner: FailoverPlanner, now: Date) -> [SessionPacer.Account] {
        let policy = failoverConfig.policy(for: provider)
        func usable(_ state: QuotaAccountState) -> Bool {
            planner.canSwitchWithoutReading(state, now: now) && planner.tier(state, now: now) <= .usable
                && (planner.secondsUntilExhaustion(state, now: now) ?? .infinity) >= Self.suspensionLead
        }
        if provider == AIProviderType.routedProvider, policy.distributeSessions, routerInUse {
            return routerPoolMembers.compactMap { member in
                guard let id = UUID(uuidString: member.accountID), accounts.contains(where: { $0.id == id }) else { return nil }
                let state = quotaState(for: accounts.first { $0.id == id }!, now: now)
                return usable(state) ? pacerAccount(id, state: state, weight: member.weight, planner: planner, now: now) : nil
            }
        }
        guard let active = activeAccount(for: provider), !policy.excludedAccountIDs.contains(active.id) else { return [] }
        let state = quotaState(for: active, now: now)
        return usable(state) ? [pacerAccount(active.id, state: state, weight: 1, planner: planner, now: now)] : []
    }

    /// Holds again, at its next tool call, every session AccountDock resumed
    /// whose account is at its limit or about to be, so a forecast that fell
    /// short never runs a session into the limit, and every surplus session
    /// whose account no longer has more than its other sessions need before
    /// the reset. It continues when capacity allows again.
    func reholdSessionsNearLimit(_ provider: AIProviderType, planner: FailoverPlanner) {
        reholdUserResumedSessions(provider, planner: planner)
        guard var admissions = sessionAdmissions[provider], !admissions.isEmpty, AgentPauseGate.read(provider) != nil else { return }
        let now = Date()
        let resumed = AgentPauseGate.resumedSessions(provider)
        let surplus = Set(admissions.values.filter(\.surplus).map(\.session))
        let others = pacerSessions(provider, now: now).filter { !surplus.contains($0.id) }
        var reheld = 0
        for (id, admission) in admissions {
            guard resumed.contains(id) else { admissions[id] = nil; continue }
            let accountID = sessionRates.entries[id].flatMap { $0.requests.contains { $0.at > admission.at } ? $0.account : nil }
                ?? admission.account
            guard let account = accounts.first(where: { $0.id == accountID }) else { continue }
            let state = quotaState(for: account, now: now)
            let nearLimit = planner.tier(state, now: now) == .exhausted
                || (planner.secondsUntilExhaustion(state, now: now) ?? .infinity) < Self.suspensionLead
            let surplusSpent = admission.surplus && !SessionPacer().covers(
                pacerAccount(account.id, state: state, weight: 1, planner: planner, now: now), sessions: others, now: now)
            guard nearLimit || surplusSpent else { continue }
            AgentPauseGate.hold(provider, session: id)
            admissions[id] = nil
            reheld += 1
        }
        sessionAdmissions[provider] = admissions
        if reheld > 0 {
            refreshPauseStatus(provider)
            failoverEvents.record(provider, "Paused \(reheld) resumed session(s) again: their account is close to its limit. They continue when capacity allows.")
        }
    }

    /// How long after its reset an account hold keeps its sessions for
    /// their own account.
    static let accountHoldGrace: TimeInterval = 10 * 60

    /// With sessions served from several accounts, an account about to reach
    /// its limit whose limiting window resets before its working sessions'
    /// prompt caches expire holds those sessions at their next tool call
    /// until the reset, rather than letting the router move them onto an
    /// account that writes their whole context again. Only sessions with a
    /// context of `heldCacheMinimumContext` tokens or more are held; a
    /// reset within the router's own hold (`RouterLogic.maximumHold`) is left
    /// to the router. The pause names the account, and its sessions continue
    /// on it once it reset.
    func holdSessionsForImminentReset(
        _ provider: AIProviderType,
        policy: ProviderFailoverPolicy,
        ladder: [Account],
        planner: FailoverPlanner
    ) async {
        let now = Date()
        if let pause = AgentPauseGate.read(provider) {
            guard let id = pause.account else { return }
            if resumesAsCapacityAllows(provider) {
                await admitPausedSessions(provider, planner: planner)
            } else if let account = accounts.first(where: { $0.id == id }) {
                let state = quotaState(for: account, now: now)
                let reset = (pause.resumeAt ?? now) <= now
                let usable = planner.isFresh(state, now: now) && planner.tier(state, now: now) <= .usable
                    && (planner.secondsUntilExhaustion(state, now: now) ?? .infinity) >= Self.suspensionLead
                if reset && usable || (pause.resumeAt ?? now).addingTimeInterval(Self.accountHoldGrace) <= now {
                    let resumed = await releasePausedAgents(provider)
                    failoverEvents.record(provider, "\(messageName(account)) reset; \(resumed) held session(s) continue on it.")
                }
            }
            return
        }
        guard policy.paceSessions, pausingProviders.contains(provider),
              pauseOverrideUntil[provider].map({ $0 <= now }) ?? true else { return }
        let working = Set(AgentPauseGate.turningSessions(provider))
        for account in ladder {
            let state = quotaState(for: account, now: now)
            let nearLimit = planner.tier(state, now: now) == .exhausted
                || (planner.secondsUntilExhaustion(state, now: now) ?? .infinity) < Self.suspensionLead
            guard nearLimit else { continue }
            let paced = pacerAccount(account.id, state: state, weight: 1, planner: planner, now: now)
            let pacer = SessionPacer()
            let reset = pacer.outlook(paced, burn: max(paced.burnPerHour, 1), now: now).windowEndsAt
            guard reset.timeIntervalSince(now) > RouterLogic.maximumHold,
                  accountHoldResets[provider].map({ abs($0.timeIntervalSince(reset)) > 120 }) ?? true else { continue }
            let sessions = sessionRates.entries.filter { id, entry in
                working.contains(id) && entry.account == account.id
                    && entry.contextTokens >= Self.heldCacheMinimumContext
                    && reset.addingTimeInterval(60) <= entry.lastSeen.addingTimeInterval(
                        entry.cacheLifetime ?? SessionPacer.defaultCacheLifetime)
            }.keys.sorted()
            guard !sessions.isEmpty else { continue }
            accountHoldResets[provider] = reset
            let name = messageName(account)
            AgentPauseGate.write(
                .init(sessions: sessions, reason: "\(name) resets before their prompt caches expire", pausedAt: now,
                      resumeAt: reset, holdsNewTurns: false, account: account.id),
                for: provider
            )
            refreshPauseStatus(provider)
            let minutes = Int((reset.timeIntervalSince(now) / 60).rounded())
            failoverEvents.record(provider, "\(name) is at its limit and resets in \(minutes) min, before the prompt caches of its \(sessions.count) working session(s) expire: they wait at their next tool call and continue on it after the reset, instead of writing their context again on another account.")
            return
        }
    }

    /// Whether `account` is at its limit or within `suspensionLead` of it.
    func isNearLimit(_ account: Account, planner: FailoverPlanner, now: Date = Date()) -> Bool {
        let state = quotaState(for: account, now: now)
        return planner.tier(state, now: now) == .exhausted
            || (planner.secondsUntilExhaustion(state, now: now) ?? .infinity) < Self.suspensionLead
    }

    /// The account serving a session now: the one its last request went to
    /// through the router, else the provider's active account.
    func servingAccount(_ provider: AIProviderType, session: String) -> Account? {
        sessionRates.entries[session].flatMap { entry in accounts.first { $0.id == entry.account } }
            ?? activeAccount(for: provider)
    }

    /// Holds again, at its next tool call, every session the user resumed
    /// while its account had room, once the account serving it nears its
    /// limit (`userResumes`). A session resumed onto an account already at
    /// its limit was resumed knowingly and is left to run.
    private func reholdUserResumedSessions(_ provider: AIProviderType, planner: FailoverPlanner) {
        guard var resumes = userResumes[provider], !resumes.isEmpty else { return }
        guard AgentPauseGate.read(provider) != nil else { userResumes[provider] = nil; return }
        let resumed = AgentPauseGate.resumedSessions(provider)
        var reheld = 0
        for (session, accountID) in resumes {
            guard resumed.contains(session) else { resumes[session] = nil; continue }
            guard let account = servingAccount(provider, session: session) ?? accounts.first(where: { $0.id == accountID }),
                  isNearLimit(account, planner: planner) else { continue }
            AgentPauseGate.hold(provider, session: session)
            resumes[session] = nil
            reheld += 1
        }
        userResumes[provider] = resumes
        if reheld > 0 {
            refreshPauseStatus(provider)
            failoverEvents.record(provider, "Paused \(reheld) session(s) you resumed again: the account serving them is close to its limit. They continue when capacity allows, or when you resume them again.")
        }
    }

    /// Paused agents continue only on a fresh reading showing the active
    /// account can serve them: either a different account than the one they
    /// were paused on, or the same account after a limiting window reset.
    /// Paused agents consume nothing, so a reading of the same account taken
    /// while they wait proves nothing about its capacity.
    private func resumeAgentsIfCapacityReturned(
        _ provider: AIProviderType,
        current: Account,
        planner: FailoverPlanner
    ) async {
        guard hasPausedAgents(provider) || suspensionContexts[provider] != nil else { return }
        // An account hold ends when its own account resets
        // (`holdSessionsForImminentReset`), not on another's capacity.
        if AgentPauseGate.read(provider)?.account != nil { return }
        if resumesAsCapacityAllows(provider), AgentPauseGate.isActive(provider) {
            await admitPausedSessions(provider, planner: planner)
            return
        }
        let now = Date()
        var state = quotaState(for: current, now: now)
        if let context = suspensionContexts[provider], context.accountID == current.id {
            guard Self.windowReset(since: context.usage, in: accountUsage[current.id]) else { return }
            state.sessionBurnPerHour = max(state.sessionBurnPerHour, context.sessionBurnPerHour)
            state.weeklyBurnPerHour = max(state.weeklyBurnPerHour, context.weeklyBurnPerHour)
        }
        guard planner.isFresh(state, now: now),
              planner.tier(state, now: now) <= .usable,
              (planner.secondsUntilExhaustion(state, now: now) ?? .infinity) >= Self.suspensionLead else { return }
        let resumed = await releasePausedAgents(provider)
        if resumed > 0 {
            pendingResetRecovery[provider] = nil
            exhaustedFailoverAccounts[provider, default: []].remove(current.id)
            saveFailoverRuntime()
            failoverEvents.record(provider, "Capacity is available on \(messageName(current)); resumed \(resumed) paused session(s).")
        }
    }

    /// Whether either quota window restarted between two readings: its reset
    /// moved later, or the provider reports clearly lower usage.
    nonisolated static func windowReset(since old: UsageAPIResponse?, in new: UsageAPIResponse?) -> Bool {
        guard let new else { return false }
        guard let old else { return true }
        func restarted(_ before: UsageWindow?, _ after: UsageWindow?) -> Bool {
            guard let after else { return false }
            if let a = before?.resetsAtDate, let b = after.resetsAtDate, b.timeIntervalSince(a) > 10 * 60 { return true }
            if let a = before?.utilization, let b = after.utilization, b <= a - 5 { return true }
            return false
        }
        return restarted(old.fiveHour, new.fiveHour) || restarted(old.sevenDay, new.sevenDay)
    }

    // MARK: - Switching

    private func performAutomaticSwitch(
        provider: AIProviderType,
        policy: ProviderFailoverPolicy,
        from current: Account,
        to target: Account,
        reason: FailoverPlan.SwitchReason
    ) async {
        if let last = lastAutomaticFailover[provider], Date().timeIntervalSince(last) < 60 { return }
        let sourceName = messageName(current)
        let targetName = messageName(target)

        if !(await credentialIsUsable(target)) { return }

        let hadSuspendedAgents = hasPausedAgents(provider)
        let reachesSessions = provider.capabilities.switchReachesRunningSessions
        var running = RunningSessions()
        if reachesSessions {
            guard let prepared = await prepareSwitchReachingSessions(
                provider, policy: policy, reason: reason, hadSuspendedAgents: hadSuspendedAgents
            ) else { return }
            running = prepared
        }

        switch reason {
        case .balance(let hours) where hours < 1:
            // The forecast decided: staying would leave more allowance unused.
            failoverEvents.record(provider, "Balancing moves work from \(sourceName) to \(targetName): over the coming week this leaves less of their allowances unused.")
        case .balance(let hours):
            failoverEvents.record(provider, "Balancing moves work from \(sourceName) to \(targetName): its allowance must start being used \(Int(hours.rounded())) hour(s) sooner to be fully consumed before it resets.")
        case .threshold:
            failoverEvents.record(provider, "Threshold reached; switching \(sourceName) → \(targetName).")
        case .exhausted:
            failoverEvents.record(provider, "\(sourceName) is at its limit; switching to \(targetName).")
        case .workloadUnavailable:
            failoverEvents.record(provider, "\(sourceName) no longer includes this workload; switching to \(targetName).")
        }
        failoverLog.info("\(provider.rawValue): \(sourceName) -> \(targetName) (\(reason))")

        await activate(target, method: policy.switchMethod, running: running, hadSuspendedAgents: hadSuspendedAgents)

        guard activeAccount(for: provider)?.id == target.id else {
            switchFailureCooldown[target.id] = Date().addingTimeInterval(10 * 60)
            updateStatus(provider, "Automatic switch to \(targetName) failed; another account will be tried.")
            // Paused sessions were continued to receive the switch; they must
            // not keep working on the account they were paused to protect.
            if reachesSessions, hadSuspendedAgents {
                await suspendAgents(provider, policy: policy, current: current, because: "the switch to \(targetName) failed")
            }
            return
        }
        // Sessions the switch reached continue once the new credential is in
        // place.
        if reachesSessions, hadSuspendedAgents { await releasePausedAgents(provider) }
        if Self.switchMovesRunningSessions(reason) {
            moveRunningSessions(provider, from: current.id)
        } else if credentialModule(for: provider)?.liveCredential != nil {
            sessionsLeftOn[provider, default: []].insert(current.id)
        }
        if provider == AIProviderType.routedProvider { await routerFollowActiveAccount() }
        lastAutomaticFailover[provider] = Date()
        exhaustedFailoverAccounts[provider, default: []].insert(current.id)
        exhaustedFailoverAccounts[provider, default: []].remove(target.id)
        saveFailoverRuntime()
        updateStatus(provider, "Switched to \(targetName).")

        // A fresh reading of the new account confirms it before paused
        // agents continue.
        await fetchUsageNow(target, priority: .candidate)
        if hadSuspendedAgents, !reachesSessions {
            await resumeAgentsIfCapacityReturned(
                provider,
                current: target,
                planner: FailoverPlanner(settings: plannerSettings(provider))
            )
        }
    }

    // MARK: - Switches that reach running sessions

    /// The CLI processes a switch must reach, found before it.
    struct RunningSessions {
        var codex: [RunningCodexProcess] = []
    }

    /// Readies a provider whose switch reaches its running sessions. Paused
    /// sessions wait inside the pause hook, so restart and reload signals
    /// reach them; they were paused precisely so they never hit the limit,
    /// so they count as affected sessions under every switch method. Nil
    /// when the switch must wait.
    private func prepareSwitchReachingSessions(
        _ provider: AIProviderType,
        policy: ProviderFailoverPolicy,
        reason: FailoverPlan.SwitchReason,
        hadSuspendedAgents: Bool
    ) async -> RunningSessions? {
        if agentSuspension.hasSuspendedAgents(provider: provider) { _ = await agentSuspension.resume(provider: provider) }
        switch provider {
        case .codex:
            let processes = codexService.recoverableRunningProcesses()
            // Switching safely restarts only sessions that hit the limit, so
            // it waits until one has.
            if policy.switchMethod == .safeRestart, !hadSuspendedAgents,
               !processes.isEmpty, !processes.contains(where: \.hasUsageLimitError) {
                if case .balance = reason { return nil }
                updateStatus(provider, "Quota reported at the failover limit; waiting for a running Codex session to receive the usage-limit error.")
                return nil
            }
            return RunningSessions(codex: processes)
        case .claudeCode, .kimi, .gemini:
            return RunningSessions()
        }
    }

    /// Makes `target` the provider's active account with the switch method.
    private func activate(
        _ target: Account,
        method: FailoverSwitchMethod,
        running: RunningSessions,
        hadSuspendedAgents: Bool
    ) async {
        switch target.provider {
        case .codex:
            switch method {
            case .safeRestart:
                let affected = hadSuspendedAgents ? running.codex : running.codex.filter(\.hasUsageLimitError)
                let unaffected = running.codex.filter { !affected.contains($0) }
                await switchTo(target, refreshAfter: false, safelyRestartingCodex: affected, liveReloadingCodex: unaffected)
            case .forceRestart:
                await switchTo(target, refreshAfter: false, safelyRestartingCodex: running.codex, closeCodexTerminalTabs: true)
            case .withoutRestart:
                await switchTo(target, refreshAfter: false, liveReloadingCodex: running.codex)
            }
        case .claudeCode, .kimi, .gemini:
            await switchTo(target, refreshAfter: false)
        }
    }
}
