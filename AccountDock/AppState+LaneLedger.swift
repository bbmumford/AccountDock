import Foundation

/// The cycle's `LaneLedger` as the app keeps and charges it: started afresh
/// by `runQuotaCycle`, charged first with the sessions waits hold on their
/// accounts, then by every rule that sends a session somewhere that cycle.
extension AppState {
    /// How long a ledger serves the rules run between two quota cycles (a
    /// move by hand, a rebalance, a session resumed from the Sessions page),
    /// which then weigh against the last cycle's charges; past it, a fresh
    /// one.
    nonisolated static let laneLedgerLifetime: TimeInterval = 2 * 60

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

    /// Where the slot path sends a session or run (`id`) whose own account
    /// can no longer serve it and that no rule placed or keeps: the first
    /// of `byWeight` (the pool, the account taking most new sessions first)
    /// that can serve it and carries it, its arrival and its rate for the
    /// hour, beside the sessions there and everything the cycle's ledger
    /// charges it (`CapacityOutlook.carries`), with the charge that move
    /// makes. Nil when none does: the slot then stays, and the pause at the
    /// limit holds the session there, rather than every such session going
    /// to the one account with the most weight.
    func ledgerFallback(_ provider: AIProviderType, id: String, from current: UUID?, byWeight: [UUID],
                        cannotServe: (UUID) -> Bool, running: [SessionPacer.RebalanceSession],
                        accounts outlook: [CapacityOutlook.Account], now: Date) -> (lane: UUID, charge: LaneLedger.Charge)? {
        let pacer = SessionPacer(moveCostFactor: provider.capabilities.sessionMoveCostFactor)
        let ledger = laneLedger(provider, now: now)
        let session = running.first { $0.id == id }
            ?? SessionPacer.RebalanceSession(id: id, account: current ?? UUID(), tokensPerHour: SessionPacer.defaultSessionRate,
                                             contextTokens: 0, model: nil, movable: true)
        let present = ledger.excluding(running.filter { $0.id != id })
        for lane in byWeight where lane != current && !cannotServe(lane) {
            guard let account = outlook.first(where: { $0.id == lane }) else { continue }
            let charge = placedCharge(session, on: lane, pacer: pacer, now: now)
            let base = present.filter { $0.account == lane }.reduce(0) { $0 + $1.tokensPerHour }
            guard CapacityOutlook.carries(account, base: base, loads: ledger.loads(on: lane, excluding: id),
                                          adding: CapacityOutlook.Load(from: now, tokensPerHour: charge.tokensPerHour,
                                                                       arrivalTokens: charge.arrivalTokens),
                                          until: now.addingTimeInterval(SessionPacer.newSessionRunway), now: now,
                                          pacer: pacer) else { continue }
            return (lane, charge)
        }
        return nil
    }
}
