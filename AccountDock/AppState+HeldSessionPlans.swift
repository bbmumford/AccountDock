import Foundation

/// What a session lane admission leaves waiting does instead of waiting on
/// its own account alone (`HeldSessionPlan`): it waits for the earliest lane,
/// whichever account's reset frees room for it first, and moves there once
/// that reset is verified, or it moves now to a lane with room when that
/// serves more work. Run by `strandedPlacements` after
/// `SessionPacer.admitToLanes`, every cycle the session is weighed.
extension AppState {
    /// `admission` with each waiting session's plan applied: a session whose
    /// plan moves it now, or whose planned lane's reset has come and that lane
    /// can serve (it is among `destinations`) and still carries it, is placed
    /// there and no longer waits. Every plan is made against the cycle's
    /// `LaneLedger` (`HeldSessionPlan.planTogether`), which first charges
    /// admission's own placements, so the sessions planned onto one lane fit
    /// its fresh window together. The plans are kept in `heldSessionPlans`;
    /// a move is recorded as an event when it changes, and the waits as one
    /// event naming each lane's sessions (`HeldSessionPlan.summary`).
    /// `candidates` are the sessions admission weighed, `running` the
    /// others, whose rates load each account.
    func planHeldSessions(_ provider: AIProviderType, admission: SessionPacer.LaneAdmission?,
                          candidates: [SessionPacer.RebalanceSession], running: [SessionPacer.RebalanceSession],
                          destinations: Set<UUID>, now: Date) -> SessionPacer.LaneAdmission? {
        let previous = heldSessionPlans[provider] ?? [:]
        let pacer = SessionPacer(moveCostFactor: provider.capabilities.sessionMoveCostFactor)
        var ledger = laneLedger(provider, now: now)
        for session in candidates { ledger.remove(session.id) }
        guard var planned = admission, !planned.waiting.isEmpty else {
            for (session, lane) in admission?.placements ?? [:] {
                guard let moved = candidates.first(where: { $0.id == session }) else { continue }
                ledger.charge(placedCharge(moved, on: lane, pacer: pacer, now: now))
            }
            laneLedgers[provider] = ledger
            heldSessionPlans[provider] = nil
            heldPlanSummaryNoted[provider] = nil
            return admission
        }
        let outlookAccounts = capacityOutlookAccounts(provider, now: now)
        let base = ledger.excluding(running).reduce(into: [UUID: Double]()) { $0[$1.account, default: 0] += $1.tokensPerHour }
        for (session, lane) in planned.placements {
            guard let moved = candidates.first(where: { $0.id == session }) else { continue }
            ledger.charge(placedCharge(moved, on: lane, pacer: pacer, now: now))
        }
        // Lanes a session may move to now: those admission could use that
        // can serve it.
        let lanes = destinations.filter { id in outlookAccounts.contains { $0.id == id && $0.availability == .serves } }
        func held(_ session: SessionPacer.RebalanceSession) -> HeldSessionPlan.Session {
            HeldSessionPlan.Session(id: session.id, account: session.account, tokensPerHour: session.tokensPerHour,
                                    contextTokens: session.contextTokens, cacheLifetime: session.cacheLifetime,
                                    lastSeen: session.lastSeen)
        }
        var plans: [String: HeldSessionPlan] = [:]
        var toPlan: [HeldSessionPlan.Session] = []
        for id in planned.waiting {
            guard let session = candidates.first(where: { $0.id == id }) else { continue }
            // The lane a wait was planned for takes the session once its
            // reset has come, a reading shows it serving and it still
            // carries the session beside everything sent there this cycle.
            switch HeldSessionPlan.due(previous[id], destinations: destinations, now: now, grace: Self.accountHoldGrace) {
            case .place(let lane):
                let charge = placedCharge(session, on: lane, pacer: pacer, now: now)
                if let account = outlookAccounts.first(where: { $0.id == lane }),
                   CapacityOutlook.carries(account, base: base[lane] ?? 0, loads: ledger.loads(on: lane, excluding: id),
                                           adding: CapacityOutlook.Load(from: now, tokensPerHour: charge.tokensPerHour,
                                                                        arrivalTokens: charge.arrivalTokens),
                                           until: now.addingTimeInterval(SessionPacer.newSessionRunway), now: now,
                                           pacer: pacer) {
                    planned.placements[id] = lane
                    planned.waiting.removeAll { $0 == id }
                    ledger.charge(charge)
                    continue
                }
                toPlan.append(held(session))
            case .stand:
                guard let plan = previous[id] else { continue }
                plans[id] = plan
                ledger.charge(LaneLedger.Charge(session: id, lane: plan.lane, tokensPerHour: session.tokensPerHour,
                                                arrivalTokens: plan.lane == session.account ? 0
                                                    : HeldSessionPlan.arrivalTokens(held(session), pacer: pacer),
                                                from: plan.at, kind: .planned))
            case .replan:
                toPlan.append(held(session))
            }
        }
        let made = HeldSessionPlan.planTogether(toPlan, accounts: outlookAccounts, base: base, lanes: lanes,
                                                ledger: &ledger, now: now, pacer: pacer)
        for (id, plan) in made {
            plans[id] = plan
            guard plan.choice == .move else { continue }
            if !plan.same(as: previous[id]) {
                failoverEvents.record(provider, plan.event(session: heldSessionName(provider, id), now: now))
            }
            planned.placements[id] = plan.lane
            planned.waiting.removeAll { $0 == id }
        }
        laneLedgers[provider] = ledger
        heldSessionPlans[provider] = plans.isEmpty ? nil : plans
        noteHeldPlanSummary(provider, plans: plans, waiting: planned.waiting, base: base, ledger: ledger,
                            accounts: outlookAccounts, pacer: pacer, now: now)
        return planned
    }

    /// The ledger charge of `session` placed on `lane` now: its rate, and
    /// its arrival's cache write unless it already runs there.
    func placedCharge(_ session: SessionPacer.RebalanceSession, on lane: UUID, pacer: SessionPacer,
                      now: Date) -> LaneLedger.Charge {
        Self.placedCharge(session, on: lane, pacer: pacer, now: now)
    }

    nonisolated static func placedCharge(_ session: SessionPacer.RebalanceSession, on lane: UUID, pacer: SessionPacer,
                                         now: Date) -> LaneLedger.Charge {
        let arrival = lane == session.account ? 0
            : SessionSizing.arrivalTokens(session.contextTokens, cacheLifetime: session.cacheLifetime) * pacer.moveCostFactor
        return LaneLedger.Charge(session: session.id, lane: lane, tokensPerHour: session.tokensPerHour,
                                 arrivalTokens: arrival, from: now, kind: .placed)
    }

    /// Records, once while it says the same, which sessions each lane's
    /// reset takes and which wait for their own accounts
    /// (`HeldSessionPlan.summary`), with how long each lane's fresh window
    /// lasts the sessions planned onto it.
    private func noteHeldPlanSummary(_ provider: AIProviderType, plans: [String: HeldSessionPlan], waiting: [String],
                                     base: [UUID: Double], ledger: LaneLedger, accounts: [CapacityOutlook.Account],
                                     pacer: SessionPacer, now: Date) {
        let waits = waiting.compactMap { id -> (name: String, plan: HeldSessionPlan)? in
            guard let plan = plans[id], plan.choice == .wait else { return nil }
            return (heldSessionName(provider, id), plan)
        }
        var lasting: [UUID: TimeInterval] = [:]
        for (_, plan) in waits where lasting[plan.lane] == nil {
            guard let account = accounts.first(where: { $0.id == plan.lane }) else { continue }
            lasting[plan.lane] = CapacityOutlook.lasting(account, base: base[plan.lane] ?? 0,
                                                         loads: ledger.loads(on: plan.lane), from: plan.at,
                                                         until: plan.at.addingTimeInterval(pacer.window), now: now,
                                                         pacer: pacer)
        }
        let unplanned = waiting.filter { plans[$0] == nil }.count
        guard let event = HeldSessionPlan.summary(waits, lasting: lasting, unplanned: unplanned, now: now) else {
            heldPlanSummaryNoted[provider] = nil
            return
        }
        guard heldPlanSummaryNoted[provider] != event else { return }
        heldPlanSummaryNoted[provider] = event
        failoverEvents.record(provider, event)
    }

    /// How the events name a held session or run: its record's folder and
    /// ID, or, for a run with no session record (keyed by its slot's path),
    /// the folder it runs in (`unrecordedRunName`), never the path cut to
    /// an ID's length.
    func heldSessionName(_ provider: AIProviderType, _ id: String) -> String {
        if let live = liveSession(id) { return Self.eventName(of: live.1) }
        if Self.isUnrecordedRun(id) { return unrecordedRunName(provider, slot: id) }
        return "session \(id.prefix(8))"
    }

    /// The provider's sessions lane admission keeps on their account
    /// (`SessionWait.Reason.awaitingLane`), with that account.
    /// `serveSessionSlots` keeps each there rather than moving it by the
    /// path for an account that can no longer serve (`slotChoice`'s
    /// `heldOn`): admission decides where it goes, a planned lane once its
    /// reset comes. One the user played or moved is left out: playing a
    /// held session means running it now, so that path takes it to the
    /// account with room even though it may not last the hour there.
    func admissionHolds(_ provider: AIProviderType) -> [String: UUID] {
        (sessionWaits[provider] ?? [:]).reduce(into: [:]) { result, entry in
            if entry.value.reason == .awaitingLane, !entry.value.played { result[entry.key] = entry.value.account }
        }
    }

    /// The Sessions page row's note for a session waiting on its plan: "resumes
    /// on fluxon about 12:50 am"; nil for one with none.
    func heldSessionNote(_ provider: AIProviderType, session: String, now: Date = Date()) -> String? {
        guard let plan = heldSessionPlans[provider]?[session], plan.choice == .wait,
              sessionWaits[provider]?[session]?.reason == .awaitingLane else { return nil }
        return plan.rowNote(now: now)
    }
}
