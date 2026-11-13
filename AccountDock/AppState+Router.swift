import Foundation

private let routingLog = FileLog("Routing")

/// Drives `AccountDockRouter` for the provider it serves
/// (`AIProviderType.routedProvider`): which backend serves new turns, which
/// accounts serve sessions in parallel, and the usage and events the router
/// reports back.
extension AppState {
    // MARK: - Configuration

    /// Whether a setting of the routed provider needs the router
    /// (`ProviderFailoverPolicy.usesRouter(for:)`).
    var routerWanted: Bool {
        guard let provider = AIProviderType.routedProvider else { return false }
        return failoverConfig.policy(for: provider).usesRouter(for: provider)
    }

    /// Whether the routed provider's requests pass through the router and
    /// something is configured for it to do.
    var routerInUse: Bool {
        routerWanted && RequestRouterController.isInstalled()
    }

    func routeTarget(for provider: AIProviderType) -> RouteTarget? {
        let id = failoverConfig.policy(for: provider).routeTarget
        return RouteTarget.available(for: provider).first { $0.id == id }
    }

    /// The target's backing account when it can serve routed requests: its
    /// window has room above the share kept for its own sessions, and it is
    /// expected to carry the demand at least the configured time.
    func routeTargetAccount(_ target: RouteTarget, now: Date = Date()) -> Account? {
        if let until = routeTargetRefusedUntil[target.id], until > now { return nil }
        guard let account = accounts.first(where: { $0.provider == target.provider && $0.isActive }) else { return nil }
        let planner = FailoverPlanner(settings: plannerSettings(target.provider))
        guard planner.tier(quotaState(for: account, now: now), now: now) <= .usable else { return nil }
        let verdict = routeCapacity(target, account: account, now: now)
        if routeTargetVerdicts[target.id] != verdict { routeTargetVerdicts[target.id] = verdict }
        return verdict.serves ? account : nil
    }

    /// Whether `target` can take the busiest recent demand of the sessions
    /// within its context cap.
    func routeCapacity(_ target: RouteTarget, account: Account, now: Date = Date()) -> RouteCapacity.Verdict {
        let policy = AIProviderType.routedProvider.map { failoverConfig.policy(for: $0) } ?? ProviderFailoverPolicy()
        let cap = policy.routeMaxContextTokens ?? target.defaultMaxContextTokens(model: policy.routeModel)
        let cost = routeTargetCosts[target.id] ?? RouteTargetCostModel()
        let reading = accountUsage[account.id]?.fiveHour?.utilization ?? 0
        return RouteCapacity.evaluate(
            targetName: target.displayName,
            sessionPercent: cost.estimatedSession(reading: reading, defaultRatio: target.defaultPercentPerMillion),
            reservePercent: policy.routeReservePercent,
            tokensPerMinute: RouteCapacity.peakTokensPerMinute(recentRouterRequests, maxContext: cap, now: now),
            percentPerMillion: cost.ratio(default: target.defaultPercentPerMillion),
            minimumMinutes: policy.routeMinimumMinutes
        )
    }

    /// Reads the target's backing account when its reading is older than
    /// `maximumAge`: a target can fill its window within minutes.
    func refreshRouteTargetReading(maximumAge: TimeInterval) async {
        guard let provider = AIProviderType.routedProvider, let target = routeTarget(for: provider),
              let account = accounts.first(where: { $0.provider == target.provider && $0.isActive }) else { return }
        let age = accountUsageUpdatedAt[account.id].map { Date().timeIntervalSince($0) } ?? .infinity
        if age > maximumAge { _ = await fetchUsageNow(account, priority: .critical) }
    }

    /// An access token for `account` lasting at least `minimumLifetime`,
    /// with its expiry, for the router to send upstream: as a pool member of
    /// the routed provider, or as a route target's credential.
    func accessCredential(_ account: Account, minimumLifetime: TimeInterval) async -> (String, Date)? {
        switch account.provider {
        case .claudeCode:
            return await currentClaudeToken(account, minimumLifetime: minimumLifetime)
        case .kimi:
            guard let location = account.credentialLocation else { return nil }
            return try? await kimiService.freshAccessToken(location: location, isActive: account.isActive, minimumLifetime: minimumLifetime)
        case .codex, .gemini:
            return nil
        }
    }

    /// The access token `account` holds now, without renewing it, for
    /// recognising which account a session's credential belongs to.
    func currentAccessToken(_ account: Account) -> String? {
        switch account.provider {
        case .claudeCode:
            let json = account.isActive
                ? keychain.readClaudeToken()
                : keychain.getAccountBackup(forAccountId: account.id.uuidString)?.token
            return json.flatMap(ClaudeService.extractAccessToken(from:))
        case .codex, .kimi, .gemini:
            return nil
        }
    }

    // MARK: - Holding work when every account is out

    /// Keeps work going when every account is out: routes to the configured
    /// target when it has capacity, and otherwise pauses the sessions that
    /// are mid-turn.
    func holdWork(
        _ provider: AIProviderType,
        policy: ProviderFailoverPolicy,
        current: Account,
        because reason: String
    ) async {
        if await routeToTarget(provider, policy: policy, current: current, because: reason) { return }
        if routedStatus[provider] != nil {
            // The target can no longer serve either, or routing was turned
            // off: stop routing and pause the sessions that are mid-turn now.
            let name = routedStatus[provider]?.target ?? "The route target"
            let target = routeTarget(for: provider)
            let why = target.flatMap { routeTargetVerdicts[$0.id]?.reason }.map { " (\($0))" } ?? ""
            routeBack(provider, announce: false)
            suspensionContexts[provider] = nil
            failoverEvents.record(provider, target == nil
                ? "Routing to \(name) is turned off; pausing instead."
                : "\(name) can no longer serve the requests\(why); pausing instead.")
        }
        await suspendAgents(provider, policy: policy, current: current, because: reason)
    }

    private func routeToTarget(
        _ provider: AIProviderType,
        policy: ProviderFailoverPolicy,
        current: Account,
        because reason: String
    ) async -> Bool {
        guard provider == AIProviderType.routedProvider, RequestRouterController.isInstalled(),
              let target = routeTarget(for: provider) else { return false }
        await refreshRouteTargetReading(maximumAge: 2 * 60)
        guard let account = routeTargetAccount(target),
              await refreshRouteTargetToken(target, account: account) else { return false }
        if let until = routeOverrideUntil[provider], until > Date() { return false }
        if suspensionContexts[provider] == nil {
            let state = quotaState(for: current)
            suspensionContexts[provider] = SuspensionContext(
                accountID: current.id,
                usage: accountUsage[current.id],
                sessionBurnPerHour: state.sessionBurnPerHour,
                weeklyBurnPerHour: state.weeklyBurnPerHour
            )
        }
        // Sessions already held by a pause continue on the target, except
        // those whose context is over the target's cap: the router keeps
        // those on the exhausted accounts, so they are held instead.
        let model = policy.routeModel ?? target.defaultModel
        holdSessionsTooLargeForRoute(provider, target: target, model: model, policy: policy)
        if routedStatus[provider] == nil {
            routedStatus[provider] = RoutedStatus(
                since: Date(),
                target: target.displayName,
                model: model,
                backingAccount: messageName(account),
                resumeAt: pendingResetRecovery[provider]?.resetDate
            )
            failoverEvents.record(provider, "Every \(provider.capabilities.displayName) account is exhausted (\(reason)); requests are now served by \(target.displayName) \(model). Sessions keep running.")
        } else {
            routedStatus[provider]?.resumeAt = pendingResetRecovery[provider]?.resetDate
        }
        applyRouterState()
        return true
    }

    /// While requests go to `target`, holds every live session whose context
    /// is over the target's cap (`routeMaxContextTokens`): the router sends
    /// those to the provider's own accounts, which are out. They wait at
    /// their next tool call and new turn; the rest continue on the target.
    /// The hold ends with the route, through the pause's usual release.
    func holdSessionsTooLargeForRoute(_ provider: AIProviderType, target: RouteTarget, model: String,
                                      policy: ProviderFailoverPolicy, now: Date = Date()) {
        let cap = policy.routeMaxContextTokens ?? target.defaultMaxContextTokens(model: policy.routeModel)
        let existing = AgentPauseGate.read(provider)
        let live = Set((liveSessions[provider] ?? []).map(\.sessionID))
        let resumed = AgentPauseGate.resumedSessions(provider)
        let overrides = pauseOverrideUntil[provider].map { $0 > now } ?? false
        let large = overrides || !pausingProviders.contains(provider) ? [] : sessionRates.entries
            .filter { id, entry in live.contains(id) && !resumed.contains(id) && entry.contextTokens > cap }
            .keys.sorted()
        let continuation = "on \(target.displayName) \(model)"
        if large.isEmpty {
            guard AgentPauseGate.isActive(provider) else { return }
            let held = endPause(provider, continuation: continuation)
            failoverEvents.record(provider, "\(target.displayName) has capacity; \(held) paused session(s) continue on it.")
            return
        }
        guard existing?.sessions.sorted() != large || existing?.holdsListedNewTurns != true
            || existing?.holdsNewTurns == true else { return }
        let released = Set(existing?.sessions ?? []).union(AgentPauseGate.waitingSessions(provider)).subtracting(large)
        AgentPauseGate.narrow(provider, to: large,
                              reason: "their context is over \(target.displayName)'s \(cap / 1000)k-token limit",
                              continuation: continuation)
        refreshPauseStatus(provider)
        let newly = Set(large).subtracting(existing?.sessions ?? [])
        if !newly.isEmpty || !released.isEmpty {
            failoverEvents.record(provider, "\(large.count) session(s) with more than \(cap / 1000)k tokens of context are paused, since \(target.displayName) does not take them and every \(provider.capabilities.displayName) account is out; they wait at their next tool call and new turn." + (released.isEmpty ? "" : " \(released.count) paused session(s) continue on \(target.displayName) \(model)."))
        }
    }

    /// Returns routed requests to the provider's own accounts. Each session
    /// moves back at the start of its next turn.
    @discardableResult
    func routeBack(_ provider: AIProviderType, announce: Bool = true) -> Bool {
        guard provider == AIProviderType.routedProvider, let status = routedStatus.removeValue(forKey: provider) else { return false }
        applyRouterState()
        if announce {
            let minutes = Int(Date().timeIntervalSince(status.since) / 60)
            let name = provider.capabilities.displayName
            failoverEvents.record(provider, "\(name) has capacity again; requests return to \(name) at each session's next turn after \(minutes) min on \(status.target).")
        }
        return true
    }

    /// The user's override: requests return now, and no new route starts
    /// until the limiting reset has passed.
    func returnToPrimaryNow(_ provider: AIProviderType) {
        routeOverrideUntil[provider] = pendingResetRecovery[provider]?.resetDate ?? Date().addingTimeInterval(30 * 60)
        suspensionContexts[provider] = nil
        routeBack(provider, announce: false)
        failoverEvents.record(provider, "Requests returned to \(provider.capabilities.displayName) at the user's request.")
    }

    // MARK: - Router upkeep

    /// Runs on every quota cycle: keeps the router current, refreshes the
    /// credentials it uses, publishes the state, and applies the usage and
    /// events it reported.
    func maintainRouter(now: Date = Date()) async {
        let wanted = routerWanted
        // The router exists only while a feature uses it: installed or
        // updated when wanted, retired once unwanted and idle.
        if routerCheckedAt.map({ now.timeIntervalSince($0) >= 2 * 60 }) ?? true {
            routerCheckedAt = now
            do {
                try await RequestRouterController.reconcile(wanted: wanted)
                routerProblem = nil
            } catch {
                routerProblem = error.localizedDescription
                routingLog.warning("Router could not be set up: \(error.localizedDescription)")
            }
        }
        guard let provider = AIProviderType.routedProvider else { return }
        let policy = failoverConfig.policy(for: provider)
        guard wanted, RequestRouterController.isInstalled() else {
            if routedStatus[provider] != nil { routedStatus[provider] = nil }
            return
        }
        if let target = routeTarget(for: provider), let account = routeTargetAccount(target) {
            _ = await refreshRouteTargetToken(target, account: account)
        }
        routerPoolMembers = policy.distributeSessions
            ? await buildPool(provider, now: now) : await activePool(provider, now: now)
        refreshCredentialFingerprints(now: now)
        applyRouterState()
        await RequestRouterController.pushCredentials()
        applyRouterEvents(provider, now: now)
        ingestRouterUsage()
    }

    /// Publishes a new active account to the router straight away, so
    /// running sessions move at their next turn instead of at the next
    /// maintenance cycle.
    func routerFollowActiveAccount() async {
        guard routerInUse, let provider = AIProviderType.routedProvider,
              !failoverConfig.policy(for: provider).distributeSessions else { return }
        routerPoolMembers = await activePool(provider, now: Date())
        credentialFingerprintsBuiltAt = nil
        refreshCredentialFingerprints(now: Date())
        applyRouterState()
        await RequestRouterController.pushCredentials(force: true)
    }

    /// Writes the router state from what AccountDock currently decided.
    /// Does nothing while no feature uses the router: `maintainRouter` has
    /// then cleared its state, and `routerPoolMembers` holds the accounts
    /// `maintainSessionSlots` serves, which have no router tokens.
    func applyRouterState() {
        guard routerWanted, let provider = AIProviderType.routedProvider else { return }
        let policy = failoverConfig.policy(for: provider)
        let target = routeTarget(for: provider)
        var state = RouterState()
        var tokenFiles = Set(routerPoolMembers.map(\.tokenFile))
        if let target {
            state.backends.append(target.backend(model: policy.routeModel, maxContextTokens: policy.routeMaxContextTokens))
            let usable = (RequestRouterController.token(target.tokenFile)?.expiresAt ?? .distantPast) > Date().addingTimeInterval(60)
            let overridden = routeOverrideUntil[provider].map { $0 > Date() } ?? false
            if usable, !overridden, routeTargetAccount(target) != nil { state.fallback = target.id }
            if routedStatus[provider] != nil { state.route = target.id }
            tokenFiles.insert(target.tokenFile)
        }
        state.pool = routerPoolMembers
        state.sessionsFollowPreferred = !policy.distributeSessions
        state.cacheAwareSessions = policy.distributeSessions && policy.paceSessions
        state.extendedCacheMinimumContext = policy.extendCacheLifetime ? 0 : nil
        if state.cacheAwareSessions {
            state.moves = routerSessionMoves.mapValues(\.uuidString)
        }
        state.reason = routedStatus[provider].map { "every \(provider.capabilities.displayName) account is exhausted; served by \($0.target)" }
        RequestRouterController.apply(state)
        RequestRouterController.retainTokens(tokenFiles, allowedCredentials: Set(credentialFingerprints.keys))
    }

    @discardableResult
    func refreshRouteTargetToken(_ target: RouteTarget, account: Account) async -> Bool {
        if let token = RequestRouterController.token(target.tokenFile), token.expiresAt > Date().addingTimeInterval(5 * 60) {
            return true
        }
        guard let (token, expiry) = await accessCredential(account, minimumLifetime: 5 * 60) else {
            routingLog.warning("\(target.displayName) credential for the router could not be renewed")
            return false
        }
        RequestRouterController.setToken(target.tokenFile, token: token, expiresAt: expiry)
        return true
    }

    // MARK: - Session distribution

    /// The active account for every session, then the other accounts with
    /// room, in failover order, for requests the active account refuses.
    /// `forRouter` gives each member a current router token; `SessionSlots`
    /// writes its own credentials instead.
    func activePool(_ provider: AIProviderType, now: Date, forRouter: Bool = true) async -> [RouterPoolMember] {
        let policy = failoverConfig.policy(for: provider)
        guard let active = accounts.first(where: { $0.provider == provider && $0.isActive }) else { return [] }
        let planner = FailoverPlanner(settings: plannerSettings(provider))
        let others = accounts.filter {
            $0.provider == provider && !$0.isActive && !policy.excludedAccountIDs.contains($0.id)
        }.sorted { lhs, rhs in
            (policy.accountOrder.firstIndex(of: lhs.id) ?? .max) < (policy.accountOrder.firstIndex(of: rhs.id) ?? .max)
        }
        var members: [RouterPoolMember] = []
        for account in [active] + others {
            if account.id != active.id {
                let state = quotaState(for: account, now: now)
                guard planner.tier(state, now: now) <= .usable, planner.canSwitchWithoutReading(state, now: now) else { continue }
            }
            let name = Self.poolTokenFile(account)
            if forRouter {
                guard let token = await accessCredential(account, minimumLifetime: 10 * 60) else { continue }
                RequestRouterController.setToken(name, token: token.0, expiresAt: token.1)
            }
            members.append(RouterPoolMember(accountID: account.id.uuidString, tokenFile: name, weight: account.id == active.id ? 1 : 0))
        }
        return members
    }

    /// Sessions with a smaller context are not held for an imminent reset
    /// (`holdSessionsForImminentReset`): writing it again elsewhere costs
    /// little.
    static let heldCacheMinimumContext = 50_000

    /// The router's token file for a pool member.
    nonisolated static func poolTokenFile(_ account: Account) -> String {
        "\(account.provider.capabilities.pauseGate?.key ?? account.provider.rawValue)-\(account.id.uuidString)"
    }

    /// The provider's accounts that may serve sessions, each with a current
    /// token.
    /// Accounts below their thresholds take new sessions, with more weight
    /// for allowances that must start being used soonest; accounts above a
    /// threshold keep only the sessions they already serve, unless nothing
    /// is below its thresholds. `forRouter` as in `activePool`.
    func buildPool(_ provider: AIProviderType, now: Date, forRouter: Bool = true) async -> [RouterPoolMember] {
        let policy = failoverConfig.policy(for: provider)
        let planner = FailoverPlanner(settings: plannerSettings(provider))
        var candidates: [(Account, QuotaTier, Date)] = []
        var states: [UUID: QuotaAccountState] = [:]
        for account in accounts where account.provider == provider && !policy.excludedAccountIDs.contains(account.id) {
            let state = quotaState(for: account, now: now)
            let tier = planner.tier(state, now: now)
            guard tier <= .usable, let observedAt = state.observedAt else { continue }
            let maximumAge = state.mayBeConsumedElsewhere ? FailoverPlanner.liveFreshness : FailoverPlanner.idleFallbackFreshness
            guard now.timeIntervalSince(observedAt) <= maximumAge else { continue }
            candidates.append((account, tier, planner.latestStart(state, now: now)))
            states[account.id] = state
        }
        let anyBelow = candidates.contains { $0.1 == .belowTrigger }
        var members: [RouterPoolMember] = []
        for (account, tier, latestStart) in candidates {
            let name = Self.poolTokenFile(account)
            if forRouter {
                guard let token = await accessCredential(account, minimumLifetime: 10 * 60) else { continue }
                RequestRouterController.setToken(name, token: token.0, expiresAt: token.1)
            }
            let urgent = latestStart.timeIntervalSince(now) < 24 * 60 * 60
            let weight: Double = tier == .belowTrigger ? (urgent ? 2 : 1) : (anyBelow ? 0 : 1)
            members.append(RouterPoolMember(accountID: account.id.uuidString, tokenFile: name, weight: weight))
        }
        // With every account at its limit, the active account serves every
        // session, as the failover plan chose it: the one on extra usage, or
        // the one that resets first. Sessions otherwise keep the credentials
        // they started with, which extra usage may not cover.
        guard !members.isEmpty else {
            routerSessionMoves = [:]
            pacingShedding = []
            return await activePool(provider, now: now, forRouter: forRouter)
        }
        guard policy.paceSessions else {
            routerSessionMoves = [:]
            pacingShedding = []
            return members
        }
        return paced(provider, members: members, states: states, planner: planner, movesSessions: forRouter, now: now)
    }

    /// The pool reweighted by `SessionPacer`, which also decides the sessions
    /// the router moves at their next turn. Sessions resumed from a pause
    /// go to the account they were placed on until they first reach it.
    /// Without `movesSessions` (`SessionSlots`, whose sessions keep the
    /// account they started on) only new sessions follow the weights.
    private func paced(_ provider: AIProviderType, members: [RouterPoolMember], states: [UUID: QuotaAccountState],
                       planner: FailoverPlanner, movesSessions: Bool, now: Date) -> [RouterPoolMember] {
        let paced = members.compactMap { member -> SessionPacer.Account? in
            guard let id = UUID(uuidString: member.accountID), let state = states[id] else { return nil }
            return pacerAccount(id, state: state, weight: member.weight, planner: planner, now: now)
        }
        let plan = SessionPacer().plan(accounts: paced, sessions: pacerSessions(provider, now: now), now: now)
        var moves = plan.moves
        for (id, account) in pendingPlacements(provider) where moves[id] == nil { moves[id] = account }
        routerSessionMoves = movesSessions ? moves : [:]
        slotSessionMoves = movesSessions ? [:] : moves
        for (id, outlook) in plan.shedding where !pacingShedding.contains(id) {
            guard let account = accounts.first(where: { $0.id == id }), let limitAt = outlook.limitAt else { continue }
            let time = limitAt.formatted(date: .omitted, time: .shortened)
            let wait = Int((outlook.waitAtLimit / 60).rounded())
            // Without the router only sessions in one-session slots can move.
            let movable = movesSessions ? nil : Set((liveSessions[provider] ?? []).compactMap { session -> String? in
                guard let pid = session.processID, let directory = slotDirectoryByProcess[pid],
                      let root = SessionSlots(provider)?.sessionRoot.path, directory.hasPrefix(root + "/") else { return nil }
                return session.sessionID
            })
            let moving = plan.moves.keys.filter {
                sessionRates.entries[$0]?.account == id && (movable?.contains($0) ?? true)
            }.count
            let outcome = movesSessions || moving > 0
                ? "\(moving) session(s) move to other accounts at their next turn."
                : "new sessions start on other accounts."
            failoverEvents.record(provider, "At its sessions' current rate \(messageName(account)) would reach its limit at \(time), \(wait) min before that window resets; \(outcome)")
        }
        pacingShedding = Set(plan.shedding.keys)
        return members.map { member in
            var member = member
            if let id = UUID(uuidString: member.accountID), let weight = plan.weights[id] { member.weight = weight }
            return member
        }
    }

    /// The account as `SessionPacer` sees it: its windows projected to now,
    /// its observed rate less what sessions that just left it took, and its
    /// own token cost.
    func pacerAccount(_ id: UUID, state: QuotaAccountState, weight: Double, planner: FailoverPlanner, now: Date) -> SessionPacer.Account {
        let projection = planner.projection(state, now: now)
        let perWeekly = state.sessionPerWeekly ?? FailoverPlanner.defaultSessionPerWeekly
        let ratio = turnCostModel.ratio(for: id)
        let limit = SessionPacer().limit
        return SessionPacer.Account(
            id: id, utilization: projection?.session ?? 0, resetsAt: projection?.sessionReset,
            burnPerHour: max(0, planner.expectedSessionBurn(of: state) - sessionRates.departed(id, now: now) / 1_000_000 * ratio),
            baseWeight: weight,
            weeklyRemaining: projection?.weekly.map { (limit - $0) * perWeekly },
            weeklyResetsAt: projection?.weeklyReset,
            percentPerMillion: ratio,
            hasSessionWindow: state.usage?.fiveHour != nil
        )
    }

    /// The provider's running sessions for `SessionPacer`: paused ones are
    /// left out, as they use nothing, and resumed ones count on the account
    /// they were placed on.
    func pacerSessions(_ provider: AIProviderType, now: Date) -> [SessionPacer.Session] {
        let held = heldSessions(provider)
        let placed = pendingPlacements(provider)
        return sessionRates.entries.compactMap { id, entry in
            guard !held.contains(id) else { return nil }
            return SessionPacer.Session(id: id, account: placed[id] ?? entry.account,
                                        tokensPerHour: sessionRates.tokensPerHour(id, now: now),
                                        contextTokens: entry.contextTokens, lastSeen: entry.lastSeen, cacheLifetime: entry.cacheLifetime,
                                        lastTurnStart: entry.lastTurnStart)
        }
    }

    /// Sessions the current pause still holds.
    func heldSessions(_ provider: AIProviderType) -> Set<String> {
        guard let pause = AgentPauseGate.read(provider) else { return [] }
        return Set(pause.sessions).union(AgentPauseGate.waitingSessions(provider))
            .subtracting(AgentPauseGate.resumedSessions(provider))
    }

    /// Resumed sessions not yet served by the account they were placed on.
    func pendingPlacements(_ provider: AIProviderType) -> [String: UUID] {
        (sessionAdmissions[provider] ?? [:]).compactMapValues { admission in
            guard let entry = sessionRates.entries[admission.session] else { return admission.account }
            let landed = entry.account == admission.account && entry.requests.contains { $0.at > admission.at }
            return landed ? nil : admission.account
        }
    }

    /// The account's access token and expiry, from `claudeCredential`.
    func currentClaudeToken(_ account: Account, minimumLifetime: TimeInterval) async -> (String, Date)? {
        await claudeCredential(account, minimumLifetime: minimumLifetime).flatMap { Self.claudeAccessToken($0) }
    }

    /// The account's Claude Code credential JSON, valid for at least
    /// `minimumLifetime`: the live Keychain copy for the active account,
    /// which needs only a minute, and the stored copy, renewed here when
    /// needed, for the others. Claude Code renews the live copy itself, but
    /// only from a session that reads it; while session slots hold its
    /// access token it is renewed here once it has less than
    /// `liveCredentialSlotLifetime` left, since a slot's session cannot.
    func claudeCredential(_ account: Account, minimumLifetime: TimeInterval) async -> String? {
        if account.isActive, liveCredentialOwner(.claudeCode).map({ $0 == account.id }) ?? true {
            guard let json = keychain.readClaudeToken(), let token = Self.claudeAccessToken(json) else { return nil }
            if Self.liveRenewalIsDue(expiry: token.1, slotsHoldIt: slotCredentialAccounts.contains(account.id), now: Date()),
               let renewed = await renewLiveClaudeCredential(account, current: json) {
                return renewed
            }
            return token.1 > Date().addingTimeInterval(60) ? json : nil
        }
        let stored = keychain.getAccountBackup(forAccountId: account.id.uuidString)?.token
        if let stored, let token = Self.claudeAccessToken(stored), token.1 > Date().addingTimeInterval(minimumLifetime) {
            return stored
        }
        guard await renewSavedCredential(account) == .renewed,
              let renewed = keychain.getAccountBackup(forAccountId: account.id.uuidString)?.token,
              Self.claudeAccessToken(renewed) != nil else { return nil }
        return renewed
    }

    /// Life the active account's live credential must have left while
    /// session slots hold its access token. Claude Code renews it only in
    /// its last five minutes, so this is reached first.
    nonisolated static let liveCredentialSlotLifetime: TimeInterval = 30 * 60

    nonisolated static func liveRenewalIsDue(expiry: Date, slotsHoldIt: Bool, now: Date) -> Bool {
        slotsHoldIt && expiry.timeIntervalSince(now) < liveCredentialSlotLifetime
    }

    /// Renews the active account's live credential and returns it. The live
    /// copy is first saved as the account's stored copy, so the renewal
    /// presents the refresh token now in use; the renewed credential then
    /// replaces the live one in place, where sessions on the CLI's default
    /// credential read it at their next request, and is written to every
    /// slot holding the account's token. A refusal counts against the
    /// account only while the live copy is the one that was presented:
    /// otherwise Claude Code renewed it first, and the next reading has it.
    private func renewLiveClaudeCredential(_ account: Account, current: String) async -> String? {
        if let running = liveCredentialRenewal { return await running.value }
        let task = Task<String?, Never> { @MainActor [weak self] in
            guard let self, !self.isLoggingIn, let module = self.credentialModule(for: .claudeCode),
                  self.claudeService.captureCurrentCredentials(forAccountId: account.id.uuidString, expectedEmail: account.email)
            else { return nil }
            let outcome = await module.renewSavedCopy(account)
            let unchanged = self.keychain.readClaudeToken() == current
            switch outcome {
            case .renewed:
                guard let renewed = self.keychain.getAccountBackup(forAccountId: account.id.uuidString)?.token else { return nil }
                guard (0..<3).contains(where: { _ in self.keychain.writeClaudeToken(renewed) }) else {
                    self.failoverEvents.record(.claudeCode, "\(self.messageName(account))'s renewed sign-in could not be written for Claude Code; re-authenticate it if its sessions ask to sign in.")
                    return nil
                }
                self.liveCredentialDigests[.claudeCode] = Self.credentialDigest(renewed)
                self.noteLiveCredentialOwner(.claudeCode, account: account.id)
                self.clearNeedsSignIn(account)
                await self.reissueSlotCredential(for: account)
                return renewed
            case .rejected:
                if unchanged { self.noteCredentialRejected(account) }
                return nil
            case .unavailable:
                return nil
            }
        }
        liveCredentialRenewal = task
        let result = await task.value
        liveCredentialRenewal = nil
        return result
    }

    /// The access token and expiry in a Claude Code credential JSON.
    nonisolated static func claudeAccessToken(_ json: String) -> (String, Date)? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              let expires = (oauth["expiresAt"] as? NSNumber)?.doubleValue else { return nil }
        return (token, Date(timeIntervalSince1970: expires / 1000))
    }

    // MARK: - Usage and events from the router

    /// Maps each routed account's current credential to its fingerprint,
    /// so usage from sessions that still hold an older account's credential
    /// is attributed exactly.
    ///
    /// The map is kept for a day, across app restarts: a running CLI process
    /// keeps the token it read, which may no longer be any account's
    /// current one, and the router serves it only while it is known.
    private func refreshCredentialFingerprints(now: Date) {
        if let built = credentialFingerprintsBuiltAt, now.timeIntervalSince(built) < 5 * 60 { return }
        if credentialFingerprintsBuiltAt == nil, credentialFingerprintSeen.isEmpty { loadCredentialFingerprints(now: now) }
        credentialFingerprintsBuiltAt = now
        for account in accounts where account.provider == AIProviderType.routedProvider {
            if let token = currentAccessToken(account) {
                let fingerprint = RouterLogic.fingerprint(token)
                credentialFingerprints[fingerprint] = account.id
                credentialFingerprintSeen[fingerprint] = now
            }
        }
        let cutoff = now.addingTimeInterval(-Self.credentialFingerprintLifetime)
        for (fingerprint, seen) in credentialFingerprintSeen where seen < cutoff {
            credentialFingerprintSeen[fingerprint] = nil
            credentialFingerprints[fingerprint] = nil
        }
        let stored = credentialFingerprints.compactMap { fingerprint, account -> [String: Any]? in
            guard let seen = credentialFingerprintSeen[fingerprint] else { return nil }
            return ["fingerprint": fingerprint, "account": account.uuidString, "seen": seen.timeIntervalSince1970]
        }
        UserDefaults.standard.set(stored, forKey: Self.credentialFingerprintsKey)
    }

    static let credentialFingerprintsKey = "app.accountdock.router.fingerprints.v1"
    static let routerEventsAppliedKey = "app.accountdock.router.eventsAppliedThrough.v1"
    static let credentialFingerprintLifetime: TimeInterval = 24 * 60 * 60

    private func loadCredentialFingerprints(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.credentialFingerprintLifetime)
        for entry in UserDefaults.standard.array(forKey: Self.credentialFingerprintsKey) as? [[String: Any]] ?? [] {
            guard let fingerprint = entry["fingerprint"] as? String,
                  let account = (entry["account"] as? String).flatMap(UUID.init(uuidString:)),
                  let seen = (entry["seen"] as? Double).map(Date.init(timeIntervalSince1970:)),
                  seen > cutoff else { continue }
            credentialFingerprints[fingerprint] = account
            credentialFingerprintSeen[fingerprint] = seen
        }
    }

    private func ingestRouterUsage() {
        for observation in RequestRouterController.usageObservations() {
            if let applied = routerUsageApplied[observation.credential], applied >= observation.observedAt { continue }
            guard let accountID = observation.accountID.flatMap(UUID.init(uuidString:))
                    ?? credentialFingerprints[observation.credential] else { continue }
            routerUsageApplied[observation.credential] = observation.observedAt
            if let updatedAt = accountUsageUpdatedAt[accountID], observation.observedAt <= updatedAt { continue }
            let iso = ISO8601DateFormatter()
            let usage = UsageAPIResponse(
                fiveHour: observation.sessionUtilization.map {
                    UsageWindow(utilization: $0, resetsAt: observation.sessionReset.map(iso.string(from:)), windowSeconds: 18_000)
                },
                sevenDay: observation.weeklyUtilization.map {
                    UsageWindow(utilization: $0, resetsAt: observation.weeklyReset.map(iso.string(from:)), windowSeconds: 604_800)
                },
                sevenDayOauthApps: nil, sevenDayOpus: nil, sevenDaySonnet: nil,
                sevenDayCowork: nil, iguanaNecktie: nil, extraUsage: nil
            )
            let merged = accountUsage[accountID].map {
                $0.merged(withNewer: usage, clearingSession: usage.reportsNoSessionWindow)
            } ?? usage
            recordUsage(merged, for: accountID, observedAt: observation.observedAt,
                        confirmsReset: usage.sevenDay != nil)
        }
    }

    private func applyRouterEvents(_ provider: AIProviderType, now: Date) {
        // The first read after launch starts at the top of the file; events
        // applied before the restart are skipped, or their token counts would
        // be learned twice and old failures reported again. With no record
        // yet, only events since launch count.
        let appliedThrough = routerEventOffset == 0
            ? (UserDefaults.standard.object(forKey: Self.routerEventsAppliedKey) as? Date ?? launchedAt) : nil
        let (events, offset) = RequestRouterController.events(after: routerEventOffset)
        routerEventOffset = offset
        if let last = events.last?.at { UserDefaults.standard.set(last, forKey: Self.routerEventsAppliedKey) }
        for event in events {
            if let appliedThrough, event.at <= appliedThrough { continue }
            let accountID = event.accountID.flatMap(UUID.init(uuidString:))
                ?? event.detail.flatMap { credentialFingerprints[$0] }
            if let session = event.session, let accountID, event.kind == .assigned || event.kind == .turnUsage {
                routedSessionSeen[session] = (accountID, event.at)
            }
            switch event.kind {
            case .replayed:
                let until = event.detail.flatMap { ISO8601DateFormatter().date(from: $0) } ?? now.addingTimeInterval(10 * 60)
                if let accountID {
                    routerRefusedUntil[accountID] = until
                } else if let backend = event.backend, backend != RouterBackend.anthropic.id {
                    routeTargetRefusedUntil[backend] = until
                }
                if lastRouterFailureNote.map({ now.timeIntervalSince($0) > 5 * 60 }) ?? true {
                    lastRouterFailureNote = now
                    failoverEvents.record(provider, "A request reached a plan limit\(accountID.flatMap { id in accounts.first { $0.id == id } }.map { " on \(messageName($0))" } ?? ""); the router served it from the next account or the route target.")
                }
            case .backendFailed:
                if lastRouterFailureNote.map({ now.timeIntervalSince($0) > 10 * 60 }) ?? true {
                    lastRouterFailureNote = now
                    failoverEvents.record(provider, "A request routed to \(event.backend ?? "the route target") failed: \(event.detail ?? "unknown error").")
                }
            case .servedByRoute:
                routedStatus[provider]?.turns += 1
            case .turnUsage:
                if let accountID { recordTurnUsage(event, account: accountID) }
                let backend = event.backend ?? RouterBackend.anthropic.id
                recentRouterRequests.append(RecentRouterRequest(
                    at: event.at, session: event.session, backend: backend,
                    context: event.contextTokens ?? 0, output: event.outputTokens ?? 0
                ))
                if backend != RouterBackend.anthropic.id {
                    routeTargetCosts[backend, default: RouteTargetCostModel()]
                        .recordRouted(tokens: (event.contextTokens ?? 0) + (event.outputTokens ?? 0))
                }
            case .assigned:
                break
            case .held:
                let resumeAt = event.detail.flatMap { ISO8601DateFormatter().date(from: $0) }
                if lastRouterHoldNote.map({ now.timeIntervalSince($0) > 10 * 60 }) ?? true {
                    lastRouterHoldNote = now
                    let account = accountID.flatMap { id in accounts.first { $0.id == id } }
                    failoverEvents.record(provider, "A session\(account.map { " on \(messageName($0))" } ?? "") reached the account's limit and waits for its reset\(resumeAt.map { " at \($0.formatted(date: .omitted, time: .shortened))" } ?? ""), which comes before its prompt cache expires.")
                }
            }
        }
        let cutoff = now.addingTimeInterval(-10 * 60)
        routedSessionSeen = routedSessionSeen.filter { $0.value.at > cutoff }
        let demandCutoff = now.addingTimeInterval(-RouteCapacity.demandLookback)
        recentRouterRequests.removeAll { $0.at < demandCutoff }
        let shown = Self.sessionsWithTranscripts(Set(routedSessionSeen.keys), provider: provider)
        var grouped: [UUID: Set<String>] = [:]
        for (session, seen) in routedSessionSeen where shown.contains(session) {
            grouped[seen.account, default: []].insert(session)
        }
        if grouped != routedSessions { routedSessions = grouped }
    }

    /// The sessions the CLI keeps a transcript for, under the directory its
    /// `RequestRouterSupport` names. One-shot requests, such as Claude Code
    /// plugins' background summaries run with `--no-session-persistence`,
    /// have none; they still count toward usage but are not shown as
    /// sessions on the account cards.
    nonisolated static func sessionsWithTranscripts(_ sessions: Set<String>, provider: AIProviderType) -> Set<String> {
        guard !sessions.isEmpty, let router = provider.capabilities.requestRouter else { return [] }
        let projects = URL(fileURLWithPath: (provider.configDirectory as NSString).expandingTildeInPath)
            .appendingPathComponent(router.transcriptDirectory, isDirectory: true)
        let directories = (try? FileManager.default.contentsOfDirectory(
            at: projects, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        return sessions.filter { session in
            directories.contains { FileManager.default.fileExists(atPath: $0.appendingPathComponent("\(session).jsonl").path) }
        }
    }
}
