import XCTest
@testable import AccountDock

/// Small plans' session windows used while the large account runs out, and
/// sessions on an account that cannot serve them spread over every account
/// with room: `SessionPacer.spendWindows` through `plan` and `rebalance`,
/// `SessionPacer.place` through `rebalance` and
/// `AppState.strandedDestinations`.
final class SessionWindowSpendingTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let personal = UUID(), hexorda = UUID(), bytrix = UUID(), cybrio = UUID(), newer = UUID()
    /// A Max 20x account at 0.25 window percent per million weighted tokens;
    /// a Pro account counts twenty times that per token.
    let maxRatio = 0.25, proRatio = 10.0

    private var pros: [UUID] { [hexorda, bytrix, cybrio] }

    private func account(_ id: UUID, used: Double, resetIn hours: Double?, ratio: Double, weeklyLeft: Double,
                         weeklyResetIn: Double, weight: Double) -> SessionPacer.Account {
        var account = SessionPacer.Account(id: id, utilization: used, resetsAt: hours.map { now.addingTimeInterval($0 * 3600) },
                                           burnPerHour: 0, baseWeight: weight, percentPerMillion: ratio)
        account.weeklyRemaining = weeklyLeft
        account.weeklyResetsAt = now.addingTimeInterval(weeklyResetIn * 3600)
        return account
    }

    /// Personal, near the end of its week until Monday, takes new sessions;
    /// three Pro accounts with no 5-hour window running take none, since a
    /// typical session would fill one within the hour.
    private func accounts() -> [SessionPacer.Account] {
        [account(personal, used: 30, resetIn: 3, ratio: maxRatio, weeklyLeft: 48, weeklyResetIn: 60, weight: 1)]
            + pros.map { account($0, used: 0, resetIn: nil, ratio: proRatio, weeklyLeft: 624, weeklyResetIn: 100, weight: 0) }
    }

    /// Thirteen slot sessions on Personal: one heavy one with a 53k context,
    /// four light ones at 340k-460k, eight heavy ones at 780k-857k.
    private func sessions(quietFor seconds: TimeInterval = 5 * 60) -> [SessionPacer.Session] {
        func session(_ id: String, rate: Double, context: Int) -> SessionPacer.Session {
            SessionPacer.Session(id: id, account: personal, tokensPerHour: rate, contextTokens: context,
                                 lastSeen: now.addingTimeInterval(-seconds), cacheLifetime: 3600,
                                 lastTurnStart: now.addingTimeInterval(-seconds - 60), recentTokensPerHour: rate)
        }
        return [session("s53k", rate: 30_000_000, context: 53_000)]
            + [340_000, 380_000, 420_000, 460_000].enumerated().map { session("light\($0.offset + 1)", rate: 1_000_000, context: $0.element) }
            + (0..<8).map { session("heavy\($0 + 1)", rate: 30_000_000, context: 780_000 + $0 * 11_000) }
    }

    private var spending: SessionPacer.RemainderSpending {
        SessionPacer.RemainderSpending(accounts: Set(pros), sessions: Set(sessions().map(\.id)))
    }

    func testCheapAndLightSessionsUseTheSmallPlansWindowsWhileTheLargeAccountRunsOut() throws {
        let plan = SessionPacer().plan(accounts: accounts(), sessions: sessions(), now: now, remainders: spending)
        XCTAssertEqual(Set(plan.moves.keys), ["light1", "light2", "light3", "light4"],
                       "the light ones go; at 300% of a Pro window an hour the heavy ones would spend one in twenty minutes")
        XCTAssertEqual(Set(plan.windowUses.keys), Set(plan.moves.keys))
        XCTAssertTrue(plan.moves.values.allSatisfy { pros.contains($0) })
        XCTAssertEqual(Set(plan.moves.values), Set(pros), "the moves are spread over every window with room")
        XCTAssertNil(plan.shedding[personal], "no move makes Personal last longer, so it sheds nothing")
        for use in plan.windowUses.values {
            XCTAssertGreaterThan(use.until, now)
            XCTAssertLessThanOrEqual(use.until, now.addingTimeInterval(FailoverPlanner.sessionWindow))
        }
        // The light ones fill a window between them.
        XCTAssertEqual(plan.moves["light1"], plan.moves["light4"])
    }

    func testWhileTheWindowsAreWorthSpendingNewSessionsGoWhereRoomWouldExpire() {
        // Every session mid-turn: none moves, and new sessions go to the
        // windows, not to Personal, whose room is spent before Monday anyway.
        let plan = SessionPacer().plan(accounts: accounts(), sessions: sessions(quietFor: 10), now: now, remainders: spending)
        XCTAssertTrue(plan.moves.isEmpty)
        XCTAssertEqual(plan.weights[personal], 0)
        for pro in pros { XCTAssertGreaterThan(plan.weights[pro] ?? 0, 0) }

        // Without the windows (balancing off) the old rule stands: Personal
        // takes the new sessions.
        let unspent = SessionPacer().plan(accounts: accounts(), sessions: sessions(quietFor: 10), now: now)
        XCTAssertGreaterThan(unspent.weights[personal] ?? 0, 0)
        XCTAssertTrue(pros.allSatisfy { (unspent.weights[$0] ?? 0) == 0 })
    }

    func testRebalanceUsesTheSameWindowRule() {
        let plan = SessionPacer().plan(accounts: accounts(), sessions: sessions(), now: now, remainders: spending)
        let running = sessions().map {
            SessionPacer.RebalanceSession(id: $0.id, account: $0.account, tokensPerHour: $0.tokensPerHour,
                                          contextTokens: $0.contextTokens, model: nil, movable: true, cacheLifetime: 3600)
        }
        let rebalanced = SessionPacer().rebalance(accounts: accounts(), sessions: running,
                                                  destinations: Set([personal] + pros), now: now, windows: Set(pros))
        XCTAssertEqual(rebalanced.moves, plan.moves)
        XCTAssertEqual(Set(rebalanced.windowUses.keys), Set(plan.windowUses.keys))
    }

    func testAMoveIntoASmallWindowIsChargedItsWholeCacheWrite() throws {
        let pro = accounts()[1]
        XCTAssertEqual(SessionSizing.arrivalTokens(800_000, cacheLifetime: nil), 1_600_000, accuracy: 0.001)
        XCTAssertEqual(SessionPacer().arrivalCost(800_000, cacheLifetime: 3600, to: pro), 16, accuracy: 0.001,
                       "1.6M weighted tokens at 10% a million: the one-hour cache is written at 2 a token")
        XCTAssertEqual(SessionPacer().arrivalCost(800_000, cacheLifetime: 300, to: pro), 10, accuracy: 0.001)
        XCTAssertGreaterThan(SessionPacer().arrivalCost(800_000, cacheLifetime: 3600, to: pro),
                             SessionPacer().moveCost(800_000, to: pro), "more than what the move adds over staying")
    }

    /// Cybrio's window is at its limit with twelve sessions on it; bytrix and
    /// hexorda have empty windows; a newer Pro account has used 17% of its.
    private func blockedAccounts() -> [SessionPacer.Account] {
        [account(cybrio, used: 100, resetIn: 3.3, ratio: proRatio, weeklyLeft: 400, weeklyResetIn: 100, weight: 0),
         account(bytrix, used: 0, resetIn: nil, ratio: proRatio, weeklyLeft: 600, weeklyResetIn: 100, weight: 1),
         account(hexorda, used: 0, resetIn: nil, ratio: proRatio, weeklyLeft: 600, weeklyResetIn: 100, weight: 0),
         account(newer, used: 17, resetIn: 4, ratio: proRatio, weeklyLeft: 700, weeklyResetIn: 150, weight: 0)]
    }

    private func blockedSessions() -> [SessionPacer.RebalanceSession] {
        (0..<12).map {
            SessionPacer.RebalanceSession(id: "c\($0)", account: cybrio, tokensPerHour: 30_000_000,
                                          contextTokens: 300_000 + $0 * 50_000, model: nil, movable: true, cacheLifetime: 3600)
        }
    }

    func testRebalanceMovesSessionsOffAnAccountThatCannotServeThemAcrossEveryWindowWithRoom() {
        // No destination carries one of these sessions for an hour; each
        // still gains from any room.
        let rebalanced = SessionPacer().rebalance(accounts: blockedAccounts(), sessions: blockedSessions(),
                                                  destinations: [bytrix, hexorda, newer], now: now)
        XCTAssertEqual(rebalanced.moves.count, 12)
        XCTAssertEqual(rebalanced.unblocked, Set(blockedSessions().map(\.id)))
        let counts = Dictionary(grouping: rebalanced.moves.values, by: { $0 }).mapValues(\.count)
        XCTAssertGreaterThan(counts[bytrix] ?? 0, 0)
        XCTAssertGreaterThan(counts[hexorda] ?? 0, 0)
        XCTAssertGreaterThanOrEqual(counts[hexorda] ?? 0, counts[newer] ?? 0, "an empty window takes at least the partly used one's share")
        XCTAssertNil(counts[cybrio])

        // A mid-turn session keeps its account.
        var busy = blockedSessions()
        busy[0].movable = false
        let held = SessionPacer().rebalance(accounts: blockedAccounts(), sessions: busy,
                                            destinations: [bytrix, hexorda, newer], now: now)
        XCTAssertNil(held.moves["c0"])
        XCTAssertEqual(held.moves.count, 11)
    }

    @MainActor
    func testFailoversCannotServeMovesSplitAcrossEveryAccountThatCanServe() {
        // Hexorda and the newer account take no new sessions; a session that
        // must leave cybrio may still go there.
        let members = [cybrio, bytrix, hexorda, newer].map {
            RouterPoolMember(accountID: $0.uuidString, tokenFile: "t", weight: $0 == bytrix ? 1 : 0)
        }
        let chosen = AppState.strandedDestinations(members) { $0 != cybrio }
        XCTAssertEqual(chosen.map(\.accountID), [bytrix, hexorda, newer].map(\.uuidString))

        let placed = SessionPacer().place(blockedSessions(), accounts: blockedAccounts(), running: [],
                                          destinations: [bytrix, hexorda, newer], now: now)
        XCTAssertEqual(placed.count, 12, "every session is served somewhere rather than refused")
        let counts = Dictionary(grouping: placed.values, by: { $0 }).mapValues(\.count)
        XCTAssertGreaterThan(counts[bytrix] ?? 0, 0)
        XCTAssertGreaterThan(counts[hexorda] ?? 0, 0)
        XCTAssertLessThan(counts[bytrix] ?? 0, 12, "not everything goes to the one account with weight")

        // Once Personal is out, all thirteen of its sessions are served on
        // the Pro windows.
        let stranded = sessions().map {
            SessionPacer.RebalanceSession(id: $0.id, account: personal, tokensPerHour: $0.tokensPerHour,
                                          contextTokens: $0.contextTokens, model: nil, movable: true, cacheLifetime: 3600)
        }
        let out = SessionPacer().place(stranded, accounts: Array(accounts().dropFirst()), running: [],
                                       destinations: Set(pros), now: now)
        XCTAssertEqual(out.count, 13)
        XCTAssertEqual(Set(out.values), Set(pros))
    }

    @MainActor
    func testTheEventsNameTheWindowAndTheUnblockedMoves() {
        let event = AppState.windowMoveEvent(session: "session 1234abcd", from: "Personal", account: "hexorda",
                                             until: now.addingTimeInterval(50 * 60), now: now)
        XCTAssertTrue(event.hasPrefix("Session balancing moved session 1234abcd from Personal to hexorda, using hexorda's session window until "))
        XCTAssertTrue(event.hasSuffix("; it rebuilds its cache there."))

        let move = AppState.RebalanceMove(session: "c0", from: cybrio, to: bytrix)
        let preview = AppState.RebalancePreview(moves: [move], unblockedMoves: 1)
        XCTAssertTrue(preview.outcome.hasPrefix("1 session(s) move off an account that cannot serve them"))
        XCTAssertTrue(AppState.rebalanceIsWorthIt(preview))
    }
}
