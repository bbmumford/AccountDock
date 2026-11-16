import Foundation

/// The hold after a slot session moves: the move wrote the session's whole
/// context into the new account's cache, which pays for itself only while
/// the session stays there for that cache's lifetime. Until then no
/// automatic rule moves it again (the pacer's shedding, remainder and window
/// rules, and the automatic rebalance), unless its account refuses it or is
/// at its limit, which the stranded placement answers whatever the hold. A
/// move the user asks for, by hand or with **Rebalance sessions now**, is
/// never held.
extension AppState {
    /// How long a session stays where a move put it before an automatic
    /// rule may move it again: its cache's lifetime, at least
    /// `SessionPacer.defaultCacheLifetime`, the hour the router asks for.
    nonisolated static func moveHold(cacheLifetime: TimeInterval?) -> TimeInterval {
        max(SessionPacer.defaultCacheLifetime, cacheLifetime ?? 0)
    }

    /// The provider's slot sessions within their hold, by session, with when
    /// their slot last moved (`slotDirectoryMovedAt`). Read by `paced`, by
    /// `serveSessionSlots` for the pacer's moves, and by the automatic
    /// rebalance.
    func slotSessionsWithinHold(_ provider: AIProviderType, now: Date) -> [String: Date] {
        (liveSessions[provider] ?? []).reduce(into: [:]) { result, session in
            guard let pid = session.processID, let directory = slotDirectoryByProcess[pid],
                  let moved = slotDirectoryMovedAt[directory],
                  Self.withinHold(movedAt: moved, cacheLifetime: sessionRates.entries[session.sessionID]?.cacheLifetime,
                                  now: now) else { return }
            result[session.sessionID] = moved
        }
    }

    /// Whether a session whose slot moved at `movedAt` is still within its
    /// hold at `now`.
    nonisolated static func withinHold(movedAt: Date, cacheLifetime: TimeInterval?, now: Date) -> Bool {
        now.timeIntervalSince(movedAt) < moveHold(cacheLifetime: cacheLifetime)
    }

    /// Records, once per hold, why each of `heldBack` stays where it is:
    /// an automatic rule would have moved it to the account named, but it
    /// moved at the time `holds` gives, and its cache there has not lasted
    /// its lifetime yet. Called by `paced` and the automatic rebalance.
    func noteHeldMoves(_ provider: AIProviderType, heldBack: [String: UUID], holds: [String: Date], rule: String,
                       now: Date) {
        // Every hold has ended within a day of its move.
        holdNoted = holdNoted.filter { now.timeIntervalSince($0.value) < 24 * 60 * 60 }
        for (session, destination) in heldBack.sorted(by: { $0.key < $1.key }) {
            guard let moved = holds[session], holdNoted[session] != moved else { continue }
            holdNoted[session] = moved
            let live = liveSessions[provider]?.first { $0.sessionID == session }
            let on = slotAccount(forSession: session, provider: provider)
                .flatMap { id in accounts.first { $0.id == id } }.map { messageName($0) } ?? "its account"
            let to = accounts.first { $0.id == destination }.map { messageName($0) } ?? "another account"
            let until = moved.addingTimeInterval(Self.moveHold(cacheLifetime: sessionRates.entries[session]?.cacheLifetime))
            failoverEvents.record(provider, Self.heldMoveEvent(session: Self.eventName(of: live), account: on, destination: to,
                                                               rule: rule, movedAt: moved, until: until, now: now))
        }
    }

    /// The event for a move a hold stopped (`noteHeldMoves`): the session
    /// stays on `account` although `rule` would move it to `destination`.
    nonisolated static func heldMoveEvent(session: String, account: String, destination: String, rule: String,
                                          movedAt: Date, until: Date, now: Date) -> String {
        "Kept \(session) on \(account) although \(rule) would move it to \(destination): it moved there at "
            + "\(UsageFormat.clock(movedAt, now: now)), and moving it again before \(UsageFormat.clock(until, now: now)) "
            + "would write its cache a second time before the first has paid off. It moves sooner only if \(account) "
            + "refuses it or reaches its limit."
    }
}
