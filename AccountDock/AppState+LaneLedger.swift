import Foundation

/// The cycle's `LaneLedger` as the app keeps and charges it: started afresh
/// by `runQuotaCycle`, charged first with the sessions waits hold on their
/// accounts, then by every rule that sends a session somewhere that cycle.
extension AppState {
    /// How long a ledger serves the rules run between two quota cycles (a
    /// move by hand, a rebalance, a session resumed from the Sessions page),
    /// which then weigh against the last cycle's charges; past it, a fresh
    /// one. Longer than a cycle that reads accounts and moves sessions
    /// under load takes, so no rule late in a slow cycle loses the charges
    /// its earlier rules made.
    nonisolated static let laneLedgerLifetime: TimeInterval = 5 * 60

    /// The provider's ledger for the cycle running at `now`.
    func laneLedger(_ provider: AIProviderType, now: Date) -> LaneLedger {
        if let ledger = laneLedgers[provider], ledger.startedAt <= now,
           now.timeIntervalSince(ledger.startedAt) < Self.laneLedgerLifetime { return ledger }
        return LaneLedger(startedAt: now)
    }

    /// Starts every provider's ledger afresh for the quota cycle beginning
    /// at `now`, before any rule moves a session.
    func startLaneLedgers(now: Date) {
        for provider in AIProviderType.implementedProviders { laneLedgers[provider] = LaneLedger(startedAt: now) }
    }

    /// Charges each session a wait keeps on its account (`sessionWaits`,
    /// played ones and lane admission's own left out, which
    /// `strandedPlacements` weighs again) to that account from the reset it
    /// waits for, at the rate it used before it was held
    /// (`SessionRates.heldDemand`): that account's fresh window is theirs
    /// first. Run every quota cycle after the waits are settled
    /// (`holdSessionsForImminentReset`, `holdSharedSessionsOnStayingAccount`)
    /// and before the slots are served.
    func chargeHeldWaits(_ provider: AIProviderType, now: Date) {
        var ledger = laneLedger(provider, now: now)
        for (id, wait) in sessionWaits[provider] ?? [:] where !wait.played && wait.reason != .awaitingLane {
            let rate = sessionRates.heldDemand(id, pausedAt: wait.since)
                ?? sessionRates.tokensPerHour(id, now: now)
            ledger.charge(LaneLedger.Charge(session: id, lane: wait.account, tokensPerHour: rate,
                                            from: max(wait.until, now), kind: .held))
        }
        laneLedgers[provider] = ledger
    }

    /// How recent the reading of an account must be for sessions to be
    /// sent, moved or released onto it (`freshForArrivals`).
    nonisolated static let arrivalReadingAge: TimeInterval = 5 * 60

    /// Whether `id` may take sessions now on what AccountDock knows of it:
    /// it was read within `arrivalReadingAge`, no reset has passed since
    /// that no reading confirmed (`resetUnverified`), so the reading
    /// describes the window it serves from now, and it has refused no
    /// request since with a reset still to come (`refusedUntilReset`).
    /// Read by every rule that sends sessions to an account or releases
    /// them there: the stranded placement's destinations, the slot path's
    /// fallback, a pause at a limit and resuming as capacity allows.
    func freshForArrivals(_ id: UUID, now: Date) -> Bool {
        Self.freshForArrivals(readAt: accountUsageUpdatedAt[id],
                              resetUnconfirmed: accountsAwaitingPostResetVerification.contains(id),
                              refused: refusedUntilReset(id, now: now), now: now)
    }

    /// `freshForArrivals`'s rule on an account read at `readAt`.
    nonisolated static func freshForArrivals(readAt: Date?, resetUnconfirmed: Bool, refused: Bool, now: Date) -> Bool {
        guard let readAt, now.timeIntervalSince(readAt) <= arrivalReadingAge else { return false }
        return !resetUnconfirmed && !refused
    }

    /// Until when a refusal at `at` in `words` keeps its account at its
    /// limit (`refusedUntilReset`): the reset it states, or
    /// `refusalStanding` after it when it states none.
    nonisolated static func refusalHolds(words: String, at: Date, calendar: Calendar = .current) -> Date {
        refusalResetDate(words, at: at, calendar: calendar) ?? at.addingTimeInterval(refusalStanding)
    }

    /// Whether a session's request was refused at a usage limit on `id`
    /// (`sessionRefusals`) with the reset it states still to come, or, when
    /// it states none, within `refusalStanding`: the account is at its limit
    /// until then, whatever readings older than that reset show. A refusal
    /// of a session whose model has an allowance of its own on the account
    /// may be that allowance's alone, which `recordedLimitRefusal` judges,
    /// and is left out.
    func refusedUntilReset(_ id: UUID, now: Date) -> Bool {
        let scoped = (accountUsage[id]?.modelWeeklyLimits ?? []).map { $0.model.lowercased() }
        return sessionRefusals.contains { session, refusal in
            guard refusal.account == id, Self.refusalCounts(verified: refusal.verified, at: refusal.at, now: now) else {
                return false
            }
            if let model = sessionModel(session, now: now)?.lowercased(), scoped.contains(where: { model.contains($0) }) {
                return false
            }
            return Self.refusalHolds(words: refusal.words, at: refusal.at) > now
        }
    }

    /// Whether `session`, held on `account` by a pause that began at
    /// `pausedAt`, may go on there now, charging the ledger for it when it
    /// may: the account was read fresh (`freshForArrivals`), and it carries
    /// the session's rate before it was held (`SessionRates.heldDemand`)
    /// for the hour beside the sessions running there and everything the
    /// cycle already sent, planned or released onto it
    /// (`CapacityOutlook.carries`). The other sessions this pause holds
    /// (`holding`) compete for the same room rather than load it, so the
    /// first that fit go on and the rest keep waiting. A session no window
    /// holds for the hour still goes on alone on an account nothing else
    /// uses, which waiting would never change. One the ledger already
    /// placed on that account this cycle goes on. Read by
    /// `limitPauseScope` for each session a pause at a limit would release.
    func releaseFits(_ provider: AIProviderType, session: String, account: UUID, pausedAt: Date, holding: Set<String>,
                     running: [SessionPacer.RebalanceSession], accounts outlook: [CapacityOutlook.Account],
                     ledger: inout LaneLedger, now: Date) -> Bool {
        let rate = sessionRates.heldDemand(session, pausedAt: pausedAt) ?? sessionRates.tokensPerHour(session, now: now)
        return Self.release(session, tokensPerHour: rate, on: outlook.first { $0.id == account },
                            fresh: freshForArrivals(account, now: now), holding: holding, running: running,
                            ledger: &ledger, now: now,
                            pacer: SessionPacer(moveCostFactor: provider.capabilities.sessionMoveCostFactor))
    }

    /// `releaseFits`'s rule for `session`, held at `tokensPerHour` on `lane`
    /// (nil when that account is unknown): it goes on, and `ledger` is
    /// charged for it, when its account's reading is `fresh` and the account
    /// carries it for the hour beside `running` there and the ledger's
    /// charges, the other held sessions of `holding` left out of both; or
    /// when nothing else uses that account; or when the ledger already
    /// placed or released it there this cycle.
    nonisolated static func release(_ session: String, tokensPerHour rate: Double, on lane: CapacityOutlook.Account?,
                                    fresh: Bool, holding: Set<String>, running: [SessionPacer.RebalanceSession],
                                    ledger: inout LaneLedger, now: Date, pacer: SessionPacer) -> Bool {
        guard let lane else { return false }
        if let own = ledger.charge(of: session), own.lane == lane.id, own.kind == .placed || own.kind == .released {
            return true
        }
        guard fresh else { return false }
        let base = ledger.excluding(running).filter { $0.account == lane.id && !holding.contains($0.id) && $0.id != session }
            .reduce(0) { $0 + $1.tokensPerHour }
        let loads = ledger.charges(on: lane.id).filter { charge in
            charge.session != session && !(charge.kind == .held && holding.contains(charge.session))
        }.map { CapacityOutlook.Load(from: $0.from, tokensPerHour: $0.tokensPerHour, arrivalTokens: $0.arrivalTokens) }
        let fits = CapacityOutlook.carries(lane, base: base, loads: loads,
                                           adding: CapacityOutlook.Load(from: now, tokensPerHour: rate),
                                           until: now.addingTimeInterval(SessionPacer.newSessionRunway), now: now,
                                           pacer: pacer)
        guard fits || (base <= 0 && loads.isEmpty && lane.availability == .serves) else { return false }
        ledger.charge(LaneLedger.Charge(session: session, lane: lane.id, tokensPerHour: rate, from: now, kind: .released))
        return true
    }

    /// Where the slot path sends a session or run (`id`) whose own account
    /// can no longer serve it and that no rule placed or keeps: the first
    /// of `byWeight` (the pool, the account taking most new sessions first)
    /// that can serve it, was read fresh (`freshForArrivals`) and carries
    /// it, its arrival and its rate for the
    /// hour, beside the sessions there and everything the cycle's ledger
    /// charges it (`CapacityOutlook.carries`), with the charge that move
    /// makes. Nil when none does: the slot then stays, and the pause at the
    /// limit holds the session there, rather than every such session going
    /// to the one account with the most weight.
    func ledgerFallback(_ provider: AIProviderType, id: String, from current: UUID?, byWeight: [UUID],
                        cannotServe: (UUID) -> Bool, running: [SessionPacer.RebalanceSession],
                        accounts outlook: [CapacityOutlook.Account], now: Date) -> (lane: UUID, charge: LaneLedger.Charge)? {
        let session = running.first { $0.id == id }
            ?? SessionPacer.RebalanceSession(id: id, account: current ?? UUID(), tokensPerHour: SessionPacer.defaultSessionRate,
                                             contextTokens: 0, model: nil, movable: true)
        return Self.fallbackLane(session, from: current, candidates: byWeight,
                                 usable: { !cannotServe($0) && self.freshForArrivals($0, now: now) },
                                 running: running, accounts: outlook, ledger: laneLedger(provider, now: now), now: now,
                                 pacer: SessionPacer(moveCostFactor: provider.capabilities.sessionMoveCostFactor))
    }

    /// `ledgerFallback`'s rule for `session`, leaving `current`: the first
    /// of `candidates` other than it that is `usable` (it can serve the
    /// session and was read fresh) and carries the session for the hour
    /// beside `running` there and `ledger`'s charges, with the charge that
    /// move makes; nil when none does.
    nonisolated static func fallbackLane(_ session: SessionPacer.RebalanceSession, from current: UUID?, candidates: [UUID],
                                         usable: (UUID) -> Bool, running: [SessionPacer.RebalanceSession],
                                         accounts outlook: [CapacityOutlook.Account], ledger: LaneLedger, now: Date,
                                         pacer: SessionPacer) -> (lane: UUID, charge: LaneLedger.Charge)? {
        let present = ledger.excluding(running.filter { $0.id != session.id })
        for lane in candidates where lane != current && usable(lane) {
            guard let account = outlook.first(where: { $0.id == lane }) else { continue }
            let charge = placedCharge(session, on: lane, pacer: pacer, now: now)
            let base = present.filter { $0.account == lane }.reduce(0) { $0 + $1.tokensPerHour }
            guard CapacityOutlook.carries(account, base: base, loads: ledger.loads(on: lane, excluding: session.id),
                                          adding: CapacityOutlook.Load(from: now, tokensPerHour: charge.tokensPerHour,
                                                                       arrivalTokens: charge.arrivalTokens),
                                          until: now.addingTimeInterval(SessionPacer.newSessionRunway), now: now,
                                          pacer: pacer) else { continue }
            return (lane, charge)
        }
        return nil
    }
}
