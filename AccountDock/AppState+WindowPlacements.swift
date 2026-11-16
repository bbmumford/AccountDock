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

    /// Records the window placement a slot move made (`serveSessionSlots`),
    /// and forgets placements whose window has long since ended: a session
    /// window past `until` plus a whole window has reset whatever happened.
    func recordWindowPlacement(_ session: String, use: SessionPacer.WindowUse, now: Date) {
        windowPlacements = windowPlacements.filter { now.timeIntervalSince($0.value.until) < FailoverPlanner.sessionWindow }
        windowPlacements[session] = WindowPlacement(account: use.account, until: use.until, at: now)
    }
}
