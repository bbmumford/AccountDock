import Foundation

/// Moves running slot sessions between accounts so they last as long as
/// possible (`SessionPacer.rebalance`): on request from settings, the usage
/// tab or the requests interface, and, with the policy's
/// `rebalanceAutomatically`, from the quota cycle.
extension AppState {
    /// One planned move, for display.
    struct RebalanceMove: Equatable, Sendable {
        let session: String
        let from: UUID
        let to: UUID
    }

    /// What a rebalance would do, or did.
    struct RebalancePreview: Equatable, Sendable {
        var moves: [RebalanceMove] = []
        /// When the first account reaches a limit, before and after; nil
        /// when none does before its windows reset.
        var earliestRunOutBefore: Date?
        var earliestRunOutAfter: Date?
        /// One line per move: the session (`sessionSummary`), from → to.
        var lines: [String] = []
        /// The room kept on the account the sessions on the shared sign-in
        /// move to (`AppState.sharedGroupNote`); nil while they stay.
        var sharedNote: String?

        /// How the earliest run-out changes, in words.
        var outcome: String {
            func when(_ date: Date?) -> String {
                date.map { UsageFormat.clock($0) } ?? "not before the resets"
            }
            guard !moves.isEmpty else {
                return "No move would make the sessions last longer; the first account runs out \(when(earliestRunOutBefore))."
            }
            return "\(moves.count) session(s) move. The first account runs out \(when(earliestRunOutAfter)) instead of \(when(earliestRunOutBefore))."
        }
    }

    /// Whether the provider's sessions can be rebalanced: they run in
    /// one-session slots (`ProviderCapabilities.sessionIsolation`) and the
    /// launcher is serving them.
    func rebalanceAvailable(_ provider: AIProviderType) -> Bool {
        sessionSlotsInUse(provider)
    }

    /// The plan for the provider's running slot sessions now.
    func rebalancePreview(_ provider: AIProviderType, now: Date = Date()) -> RebalancePreview {
        guard rebalanceAvailable(provider), let slots = SessionSlots(provider) else { return RebalancePreview() }
        let (pacerAccounts, destinations) = rebalanceAccounts(provider, now: now)
        let pacer = SessionPacer(moveCostFactor: provider.capabilities.sessionMoveCostFactor)
        let sessions = slotRebalanceSessions(provider, slots: slots, now: now)
        // The sessions on the shared sign-in are none of these and never
        // move; they count where the active account is and will be.
        let shared = sharedGroup(provider, sessions: pacerSessions(provider, now: now), now: now)?.group
        let plan = pacer.rebalance(accounts: pacerAccounts, sessions: sessions, destinations: destinations, now: now,
                                   sharedGroup: shared)
        let from = sessions.reduce(into: [String: UUID]()) { $0[$1.id] = $1.account }
        let moves = plan.moves.compactMap { id, to in from[id].map { RebalanceMove(session: id, from: $0, to: to) } }
            .sorted { $0.session < $1.session }
        func name(_ id: UUID) -> String { accounts.first { $0.id == id }.map { messageName($0) } ?? "an account" }
        return RebalancePreview(
            moves: moves, earliestRunOutBefore: plan.earliestRunOutBefore, earliestRunOutAfter: plan.earliestRunOutAfter,
            lines: moves.map { "\(sessionSummary([$0.session], now: now)): \(name($0.from)) → \(name($0.to))" },
            sharedNote: sharedGroupNote(shared)
        )
    }

    /// The provider's accounts as rebalancing weighs them: each one failover
    /// includes and that needs no sign-in, judged by its whole allowance,
    /// and of those the destinations, which can serve or are near their
    /// limit. Read by `rebalancePreview` and by `balancingChoice`, which
    /// asks where balancing would place one session.
    func rebalanceAccounts(_ provider: AIProviderType, now: Date) -> (accounts: [SessionPacer.Account], destinations: Set<UUID>) {
        let policy = failoverConfig.policy(for: provider)
        let planner = FailoverPlanner(settings: plannerSettings(provider))
        var pacerAccounts: [SessionPacer.Account] = []
        var destinations = Set<UUID>()
        for account in accounts
        where account.provider == provider && !policy.excludedAccountIDs.contains(account.id) && !needsSignIn(account) {
            let state = quotaState(for: account, now: now, wholeAllowance: true)
            pacerAccounts.append(pacerAccount(account.id, state: state, weight: 1, planner: planner, now: now))
            switch planner.servingVerdict(state, now: now, lead: 0) {
            case .canServe, .nearLimit: destinations.insert(account.id)
            case .atLimit, .ineligible: break
            }
        }
        return (pacerAccounts, destinations)
    }

    /// The provider's running slot sessions as `SessionPacer.rebalance` and
    /// `SessionPacer.place` take them: each on the account its slot serves,
    /// at its rate over its last hour (at least its current rate, and
    /// `defaultSessionRate` with no history), movable unless mid-turn or
    /// pinned.
    func slotRebalanceSessions(_ provider: AIProviderType, slots: SessionSlots,
                               now: Date) -> [SessionPacer.RebalanceSession] {
        let pacer = SessionPacer()
        let root = slots.sessionRoot.path + "/"
        return (liveSessions[provider] ?? []).compactMap { session -> SessionPacer.RebalanceSession? in
            guard let pid = session.processID, let directory = slotDirectoryByProcess[pid], directory.hasPrefix(root),
                  let account = slotDirectoryServing[directory] else { return nil }
            let id = session.sessionID
            let entry = sessionRates.entries[id]
            let measured = max(sessionRates.tokensPerHour(id, now: now), sessionRates.demand(id, until: now) ?? 0)
            let model = sessionModel(id, now: now)
            let pacing = SessionPacer.Session(id: id, account: account, tokensPerHour: measured,
                                              contextTokens: entry?.contextTokens ?? 0, lastSeen: entry?.lastSeen ?? now,
                                              cacheLifetime: entry?.cacheLifetime, lastTurnStart: entry?.lastTurnStart, model: model)
            return SessionPacer.RebalanceSession(
                id: id, account: account, tokensPerHour: measured > 0 ? measured : SessionPacer.defaultSessionRate,
                contextTokens: entry?.contextTokens ?? 0, model: model,
                movable: !session.isWorking && pacer.movable(pacing, now: now) && !sessionPins.isPinned(id)
            )
        }
    }

    /// Where `serveSessionSlots` sends each slot session whose account can
    /// no longer serve it (`SessionPacer.place`), among the pool's accounts
    /// that can: those taking new sessions, or every one that can serve
    /// when none does. Pinned sessions stay where they are pinned and are
    /// left out.
    func strandedPlacements(_ provider: AIProviderType, slots: SessionSlots, members: [RouterPoolMember],
                            now: Date) -> [String: UUID] {
        let planner = FailoverPlanner(settings: plannerSettings(provider))
        let running = slotRebalanceSessions(provider, slots: slots, now: now)
        let stranded = running.filter { session in
            !sessionPins.isPinned(session.id)
                && accountCannotServe(session.account, provider: provider, planner: planner, now: now, wholeAllowance: true)
        }
        guard !stranded.isEmpty else { return [:] }
        let serving = members.filter { member in
            UUID(uuidString: member.accountID).map {
                !accountCannotServe($0, provider: provider, planner: planner, now: now, wholeAllowance: true)
            } ?? false
        }
        let open = serving.filter { $0.weight > 0 }
        let chosen = open.isEmpty ? serving : open
        var pacerAccounts: [SessionPacer.Account] = []
        for member in chosen {
            guard let id = UUID(uuidString: member.accountID),
                  let account = accounts.first(where: { $0.id == id }) else { continue }
            let state = quotaState(for: account, now: now, wholeAllowance: true)
            pacerAccounts.append(pacerAccount(id, state: state, weight: member.weight, planner: planner, now: now))
        }
        let strandedIDs = Set(stranded.map(\.id))
        let shared = sharedGroup(provider, sessions: pacerSessions(provider, now: now), now: now)?.group
        return SessionPacer(moveCostFactor: provider.capabilities.sessionMoveCostFactor).place(stranded, accounts: pacerAccounts, running: running.filter { !strandedIDs.contains($0.id) },
                                    destinations: Set(pacerAccounts.map(\.id)), now: now, sharedGroup: shared)
    }

    /// Makes the moves of `rebalancePreview` through the slot-move path
    /// (`requestedSlotMoves`, honoured by `serveSessionSlots`, which records
    /// each move). Returns the plan it made.
    @discardableResult
    func applyRebalance(_ provider: AIProviderType, now: Date = Date()) async -> RebalancePreview {
        let preview = rebalancePreview(provider, now: now)
        guard !preview.moves.isEmpty else { return preview }
        for move in preview.moves { requestedSlotMoves[move.session] = move.to }
        lastRebalance[provider] = now
        failoverEvents.record(provider, "Rebalancing sessions: \(preview.outcome)"
                              + (preview.sharedNote.map { " " + $0 } ?? ""))
        await maintainSessionSlots(now: now)
        return preview
    }

    /// How much later a rebalance must make the earliest run-out to be
    /// made without being asked for.
    nonisolated static let automaticRebalanceGain: TimeInterval = 60 * 60

    /// Whether `preview` is worth making unasked: it moves something and
    /// makes the earliest run-out more than `automaticRebalanceGain` later.
    nonisolated static func rebalanceIsWorthIt(_ preview: RebalancePreview) -> Bool {
        guard !preview.moves.isEmpty, let before = preview.earliestRunOutBefore else { return false }
        guard let after = preview.earliestRunOutAfter else { return true }
        return after.timeIntervalSince(before) > automaticRebalanceGain
    }

    /// Rebalances each provider whose policy asks for it, at most once per
    /// `balanceMoveInterval` and only when it is worth it, so caches are not
    /// rewritten for little. Runs on every quota cycle after
    /// `maintainSessionSlots`.
    func rebalanceAutomaticallyIfDue(now: Date = Date()) async {
        for provider in AIProviderType.implementedProviders
        where failoverConfig.policy(for: provider).rebalanceAutomatically && rebalanceAvailable(provider) {
            if let last = lastRebalance[provider], now.timeIntervalSince(last) < Self.balanceMoveInterval { continue }
            guard Self.rebalanceIsWorthIt(rebalancePreview(provider, now: now)) else { continue }
            await applyRebalance(provider, now: now)
        }
    }
}
