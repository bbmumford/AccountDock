import Foundation

private let paceLog = FileLog("Pacing")

/// "Pace sessions to the resets" (`ProviderFailoverPolicy.paceToResets`):
/// every quota cycle, the provider's total use is held to what its accounts
/// carry until capacity materially returns (`SustainablePace.target`), by
/// holding the lowest-ranked sessions at their next tool call or turn and
/// releasing them as room allows. A held session is one more wait
/// (`SessionWait.Reason.paced`) a pause at a limit lists, so the per-account
/// pause machinery holds it; only this rule ends it.
extension AppState {
    /// How soon a check that found nothing to pace runs again: the target's
    /// projections are too many for every cycle, and a pace only matters
    /// over hours.
    nonisolated static let pacingRecheck: TimeInterval = 5 * 60

    /// Runs every quota cycle after the waits are settled
    /// (`holdSessionsForImminentReset`, `holdSharedSessionsOnStayingAccount`)
    /// and before the ledger charges them and the slots are served. With
    /// the policy on, pausing at the limit on (the gate is what holds a
    /// session), no route target serving the provider and no "Resume all"
    /// in force (`pauseOverrideUntil`), it decides which sessions run
    /// (`SustainablePace.decide`, with a fresh target only when the running
    /// set may change: `needsTarget`), lists the newly held ones in the
    /// provider's pause (`holdAtLimit`, for `SustainablePace.holdReason`)
    /// and lets the released ones go (`releasePacedHolds`). Otherwise, or
    /// when nothing needs pacing, every session it held goes on.
    func paceSessionsToResets(_ provider: AIProviderType, now: Date = Date()) {
        prunePriorities(provider, now: now)
        settlePacedPlays(provider, now: now)
        let policy = failoverConfig.policy(for: provider)
        guard policy.paceToResets else {
            // Turned on again, it looks for a target at once.
            pacingCheckedAt[provider] = nil
            return endPacing(provider, reason: "pacing to the resets is off")
        }
        guard pausingProviders.contains(provider) else {
            return endPacing(provider, reason: "pausing at the limit is off, and the pause gate is what holds them")
        }
        guard routedStatus[provider] == nil else {
            return endPacing(provider, reason: "a route target serves the requests")
        }
        guard pauseOverrideUntil[provider].map({ $0 <= now }) ?? true else {
            return endPacing(provider, reason: "you resumed every session")
        }
        guard let sessions = capacityOutlookSessions(provider, now: now) else {
            return endPacing(provider, reason: "no session's rate is measured yet")
        }
        let candidates = pacingCandidates(provider, sessions: sessions, now: now)
        let previous = pacedDecisions[provider]
        var target = previous?.target
        if SustainablePace.needsTarget(previous: previous, candidates: candidates, now: now) {
            if previous == nil, let checked = pacingCheckedAt[provider], now.timeIntervalSince(checked) < Self.pacingRecheck {
                return
            }
            pacingCheckedAt[provider] = now
            let accounts = capacityOutlookAccounts(provider, now: now)
            let flatOut = sessions.reduce(0) { $0 + max(0, $1.tokensPerHour) }
            target = SustainablePace.target(
                accounts: accounts, flatOut: flatOut, now: now,
                pacer: SessionPacer(moveCostFactor: provider.capabilities.sessionMoveCostFactor))
            guard let target else {
                let paused = CapacityOutlook.run(accounts, demand: .init(tokensPerHour: flatOut), now: now,
                                                 step: SustainablePace.searchStep, horizon: 3600, reach: .firstPause)
                    .allPausedAt.map { $0 <= now.addingTimeInterval(60) } ?? false
                return endPacing(provider, reason: paused
                    ? "no account has room now, so the limit pauses hold sessions until one has"
                    : "the accounts now carry every session at its rate until capacity returns")
            }
            logPacingInputs(provider, target: target, accounts: accounts, candidates: candidates, now: now)
        }
        guard let target else { return }
        let decision = SustainablePace.decide(previous: previous, candidates: candidates, target: target, now: now)
        pacedDecisions[provider] = decision
        applyPacing(provider, held: decision.held, until: target.until, now: now)
        guard decision.held != (previous?.held ?? []) else { return }
        let summary = SustainablePace.summary(candidates, held: decision.held, target: target, flatOutResume: nil)
        let event = SustainablePace.event(summary, now: now)
        paceLog.info("\(provider.rawValue): \(event)")
        guard pacedEventNoted[provider] != event else { return }
        pacedEventNoted[provider] = event
        failoverEvents.record(provider, event)
    }

    /// The provider's live sessions as pacing weighs them: each at the
    /// rate the Outlook counts it (`capacityOutlookSessions`), fixed when
    /// pinned, marked priority, played within `SustainablePace.playLasts`
    /// or started before the gate was installed, and with the user's last
    /// prompt (`AgentSession.humanPromptAt`) or play. Sessions another rule
    /// holds (the user's own pause, a pause at a limit, a wait for a reset
    /// or a lane) are left out: they use nothing while held, and those
    /// rules release them.
    func pacingCandidates(_ provider: AIProviderType, sessions: [CapacityOutlook.Session],
                          now: Date) -> [SustainablePace.Candidate] {
        let live = liveSessions[provider] ?? []
        let pause = AgentPauseGate.read(provider)
        let userHeld = pause?.userHeld(running: Set(live.map(\.sessionID))) ?? []
        let paced = pacedSessions(provider)
        let otherHolds = heldSessions(provider).subtracting(paced)
            .union((sessionWaits[provider] ?? [:]).filter { $0.value.reason != .paced && !$0.value.played }.keys)
        let ungated = Set(sessionsWithoutGate(provider).map(\.sessionID))
        let records = AgentSessions.records(provider)
        let counted = sessions.reduce(into: [String: CapacityOutlook.Session]()) { $0[$1.id] = $1 }
        return live.compactMap { session in
            let id = session.sessionID
            guard !userHeld.contains(id), !otherHolds.contains(id), let measured = counted[id] else { return nil }
            let played = pacedPlays[id].map { now.timeIntervalSince($0) < SustainablePace.playLasts } ?? false
            let fixed: SustainablePace.Candidate.Fixed? = sessionPins.isPinned(id) ? .pinned
                : sessionPriorities.isPriority(id) ? .priority
                : played ? .played
                : ungated.contains(id) ? .cannotHold : nil
            let prompt = [session.humanPromptAt, records[id]?.humanPromptAt, pacedPlays[id]].compactMap { $0 }.max()
            return SustainablePace.Candidate(id: id, label: measured.label, tokensPerHour: measured.tokensPerHour,
                                             fixed: fixed, lastPrompt: prompt)
        }
    }

    /// Holds `held` and lets every other session pacing held go on: each
    /// held one is a wait on the account it runs on (its slot's, or the
    /// active account for one on the shared sign-in) until `until`, listed
    /// in the provider's pause (`holdAtLimit`), which holds it at its next
    /// tool call and new turn; each released one leaves the pause
    /// (`releasePacedHolds`).
    func applyPacing(_ provider: AIProviderType, held: Set<String>, until: Date, now: Date) {
        let before = pacedSessions(provider)
        var waits = sessionWaits[provider] ?? [:]
        for id in before.subtracting(held) { waits[id] = nil }
        let active = activeAccount(for: provider)?.id
        var holding: [String] = []
        for id in held.sorted() {
            if waits[id]?.reason == .paced {
                waits[id]?.until = until
                holding.append(id)
                continue
            }
            guard waits[id] == nil else { continue }
            let slot = slotAccount(forSession: id, provider: provider)
            guard let account = slot ?? active else { continue }
            waits[id] = SessionWait(account: account, reason: .paced, until: until, since: now, shared: slot == nil)
            holding.append(id)
        }
        sessionWaits[provider] = waits.isEmpty ? nil : waits
        // Listed again each cycle, as a pause ending around them (a reset,
        // the user's "Resume all") lets them go.
        if !holding.isEmpty { _ = holdAtLimit(provider, holding, reason: SustainablePace.holdReason, now: now) }
        releasePacedHolds(provider, before.subtracting(held))
    }

    /// Takes `sessions` out of the provider's pause, so the gate lets them
    /// go at their next poll. A pause left holding nothing ends
    /// (`endPause`), unless it holds every new turn, the user took it or it
    /// names one account, which end by their own rules.
    func releasePacedHolds(_ provider: AIProviderType, _ sessions: Set<String>) {
        guard !sessions.isEmpty, var pause = AgentPauseGate.read(provider),
              !Set(pause.sessions).isDisjoint(with: sessions) else { return }
        let remaining = pause.sessions.filter { !sessions.contains($0) }
        if remaining.isEmpty, pause.holdsNewTurns != true, pause.manual != true, pause.account == nil {
            endPause(provider)
        } else {
            pause.sessions = remaining
            AgentPauseGate.write(pause, for: provider)
            refreshPauseStatus(provider)
        }
    }

    /// Lets every session pacing holds go on, records why once, and forgets
    /// the decision.
    func endPacing(_ provider: AIProviderType, reason: String) {
        let held = pacedSessions(provider)
        pacedDecisions[provider] = nil
        guard !held.isEmpty else { return }
        sessionWaits[provider] = sessionWaits[provider]?.filter { $0.value.reason != .paced }
        if sessionWaits[provider]?.isEmpty == true { sessionWaits[provider] = nil }
        releasePacedHolds(provider, held)
        let event = SustainablePace.releaseEvent(count: held.count, reason: reason)
        pacedEventNoted[provider] = event
        failoverEvents.record(provider, event)
        paceLog.info("\(provider.rawValue): \(event)")
    }

    /// A paced session the user played (`SessionWait.played`, set by
    /// `resumeSession`, which also records the play in `pacedPlays`) leaves
    /// pacing's waits and the pause: it runs as a fixed session for
    /// `SustainablePace.playLasts`, and the next decision chooses the others
    /// around it. Plays older than that and `SustainablePace.interactionWindow`,
    /// or of sessions no longer running, are forgotten.
    func settlePacedPlays(_ provider: AIProviderType, now: Date) {
        let live = Set((liveSessions[provider] ?? []).map(\.sessionID))
        let played = Set((sessionWaits[provider] ?? [:]).filter { $0.value.reason == .paced && $0.value.played }.keys)
        for id in played {
            if pacedPlays[id] == nil { pacedPlays[id] = now }
            sessionWaits[provider]?[id] = nil
        }
        if sessionWaits[provider]?.isEmpty == true { sessionWaits[provider] = nil }
        releasePacedHolds(provider, played)
        pacedPlays = pacedPlays.filter { id, at in
            now.timeIntervalSince(at) < max(SustainablePace.interactionWindow, SustainablePace.playLasts)
                && (live.contains(id) || liveSession(id).map { $0.0 != provider } ?? false)
        }
    }

    /// Marks or unmarks a running session as priority (the star on the
    /// Sessions page and in an account card's session list), and records it.
    func setSessionPriority(_ sessionID: String, _ priority: Bool, now: Date = Date()) {
        guard let (provider, session) = liveSession(sessionID),
              sessionPriorities.set(sessionID, priority: priority, provider: provider, at: now) else { return }
        sessionPriorities.save()
        let name = Self.eventName(of: session)
        failoverEvents.record(provider, priority
            ? "Marked \(name) as a priority session: pacing to the resets runs it first, beside pinned sessions."
            : "\(name) is no longer a priority session: pacing to the resets ranks it with the others.")
    }

    /// Drops the priority marks of sessions whose record is gone or says
    /// they ended (`SessionPriorities.prune`).
    func prunePriorities(_ provider: AIProviderType, now: Date) {
        guard !sessionPriorities.marked(provider).isEmpty else { return }
        let open = AgentSessions.records(provider).filter { $0.value.event != "SessionEnd" }
        if !sessionPriorities.prune(provider, recorded: Set(open.keys), now: now).isEmpty { sessionPriorities.save() }
    }

    /// What pacing does now, for the Outlook: nil while it holds nothing.
    /// The running and held sessions are named from `sessions`, the
    /// Outlook's own (`capacityOutlookSessions`), and `resume` is the
    /// flat-out projection's resume.
    func pacedSummary(_ provider: AIProviderType, sessions: [CapacityOutlook.Session],
                      resume: Date?) -> SustainablePace.Summary? {
        guard failoverConfig.policy(for: provider).paceToResets, let decision = pacedDecisions[provider],
              !decision.held.isEmpty else { return nil }
        let candidates = sessions.map { SustainablePace.Candidate(id: $0.id, label: $0.label, tokensPerHour: $0.tokensPerHour) }
        return SustainablePace.summary(candidates, held: decision.held, target: decision.target, flatOutResume: resume)
    }

    /// The row note of a session pacing holds: "runs as room allows, about
    /// Mon 8:00 am at the latest"; nil for any other session.
    func pacedNote(_ provider: AIProviderType, session: String, now: Date) -> String? {
        guard pacedSessions(provider).contains(session), let until = sessionWaits[provider]?[session]?.until else { return nil }
        return "runs as room allows, when capacity returns about \(UsageFormat.clock(until, now: now)) at the latest"
    }

    /// Logs what a target was found from: the flat-out rate and its pause,
    /// the target and until when, and each account's availability, room
    /// until then in tokens, token cost and where that cost comes from
    /// (`ratioSources`), and weekly-to-window ratio; and the sessions with
    /// their rates and what fixes them.
    func logPacingInputs(_ provider: AIProviderType, target: SustainablePace.Target, accounts: [CapacityOutlook.Account],
                         candidates: [SustainablePace.Candidate], now: Date) {
        let pacer = SessionPacer(moveCostFactor: provider.capabilities.sessionMoveCostFactor)
        func millions(_ tokens: Double) -> String { CapacityOutlook.millions(tokens) }
        paceLog.info("\(provider.rawValue): target \(millions(target.tokensPerHour)) tokens/h until "
                     + "\(SustainablePace.until(target, now: now)); flat out \(millions(target.flatOutTokensPerHour)) "
                     + "tokens/h pauses everything at \(UsageFormat.clock(target.flatOutPausedAt, now: now))")
        for account in accounts {
            let room = pacer.roomBy(account.pacer, target.until, spent: 0, now: now)
            let source = ratioSources[account.id].map(Self.ratioOrigin) ?? "not yet resolved"
            paceLog.info("  \(account.name): \(account.availability), window \(Int(account.pacer.utilization.rounded()))%, "
                         + "week left \(account.pacer.weeklyRemaining.map { String(format: "%.0f", $0) } ?? "none") window-%, "
                         + "\(String(format: "%.2f", account.sessionPerWeekly)) window-% per weekly %, "
                         + "\(String(format: "%.3f", account.pacer.percentPerMillion))% per million (\(source)), "
                         + "room until then ≈ \(millions(pacer.millions(max(0, room), on: account.pacer) * 1_000_000)) tokens")
        }
        for candidate in candidates.sorted(by: { $0.tokensPerHour > $1.tokensPerHour }) {
            let prompt = candidate.lastPrompt.map { "prompted \(UsageFormat.clock($0, now: now))" } ?? "no prompt known"
            paceLog.info("  \(candidate.label): \(millions(candidate.tokensPerHour)) tokens/h, "
                         + "\(candidate.fixed.map { "\($0)" } ?? "may be held"), \(prompt)")
        }
    }
}
