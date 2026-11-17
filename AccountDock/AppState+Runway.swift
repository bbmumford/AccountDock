import Foundation

/// How long each account's room lasts its sessions at their pace now (its
/// runway, `FailoverPlanner.runway`), and what follows from it each quota
/// cycle: an account whose runway is shorter than a reading and a request
/// round sends its heaviest sessions to accounts with room, or holds them,
/// before the provider refuses them (`shedSessionsShortOfRunway`).
/// A heavy session's burst, many subagents at once or a whole context
/// written afresh, can spend the last tenth of a window in minutes, less
/// than the time between two readings, and its subagents' requests are
/// already on their way when the pause gate would hold it at its next tool
/// call.
extension AppState {
    /// The interval between two readings of an account whose sessions
    /// report one with each response, as Claude Code's status line does.
    nonisolated static let runwayReadInterval: TimeInterval = 60
    /// How long a request sent before a hold takes effect may still run:
    /// the pause gate holds a session at its next tool call, and the
    /// requests its subagents sent before then are already on their way.
    nonisolated static let requestRound: TimeInterval = 60
    /// How short an account's runway may be before it counts as near its
    /// limit for its sessions (`QuotaAccountState.runwayLead`): two readings
    /// apart, so the reading that shows it comes in time, and one request
    /// round, at least `suspensionLead`.
    nonisolated static let runwayLead: TimeInterval = max(suspensionLead, 2 * runwayReadInterval + requestRound)

    // MARK: - Burn

    /// A session's pace for its account's runway: the larger of its decayed
    /// rate and what it sent over the last few minutes
    /// (`SessionRates.recentRate`), its subagents' requests included.
    func burstRate(_ session: String, now: Date) -> Double {
        max(sessionRates.tokensPerHour(session, now: now), sessionRates.recentRate(session, now: now))
    }

    /// Recomputes `sessionsBurn`: for each account, the `burstRate` of every
    /// session running on it (`pacerSessions`: held sessions left out, as
    /// they send nothing, each counted on the account serving it). Run by
    /// `runQuotaCycle` after the transcripts are read, before any rule
    /// weighs an account's room.
    func refreshSessionsBurn(now: Date) {
        var burns: [UUID: Double] = [:]
        for provider in AIProviderType.implementedProviders {
            let own = Set(accounts.filter { $0.provider == provider }.map(\.id))
            for session in pacerSessions(provider, now: now) where own.contains(session.account) {
                let rate = burstRate(session.id, now: now)
                if rate > 0 { burns[session.account, default: 0] += rate }
            }
        }
        sessionsBurn = burns
    }

    // MARK: - Shedding

    /// Which of the sessions on one account leave it, heaviest first, so the
    /// rest last at least `lead` on the room left (`roomPercent`, in window
    /// percent): the account's total pace is `sessions`' rates and `others`,
    /// the pace of its sessions no rule here moves (those on the shared
    /// sign-in), in weighted tokens per hour at `percentPerMillion`. At its
    /// limit (no room) every session that sends anything leaves; one that
    /// sends nothing costs no room and stays. Read by
    /// `shedSessionsShortOfRunway`.
    nonisolated static func runwayShed(_ sessions: [(id: String, tokensPerHour: Double)], others: Double,
                                       roomPercent: Double, percentPerMillion: Double,
                                       lead: TimeInterval) -> [String] {
        func lasts(_ tokensPerHour: Double) -> TimeInterval {
            guard tokensPerHour > 0 else { return .infinity }
            return max(0, roomPercent) / (tokensPerHour / 1_000_000 * percentPerMillion) * 3600
        }
        var remaining = sessions.filter { $0.tokensPerHour > 0 }.sorted {
            $0.tokensPerHour != $1.tokensPerHour ? $0.tokensPerHour > $1.tokensPerHour : $0.id < $1.id
        }
        var total = max(0, others) + remaining.reduce(0) { $0 + $1.tokensPerHour }
        var shed: [String] = []
        while lasts(total) < lead, !remaining.isEmpty {
            let heaviest = remaining.removeFirst()
            shed.append(heaviest.id)
            total -= heaviest.tokensPerHour
        }
        return shed
    }

    /// Sends the heaviest slot sessions off each account whose runway is
    /// shorter than `runwayLead`, or that is at its limit or refused one
    /// (no room), until the rest last that long there (`runwayShed`): each
    /// to the first account with room that carries it for the hour beside
    /// everything the cycle's ledger sent there (`fallbackLane`, at its
    /// arrival rate), through the slot-move path (`requestPauseMoves`); one
    /// mid-turn, or that no account carries, is held at its next tool call
    /// by a pause at a limit listing it (`pinnedHoldPause`), which
    /// `rescopeLimitPause` releases where a fresh reading shows room for it
    /// (`releaseFits`) or moves where one has. Pinned sessions, sessions a
    /// pause or a wait already holds, and a provider whose requests a route
    /// target serves are left out; with pausing off, or while the user's
    /// "Resume all" holds pauses off, sessions only move. Run by
    /// `runQuotaCycle` after the waits are charged and before the slots are
    /// served, so a refusal read this cycle moves or holds its account's
    /// sessions as a short runway does.
    func shedSessionsShortOfRunway(_ provider: AIProviderType, now: Date) {
        guard routedStatus[provider] == nil, sessionSlotsInUse(provider), let slots = SessionSlots(provider) else { return }
        let pausing = pausingProviders.contains(provider) && (pauseOverrideUntil[provider].map { $0 <= now } ?? true)
        let planner = FailoverPlanner(settings: plannerSettings(provider))
        let waiting = Set((sessionWaits[provider] ?? [:]).filter { !$0.value.played }.keys)
        let held = heldSessions(provider).union(waiting)
        let running = slotRebalanceSessions(provider, slots: slots, now: now)
        let candidates = running.filter { !held.contains($0.id) && !sessionPins.isPinned($0.id) }
        guard !candidates.isEmpty else { return }
        var short: [String: (account: UUID, lasts: TimeInterval, percentPerHour: Double)] = [:]
        for (id, group) in Dictionary(grouping: candidates, by: \.account) {
            guard let account = accounts.first(where: { $0.id == id }) else { continue }
            let state = quotaState(for: account, now: now)
            let atLimit = state.refusedAtLimit || refusedUntilReset(id, now: now)
                || planner.servingVerdict(planner.servingView(state), now: now, lead: 0) == .atLimit
            let runway = planner.runway(state, now: now)
            guard atLimit || (runway ?? .infinity) < Self.runwayLead else { continue }
            let room = atLimit ? 0 : (runway ?? 0) * state.sessionsBurnPerHour / 3600
            let rates = group.map { (id: $0.id, tokensPerHour: burstRate($0.id, now: now)) }
            let others = (sessionsBurn[id] ?? 0) - rates.reduce(0) { $0 + $1.tokensPerHour }
            for session in Self.runwayShed(rates, others: others, roomPercent: room,
                                           percentPerMillion: state.percentPerMillion, lead: Self.runwayLead) {
                short[session] = (id, atLimit ? 0 : runway ?? 0, state.sessionsBurnPerHour)
            }
        }
        guard !short.isEmpty else { return }
        let policy = failoverConfig.policy(for: provider)
        let outlook = capacityOutlookAccounts(provider, now: now)
        let lanes = accounts.filter { account in
            account.provider == provider && !policy.excludedAccountIDs.contains(account.id) && !needsSignIn(account)
                && !short.values.contains { $0.account == account.id }
                && freshForArrivals(account.id, now: now)
                && planner.servingVerdict(planner.servingView(quotaState(for: account, now: now)), now: now,
                                          lead: Self.suspensionLead) == .canServe
        }.map(\.id).sorted { lhs, rhs in
            let left = outlook.first { $0.id == lhs }?.pacer.utilization ?? 100
            let right = outlook.first { $0.id == rhs }?.pacer.utilization ?? 100
            return left != right ? left < right : lhs.uuidString < rhs.uuidString
        }
        let pacer = SessionPacer(moveCostFactor: provider.capabilities.sessionMoveCostFactor)
        var ledger = laneLedger(provider, now: now)
        var moves: [String: UUID] = [:]
        var holds: [String] = []
        let leaving = candidates.filter { short[$0.id] != nil }.sorted {
            let left = burstRate($0.id, now: now), right = burstRate($1.id, now: now)
            return left != right ? left > right : $0.id < $1.id
        }
        for session in leaving {
            guard let from = short[session.id]?.account else { continue }
            if session.movable,
               let lane = Self.fallbackLane(arriving(session), from: from, candidates: lanes, usable: { _ in true },
                                            running: running, accounts: outlook, ledger: ledger, now: now, pacer: pacer) {
                moves[session.id] = lane.lane
                ledger.charge(lane.charge)
            } else if pausing {
                holds.append(session.id)
            }
        }
        laneLedgers[provider] = ledger
        requestPauseMoves(provider, moves)
        let existing = AgentPauseGate.read(provider)
        let resumed = AgentPauseGate.resumedSessions(provider)
        let due = holds.filter { !(existing?.sessions.contains($0) ?? false) && !resumed.contains($0) }.sorted()
        guard let pause = Self.pinnedHoldPause(existing: existing, adding: due, at: now,
                                               reason: "an account's room lasts its sessions less than a reading and a request round")
        else { return }
        AgentPauseGate.write(pause, for: provider)
        refreshPauseStatus(provider)
        for id in due {
            guard let entry = short[id] else { continue }
            let name = liveSession(id).map { Self.eventName(of: $0.1) } ?? "session \(id.prefix(8))"
            let on = accounts.first { $0.id == entry.account }.map { messageName($0) } ?? "its account"
            failoverEvents.record(provider, Self.runwayHoldEvent(session: name, account: on, lasts: entry.lasts,
                                                                 percentPerHour: entry.percentPerHour))
        }
    }

    /// The event recording that a session waits because its account's
    /// room would not last it until the next reading and a request round.
    nonisolated static func runwayHoldEvent(session: String, account: String, lasts: TimeInterval,
                                            percentPerHour: Double) -> String {
        guard lasts > 0 else {
            return "Paused \(session): \(account) is at its limit and no account with room carries it; it continues when one has room for it."
        }
        let minutes = max(1, Int((lasts / 60).rounded()))
        let lead = Int((runwayLead / 60).rounded())
        return "Paused \(session) on \(account): at its sessions' pace now (about \(Int(percentPerHour.rounded()))% of its window an hour) its room lasts about \(minutes) min, less than the \(lead) min a reading and a request round take, and no account with room carries it; it continues when one has room for it."
    }
}
