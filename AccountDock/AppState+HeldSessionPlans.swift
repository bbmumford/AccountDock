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
    /// can serve (it is among `destinations`), is placed there and no longer
    /// waits. The plans are kept in `heldSessionPlans`, each recorded as an
    /// event when it changes. `candidates` are the sessions admission weighed,
    /// `running` the others, whose rates load each account.
    func planHeldSessions(_ provider: AIProviderType, admission: SessionPacer.LaneAdmission?,
                          candidates: [SessionPacer.RebalanceSession], running: [SessionPacer.RebalanceSession],
                          destinations: Set<UUID>, now: Date) -> SessionPacer.LaneAdmission? {
        let previous = heldSessionPlans[provider] ?? [:]
        guard var planned = admission, !planned.waiting.isEmpty else {
            heldSessionPlans[provider] = nil
            return admission
        }
        let pacer = SessionPacer(moveCostFactor: provider.capabilities.sessionMoveCostFactor)
        let outlookAccounts = capacityOutlookAccounts(provider, now: now)
        var base = running.reduce(into: [UUID: Double]()) { $0[$1.account, default: 0] += $1.tokensPerHour }
        for (session, lane) in planned.placements {
            base[lane, default: 0] += candidates.first { $0.id == session }?.tokensPerHour ?? 0
        }
        // Lanes a session may move to now: those admission could use that
        // can serve it.
        let lanes = destinations.filter { id in outlookAccounts.contains { $0.id == id && $0.availability == .serves } }
        var plans: [String: HeldSessionPlan] = [:]
        for id in planned.waiting {
            guard let session = candidates.first(where: { $0.id == id }) else { continue }
            // The lane a wait was planned for takes the session once its
            // reset has come and a reading shows it serving.
            switch HeldSessionPlan.due(previous[id], destinations: destinations, now: now, grace: Self.accountHoldGrace) {
            case .place(let lane):
                planned.placements[id] = lane
                planned.waiting.removeAll { $0 == id }
                base[lane, default: 0] += session.tokensPerHour
                continue
            case .stand:
                plans[id] = previous[id]
                continue
            case .replan:
                break
            }
            let held = HeldSessionPlan.Session(id: id, account: session.account, tokensPerHour: session.tokensPerHour,
                                               contextTokens: session.contextTokens, cacheLifetime: session.cacheLifetime,
                                               lastSeen: session.lastSeen)
            guard let plan = HeldSessionPlan.decide(held, accounts: outlookAccounts, base: base, lanes: lanes, now: now,
                                                    pacer: pacer) else { continue }
            plans[id] = plan
            if !plan.same(as: previous[id]) {
                let name = liveSession(id).map { Self.eventName(of: $0.1) } ?? "session \(id.prefix(8))"
                failoverEvents.record(provider, plan.event(session: name, now: now))
            }
            guard plan.choice == .move else { continue }
            planned.placements[id] = plan.lane
            planned.waiting.removeAll { $0 == id }
            base[plan.lane, default: 0] += session.tokensPerHour
        }
        heldSessionPlans[provider] = plans.isEmpty ? nil : plans
        return planned
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
