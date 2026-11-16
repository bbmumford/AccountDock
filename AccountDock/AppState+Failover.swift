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
        // A passed reset is confirmed, and its window warmed, as soon as
        // the provider takes the reading (`verifyPassedResets`).
        if let due = passedResetWorkDue(now: now) {
            interval = min(interval, max(20, due.timeIntervalSince(now) + 1))
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
        // The paused-session display follows the pause files on every tick,
        // skipped cycles included, so sessions are never held unseen.
        for provider in AgentPauseGate.providers { refreshPauseStatus(provider) }
        guard Self.quotaCycleMayStart(monitoring: isMonitoringFailover, credentialWorkBusy: credentialGate.isBusy,
                                      loggingIn: isLoggingIn) else { return }
        isMonitoringFailover = true
        defer { isMonitoringFailover = false }

        await ingestPassiveTelemetry()
        await adoptRenewedCredentials()
        moveSessionsOffLimitedAccounts()
        synchronizePauseGateIfDue()
        let now = Date()
        for provider in monitoredProviders {
            for account in accountsServingSessions(provider) {
                let due = (account.isActive && activeReadingIsDue(account, now: now))
                    || Self.wholeReadingIsDue(accountUsage[account.id], whole: accountWholeReadings[account.id], now: now)
                if due { await fetchUsageNow(account, priority: account.isActive ? .critical : .candidate) }
            }
        }
        await verifyPassedResets(now: now)
        await recheckCLIAccessIfDue(now: now)
        await refreshLimitResetsIfDue(now: now)
        if let routed = AIProviderType.routedProvider, routedStatus[routed] != nil {
            await refreshRouteTargetReading(maximumAge: 60)
        }
        await maintainRouter()
        // Before sessions are counted, so one started on a slot since the
        // last cycle is counted on the slot's account from its first cycle.
        await refreshSlotProcesses()
        refreshSessions()
        await handleExternalRequests()
        await ingestTranscriptRequests()
        await maintainSessionSlots(processesRead: true)
        await applyModelFallbacks()
        await resumeSessionsLeftWaiting()
        await noteUnisolatedSessions()
        await handleStuckBackgroundSessions()
        await rebalanceAutomaticallyIfDue()

        await evaluateFailover()
        saveLearningIfDue()
        for provider in AgentPauseGate.providers {
            holdPinnedSessionsAtLimit(provider)
            prunePausedSessions(provider)
        }
    }

    /// Whether a quota cycle may start: none is running, no credential work
    /// is under way (`credentialGate`) and no sign-in is.
    nonisolated static func quotaCycleMayStart(monitoring: Bool, credentialWorkBusy: Bool, loggingIn: Bool) -> Bool {
        !monitoring && !credentialWorkBusy && !loggingIn
    }

    /// Keeps the pause hook installed for every provider that has one
    /// (`gatedProviders`), and the request hold for the providers that pause
    /// agents automatically. Reading the hook files is cheap; it is still
    /// limited to once every ten minutes because policy changes are rare.
    func synchronizePauseGateIfDue(now: Date = Date()) {
        if let last = pauseGateSynchronizedAt, now.timeIntervalSince(last) < 10 * 60 { return }
        pauseGateSynchronizedAt = now
        let enabled = pausingProviders
        let gated = gatedProviders
        let routerRunning = routerInUse
        // The request hold first: the gate's command depends on it.
        Task.detached(priority: .utility) {
            ProviderRequestHold.synchronize(enabledFor: enabled, routerRunning: routerRunning)
            AgentPauseGate.synchronize(enabledFor: gated)
        }
    }

    /// Providers whose sessions carry the pause gate. A CLI reads its hooks
    /// when it starts, so the gate is kept installed whether or not pausing
    /// is automatic: a session can then be paused by the user
    /// (`pauseSessionsNow`) or automatically at any time. The gate does
    /// nothing while no pause is written for its provider.
    var gatedProviders: Set<AIProviderType> {
        Set(AgentPauseGate.providers.filter { $0.capabilities.pauseGate != nil })
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

    /// The provider's active account, then its other accounts that
    /// `refreshSessions` counts running sessions on: the accounts in use,
    /// which `runQuotaCycle` keeps read.
    func accountsServingSessions(_ provider: AIProviderType) -> [Account] {
        accounts.filter { $0.provider == provider && ($0.isActive || accountSessions[$0.id]?.isEmpty == false) }
            .sorted { $0.isActive && !$1.isActive }
    }

    /// One reading of an account taken whole from its provider's endpoint.
    struct WholeReading: Equatable {
        var at: Date
        /// Percent of the long window used then; nil when it reported none.
        var longUtilization: Double?
    }

    /// The least time between two whole readings of one account that
    /// `wholeReadingIsDue` asks for.
    nonisolated static let wholeReadingSpacing: TimeInterval = 60
    /// Points of the long window an account's passive readings must show
    /// used since its last whole reading for another to be due. A model's
    /// own allowance is a share of the long window, so it can have moved by
    /// as many points of the window, which is more of its own limit.
    nonisolated static let wholeReadingDrift = 1.0

    /// Whether an account in use needs reading from its provider although
    /// passive readings keep its windows current. Its reading holds a
    /// model's own limit, which only the provider's endpoint reports, and
    /// either that limit was never read whole or the long window has moved
    /// by `wholeReadingDrift` since it was, in either direction. Consumed
    /// by `runQuotaCycle` for every account serving sessions.
    nonisolated static func wholeReadingIsDue(_ usage: UsageAPIResponse?, whole: WholeReading?, now: Date) -> Bool {
        guard let usage, !usage.modelWeeklyLimits.isEmpty else { return false }
        guard let whole else { return true }
        guard now.timeIntervalSince(whole.at) >= wholeReadingSpacing,
              let known = whole.longUtilization, let current = usage.sevenDay?.utilization else { return false }
        return abs(current - known) >= wholeReadingDrift
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
        let running = observations.isEmpty
            ? nil : await ProcessTable.currentInBackground(maxAge: Self.runningProcessTableAge)
        let now = Date()
        let servedCutoff = now.addingTimeInterval(-SessionAttribution.servedLifetime)
        sessionServedBy = sessionServedBy.filter { $0.value.at > servedCutoff }
        var attributions: [AIProviderType: (SessionAttribution, [String: Int32])] = [:]
        for observation in observations {
            let provider = observation.source.provider
            if let session = observation.processKey, let name = observation.sessionName, sessionNames[session] != name {
                sessionNames[session] = name
            }
            let noSessionWindow = observation.usage.reportsNoSessionWindow
            // A window whose reset has passed describes the window before it.
            let usage = observation.usage.droppingPassedWindows(at: now)
            guard usage.fiveHour != nil || usage.sevenDay != nil else { continue }
            let observation = observation.with(usage: usage)
            if let model = observation.model {
                workloadModels[provider] = (model, observation.observedAt)
                if let session = observation.processKey { noteSessionModel(session, model: model, at: observation.observedAt) }
            }
            if let directory = observation.slotDirectory, let session = observation.processKey {
                slotSessionsByDirectory[directory] = session
            }
            // A session in a slot reports its slot's account; others are
            // matched by their reset times.
            if sessionSlotIsSettling(observation.processKey, provider: provider,
                                     reportedAt: observation.observedAt) { continue }
            let (attribution, processes) = attributions[provider]
                ?? (sessionAttribution(provider, now: now), sessionProcesses(provider))
            attributions[provider] = (attribution, processes)
            let decision = attribution.decide(session: observation.processKey,
                                              process: observation.processKey.flatMap { processes[$0] })
            let slot = decision?.source == .slot ? decision?.account : nil
            let attributed = slot == nil ? attribute(observation) : nil
            // What a session's own reading matched by reset times names the
            // account its token belongs to (`SessionAttribution.lastServed`).
            if let session = observation.processKey, let attributed, attributed.byResets,
               observation.observedAt > servedCutoff,
               sessionServedBy[session].map({ $0.at < observation.observedAt }) ?? true {
                sessionServedBy[session] = SessionAttribution.Observation(account: attributed.account, at: observation.observedAt)
            }
            // The same reset times name the token a slot's session holds,
            // which the audit compares with its slot's account.
            if let session = observation.processKey, observation.observedAt > servedCutoff,
               let evidence = slot == nil ? attributed : attribute(observation), evidence.byResets {
                noteProcessCredential(provider, session: session, process: processes[session], running: running,
                                      observed: evidence.account, source: "statusLineResets",
                                      observedAt: observation.observedAt)
            }
            guard let accountID = slot ?? attributed?.account else { continue }
            if let updatedAt = accountUsageUpdatedAt[accountID], observation.observedAt <= updatedAt { continue }
            if Self.describesSupersededWindow(observation.usage, stored: accountUsage[accountID]) { continue }
            let applied = Self.passiveApplication(
                observation, reportedNoSessionWindow: noSessionWindow, reset: resetToSeeAfresh(accountID),
                hasSessionWindow: Self.readingHasSessionWindow(
                    planHasSessionWindow: accounts.first(where: { $0.id == accountID })?.planHasSessionWindow,
                    sessionWindowReset: sessionWindowResetPending(accountID)),
                sessionRequestedAt: observation.processKey.flatMap { lastRequestSeen(bySession: $0) }
            )
            let merged = accountUsage[accountID].map {
                $0.merged(withNewer: applied.usage, clearingSession: applied.clearsSession)
            } ?? applied.usage
            recordUsage(merged, for: accountID, observedAt: observation.observedAt, confirmsReset: applied.confirmsReset)
            if accountUsageErrors[accountID]?.isRateLimited == true {
                accountUsageErrors[accountID] = nil
            }
            if applied.isLive {
                liveReadingAt[accountID] = observation.observedAt
                answerRouterRefusal(accountID, liveAt: observation.observedAt, now: now)
            }
            failoverLog.debug("passive \(observation.source.rawValue) reading applied to \(accountID.uuidString)")
        }
    }

    /// Drops the router's refusal of `accountID` once a reading a session
    /// reported after it shows room below the triggers
    /// (`FailoverPlanner.liveReadingShowsRoom`), so failover need not wait
    /// for an endpoint reading the request budget or a cool-down
    /// (`usageRetryAfter`) holds back. An account with allowances of a
    /// model's own may have been refused for one of them, which such a
    /// reading never carries: its refusal waits for a whole reading
    /// (`accountWholeReadings`) after it.
    private func answerRouterRefusal(_ accountID: UUID, liveAt: Date, now: Date) {
        guard let refusedAt = routerRefusedAt[accountID], refusedAt < liveAt,
              routerRefusedUntil[accountID].map({ $0 > now }) ?? false,
              let account = accounts.first(where: { $0.id == accountID }) else { return }
        let scoped = accountUsage[accountID]?.modelWeeklyLimits.isEmpty == false
        if scoped, (accountWholeReadings[accountID]?.at ?? .distantPast) <= refusedAt { return }
        let planner = FailoverPlanner(settings: plannerSettings(account.provider))
        var state = quotaState(for: account, now: now)
        state.refusedAtLimit = false
        guard planner.liveReadingShowsRoom(state, now: now) else { return }
        routerRefusedUntil[accountID] = nil
        routerRefusedAt[accountID] = nil
        failoverLog.info("\(account.provider.rawValue): a live reading after the router's refusal shows room on \(accountID.uuidString)")
    }

    /// The account a passive reading belongs to: the one it names, or the
    /// one whose reset times it matches. `byResets` says the reset times
    /// matched it, which `ingestPassiveTelemetry` alone takes to name the
    /// account serving the reporting session.
    private func attribute(_ observation: PassiveUsageObservation) -> (account: UUID, byResets: Bool)? {
        let provider = observation.source.provider
        switch observation.accountKey {
        case .providerAccountID(let id):
            return accountID(forProviderAccountID: id, provider: provider).map { ($0, false) }
        case .credentialLocation(let location):
            return accounts.first { $0.provider == provider && $0.credentialLocation == location }.map { ($0.id, false) }
        case nil:
            return observation.source.alwaysNamesAccount ? nil : matchByResets(observation.usage, provider: provider)
        }
    }

    /// The account the provider identifies by `id`: the one whose saved
    /// copy the provider's credential module names so.
    private func accountID(forProviderAccountID id: String, provider: AIProviderType) -> UUID? {
        guard let live = credentialModule(for: provider)?.liveCredential else { return nil }
        return accounts.first { $0.provider == provider && live.providerAccountID(ofSavedCopy: $0) == id }?.id
    }

    /// Every account's quota window resets at its own moment, so a reading
    /// whose reset times match exactly one known account belongs to it. When
    /// nothing matches, the reading is attributed to the active account only
    /// while that account has no established window of its own; `byResets`
    /// is then false.
    private func matchByResets(_ usage: UsageAPIResponse, provider: AIProviderType) -> (account: UUID, byResets: Bool)? {
        let candidates = accounts.filter { $0.provider == provider }.map { account in
            ResetsCandidate(id: account.id, weeklyReset: accountUsage[account.id]?.sevenDay?.resetsAtDate,
                            sessionReset: accountUsage[account.id]?.fiveHour?.resetsAtDate)
        }
        let active = activeAccount(for: provider)
        return Self.matchByResets(weeklyReset: usage.sevenDay?.resetsAtDate, sessionReset: usage.fiveHour?.resetsAtDate,
                                  candidates: candidates, active: active?.id,
                                  activeHasWeekly: active.map { accountUsage[$0.id]?.sevenDay?.resetsAtDate != nil } ?? false)
    }

    /// An account's stored reset times, as `matchByResets` compares them.
    struct ResetsCandidate: Equatable {
        var id: UUID
        var weeklyReset: Date?
        var sessionReset: Date?
    }

    /// The account a reading with these reset times belongs to, among
    /// `candidates`. Two resets within two minutes match. A unique weekly
    /// match decides, unless the matched account's stored session reset
    /// contradicts the reading's, which leaves a unique session match to
    /// decide. Accounts whose weekly resets both match
    /// share them, which two sign-ins of one subscription do, so only a
    /// session reset that matches one of them alone decides between them,
    /// never another's contradicting one: a copy of one account's
    /// credential saved for another reads the same resets as the first.
    /// Without a weekly match a unique session match decides; with neither,
    /// `active` takes the reading while it has no weekly window of its own
    /// (`byResets` false).
    nonisolated static func matchByResets(weeklyReset: Date?, sessionReset: Date?, candidates: [ResetsCandidate],
                                          active: UUID?, activeHasWeekly: Bool) -> (account: UUID, byResets: Bool)? {
        func close(_ a: Date?, _ b: Date?) -> Bool {
            guard let a, let b else { return false }
            return abs(a.timeIntervalSince(b)) <= 120
        }
        func contradicts(_ stored: Date?) -> Bool {
            guard let stored, let sessionReset else { return false }
            return abs(stored.timeIntervalSince(sessionReset)) > 120
        }
        let weeklyClose = candidates.filter { close($0.weeklyReset, weeklyReset) }
        if weeklyClose.count > 1 {
            let sessionMatches = weeklyClose.filter { close($0.sessionReset, sessionReset) }
            return sessionMatches.count == 1 ? (sessionMatches[0].id, true) : nil
        }
        let weeklyMatches = weeklyClose.filter { !contradicts($0.sessionReset) }
        if weeklyMatches.count == 1 { return (weeklyMatches[0].id, true) }
        let sessionMatches = candidates.filter { close($0.sessionReset, sessionReset) }
        if sessionMatches.count == 1 { return (sessionMatches[0].id, true) }
        if weeklyMatches.isEmpty, sessionMatches.isEmpty, let active, !activeHasWeekly {
            return (active, false)
        }
        return nil
    }

    // MARK: - Request budget

    /// Whether the periodic refresh should read this account, and at which
    /// priority. Idle accounts do not change, so they are read rarely; an
    /// account that was just switched away from may still be consumed by
    /// sessions holding its credential, so it is read more often.
    func usageReadPriority(_ account: Account, forced: Bool, now: Date = Date()) -> UsageRequestBudget.Priority? {
        if let until = usageRetryAfter[account.id], until > now { return nil }
        if accountsAwaitingPostResetVerification.contains(account.id) { return .verification }
        guard accountUsage[account.id] != nil, let updatedAt = accountUsageUpdatedAt[account.id] else {
            return forced ? .candidate : .background
        }
        // A reading holding a model's own limit is as old as its last whole
        // reading: the passive readings since carry the windows alone.
        let holdsModelLimits = accountUsage[account.id]?.modelWeeklyLimits.isEmpty == false
        let readAt = (holdsModelLimits ? accountWholeReadings[account.id]?.at : nil) ?? updatedAt
        let age = now.timeIntervalSince(readAt)
        if forced { return age > 60 ? .candidate : nil }
        // An account serving sessions is consumed as the active one is.
        if account.isActive || slotServedAccounts.contains(account.id) || accountSessions[account.id]?.isEmpty == false {
            return age > 120 ? .background : nil
        }
        let recentlyAway = lastSwitchedAway[account.id].map { now.timeIntervalSince($0) < FailoverPlanner.sessionWindow } ?? false
        let atLimit = Self.readingIsAtALimit(accountUsage[account.id])
        return age >= (recentlyAway || atLimit ? Self.idleAtLimitReadingInterval : 30 * 60) ? .background : nil
    }

    /// How often an idle account at one of its limits is read: a provider
    /// can reset an allowance before its scheduled time, and such an account
    /// takes no work until a reading shows the reset.
    nonisolated static let idleAtLimitReadingInterval: TimeInterval = 10 * 60
    /// Percent of a window or a model's own limit at which an idle account
    /// counts as at that limit for `idleAtLimitReadingInterval`.
    nonisolated static let atLimitPercent = 95.0

    nonisolated static func readingIsAtALimit(_ usage: UsageAPIResponse?) -> Bool {
        guard let usage else { return false }
        let windows = [usage.fiveHour?.utilization, usage.sevenDay?.utilization].compactMap { $0 }
        return (windows + usage.modelWeeklyLimits.map(\.percent)).contains { $0 >= atLimitPercent }
    }

    func spendUsageRequest(_ provider: AIProviderType, _ priority: UsageRequestBudget.Priority) -> Bool {
        usageBudgets[provider]?.spend(priority) ?? true
    }

    /// The second request of a reading `spendUsageRequest` admitted at
    /// `priority` (`UsageRequestBudget.spendFollowUp`).
    func spendUsageFollowUp(_ provider: AIProviderType, of priority: UsageRequestBudget.Priority) -> Bool {
        usageBudgets[provider]?.spendFollowUp(of: priority) ?? true
    }

    /// When a request of `priority` to the provider's usage endpoint can
    /// next be sent for `account`: after its cool-down (`usageRetryAfter`)
    /// and once the allowance holds it. Consumed by the warm-up retry and
    /// the quota cycle's timing, so a deferred reading runs once the
    /// provider can take it rather than on a fixed delay.
    func usageRequestAvailable(_ account: Account, _ priority: UsageRequestBudget.Priority, now: Date = Date()) -> Date {
        let cooled = usageRetryAfter[account.id].map { max($0, now) } ?? now
        let allowed = usageBudgets[account.provider]?.nextAvailable(priority, now: now) ?? now
        return max(cooled, allowed)
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

    /// Whether an account's plan is due a check by its provider's plan
    /// authority (`planCheckDue`). Plan requests share the usage budget.
    func planCheckIsDue(_ account: Account, forced: Bool, now: Date = Date()) -> Bool {
        Self.planCheckDue(checkedAt: account.profileCheckedAt, attemptedAt: lastProfileCheck[account.id],
                          forced: forced, available: account.supportsProviderWorkloads, now: now)
    }

    /// How long an answered plan check stands: plans change rarely, but
    /// an upgrade or a downgrade changes how much work the account holds.
    nonisolated static let profileRecheckInterval: TimeInterval = 3 * 60 * 60
    /// How long after a plan check that got no answer it is tried again.
    nonisolated static let profileRetryInterval: TimeInterval = 15 * 60

    /// Whether an account's plan is due a check by its provider's plan
    /// authority (`ProviderCapabilities.planAuthority`): on the user's
    /// refresh and on an account whose plan serves no workload (`forced`,
    /// `available`), when no check has answered (`checkedAt`, kept with the
    /// account), `profileRecheckInterval` after the last answer, and no
    /// sooner than `profileRetryInterval` after a check that got none
    /// (`attemptedAt`). Read by `planCheckIsDue`.
    nonisolated static func planCheckDue(checkedAt: Date?, attemptedAt: Date?, forced: Bool, available: Bool,
                                        now: Date) -> Bool {
        if forced || !available { return true }
        if let attemptedAt, checkedAt.map({ attemptedAt > $0 }) ?? true,
           now.timeIntervalSince(attemptedAt) < profileRetryInterval { return false }
        guard let checkedAt else { return true }
        return now.timeIntervalSince(checkedAt) >= profileRecheckInterval
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
                                              resetDetails: resetDetails, priority: priority), for: account)
    }

    /// How long failover leaves an account the user switched to themselves.
    static let userSwitchHold: TimeInterval = 5 * 60

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

    /// `readUsageNow` for each provider's active account, and for every
    /// signed-in account that has no reading yet, whose card would otherwise
    /// stay empty until a background read; the menu's Refresh button calls
    /// it before the ordinary refresh.
    func readActiveUsageNow() async {
        for provider in AIProviderType.implementedProviders {
            if let active = activeAccount(for: provider), !needsSignIn(active) { await readUsageNow(active) }
        }
        for account in accounts where !account.isActive && accountUsage[account.id] == nil && !needsSignIn(account) {
            await readUsageNow(account)
        }
    }

    /// How `ingestPassiveTelemetry` applies one passive reading: the
    /// windows it records (`usage`), whether it drops a stored session
    /// window (`clearsSession`), whether it confirms a passed reset
    /// (`recordUsage`'s `confirmsReset`) and whether it stands as the
    /// account's live reading (`liveReadingAt`).
    struct PassiveApplication {
        var usage: UsageAPIResponse
        var clearsSession: Bool
        var confirmsReset: Bool
        var isLive: Bool
    }

    /// How a passive reading applies (`PassiveApplication`). `observation`
    /// carries its windows with the passed resets dropped, and
    /// `reportedNoSessionWindow` is whether it carried the long window
    /// without a session window before they were. `reset` is the latest
    /// reset of the account still to be seen afresh (`resetToSeeAfresh`);
    /// with none, the reading applies as it reads: it confirms a reset when
    /// it carries every window the provider reports for the account, each
    /// with a reset still ahead.
    ///
    /// Claude Code redraws a session's status line when a window resets,
    /// without a request, and leaves the passed window out. After a reset a
    /// status line therefore speaks for the account's session window only
    /// when the session sent a request after it (`sessionRequestedAt`) or
    /// shows the window with use, which only a reply after the reset can
    /// carry: until then its missing session window is no sign the account
    /// has none, and a session window it shows at no use, the provider's
    /// moving placeholder, is not taken for a started one. Such a reading
    /// still records the long window, but confirms nothing and stands as no
    /// live reading. The usage cache is the endpoint's whole reply, which
    /// leaves an unstarted session window out, so on an account with a
    /// session window (`hasSessionWindow`) its missing window is not
    /// dropped; one fetched before the reset confirms nothing.
    nonisolated static func passiveApplication(_ observation: PassiveUsageObservation, reportedNoSessionWindow: Bool,
                                               reset: Date?, hasSessionWindow: Bool,
                                               sessionRequestedAt: Date?) -> PassiveApplication {
        let usage = observation.usage
        let carriesEvery = usage.sevenDay != nil && (usage.fiveHour != nil || reportedNoSessionWindow)
        guard let reset else {
            return PassiveApplication(usage: usage, clearsSession: reportedNoSessionWindow, confirmsReset: carriesEvery,
                                      isLive: observation.source.reportsWithEachResponse)
        }
        switch observation.source {
        case .claudeStatusLine:
            let requested = sessionRequestedAt.map { $0 >= reset } ?? false
            let started = usage.fiveHour.map { requested || ($0.utilization ?? 0) > 0 } ?? false
            let shown = usage.fiveHour == nil || started ? usage : usage.replacingFiveHour(nil)
            let absent = requested && reportedNoSessionWindow
            return PassiveApplication(usage: shown, clearsSession: absent,
                                      confirmsReset: shown.sevenDay != nil && (started || absent),
                                      isLive: started || requested)
        case .claudeUsageCache:
            let afterReset = observation.observedAt >= reset
            return PassiveApplication(usage: usage, clearsSession: afterReset && reportedNoSessionWindow && !hasSessionWindow,
                                      confirmsReset: afterReset && carriesEvery,
                                      isLive: observation.source.reportsWithEachResponse)
        case .codexRollout:
            return PassiveApplication(usage: usage, clearsSession: reportedNoSessionWindow, confirmsReset: carriesEvery,
                                      isLive: observation.source.reportsWithEachResponse)
        }
    }

    /// When a session's newest request was seen: in its transcript
    /// (`sessionRequestSeenAt`) or through the router (`sessionRates`).
    func lastRequestSeen(bySession session: String) -> Date? {
        [sessionRequestSeenAt[session], sessionRates.entries[session]?.lastSeen].compactMap { $0 }.max()
    }

    /// Whether a reading of an account should hold a session window: its
    /// plan has one (`Account.planHasSessionWindow`), or one of its session
    /// windows has just reset (`sessionWindowReset`, a pending session
    /// warm-up), which shows the plan has them whatever its stored name
    /// says. A whole reply that leaves the window out then reports it not
    /// started (`recordUsage`), and a passive one does not drop it
    /// (`passiveApplication`).
    nonisolated static func readingHasSessionWindow(planHasSessionWindow: Bool?, sessionWindowReset: Bool) -> Bool {
        planHasSessionWindow == true || sessionWindowReset
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
        settings.referenceRatio = turnCostModel.ratio
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

    func quotaState(for account: Account, now: Date = Date(), model: String? = nil,
                    wholeAllowance: Bool = false) -> QuotaAccountState {
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
            usage: plannedUsage(account, now: now, model: model, wholeAllowance: wholeAllowance),
            observedAt: accountUsageUpdatedAt[account.id],
            liveReadingAt: liveReadingAt[account.id].flatMap { $0 == accountUsageUpdatedAt[account.id] ? $0 : nil },
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
            refusedAtLimit: (routerRefusedUntil[account.id].map { $0 > now } ?? false)
                || recordedLimitRefusal(account, model: model, now: now),
            percentPerMillion: accountRatio(account.id)
        )
    }

    /// How long a refusal recorded in a transcript stands without a reading.
    nonisolated static let refusalStanding: TimeInterval = 30 * 60

    /// Whether a session's transcript recorded a refusal at a usage limit on
    /// `account` (`sessionRefusals`) that no reading has answered since,
    /// within `refusalStanding`: `quotaState` counts it as a measured limit.
    ///
    /// A refused session whose model has an allowance of its own on the
    /// account may have been refused for that allowance alone: its refusal
    /// counts only when `model` is that model, and stands until a whole
    /// reading (`accountWholeReadings`), the only kind that carries a
    /// model's own limit. Any other refusal counts for every model until any
    /// newer reading. A refusal whose account `verifyRefusals` has not
    /// settled counts only once `refusalCounts` lets it.
    func recordedLimitRefusal(_ account: Account, model: String?, now: Date) -> Bool {
        guard !sessionRefusals.isEmpty else { return false }
        let readAt = accountUsageUpdatedAt[account.id] ?? .distantPast
        let wholeAt = accountWholeReadings[account.id]?.at ?? .distantPast
        let keys = (accountUsage[account.id]?.modelWeeklyLimits ?? []).map { $0.model.lowercased() }
        func key(_ model: String?) -> String? {
            guard let model = model?.lowercased() else { return nil }
            return keys.first { model.contains($0) }
        }
        let asked = key(model)
        return sessionRefusals.contains { session, refusal in
            refusal.account == account.id
                && Self.refusalCounts(verified: refusal.verified, at: refusal.at, now: now)
                && Self.refusalStands(at: refusal.at, scopedKey: key(sessionModel(session, now: now)), askedKey: asked,
                                      readAt: readAt, wholeAt: wholeAt, now: now)
        }
    }

    /// `recordedLimitRefusal`'s rule for one refusal at `at`: `scopedKey`
    /// names the allowance of the refused session's model when it has one
    /// of its own, `askedKey` that of the model asked about.
    nonisolated static func refusalStands(at: Date, scopedKey: String?, askedKey: String?,
                                          readAt: Date, wholeAt: Date, now: Date) -> Bool {
        guard now.timeIntervalSince(at) < refusalStanding else { return false }
        if let scopedKey { return scopedKey == askedKey && at > wholeAt }
        return at > readAt
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
    /// `wholeAllowance` leaves the window as the provider reports it, for
    /// `buildPool`, whose pacer weighs each model's allowance itself.
    func plannedUsage(_ account: Account, now: Date = Date(), model: String? = nil,
                      wholeAllowance: Bool = false) -> UsageAPIResponse? {
        guard let usage = accountUsage[account.id] else { return nil }
        guard !wholeAllowance, !usage.modelWeeklyLimits.isEmpty else { return usage }
        let models = model.map { [$0] } ?? sharedSessionModels(account.provider, now: now)
        return usage.replacingSevenDay(usage.weeklyWindow(forModels: models))
    }

    /// The model whose own weekly allowance is what has `account` at its
    /// limit for sessions on `models`: the account is measured at its limit
    /// for them (`plannedUsage` narrowed to their tightest model) but not by
    /// its whole allowance. Nil when the whole allowance is spent too, or
    /// when none of the models has an allowance of its own. Names the limit
    /// in failover and session-move events.
    func limitingModel(_ account: Account, models: [String], now: Date = Date()) -> String? {
        guard !models.isEmpty, let usage = accountUsage[account.id] else { return nil }
        let planner = FailoverPlanner(settings: plannerSettings(account.provider))
        let wholeState = quotaState(for: account, now: now, wholeAllowance: true)
        let reserve = planner.onAccount(planner.settings.inFlightReservePercent, wholeState)
        let whole = planner.isMeasuredAtLimit(wholeState, now: now, reserve: reserve)
        let narrowed = planner.isMeasuredAtLimit(
            quotaState(for: account, now: now, model: models.count == 1 ? models[0] : nil), now: now, reserve: reserve)
        return Self.limitingModel(usage: usage, models: models, wholeAtLimit: whole, narrowedAtLimit: narrowed)
    }

    /// `limitingModel`'s rule: with the narrowed allowance at its limit and
    /// the whole one not, the tightest own allowance among `models`.
    nonisolated static func limitingModel(usage: UsageAPIResponse, models: [String], wholeAtLimit: Bool,
                                          narrowedAtLimit: Bool) -> String? {
        guard narrowedAtLimit, !wholeAtLimit else { return nil }
        let names = models.map { $0.lowercased() }
        return usage.modelWeeklyLimits
            .filter { limit in names.contains { $0.contains(limit.model.lowercased()) } }
            .max { $0.percent < $1.percent }?.model
    }

    /// The event for a balance switch from `source` to `target` decided by
    /// latest start (`FailoverPlan.SwitchReason.balance`): `hours` is how
    /// much earlier `target`'s allowance must start being used than
    /// `source`'s for each to be used up before it resets. Without a 5-hour
    /// window an allowance can be used at any pace, so its latest start is
    /// its reset, and the figure is how much sooner `target` resets.
    nonisolated static func balanceSwitchEvent(source: String, target: String, hours: Double) -> String {
        "Balancing moves work from \(source) to \(target): \(target)'s allowance must start being used \(Int(hours.rounded())) hour(s) before \(source)'s for each to be used up before it resets."
    }

    /// The event for an exhausted switch away from `source`; `modelLimit`
    /// names the model whose own allowance ran out for the sessions on the
    /// shared sign-in, when that is the limit (`limitingModel`).
    nonisolated static func exhaustedSwitchEvent(source: String, target: String, modelLimit: String?) -> String {
        guard let modelLimit else { return "\(source) is at its limit; switching to \(target)." }
        return "\(source) has no \(modelLimit) allowance left for the sessions on the shared sign-in; switching to \(target)."
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

    /// The model allowance most of `models` draw on, among `keys`: where a
    /// session started now is expected to need room. Nil when most draw on
    /// none of them, or no session has said its model. A tie goes to the
    /// allowance, since a session on a model without one runs anywhere.
    nonisolated static func prevailingAllowance(models: [String], keys: [String]) -> String? {
        var counts: [String: Int] = [:]
        var unscoped = 0
        for model in models.map({ $0.lowercased() }) {
            if let key = keys.sorted().first(where: { model.contains($0) }) { counts[key, default: 0] += 1 } else { unscoped += 1 }
        }
        guard let most = counts.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }),
              most.value >= unscoped else { return nil }
        return most.key
    }

    /// The models the provider's running sessions use, or the one a session
    /// last reported when none of those running has said.
    func runningSessionModels(_ provider: AIProviderType, now: Date) -> [String] {
        let models = (liveSessions[provider] ?? []).compactMap { sessionModel($0.sessionID, now: now) }
        if !models.isEmpty { return models }
        return workloadModels[provider].flatMap { now.timeIntervalSince($0.seenAt) < 2 * 60 * 60 ? [$0.model] : nil } ?? []
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
            // A pause the user took holds whatever the automatic setting, until
            // the user ends it (`releaseSuspendedAgents` leaves it).
            let userPaused = AgentPauseGate.read(provider)?.manual == true
            if !monitored.contains(provider) || (!policy.suspendAgentsWhenExhausted && !userPaused) {
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
        // A pause the user took waits for the user, whatever AccountDock
        // manages for the provider.
        if AgentPauseGate.read(provider)?.heldByUser == true { return }
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
        // Each account's slot sessions stay on it when the active account
        // changes; the plan charges a destination for them beside the work
        // that moves.
        let states = withStayingBurns(ladder.map { quotaState(for: $0, now: now) }, provider: provider, now: now)
        let plan = planner.plan(
            current: states.first { $0.id == current.id }
                ?? withStayingBurns([quotaState(for: current, now: now)], provider: provider, now: now)[0],
            ladder: states,
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
        // Each switch of the active account follows its own setting: a
        // switch at a threshold or at the limit is failover's, so with
        // failover off the active account stays even when it runs out; a
        // balancing switch is intelligent balancing's.
        plan = await planWithUsableDestination(plan, actsOn: { reason in
            switch reason {
            case .balance: policy.intelligentBalancingEnabled
            default: policy.enabled
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
            return servingVerdict(account, planner: planner, now: now) == .canServe
        }
        if pooled {
            await holdSessionsForImminentReset(provider, policy: policy, ladder: ladder, planner: planner)
        }
        let fallbackAvailable = poolHasRoom || policy.enabled
            && planner.hasFallback(
                current: currentState,
                ladder: ladder.map { quotaState(for: $0, now: now) },
                now: now
            )
        // The active account is judged as it serves the work already on it,
        // as `FailoverPlanner.plan` judges it.
        let exhaustionSoon = currentState.refusedAtLimit
            || planner.servingVerdict(planner.servingView(currentState), now: now, lead: Self.suspensionLead).atOrNearLimit

        switch plan {
        case .waitForReset, .noCapacity, .verify: break
        default:
            if pendingResetRecovery[provider] != nil {
                pendingResetRecovery[provider] = nil
                saveFailoverRuntime()
            }
        }

        // Every account at its limit is concluded only from readings: one
        // stored before launch and since grown stale says nothing yet.
        switch plan {
        case .waitForReset, .noCapacity:
            if awaitsFirstReadings(ladder, planner: planner, now: now) { return }
        default: break
        }

        switch plan {
        case .stay(let reason):
            if reason == .drainingToLimit {
                updateStatus(provider, "Using \(messageName(current)) up to its limit; no other account is below its failover threshold.", settles: true)
            } else if reason == .holdingForImminentReset {
                updateStatus(provider, "Holding \(messageName(current)); its limiting window resets soon.", settles: true)
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
            // Switching at a threshold or at the limit is failover's alone.
            if !reason.isBalance, !policy.enabled {
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
            let resetText = UsageFormat.clock(rounded, dated: true)
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
               policy.enabled, let target {
                updateStatus(provider, "All accounts exhausted. Preparing \(messageName(target)), which resets at \(resetText).\(signInNote(ladder))", settles: true)
                await performAutomaticSwitch(provider: provider, policy: policy, from: current, to: target, reason: .exhausted)
            } else {
                updateStatus(provider, "All accounts exhausted. Waiting for \(messageName(target ?? current)) to reset at \(resetText).\(signInNote(ladder))", settles: true)
            }

        case .noCapacity:
            updateStatus(provider, "All configured accounts are at their limits; reset times are unavailable.\(signInNote(ladder))", settles: true)
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

    /// Shows `message` as the provider's status. A status that describes
    /// the plan's standing state (`settles`), restated every cycle, becomes
    /// an event only once it has differed from the last one recorded for
    /// longer than `statusSettle` (`StatusEventGate`); any other status,
    /// the outcome of an action, is recorded when it changes.
    private func updateStatus(_ provider: AIProviderType, _ message: String, settles: Bool = false) {
        let changed = failoverStatus[provider] != message
        failoverStatus[provider] = message
        if settles {
            if let event = statusEventGates[provider, default: StatusEventGate()].note(message, now: Date(), settle: Self.statusSettle) {
                failoverEvents.record(provider, event)
            }
        } else if changed {
            failoverEvents.record(provider, message)
            statusEventGates[provider, default: StatusEventGate()].recorded(message)
        }
    }

    /// How long a standing status must differ from the last one recorded
    /// before it is recorded: the longest quota cycle
    /// (`nextQuotaCycleInterval`), so two states alternating from one cycle
    /// to the next record nothing.
    nonisolated static let statusSettle: TimeInterval = 120

    /// Decides when a provider's standing status becomes an event.
    struct StatusEventGate: Equatable {
        private(set) var lastRecorded: String?
        private(set) var pending: String?
        private(set) var pendingSince: Date?

        /// Takes the status shown at `now`; returns it when it is to be
        /// recorded: it differs from the last recorded status and has been
        /// shown unchanged for at least `settle`.
        mutating func note(_ status: String, now: Date, settle: TimeInterval) -> String? {
            guard status != lastRecorded else {
                pending = nil
                pendingSince = nil
                return nil
            }
            guard status == pending, let since = pendingSince else {
                pending = status
                pendingSince = now
                return nil
            }
            guard now.timeIntervalSince(since) >= settle else { return nil }
            recorded(status)
            return status
        }

        /// Notes a status recorded without waiting.
        mutating func recorded(_ status: String) {
            lastRecorded = status
            pending = nil
            pendingSince = nil
        }
    }

    /// Whether the provider's plan that every account is at its limit waits
    /// for readings: within `FailoverPlanner.liveFreshness` of launch, some
    /// account in `ladder` that can be read, signed in and not failing to
    /// read, has neither a reading from this launch nor a stored one still
    /// fresh (`FailoverPlanner.isFresh`).
    func awaitsFirstReadings(_ ladder: [Account], planner: FailoverPlanner, now: Date) -> Bool {
        let readings = ladder.compactMap { account -> (readAt: Date?, fresh: Bool)? in
            guard !needsSignIn(account), accountUsageErrors[account.id] == nil else { return nil }
            return (accountUsageUpdatedAt[account.id], planner.isFresh(quotaState(for: account, now: now), now: now))
        }
        return Self.awaitsFirstReadings(readings, launchedAt: launchedAt, now: now)
    }

    nonisolated static func awaitsFirstReadings(_ readings: [(readAt: Date?, fresh: Bool)], launchedAt: Date, now: Date) -> Bool {
        guard now.timeIntervalSince(launchedAt) < FailoverPlanner.liveFreshness else { return false }
        return readings.contains { reading in
            !reading.fresh && (reading.readAt.map { $0 < launchedAt } ?? true)
        }
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
        // Each session is judged by the account it runs on: only those whose
        // own account is at or near its limit, with no move that helps, wait.
        let scope = limitPauseScope(provider, current: current, now: Date())
        requestPauseMoves(provider, scope.moves)
        let existing = AgentPauseGate.read(provider)
        // The user's "Pause all" already holds every session and turn, and
        // a pause at a limit written over it would end it automatically.
        if Self.limitPauseYields(to: existing) { return }
        guard !scope.held.isEmpty || scope.holdsNewTurns || existing != nil else {
            // Nothing waits: the next cycle judges again.
            suspensionContexts[provider] = nil
            return
        }
        // An account hold's sessions stay listed under the wider pause.
        let sessions = Array(Set(scope.held).union(existing?.sessions ?? [])).sorted()
        // A resume lasts for the pause it was given in; a pause file left
        // from before this limit, as after a restart, keeps its markers.
        AgentPauseGate.clearResumed(provider, sessions: sessions)
        userResumes[provider] = nil
        // While no account has room, every turn that starts waits too, so no
        // request is sent to an account known to refuse it; otherwise only
        // the listed sessions' new turns do.
        AgentPauseGate.write(
            .init(sessions: sessions, reason: reason, pausedAt: Date(),
                  resumeAt: pendingResetRecovery[provider]?.resetDate, holdsNewTurns: scope.holdsNewTurns,
                  holdsListedNewTurns: scope.holdsNewTurns ? nil : true, chosen: existing?.chosen),
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
            failoverEvents.record(provider, scope.holdsNewTurns
                ? "Paused \(sessions.count + stopped) running session(s) before they reached a usage limit: \(reason). New turns wait until capacity returns."
                : "Paused \(sessions.count + stopped) session(s) whose own account is at or near its limit with no account to move to: \(reason). Sessions on accounts with room keep running; each paused one continues once its own account has room.")
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
    /// What the user paused stays held (`AgentPauseGate.narrowToChosen`):
    /// sessions chosen one at a time, and the whole of the user's own
    /// pause, unless `keepingChosen` is false, as when the user resumes
    /// all or plays the last held session.
    @discardableResult
    func endPause(_ provider: AIProviderType, continuation: String? = nil, keepingChosen: Bool = true) -> Int {
        let pause = AgentPauseGate.read(provider)
        let continuation = continuation ?? continuationDescription(provider)
        let kept = keepingChosen && AgentPauseGate.narrowToChosen(provider, continuation: continuation)
        if !kept { AgentPauseGate.release(provider, continuation: continuation) }
        let stillHeld = !kept ? 0 : pause?.heldByUser == true ? pause?.sessions.count ?? 0 : pause?.chosenListed.count ?? 0
        let held = (pause?.sessions.count ?? 0) - stillHeld
        if kept { refreshPauseStatus(provider) } else { agentPauseStatus[provider] = nil }
        sessionAdmissions[provider] = nil
        userResumes[provider] = nil
        // Each resumed session's first request re-sends its whole context;
        // that burst is not the accounts' burn rate.
        let now = Date()
        for account in accounts where account.provider == provider {
            quotaTrends[account.id]?.settle(at: now)
        }
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

    /// Releases every paused session of the provider and ends the pause,
    /// but for the sessions the user paused one at a time unless
    /// `keepingChosen` is false (`endPause`). Returns the number of
    /// sessions and processes released.
    @discardableResult
    func releasePausedAgents(_ provider: AIProviderType, keepingChosen: Bool = true) async -> Int {
        let held = endPause(provider, keepingChosen: keepingChosen)
        let continued = agentSuspension.hasSuspendedAgents(provider: provider)
            ? await agentSuspension.resume(provider: provider) : 0
        suspensionContexts[provider] = nil
        refreshPauseStatus(provider)
        let routedBack = routeBack(provider) ? 1 : 0
        return held + continued + routedBack
    }

    /// The user's own pause, taken before moving work onto accounts that are
    /// at or near their limits: every session waits at its next tool call
    /// and every new turn at its start. Only the user ends it ("Resume all",
    /// or playing each session): no returning capacity, reset, rescoping,
    /// paced resume, route or other automatic path does
    /// (`AgentPauseGate.PauseFile.heldByUser`).
    func pauseSessionsNow(_ provider: AIProviderType) {
        guard gatedProviders.contains(provider) else { return }
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
                  resumeAt: pendingResetRecovery[provider]?.resetDate, holdsNewTurns: true, manual: true,
                  chosen: existing?.chosen),
            for: provider
        )
        refreshPauseStatus(provider)
        failoverEvents.record(provider, "Paused sessions at the user's request: each waits at its next tool call and new turns wait at their start, until you resume them.")
    }

    /// The user's own override: paused sessions continue now, and no new
    /// pause starts for this provider until the limiting reset has passed.
    func resumePausedAgentsNow(_ provider: AIProviderType) async {
        // Resuming sessions paused one at a time overrides no limit.
        let chosenOnly = AgentPauseGate.read(provider)?.holdsOnlyChosenSessions == true
        let resumed = await releasePausedAgents(provider, keepingChosen: false)
        if !chosenOnly { notePauseOverride(provider) }
        failoverEvents.record(provider, "Resumed \(resumed) paused session(s) at the user's request.")
    }

    /// The user resumed every session a pause held: no new pause starts for
    /// the provider until the limiting reset has passed, or for half an
    /// hour when none is known. Set by `resumePausedAgentsNow` and by
    /// `resumeSession` for the last held session.
    func notePauseOverride(_ provider: AIProviderType) {
        pauseOverrideUntil[provider] = pendingResetRecovery[provider]?.resetDate ?? Date().addingTimeInterval(30 * 60)
    }

    /// What a pause at a limit holds (`pauseScope`).
    struct PauseScope: Equatable {
        /// The sessions that wait, sorted.
        var held: [String] = []
        /// Every new turn waits, as no account has room.
        var holdsNewTurns = false
        /// Slot sessions that go on by moving to an account with room
        /// instead of waiting, with that account.
        var moves: [String: UUID] = [:]
    }

    /// Which of `sessions` a pause at a limit holds, each judged by the
    /// account it runs on: its slot's account, or the active account for a
    /// session on the shared sign-in (nil). A session waits only when its
    /// own account is at or near its limit (`atOrNearLimit`) and no move
    /// helps: a session on the shared sign-in moves only with a failover
    /// switch, which `evaluate` found none for before pausing; a slot
    /// session goes on instead on the account `destination` moves it to
    /// while some account has room (`anyRoom`). A session on an account with
    /// room never waits for another account's limit. Every new turn waits
    /// (`holdsNewTurns`) only while no account has room. Read by
    /// `suspendAgents` and `rescopeLimitPause`.
    ///
    /// A pinned session never moves, so nothing failover does keeps it off
    /// its account's limit: `pinnedHeld` answers for each pinned session
    /// whether it waits (its account is past its failover threshold or at
    /// its limit, and the user has not played it there), and nil for a
    /// session that is not pinned, which the rules above judge.
    nonisolated static func pauseScope(sessions: [String: UUID?], active: UUID, atOrNearLimit: (UUID) -> Bool,
                                       anyRoom: Bool, destination: (String) -> UUID?,
                                       pinnedHeld: (String) -> Bool? = { _ in nil }) -> PauseScope {
        var scope = PauseScope(holdsNewTurns: !anyRoom)
        for (session, slot) in sessions.sorted(by: { $0.key < $1.key }) {
            if let held = pinnedHeld(session) {
                if held { scope.held.append(session) }
                continue
            }
            guard atOrNearLimit(slot ?? active) else { continue }
            if slot != nil, anyRoom, let target = destination(session) {
                scope.moves[session] = target
                continue
            }
            scope.held.append(session)
        }
        return scope
    }

    /// `pauseScope` for the provider's running sessions now. An account is
    /// at or near its limit as `evaluate` judges the active one: refused at
    /// it, or reaching it within `suspensionLead`. An account has room when
    /// it is in the failover order, signed in and neither. A slot session on
    /// an account at or near its limit moves where `SessionPacer.place`
    /// puts it among the accounts that also carry one more typical session
    /// for `SessionPacer.newSessionRunway` (`carriesNewSession`); with none,
    /// it waits.
    func limitPauseScope(_ provider: AIProviderType, current: Account, now: Date) -> PauseScope {
        let policy = failoverConfig.policy(for: provider)
        let planner = FailoverPlanner(settings: plannerSettings(provider))
        var verdicts: [UUID: Bool] = [:]
        func atOrNearLimit(_ id: UUID) -> Bool {
            if let known = verdicts[id] { return known }
            guard let account = accounts.first(where: { $0.id == id }) else { return true }
            let state = quotaState(for: account, now: now)
            let value = state.refusedAtLimit
                || planner.servingVerdict(planner.servingView(state), now: now, lead: Self.suspensionLead).atOrNearLimit
            verdicts[id] = value
            return value
        }
        let ladder = accounts.filter {
            $0.provider == provider && !policy.excludedAccountIDs.contains($0.id) && !needsSignIn($0)
        }
        let roomy = ladder.filter { !atOrNearLimit($0.id) }
        let live = liveSessions[provider] ?? []
        var sessions: [String: UUID?] = [:]
        for session in live { sessions[session.sessionID] = slotAccount(forSession: session.sessionID, provider: provider) }
        // Where the slot sessions on an account at or near its limit can go.
        let typical = SessionPacer.typicalNewSessionRate(pacerSessions(provider, now: now))
        let destinations = Set(roomy.filter { account in
            let state = quotaState(for: account, now: now)
            guard let projection = planner.projection(state, now: now) else { return false }
            return Self.carriesNewSession(headroom: planner.headroom(state, projection),
                                          burn: planner.expectedSessionBurn(of: state),
                                          newSessionBurn: typical / 1_000_000 * accountRatio(account.id))
        }.map(\.id))
        var placements: [String: UUID] = [:]
        if !destinations.isEmpty, let slots = SessionSlots(provider) {
            let running = slotRebalanceSessions(provider, slots: slots, now: now)
            let leaving = running.filter { $0.movable && atOrNearLimit($0.account) }
            let ids = Set(leaving.map(\.id))
            let pacerAccounts = ladder.map { account in
                pacerAccount(account.id, state: quotaState(for: account, now: now, wholeAllowance: true), weight: 1,
                             planner: planner, now: now)
            }
            placements = SessionPacer(moveCostFactor: provider.capabilities.sessionMoveCostFactor)
                .place(leaving, accounts: pacerAccounts, running: running.filter { !ids.contains($0.id) },
                       destinations: destinations, now: now)
        }
        let pinned = pinnedSessionAccounts(provider)
        var pinnedLimits: [UUID: PinnedHold?] = [:]
        return Self.pauseScope(sessions: sessions, active: current.id, atOrNearLimit: atOrNearLimit,
                               anyRoom: !roomy.isEmpty, destination: { placements[$0] },
                               pinnedHeld: { session in
            guard let account = pinned[session] else { return nil }
            if self.pinnedHoldsPlayed[session] == account { return false }
            let hold = pinnedLimits[account] ?? self.pinnedHold(account, planner: planner, now: now)
            pinnedLimits[account] = hold
            return hold != nil
        })
    }

    /// Why a session pinned to an account waits (`pinnedHold`).
    enum PinnedHold: Equatable {
        /// The account is past its failover threshold, or reaches its limit
        /// within `suspensionLead`: failover would move an unpinned session
        /// off it now.
        case threshold
        /// The account is at its limit, or refused a request at it.
        case limit
    }

    /// Whether a session pinned to `id` waits, and why: the account is at
    /// its limit, or past the threshold that makes failover move unpinned
    /// sessions off it (`FailoverPlanner.isTriggered`, or reaching its
    /// limit within `suspensionLead`). Nil while it has room. Read by
    /// `limitPauseScope` and `holdPinnedSessionsAtLimit`.
    func pinnedHold(_ id: UUID, planner: FailoverPlanner, now: Date) -> PinnedHold? {
        guard let account = accounts.first(where: { $0.id == id }) else { return nil }
        let state = quotaState(for: account, now: now)
        let verdict = planner.servingVerdict(planner.servingView(state), now: now, lead: Self.suspensionLead)
        if state.refusedAtLimit || verdict == .atLimit { return .limit }
        if verdict == .nearLimit || planner.isTriggered(state, now: now) { return .threshold }
        return nil
    }

    /// The provider's running pinned sessions, each with the account it is
    /// pinned to: the account its slot serves, which `serveSessionSlots`
    /// keeps on the pin.
    func pinnedSessionAccounts(_ provider: AIProviderType) -> [String: UUID] {
        (liveSessions[provider] ?? []).reduce(into: [:]) { result, session in
            guard let pin = sessionPins.account(of: session.sessionID) else { return }
            result[session.sessionID] = slotAccount(forSession: session.sessionID, provider: provider) ?? pin
        }
    }

    /// Holds each running pinned session whose own account reached its
    /// failover threshold or its limit (`pinnedHold`), with pausing at the
    /// limit on: failover never moves a pinned session, so without the
    /// hold it would run into the limit. The session joins the pause in
    /// effect, or a pause at a limit holding it alone (`pinnedHoldPause`),
    /// at its next tool call and new turn. `rescopeLimitPause`, through
    /// `limitPauseScope`, lets it go on once its account has room (a reset
    /// or a reading), or once the user unpins or moves it; the user may
    /// also play it (`pinnedHoldsPlayed`). Not while the user's "Resume
    /// all" holds pauses off (`pauseOverrideUntil`), or a route target
    /// serves the provider's requests. Run every quota cycle before
    /// `prunePausedSessions`.
    func holdPinnedSessionsAtLimit(_ provider: AIProviderType, now: Date = Date()) {
        let pinned = pinnedSessionAccounts(provider)
        // A played session that ended, or left the account, is forgotten.
        pinnedHoldsPlayed = pinnedHoldsPlayed.filter { session, account in
            liveSession(session).map { $0.0 != provider } ?? false || pinned[session] == account
        }
        guard pausingProviders.contains(provider), routedStatus[provider] == nil,
              pauseOverrideUntil[provider].map({ $0 <= now }) ?? true, !pinned.isEmpty else { return }
        let planner = FailoverPlanner(settings: plannerSettings(provider))
        var holds: [UUID: PinnedHold?] = [:]
        var reached: [String: (account: UUID, hold: PinnedHold)] = [:]
        for (session, account) in pinned {
            let hold = holds[account] ?? pinnedHold(account, planner: planner, now: now)
            holds[account] = hold
            guard let hold else {
                // Its account has room again: a later limit holds it again.
                if pinnedHoldsPlayed[session] == account { pinnedHoldsPlayed[session] = nil }
                continue
            }
            if pinnedHoldsPlayed[session] == account { continue }
            reached[session] = (account, hold)
        }
        let existing = AgentPauseGate.read(provider)
        let resumed = AgentPauseGate.resumedSessions(provider)
        let due = reached.keys.filter { !(existing?.sessions.contains($0) ?? false) && !resumed.contains($0) }.sorted()
        guard let pause = Self.pinnedHoldPause(existing: existing, adding: due, at: now) else { return }
        AgentPauseGate.write(pause, for: provider)
        refreshPauseStatus(provider)
        for session in due {
            guard let entry = reached[session] else { continue }
            let name = liveSession(session).map { Self.eventName(of: $0.1) } ?? "session \(session.prefix(8))"
            let on = accounts.first { $0.id == entry.account }.map { messageName($0) } ?? "its account"
            failoverEvents.record(provider, Self.pinnedHoldEvent(session: name, account: on, hold: entry.hold))
        }
    }

    /// The pause file that holds `adding`, pinned sessions whose account
    /// reached its threshold or limit, with the pause `existing` in effect;
    /// nil when nothing changes. Without a pause, a pause at a limit holding
    /// them alone, at their next tool call and new turn, while every other
    /// session runs. A pause holding every new turn holds them already. A
    /// pause of sessions the user chose one at a time becomes a pause at a
    /// limit that still lists them as chosen, so `rescopeLimitPause` judges
    /// the pinned ones by their account and `endPause` leaves the chosen
    /// ones held. Any other pause lists them too.
    nonisolated static func pinnedHoldPause(existing: AgentPauseGate.PauseFile?, adding: [String],
                                            at now: Date) -> AgentPauseGate.PauseFile? {
        guard !adding.isEmpty else { return nil }
        guard var pause = existing else {
            return AgentPauseGate.PauseFile(sessions: adding, reason: "a pinned session's account reached its limit",
                                            pausedAt: now, resumeAt: nil, holdsNewTurns: false,
                                            holdsListedNewTurns: true)
        }
        if pause.holdsNewTurns == true { return nil }
        let sessions = pause.sessions + adding.filter { !pause.sessions.contains($0) }
        guard sessions != pause.sessions else { return nil }
        pause.sessions = sessions
        if pause.manual == true, pause.account == nil {
            pause.manual = nil
            pause.reason = "a pinned session's account reached its limit"
            pause.holdsListedNewTurns = true
        }
        return pause
    }

    /// The event recording that a pinned session waits for its account.
    nonisolated static func pinnedHoldEvent(session: String, account: String, hold: PinnedHold) -> String {
        "Paused \(session), pinned to \(account), which reached its \(hold == .limit ? "limit" : "threshold"); it continues when \(account) has room."
    }

    /// Sends each of `moves` to its account through the slot-move path,
    /// which records each move, and says so once.
    private func requestPauseMoves(_ provider: AIProviderType, _ moves: [String: UUID]) {
        let fresh = moves.filter { requestedSlotMoves[$0.key] != $0.value }
        guard !fresh.isEmpty else { return }
        for (session, target) in fresh {
            requestedSlotMoves[session] = target
            requestedWindowUses[session] = nil
            automaticSlotMoves.remove(session)
        }
        let names = Set(fresh.values).compactMap { id in accounts.first { $0.id == id }.map { messageName($0) } }.sorted()
        failoverEvents.record(provider, "Moving \(fresh.count) session(s) off accounts at or near their limit to \(names.joined(separator: ", ")), which have room, instead of pausing them.")
    }

    /// Narrows a pause at a limit to `limitPauseScope` now: each listed
    /// session whose own account has room again (a reset, a reading, or its
    /// slot moved to an account with room) goes on, and once some account
    /// has room the pause stops holding every new turn and lists the
    /// sessions that must still wait. Ends the pause when none must. Run
    /// every cycle by `prunePausedSessions`, also for a pause file found
    /// after a relaunch.
    func rescopeLimitPause(_ provider: AIProviderType, pause: AgentPauseGate.PauseFile, current: Account, now: Date) {
        let scope = limitPauseScope(provider, current: current, now: now)
        if pause.holdsNewTurns == true && scope.holdsNewTurns { return }
        requestPauseMoves(provider, scope.moves)
        let held = Set(scope.held)
        // Sessions the user paused one at a time stay held whatever their
        // account's room (`AgentPauseGate.PauseFile.chosen`).
        let chosen = Set(pause.chosenListed)
        let sessions = (pause.holdsNewTurns == true ? held : Set(pause.sessions).intersection(held)).union(chosen)
        let released = pause.holdsNewTurns == true ? [] : Set(pause.sessions).subtracting(sessions)
        guard !sessions.subtracting(chosen).isEmpty || scope.holdsNewTurns else {
            let count = endPause(provider)
            suspensionContexts[provider] = nil
            failoverEvents.record(provider, "The account each paused session runs on has room again; resumed \(count) session(s) and ended the pause."
                                  + (chosen.isEmpty ? "" : " The \(chosen.count) session(s) you paused stay paused until you play them."))
            return
        }
        guard sessions != Set(pause.sessions) || pause.holdsNewTurns != scope.holdsNewTurns else { return }
        var narrowed = pause
        narrowed.sessions = sessions.sorted()
        narrowed.holdsNewTurns = scope.holdsNewTurns
        narrowed.holdsListedNewTurns = scope.holdsNewTurns ? nil : true
        AgentPauseGate.write(narrowed, for: provider)
        if pause.holdsNewTurns == true {
            failoverEvents.record(provider, "An account has room again: sessions on accounts with room continue, and \(sessions.count) session(s) whose own account is still at its limit keep waiting.")
        } else if !released.isEmpty {
            failoverEvents.record(provider, "Resumed \(released.count) paused session(s): the account each runs on has room again.")
        }
    }

    /// Drops sessions that ended after the pause started, and refreshes the
    /// paused-session display.
    func prunePausedSessions(_ provider: AIProviderType) {
        // An automatic pause left behind while pausing is turned off for the
        // provider has nothing that would end it; a pause the user took ends
        // only when the user resumes.
        if let pause = AgentPauseGate.read(provider), pause.manual != true, !pausingProviders.contains(provider) {
            let released = endPause(provider)
            failoverEvents.record(provider, "Released \(released) paused session(s): pausing at the limit is turned off for \(provider.capabilities.displayName).")
            return
        }
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
            // A pause at a limit lets each session go on once its own account
            // has room; a pause the user took, an account hold or one that
            // narrows a route ends by its own rule.
            if pause.manual != true, pause.account == nil, routedStatus[provider] == nil,
               let current = activeAccount(for: provider), AgentPauseGate.read(provider) != nil {
                rescopeLimitPause(provider, pause: pause, current: current, now: Date())
            }
            // Resuming as capacity allows already uses what is left before a
            // reset, with whole sessions.
            if AgentPauseGate.isActive(provider), !resumesAsCapacityAllows(provider),
               let current = AgentPauseGate.read(provider) {
                releaseStepsWithinHeadroom(provider, pause: current)
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
        // A session pinned to another account spends that account, not the
        // active one's headroom; one the user paused waits for the user.
        let pinned = pinnedSessionAccounts(provider)
        let waiting = Self.automaticallyReleasable(AgentPauseGate.waitingSessions(provider), pause: pause)
            .filter { pinned[$0].map { $0 == current.id } ?? true }
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
    /// capacity returns. Forecasts need each request's token counts, which
    /// the router or the CLI's transcripts report (`learnsRequestCost`).
    /// It governs automatic pauses at a limit only: the user's own pause
    /// ends whole, and only when the user resumes it.
    func resumesAsCapacityAllows(_ provider: AIProviderType) -> Bool {
        failoverConfig.policy(for: provider).resumeAsCapacityAllows && learnsRequestCost(provider)
            && AgentPauseGate.read(provider)?.manual != true
    }

    /// Typical weighted tokens per hour of a session with no history, such
    /// as one started during the pause, when no paused session has one.
    static let defaultSessionDemand = SessionPacer.defaultSessionRate

    /// Lets paused sessions continue where their forecast use fits
    /// (`SessionPacer.admit`): on the router's pool accounts while sessions
    /// are served from several accounts, otherwise on the active account.
    /// The pause ends once it holds no session.
    func admitPausedSessions(_ provider: AIProviderType, planner: FailoverPlanner) async {
        guard let pause = AgentPauseGate.read(provider), !pause.holdsAllForUser else { return }
        let allHeld = heldSessions(provider)
        guard !allHeld.isEmpty else {
            let resumed = await releasePausedAgents(provider)
            if resumed > 0 { failoverEvents.record(provider, "Every paused session has continued; the pause is over.") }
            return
        }
        // Sessions the user paused wait for the user. A pinned session goes
        // on only on its own account, once that account has room
        // (`rescopeLimitPause`), never where the forecast would place it.
        let releasable = Self.automaticallyReleasable(allHeld, pause: pause)
        let pinned = pinnedSessionAccounts(provider)
        let held = releasable.filter { pinned[$0] == nil }
        guard !held.isEmpty else { return }
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
            quotaTrends[placement.account]?.settle(at: now)
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
        // Pinned sessions still held keep the pause; the user's chosen ones
        // stay held when it ends (`endPause`).
        if waiting == 0, held.count == releasable.count {
            await releasePausedAgents(provider)
        }
    }

    /// The accounts paused sessions may continue on: any that is not at a
    /// limit and not about to reach one, read recently enough to trust.
    private func admissionAccounts(_ provider: AIProviderType, planner: FailoverPlanner, now: Date) -> [SessionPacer.Account] {
        let policy = failoverConfig.policy(for: provider)
        func usable(_ state: QuotaAccountState) -> Bool {
            planner.canSwitchWithoutReading(state, now: now)
                && planner.servingVerdict(state, now: now, lead: Self.suspensionLead) == .canServe
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
        let attribution = sessionAttribution(provider, now: now)
        let processes = sessionProcesses(provider)
        var reheld = 0
        for (id, admission) in admissions {
            guard resumed.contains(id) else { admissions[id] = nil; continue }
            // The account seen serving it since it was resumed, else the
            // one it was placed on.
            let accountID = attribution.decide(session: id, process: processes[id]).flatMap { decision in
                decision.observedAt.map { $0 > admission.at } == true ? decision.account : nil
            } ?? admission.account
            guard let account = accounts.first(where: { $0.id == accountID }) else { continue }
            let state = quotaState(for: account, now: now)
            let nearLimit = planner.servingVerdict(state, now: now, lead: Self.suspensionLead).atOrNearLimit
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
                let usable = planner.isFresh(state, now: now)
                    && planner.servingVerdict(state, now: now, lead: Self.suspensionLead) == .canServe
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
            guard planner.servingVerdict(state, now: now, lead: Self.suspensionLead).atOrNearLimit else { continue }
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
            let until = UsageFormat.duration(reset.timeIntervalSince(now))
            failoverEvents.record(provider, "\(name) is at its limit and resets in \(until), before the prompt caches of its \(sessions.count) working session(s) expire: they wait at their next tool call and continue on it after the reset, instead of writing their context again on another account.")
            return
        }
    }

    /// Whether `account` can take work now, with `suspensionLead` as the
    /// lead (`FailoverPlanner.servingVerdict`).
    func servingVerdict(_ account: Account, planner: FailoverPlanner, now: Date = Date(),
                        model: String? = nil) -> ServingVerdict {
        planner.servingVerdict(quotaState(for: account, now: now, model: model), now: now, lead: Self.suspensionLead)
    }

    /// Whether `account` is at its limit, refused at it, or within
    /// `suspensionLead` of it.
    func isNearLimit(_ account: Account, planner: FailoverPlanner, now: Date = Date()) -> Bool {
        servingVerdict(account, planner: planner, now: now).atOrNearLimit
    }

    /// The account serving a session now (`SessionAttribution`).
    func servingAccount(_ provider: AIProviderType, session: String) -> Account? {
        servingDecision(provider, session: session).flatMap { decision in accounts.first { $0.id == decision.account } }
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
        // (`holdSessionsForImminentReset`), not on another's capacity, and
        // a pause the user took when the user resumes.
        if let pause = AgentPauseGate.read(provider), pause.account != nil || pause.heldByUser { return }
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
              planner.servingVerdict(state, now: now, lead: Self.suspensionLead) == .canServe else { return }
        guard Self.capacityEndsPause(AgentPauseGate.read(provider), routed: routedStatus[provider] != nil) else {
            // Its sessions go on one by one as their own accounts have room
            // (`rescopeLimitPause`); a later limit of the active account may
            // pause again (`suspendAgents`).
            suspensionContexts[provider] = nil
            return
        }
        let resumed = await releasePausedAgents(provider)
        if resumed > 0 {
            pendingResetRecovery[provider] = nil
            exhaustedFailoverAccounts[provider, default: []].remove(current.id)
            saveFailoverRuntime()
            failoverEvents.record(provider, "Capacity is available on \(messageName(current)); resumed \(resumed) paused session(s).")
        }
    }

    /// Whether the active account having room again ends `pause` whole
    /// (`resumeAgentsIfCapacityReturned`). A pause at a limit that lists the
    /// sessions it holds, without holding every new turn, does not: each
    /// listed session goes on once its own account has room
    /// (`rescopeLimitPause`), so a session pinned to an account still at
    /// its limit stays held whatever the active account's room. While a
    /// route target serves the requests (`routed`), ending the pause is
    /// what brings them back (`releasePausedAgents`), so it ends. An account
    /// hold ends at its own account's reset, and a pause the user took
    /// (`AgentPauseGate.PauseFile.heldByUser`) only when the user resumes.
    nonisolated static func capacityEndsPause(_ pause: AgentPauseGate.PauseFile?, routed: Bool = false) -> Bool {
        guard let pause else { return true }
        if pause.account != nil || pause.heldByUser { return false }
        return routed || pause.holdsNewTurns == true
    }

    /// Whether a pause at a limit leaves `existing` as it is
    /// (`suspendAgents`): the user's "Pause all" holds every session and
    /// turn already, and only the user ends it.
    nonisolated static func limitPauseYields(to existing: AgentPauseGate.PauseFile?) -> Bool {
        existing?.holdsAllForUser == true
    }

    /// Which of `sessions` an automatic release may let go under `pause`:
    /// none of the user's own pause (`PauseFile.userHeld`), which only the
    /// user ends, so a session both the user and a limit hold waits for the
    /// user. Read by paced resume (`admitPausedSessions`), the steps let
    /// through within headroom (`releaseStepsWithinHeadroom`) and the
    /// sessions the CLI left waiting at a limit (`resumeSessionsLeftWaiting`).
    nonisolated static func automaticallyReleasable(_ sessions: Set<String>, pause: AgentPauseGate.PauseFile?,
                                                    running: Set<String> = []) -> Set<String> {
        guard let pause else { return sessions }
        return sessions.subtracting(pause.userHeld(running: running.union(sessions)))
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
        if policy.activeAccountLocked {
            if lockedSwitchNoted[provider] != target.id {
                lockedSwitchNoted[provider] = target.id
                failoverEvents.record(provider, "\(messageName(current)) is locked as the active account, so no switch to \(messageName(target)) was made.")
            }
            return
        }
        let sourceName = messageName(current)
        let targetName = messageName(target)
        // Every switch moves the sessions on the shared credential, which
        // rebuild their whole prompt cache on the other account, so failover
        // does not undo a switch the user just made, and stops when it keeps
        // leaving one account: something is putting it back.
        let now = Date()
        if let chosen = userSwitchedAt[provider], now.timeIntervalSince(chosen) < Self.userSwitchHold { return }
        let recent = (automaticSwitchesAway[current.id] ?? []).filter { now.timeIntervalSince($0) < FailoverPlanner.switchLoopWindow }
        if FailoverPlanner.isSwitchLoop(recent, now: now) {
            if lockedSwitchNoted[provider] != current.id {
                lockedSwitchNoted[provider] = current.id
                failoverEvents.record(provider, "Failover has switched away from \(sourceName) \(recent.count) times in \(Int(FailoverPlanner.switchLoopWindow / 60)) minutes and it keeps becoming active again, so it stays active. Switch manually or lock it.")
            }
            return
        }

        if !(await credentialIsUsable(target)) { return }
        automaticSwitchesAway[current.id] = recent + [now]

        let hadSuspendedAgents = hasPausedAgents(provider)
        let reachesSessions = provider.capabilities.switchReachesRunningSessions
        var running = RunningSessions()
        if reachesSessions {
            guard let prepared = await prepareSwitchReachingSessions(
                provider, policy: policy, reason: reason, hadSuspendedAgents: hadSuspendedAgents
            ) else { return }
            running = prepared
        }

        let modelLimit = reason == .exhausted
            ? limitingModel(current, models: sharedSessionModels(provider, now: now), now: now) : nil
        switch reason {
        case .balance(let hours) where hours < 1:
            // The forecast decided: staying would leave more allowance unused.
            failoverEvents.record(provider, "Balancing moves work from \(sourceName) to \(targetName): over the coming week this leaves less of their allowances unused.")
        case .balance(let hours):
            failoverEvents.record(provider, Self.balanceSwitchEvent(source: sourceName, target: targetName, hours: hours))
        case .threshold:
            failoverEvents.record(provider, "Threshold reached; switching \(sourceName) → \(targetName).")
        case .exhausted:
            failoverEvents.record(provider, Self.exhaustedSwitchEvent(source: sourceName, target: targetName, modelLimit: modelLimit))
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
            moveRunningSessions(provider, from: current.id, reason: "failover.switch")
        } else if credentialModule(for: provider)?.liveCredential != nil {
            sessionsLeftOn[provider, default: []].insert(current.id)
        }
        // A threshold, or a forecast crossing one, leaves room on the
        // account; `buildPool` drains it until a reading shows the limit.
        if reason == .threshold { drainingAccounts[current.id] = Date() }
        drainingAccounts[target.id] = nil
        // The sessions that follow the switch rewrite their contexts on the
        // target; that burst is not its burn rate, which `nextSwitch` and the
        // pacer project from.
        quotaTrends[target.id]?.settle(at: Date(), for: QuotaTrend.arrivalSettlePeriod)
        if provider == AIProviderType.routedProvider { await routerFollowActiveAccount() }
        lastAutomaticFailover[provider] = Date()
        exhaustedFailoverAccounts[provider, default: []].insert(current.id)
        exhaustedFailoverAccounts[provider, default: []].remove(target.id)
        saveFailoverRuntime()
        updateStatus(provider, "Switched to \(targetName)."
            + (modelLimit.map { " \(sourceName) has no \($0) allowance left for the sessions on the shared sign-in." } ?? ""))

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
