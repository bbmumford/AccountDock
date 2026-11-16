import XCTest
@testable import AccountDock

/// Two Max 5x accounts with room in their 5-hour windows beside a Max 20x
/// account with only a weekly allowance, and very heavy sessions: a session
/// placed to use a small window stays there while the window fills, so the
/// shedding rule, a rebalance and the window rule no longer move it back and
/// forth (`SessionPacer.plan`'s and `rebalance`'s `placements`).
final class WindowPlacementTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let hexorda = UUID(), bytrix = UUID(), backup = UUID()

    /// Hexorda (Max 5x, 40% of its window, reset in 3 hours) and bytrix
    /// (Max 5x, 55%, reset in 2.5 hours), each 6-8% into its week and
    /// taking no new session, at their learned 3.25 and 2.25 percent per
    /// million weighted tokens; Backup (Max 20x, no 5-hour window, 7% into
    /// its week) taking new sessions at 0.97.
    func accounts() -> [SessionPacer.Account] {
        func small(_ id: UUID, used: Double, resetIn hours: Double, ratio: Double, weekly: Double) -> SessionPacer.Account {
            var account = SessionPacer.Account(id: id, utilization: used, resetsAt: now.addingTimeInterval(hours * 3600),
                                               burnPerHour: 0, baseWeight: 0, percentPerMillion: ratio)
            account.weeklyRemaining = (99 - weekly) * 8
            account.weeklyResetsAt = now.addingTimeInterval(100 * 3600)
            return account
        }
        var large = SessionPacer.Account(id: backup, utilization: 0, resetsAt: nil, burnPerHour: 0, baseWeight: 1,
                                         percentPerMillion: 0.97)
        large.weeklyRemaining = (99 - 7) * 8
        large.weeklyResetsAt = now.addingTimeInterval(48 * 3600)
        large.hasSessionWindow = false
        return [small(hexorda, used: 40, resetIn: 3, ratio: 3.25, weekly: 6),
                small(bytrix, used: 55, resetIn: 2.5, ratio: 2.25, weekly: 8), large]
    }

    /// Three heavy sessions on Backup, 1603da04 on hexorda where a window
    /// move put it, and a78ddf66 on bytrix; all between turns.
    func sessions() -> [SessionPacer.Session] {
        func session(_ id: String, on account: UUID, millions: Double, context: Int) -> SessionPacer.Session {
            SessionPacer.Session(id: id, account: account, tokensPerHour: millions * 1_000_000, contextTokens: context,
                                 lastSeen: now.addingTimeInterval(-5 * 60), cacheLifetime: 3600,
                                 lastTurnStart: now.addingTimeInterval(-6 * 60), recentTokensPerHour: millions * 1_000_000)
        }
        return [session("s97", on: backup, millions: 97.5, context: 900_000),
                session("s70", on: backup, millions: 69.7, context: 800_000),
                session("s38", on: backup, millions: 38.3, context: 600_000),
                session("1603da04", on: hexorda, millions: 11.7, context: 640_000),
                session("a78ddf66", on: bytrix, millions: 21.3, context: 500_000)]
    }

    func rebalanceSessions() -> [SessionPacer.RebalanceSession] {
        sessions().map {
            SessionPacer.RebalanceSession(id: $0.id, account: $0.account, tokensPerHour: $0.tokensPerHour,
                                          contextTokens: $0.contextTokens, model: nil, movable: true, cacheLifetime: 3600)
        }
    }

    var hexordaPlacement: [String: SessionPacer.WindowUse] {
        ["1603da04": SessionPacer.WindowUse(account: hexorda, until: now.addingTimeInterval(75 * 60))]
    }

    func testWithoutAPlacementTheShedderPullsTheWindowSessionBack() {
        let plan = SessionPacer().plan(accounts: accounts(), sessions: sessions(), now: now)
        XCTAssertNotNil(plan.shedding[hexorda], "hexorda reaches its limit 1.5 hours before its reset")
        XCTAssertEqual(plan.moves["1603da04"], backup, "the move the window rule had just made is undone")
        XCTAssertNotNil(plan.shedding[bytrix])
    }

    func testAnAccountAWindowPlacementFillsIsNotShedAndItsSessionStays() {
        let plan = SessionPacer().plan(accounts: accounts(), sessions: sessions(), now: now, placements: hexordaPlacement)
        XCTAssertNil(plan.shedding[hexorda], "reaching its window's limit is what the placement is for")
        XCTAssertNil(plan.moves["1603da04"])
        XCTAssertEqual(plan.filling[hexorda], now.addingTimeInterval(75 * 60))
        // Bytrix has no placement: the shedding rule still applies to it,
        // and nothing it gives up goes to hexorda's planned room.
        XCTAssertNotNil(plan.shedding[bytrix])
        XCTAssertEqual(plan.moves["a78ddf66"], backup)
        XCTAssertFalse(plan.moves.values.contains(hexorda))

        // Once a window move has put 4822c359 on bytrix as well, neither
        // small account is shed.
        var both = hexordaPlacement
        both["a78ddf66"] = SessionPacer.WindowUse(account: bytrix, until: now.addingTimeInterval(45 * 60))
        let filled = SessionPacer().plan(accounts: accounts(), sessions: sessions(), now: now, placements: both)
        XCTAssertTrue(filled.shedding.isEmpty)
        XCTAssertTrue(filled.moves.isEmpty)
    }

    func testAPlacementOnAnotherAccountThanTheSessionsIsNotInForce() {
        var moved = sessions()
        moved[3].account = backup
        let plan = SessionPacer().plan(accounts: accounts(), sessions: moved, now: now, placements: hexordaPlacement)
        XCTAssertTrue(plan.filling.isEmpty, "the session has left the window it was placed on")
    }

    func testAWeeklyLimitBindingFirstStillSheds() {
        // Hexorda's week nearly spent: its weekly allowance binds before its
        // window fills, which no window placement planned.
        var short = accounts()
        short[0].weeklyRemaining = 20
        let plan = SessionPacer().plan(accounts: short, sessions: sessions(), now: now, placements: hexordaPlacement)
        XCTAssertNotNil(plan.shedding[hexorda])
        XCTAssertNil(plan.moves["1603da04"], "the placed session itself still stays")
    }

    func testRebalanceCountsTheWindowsPlannedUseAsServedWork() {
        let destinations: Set<UUID> = [hexorda, bytrix, backup]
        let unplaced = SessionPacer().rebalance(accounts: accounts(), sessions: rebalanceSessions(),
                                                destinations: destinations, now: now)
        XCTAssertEqual(unplaced.moves["1603da04"], backup, "without the placement the search undoes the window move")
        XCTAssertEqual(unplaced.moves["a78ddf66"], backup)

        let placed = SessionPacer().rebalance(accounts: accounts(), sessions: rebalanceSessions(),
                                              destinations: destinations, now: now, placements: hexordaPlacement)
        XCTAssertNil(placed.moves["1603da04"])
        XCTAssertEqual(placed.filling, [hexorda])
        XCTAssertFalse(placed.moves.values.contains(hexorda), "no session is moved onto the planned room")
        XCTAssertEqual(placed.moves["a78ddf66"], backup, "bytrix has no placement")
        // Hexorda's planned fill in about 1.5 hours is not the run-out
        // reported: bytrix's is, before the move.
        let bytrixRunOut = SessionPacer().runway(accounts()[1], sessions: [rebalanceSessions()[4]], spent: 0, now: now)
        XCTAssertEqual(placed.earliestRunOutBefore?.timeIntervalSince(now) ?? 0, bytrixRunOut, accuracy: 1)
        XCTAssertGreaterThan(placed.earliestRunOutAfter ?? now, now.addingTimeInterval(3 * 3600))
    }

    func testAPlacedSessionWhoseWindowIsAtItsLimitMovesOn() {
        // Hexorda's window is full: it is no destination, and its placed
        // session moves as any session on an account that cannot serve it.
        let rebalanced = SessionPacer().rebalance(accounts: accounts(), sessions: rebalanceSessions(),
                                                  destinations: [bytrix, backup], now: now, placements: hexordaPlacement)
        XCTAssertNotNil(rebalanced.moves["1603da04"])
        XCTAssertTrue(rebalanced.unblocked.contains("1603da04"))
        XCTAssertTrue(rebalanced.filling.isEmpty)
    }

    func testAStrandedSessionAvoidsAWindowAPlacementFillsWhileAnotherAccountCanServe() {
        // A light placed session leaves hexorda's window lasting past its
        // reset, so a light session leaving bytrix, at its limit, would
        // otherwise go there.
        var running = rebalanceSessions().filter { $0.id != "a78ddf66" }
        running[3].tokensPerHour = 2_000_000
        let stranded = SessionPacer.RebalanceSession(id: "c0", account: bytrix, tokensPerHour: 2_200_000, contextTokens: 50_000,
                                                     model: nil, movable: true, cacheLifetime: 3600)
        let unplaced = SessionPacer().rebalance(accounts: accounts(), sessions: running + [stranded],
                                                destinations: [hexorda, backup], now: now)
        XCTAssertEqual(unplaced.moves["c0"], hexorda)
        let placed = SessionPacer().rebalance(accounts: accounts(), sessions: running + [stranded],
                                              destinations: [hexorda, backup], now: now, placements: hexordaPlacement)
        XCTAssertEqual(placed.moves["c0"], backup, "hexorda's room is planned for the placement")
    }

    // MARK: - The hold after a move

    func testAMovedSessionIsHeldForItsCacheLifetimeAtLeastAnHour() {
        XCTAssertEqual(AppState.moveHold(cacheLifetime: nil), 3600)
        XCTAssertEqual(AppState.moveHold(cacheLifetime: 300), 3600, "an hour even for a five-minute cache")
        XCTAssertEqual(AppState.moveHold(cacheLifetime: 7200), 7200)
        let moved = now.addingTimeInterval(-59 * 60)
        XCTAssertTrue(AppState.withinHold(movedAt: moved, cacheLifetime: 3600, now: now))
        XCTAssertFalse(AppState.withinHold(movedAt: moved, cacheLifetime: 3600, now: now.addingTimeInterval(2 * 60)))
    }

    func testTheShedderLeavesAHeldSessionAndSaysWhy() {
        // 1603da04 moved to hexorda by another rule minutes ago, with no
        // placement: hexorda still gives sessions up, but not that one.
        let plan = SessionPacer().plan(accounts: accounts(), sessions: sessions(), now: now, held: ["1603da04"])
        XCTAssertNotNil(plan.shedding[hexorda])
        XCTAssertNil(plan.moves["1603da04"])
        XCTAssertEqual(plan.heldBack["1603da04"], backup, "the move the hold stopped, for its event")
        XCTAssertEqual(plan.moves["a78ddf66"], backup, "a session outside its hold still moves")
        XCTAssertNil(plan.heldBack["a78ddf66"])
    }

    func testTheAutomaticRebalanceLeavesHeldSessionsUnlessTheirAccountCannotServe() {
        let destinations: Set<UUID> = [hexorda, bytrix, backup]
        let held = SessionPacer().rebalance(accounts: accounts(), sessions: rebalanceSessions(), destinations: destinations,
                                            now: now, held: ["a78ddf66", "1603da04"])
        XCTAssertTrue(held.moves.isEmpty)
        XCTAssertEqual(held.heldBack["a78ddf66"], backup)

        // Bytrix at its limit: its held session moves all the same.
        let blocked = SessionPacer().rebalance(accounts: accounts(), sessions: rebalanceSessions(),
                                               destinations: [hexorda, backup], now: now, held: ["a78ddf66"])
        XCTAssertNotNil(blocked.moves["a78ddf66"])
        XCTAssertTrue(blocked.unblocked.contains("a78ddf66"))
    }

    func testTheWindowRuleTakesNoHeldSession() {
        // The automatic rebalance moved 4822c359 onto the large account a
        // few minutes ago; the window rule then moved it on to bytrix.
        let carrier = UUID()
        var large = SessionPacer.Account(id: carrier, utilization: 30, resetsAt: now.addingTimeInterval(3 * 3600),
                                         burnPerHour: 0, baseWeight: 1, percentPerMillion: 0.25)
        large.weeklyRemaining = 48
        large.weeklyResetsAt = now.addingTimeInterval(60 * 3600)
        var window = SessionPacer.Account(id: bytrix, utilization: 0, resetsAt: nil, burnPerHour: 0, baseWeight: 0,
                                          percentPerMillion: 1)
        window.weeklyRemaining = 600
        window.weeklyResetsAt = now.addingTimeInterval(100 * 3600)
        let running = (0..<6).map {
            SessionPacer.Session(id: $0 == 0 ? "4822c359" : "big\($0)", account: carrier, tokensPerHour: 30_000_000,
                                 contextTokens: 100_000, lastSeen: now.addingTimeInterval(-5 * 60), cacheLifetime: 3600,
                                 lastTurnStart: now.addingTimeInterval(-6 * 60), recentTokensPerHour: 30_000_000)
        }
        let spending = SessionPacer.RemainderSpending(accounts: [bytrix], sessions: Set(running.map(\.id)))
        let free = SessionPacer().plan(accounts: [large, window], sessions: running, now: now, remainders: spending)
        XCTAssertNotNil(free.windowUses["4822c359"])
        let held = SessionPacer().plan(accounts: [large, window], sessions: running, now: now, remainders: spending,
                                       held: ["4822c359"])
        XCTAssertNil(held.moves["4822c359"])
        XCTAssertFalse(held.windowUses.isEmpty, "another session uses the window instead")
    }

    @MainActor
    func testTheHeldMoveEventSaysWhyTheSessionStays() {
        let event = AppState.heldMoveEvent(session: "session 1603da04 in ~/Mother", account: "hexorda", destination: "Backup",
                                           rule: "pacing", movedAt: now.addingTimeInterval(-60), until: now.addingTimeInterval(59 * 60),
                                           now: now)
        XCTAssertTrue(event.hasPrefix("Kept session 1603da04 in ~/Mother on hexorda although pacing would move it to Backup: it moved there at "))
        XCTAssertTrue(event.hasSuffix("It moves sooner only if hexorda refuses it or reaches its limit."))
    }

    // MARK: - New sessions on small windows

    @MainActor
    func testASmallWindowWithRoomThatWouldExpireTakesAShareSizedToItsRoom() {
        // A typical session (29M an hour, 94% of hexorda's window) cannot run
        // for an hour on either Max 5x account. Hexorda's own rate leaves
        // its 59% unused at its reset: 18M tokens over 3 hours, a fifth of
        // a typical session's rate. Bytrix's own session fills its window.
        let typical = 29_000_000.0
        var empty = accounts()[0]
        XCTAssertEqual(AppState.windowShare(empty, typicalRate: typical, now: now), 59 / 3.25 / 3 / 29, accuracy: 0.001)
        var busy = accounts()[1]
        busy.burnPerHour = 21.3 * 2.25
        XCTAssertEqual(AppState.windowShare(busy, typicalRate: typical, now: now), 0, "its own session uses that room")
        XCTAssertEqual(AppState.windowShare(accounts()[2], typicalRate: typical, now: now), 0, "no session window")
        empty.utilization = 99
        XCTAssertEqual(AppState.windowShare(empty, typicalRate: typical, now: now), 0)
    }

    func testThePacerGivesAnExpiringWindowNewSessionsBesideACarrier() {
        // Backup carries a typical session for the hour; hexorda does not,
        // but its window's room is lost at its reset unless used, so it
        // takes new sessions too, fewer than Backup. Bytrix's own use, which
        // its readings show, reaches its limit before its reset: none there.
        var open = accounts()
        open[0].baseWeight = 1
        open[1].baseWeight = 1
        open[1].burnPerHour = 21.3 * 2.25
        let running = [SessionPacer.Session(id: "b1", account: backup, tokensPerHour: 11_700_000, contextTokens: 300_000,
                                            lastSeen: now.addingTimeInterval(-60), cacheLifetime: 3600,
                                            recentTokensPerHour: 11_700_000)]
        let plan = SessionPacer().plan(accounts: open, sessions: running, now: now)
        XCTAssertGreaterThan(plan.weights[backup] ?? 0, 0)
        XCTAssertGreaterThan(plan.weights[hexorda] ?? 0, 0)
        XCTAssertLessThan(plan.weights[hexorda] ?? 0, plan.weights[backup] ?? 0)
        XCTAssertEqual(plan.weights[bytrix], 0)
        // The share is the room's own rate at most.
        let room = SessionPacer().expiringWindowRate(open[0], burn: 0, now: now)
        XCTAssertEqual(room, 59 / 3.25 / 3, accuracy: 0.001)
        XCTAssertLessThanOrEqual(plan.weights[hexorda] ?? 0, room + 0.0001)
    }

    func testARestingWindowStaysAWindowButTakesNoFurtherSession() {
        // Three Max 5x windows offered for spending while the large account
        // runs out before they refill; hexorda took a session within the
        // last half hour.
        let carrier = UUID(), third = UUID()
        var large = SessionPacer.Account(id: carrier, utilization: 30, resetsAt: now.addingTimeInterval(3 * 3600),
                                         burnPerHour: 0, baseWeight: 1, percentPerMillion: 0.25)
        large.weeklyRemaining = 48
        large.weeklyResetsAt = now.addingTimeInterval(60 * 3600)
        let windows = [hexorda, bytrix, third].map { id -> SessionPacer.Account in
            var account = SessionPacer.Account(id: id, utilization: 0, resetsAt: nil, burnPerHour: 0, baseWeight: 0,
                                               percentPerMillion: 1)
            account.weeklyRemaining = 600
            account.weeklyResetsAt = now.addingTimeInterval(100 * 3600)
            return account
        }
        func session(_ id: String, on account: UUID, millions: Double, context: Int) -> SessionPacer.Session {
            SessionPacer.Session(id: id, account: account, tokensPerHour: millions * 1_000_000, contextTokens: context,
                                 lastSeen: now.addingTimeInterval(-5 * 60), cacheLifetime: 3600,
                                 lastTurnStart: now.addingTimeInterval(-6 * 60), recentTokensPerHour: millions * 1_000_000)
        }
        let running = (0..<6).map { session("big\($0)", on: carrier, millions: 30, context: 100_000) }
            + [session("onHexorda", on: hexorda, millions: 5, context: 100_000)]
        let spending = SessionPacer.RemainderSpending(accounts: [hexorda, bytrix, third], sessions: Set(running.map(\.id)),
                                                      resting: [hexorda])
        let plan = SessionPacer().plan(accounts: [large] + windows, sessions: running, now: now, remainders: spending)
        XCTAssertFalse(plan.windowUses.isEmpty, "the large account runs out before the windows refill")
        XCTAssertFalse(plan.moves.values.contains(hexorda), "a resting window takes no further session")
        XCTAssertNil(plan.moves["onHexorda"], "and the session it took stays")
        XCTAssertNil(plan.shedding[hexorda])
    }
}
