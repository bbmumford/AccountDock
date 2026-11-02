import Foundation

/// Learned models that sharpen failover decisions: the quota cost of a
/// request and of a switch, and forecast demand by hour of the week.
extension AppState {
    private static let learningKey = "app.accountdock.learning.v1"

    private struct StoredLearning: Codable {
        var turnCost: TurnCostModel
        var forecasts: [AIProviderType: DemandForecast]
        var routeTargets: [String: RouteTargetCostModel]?
        var sessionRates: SessionRates?
        var cacheExtension: CacheExtensionLedger?
    }

    func loadLearning() {
        guard let data = UserDefaults.standard.data(forKey: Self.learningKey),
              let stored = try? JSONDecoder().decode(StoredLearning.self, from: data) else { return }
        turnCostModel = stored.turnCost
        demandForecasts = stored.forecasts
        routeTargetCosts = stored.routeTargets ?? [:]
        sessionRates = stored.sessionRates ?? SessionRates()
        cacheExtension = stored.cacheExtension ?? CacheExtensionLedger()
    }

    /// Saved at most every five minutes; losing the latest minutes of
    /// learning on a crash only slows convergence.
    func saveLearningIfDue(now: Date = Date()) {
        if let saved = learningSavedAt, now.timeIntervalSince(saved) < 5 * 60 { return }
        learningSavedAt = now
        let stored = StoredLearning(turnCost: turnCostModel, forecasts: demandForecasts, routeTargets: routeTargetCosts,
                                    sessionRates: sessionRates, cacheExtension: cacheExtension)
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: Self.learningKey)
        }
    }

    /// Learns a request a session's transcript recorded, as the router's
    /// own record of a request is learned.
    func recordTurnUsage(_ request: TranscriptRequest, account: UUID) {
        turnCostModel.recordRequest(
            session: request.session, account: account, context: request.contextTokens,
            cacheWrite: request.cacheWriteTokens, output: request.outputTokens,
            cacheWriteLong: request.cacheWriteLongTokens, at: request.at
        )
        sessionRates.record(
            session: request.session, account: account, context: request.contextTokens,
            cacheWrite: request.cacheWriteTokens, output: request.outputTokens,
            cacheWriteLong: request.cacheWriteLongTokens, cacheLifetime: request.cacheLifetime,
            startsTurn: request.startsTurn, at: request.at
        )
    }

    func recordTurnUsage(_ event: RouterEvent, account: UUID) {
        turnCostModel.recordRequest(
            session: event.session,
            account: account,
            context: event.contextTokens ?? 0,
            cacheWrite: event.cacheWriteTokens ?? 0,
            output: event.outputTokens ?? 0,
            cacheWriteLong: event.cacheWriteLongTokens ?? 0,
            at: event.at
        )
        if event.cacheExtended == true {
            let previous = event.session.flatMap { sessionRates.entries[$0]?.lastSeen }
            cacheExtension.record(event, after: previous)
        }
        sessionRates.record(
            session: event.session, account: account, context: event.contextTokens ?? 0,
            cacheWrite: event.cacheWriteTokens ?? 0, output: event.outputTokens ?? 0,
            cacheWriteLong: event.cacheWriteLongTokens ?? 0,
            cacheLifetime: event.cacheLifetime.map(TimeInterval.init), startsTurn: event.startsTurn, at: event.at
        )
    }

    /// Feeds a new reading into the request-cost and demand models.
    func learnFromReading(_ usage: UsageAPIResponse, previous: UsageAPIResponse?, account: Account, at date: Date) {
        if account.isActive, let session = usage.fiveHour?.utilization {
            for target in RouteTarget.all where target.provider == account.provider {
                routeTargetCosts[target.id, default: RouteTargetCostModel()].recordReading(session: session)
            }
        }
        if learnsRequestCost(account.provider), let session = usage.fiveHour?.utilization {
            turnCostModel.recordReading(account: account.id, session: session)
        }
        guard let weekly = usage.sevenDay?.utilization, let before = previous?.sevenDay?.utilization else { return }
        let sameWindow = (usage.sevenDay?.resetsAtDate).flatMap { new in
            (previous?.sevenDay?.resetsAtDate).map { abs($0.timeIntervalSince(new)) < 10 * 60 }
        } ?? true
        guard sameWindow, weekly > before else { return }
        demandForecasts[account.provider, default: DemandForecast()].record(weeklyRise: weekly - before, at: date)
    }

    /// Whether the provider's per-request cost is learned: the router reports
    /// each request's tokens for the provider it serves.
    func learnsRequestCost(_ provider: AIProviderType) -> Bool {
        provider == AIProviderType.routedProvider
    }

    /// Session percent a switch of the active account costs its destination.
    /// Sessions the router serves from their own accounts do not move.
    func switchCostPercent(_ provider: AIProviderType, now: Date = Date()) -> Double {
        guard learnsRequestCost(provider) else { return 0 }
        if failoverConfig.policy(for: provider).distributeSessions, routerInUse { return 0 }
        return min(25, turnCostModel.switchCost(sessionsOn: nil, now: now))
    }

    /// Session percent the provider's requests already under way may still
    /// use: one expected request for every session the router saw in the
    /// last three minutes, or for every session mid-turn, at the learned
    /// request cost or the provider's default.
    func inFlightReservePercent(_ provider: AIProviderType, now: Date = Date()) -> Double {
        let learned = learnsRequestCost(provider)
        let measured = learned
            ? turnCostModel.sessions(activeSince: now.addingTimeInterval(-3 * 60))
                .reduce(0) { $0 + turnCostModel.expectedRequestCost(session: $1) }
            : 0
        let perRequest = learned
            ? turnCostModel.expectedRequestCost(session: "")
            : provider.capabilities.defaultRequestCostPercent
        let counted = Double(workingSessionCount(provider)) * perRequest
        return min(10, max(measured, counted))
    }

    /// Forecast demand for the planner, once a day of hours has been seen.
    func demandFunction(_ provider: AIProviderType) -> (@Sendable (Date) -> Double)? {
        guard let forecast = demandForecasts[provider], forecast.isTrained else { return nil }
        return { forecast.rate(at: $0) }
    }

    /// Whether the account may serve past its plan limit on extra usage.
    func extraUsageAvailable(_ account: Account) -> Bool {
        guard let limit = failoverConfig.policy(for: account.provider).extraUsageMonthlyLimit,
              let extra = accountUsage[account.id]?.extraUsage, extra.isEnabled == true else { return false }
        let spent = (extra.usedCredits ?? 0) / pow(10, Double(extra.decimalPlaces ?? 2))
        let accountLimit = extra.monthlyLimit.map { $0 / pow(10, Double(extra.decimalPlaces ?? 2)) } ?? .infinity
        return spent < min(limit, accountLimit)
    }

    /// Where a provider stands at the active account's current pace: when
    /// the active account reaches a limit and when every included account is
    /// used up, which is when sessions are paused. Shown under the provider
    /// heading beside the week outlook, which plays the usual pace instead.
    struct PaceOutlook: Equatable {
        /// The active account's name as the usage view shows it.
        var account: String
        /// When the active account can take no more work, and the limit
        /// that stops it.
        var runsOutAt: Date?
        var limit: String?
        /// When the 5-hour window the active account fills resets, so it has
        /// room again; nil when the long window stops it.
        var resumesAt: Date?
        /// Whether that limit falls in a later 5-hour window than the one
        /// running now.
        var afterCurrentWindow = false
        /// When no included account has room left; nil when that is beyond
        /// the simulated week.
        var holdAt: Date?
        /// Whether AccountDock pauses the provider's sessions then; otherwise
        /// they stop at the limit themselves.
        var pausesSessions = true
    }

    /// Below this pace, in long-window percent per hour, the active account
    /// counts as idle and no estimate is shown.
    static let minimumOutlookPace = 0.05

    /// The provider's `PaceOutlook`, from the same simulation as the week
    /// outlook with demand held at the active account's current burn.
    func paceOutlook(_ provider: AIProviderType, now: Date = Date()) -> PaceOutlook? {
        guard let active = activeAccount(for: provider) else { return nil }
        let policy = failoverConfig.policy(for: provider)
        let planner = FailoverPlanner(settings: plannerSettings(provider))
        let current = quotaState(for: active, now: now)
        let perWeekly = max(1, current.sessionPerWeekly ?? FailoverPlanner.defaultSessionPerWeekly)
        let pace = max(current.weeklyBurnPerHour, current.sessionBurnPerHour / perWeekly)
        guard pace >= Self.minimumOutlookPace, let activeAccount = planner.simulatorAccount(current, now: now) else { return nil }
        var simulator = QuotaSimulator()
        simulator.step = 5 * 60
        let demand: (Date) -> Double = { _ in pace }
        let alone = simulator.run(accounts: [activeAccount], strategy: .earliestDeadline, demand: demand, start: now)
        let included = accounts.filter { $0.provider == provider && !policy.excludedAccountIDs.contains($0.id) }
            .map { quotaState(for: $0, now: now) }
            .compactMap { planner.simulatorAccount($0, now: now) }
        let all = simulator.run(accounts: included, strategy: .preferring([active.id]), demand: demand, start: now)

        var limit: String?
        var resumesAt: Date?
        var afterCurrentWindow = false
        if let runsOut = alone.firstShortfall {
            // The long window stops the account when it fills before its
            // reset; otherwise the 5-hour window does.
            let hours = runsOut.timeIntervalSince(now) / 3600
            let weeklyResetsFirst = activeAccount.weeklyReset.map { $0 <= runsOut } ?? false
            let capabilities = provider.capabilities
            limit = !weeklyResetsFirst && activeAccount.weekly + pace * hours >= 100 - FailoverPlanner.minimumUsableHeadroom
                ? capabilities.weeklyQuotaLabel.lowercased()
                : "\(capabilities.sessionQuotaLabel.lowercased()) limit"
            if limit != capabilities.weeklyQuotaLabel.lowercased() {
                // Demand is held steady, so each later window opens at the
                // previous one's reset.
                var end = activeAccount.sessionReset ?? now.addingTimeInterval(QuotaSimulator.sessionWindow)
                afterCurrentWindow = end <= runsOut
                while end <= runsOut { end = end.addingTimeInterval(QuotaSimulator.sessionWindow) }
                resumesAt = end
            }
        }
        return PaceOutlook(
            account: messageName(active),
            runsOutAt: alone.firstShortfall,
            limit: limit,
            resumesAt: resumesAt,
            afterCurrentWindow: afterCurrentWindow,
            holdAt: all.firstShortfall,
            pausesSessions: pausingProviders.contains(provider)
        )
    }

    /// The coming week under the current strategy, for the usage view.
    func weekOutlook(_ provider: AIProviderType, now: Date = Date()) -> QuotaSimulator.Outcome? {
        guard let demand = demandFunction(provider) else { return nil }
        let policy = failoverConfig.policy(for: provider)
        let planner = FailoverPlanner(settings: plannerSettings(provider))
        let states = accounts.filter { $0.provider == provider && !policy.excludedAccountIDs.contains($0.id) }
            .map { quotaState(for: $0, now: now) }
        let simulated = states.compactMap { planner.simulatorAccount($0, now: now) }
        guard !simulated.isEmpty else { return nil }
        let strategy: QuotaSimulator.Strategy = policy.distributeSessions && (routerInUse || sessionSlotsInUse) ? .parallel : .earliestDeadline
        return QuotaSimulator().run(accounts: simulated, strategy: strategy, demand: demand, start: now)
    }
}
