import Foundation

/// Window placements: slot sessions a window move put on an account to use
/// its session window, whose room would otherwise expire unused, until it
/// fills (`SessionPacer.WindowUse`). Every rule that moves slot sessions
/// follows the one intent: the session stays on that account until the
/// window is at its limit or refuses it, or the placement's `until` passes.
/// `SessionPacer.plan` and `rebalance` take the placements in force as
/// sessions that stay and the windows they fill as filling as planned, so
/// neither the shedding rule nor a rebalance pulls the session back while
/// the window fills; `strandedPlacements` moves it on once the window can
/// no longer serve it.
extension AppState {
    /// A slot session's window placement: the account whose session window
    /// it uses, until when that window's room was planned to last, and when
    /// the move was made.
    struct WindowPlacement: Equatable {
        var account: UUID
        var until: Date
        var at: Date
    }

    /// The provider's window placements still in force, by session: the
    /// session's slot serves the placement's account and `until` has not
    /// passed. Read by `paced` and `rebalancePreview`.
    func windowPlacementsInForce(_ provider: AIProviderType, now: Date) -> [String: SessionPacer.WindowUse] {
        windowPlacements.reduce(into: [:]) { result, entry in
            let (session, placement) = entry
            guard now < placement.until, slotAccount(forSession: session, provider: provider) == placement.account else { return }
            result[session] = SessionPacer.WindowUse(account: placement.account, until: placement.until)
        }
    }

    /// Why a session leaves the window placement it had on `account`, for
    /// the event of the move that takes it off (`serveSessionSlots`): the
    /// account cannot serve it, its session window used up or refusing it,
    /// or the placement's `until` has passed. Nil for a move made while the
    /// placement still held, as one the user asked for, whose event gives
    /// its own reason.
    nonisolated static func windowLeaveReason(account: String, cannotServe: Bool, refused: Bool, until: Date,
                                              now: Date) -> String? {
        let planned = UsageFormat.clock(until, now: now)
        if cannotServe {
            return refused ? "\(account) refused it at its limit, ending its placement there until \(planned)"
                : "\(account)'s session window is used up, as its placement there until \(planned) planned"
        }
        return now >= until ? "its placement on \(account)'s session window ended at \(planned) as planned" : nil
    }

    /// Records the window placement a slot move made (`serveSessionSlots`),
    /// and forgets placements whose window has long since ended: a session
    /// window past `until` plus a whole window has reset whatever happened.
    func recordWindowPlacement(_ session: String, use: SessionPacer.WindowUse, now: Date) {
        windowPlacements = windowPlacements.filter { now.timeIntervalSince($0.value.until) < FailoverPlanner.sessionWindow }
        windowPlacements[session] = WindowPlacement(account: use.account, until: use.until, at: now)
    }
}
