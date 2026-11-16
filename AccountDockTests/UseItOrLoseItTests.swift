import XCTest
@testable import AccountDock

/// Allowance that would expire unused is spent first: an account whose
/// weekly allowance its session windows can no longer drain before the
/// weekly reset fills its window instead of giving work up
/// (`SessionPacer.useBy`, `freeRoom`), and new sessions follow how soon
/// each allowance must be spent (`evenRate`). The fixture is six Claude
/// accounts at 9:12 pm on a Monday: bytrix (Max 5x) with 68% of its week
/// resetting at 1:00 am and its 5-hour window 37% used until 1:30 am;
/// hexorda (Max 5x) resetting on Saturday; cybrio (Max 5x) resetting on
/// Tuesday evening; fluxon (Max 20x, the active account) on Tuesday night;
/// Backup (Max 20x, no 5-hour window) with 11% of its week left until next
/// Monday; and voltrix (Pro) with a fresh window.
final class UseItOrLoseItTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let bytrix = UUID(), hexorda = UUID(), cybrio = UUID(), fluxon = UUID(), backup = UUID(), voltrix = UUID()

    private func at(_ hours: Double) -> Date { now.addingTimeInterval(hours * 3600) }

    /// An account with its window `used`% resetting in `resetIn` hours and
    /// its week `weeklyUsed`% resetting in `weeklyResetIn` hours, eight
    /// windows to the week, spending `rate` weighted tokens an hour.
    private func account(_ id: UUID, used: Double, resetIn: Double?, ratio: Double, weeklyUsed: Double,
                         weeklyResetIn: Double, weight: Double, window: Bool = true, rate: Double) -> SessionPacer.Account {
        var account = SessionPacer.Account(id: id, utilization: used, resetsAt: resetIn.map(at),
                                           burnPerHour: rate / 1_000_000 * ratio, baseWeight: weight, percentPerMillion: ratio)
        account.weeklyRemaining = (99 - weeklyUsed) * 8
        account.weeklyResetsAt = at(weeklyResetIn)
        account.hasSessionWindow = window
        return account
    }

    /// The accounts as the readings show them, with the pool's weights:
    /// the Max 5x accounts short of the runway take no new session.
    /// `bytrixRate` is what bytrix's sessions spend.
    private func accounts(bytrixRate: Double = 52_000_000, bytrixWeight: Double = 0) -> [SessionPacer.Account] {
        [account(bytrix, used: 37, resetIn: 4.3, ratio: 0.989, weeklyUsed: 32, weeklyResetIn: 3.8, weight: bytrixWeight,
                 rate: bytrixRate),
         account(hexorda, used: 15, resetIn: 3.97, ratio: 4.25, weeklyUsed: 23, weeklyResetIn: 103.8, weight: 0,
                 rate: 15_000_000),
         account(cybrio, used: 31, resetIn: 4.3, ratio: 1.262, weeklyUsed: 29, weeklyResetIn: 23.8, weight: 0,
                 rate: 113_000_000),
         account(fluxon, used: 43, resetIn: 3.63, ratio: 0.2537, weeklyUsed: 51, weeklyResetIn: 25.8, weight: 1,
                 rate: 102_000_000),
         account(backup, used: 0, resetIn: nil, ratio: 0.516, weeklyUsed: 89, weeklyResetIn: 154.8, weight: 1, window: false,
                 rate: 28_000_000),
         account(voltrix, used: 0, resetIn: 4.3, ratio: 8.96, weeklyUsed: 5, weeklyResetIn: 163.8, weight: 1, rate: 0)]
    }

    private func session(_ id: String, _ account: UUID, _ rate: Double, context: Int = 300_000) -> SessionPacer.Session {
        SessionPacer.Session(id: id, account: account, tokensPerHour: rate, contextTokens: context,
                             lastSeen: now.addingTimeInterval(-300), cacheLifetime: 3600,
                             lastTurnStart: now.addingTimeInterval(-360), recentTokensPerHour: rate)
    }

    /// cf-builder (8c64c5f8) on bytrix, two on hexorda, the heavy 33962de2
    /// on cybrio, three on fluxon and a78ddf66 on Backup.
    private func sessions(bytrixRate: Double = 52_000_000) -> [SessionPacer.Session] {
        [session("8c64c5f8", bytrix, bytrixRate),
         session("19496bb9", hexorda, 12_000_000, context: 295_000), session("1603da04", hexorda, 3_000_000, context: 100_000),
         session("33962de2", cybrio, 113_000_000, context: 227_000),
         session("583fb354", fluxon, 26_000_000), session("4822c359", fluxon, 22_000_000),
         session("345dc95e", fluxon, 14_000_000, context: 887_000),
         session("a78ddf66", backup, 28_000_000, context: 249_000)]
    }

    /// The sessions on the shared sign-in, on fluxon with failover off.
    private var group: SessionPacer.SharedGroup {
        SessionPacer.SharedGroup(account: fluxon, tokensPerHour: 40_000_000, contextTokens: 400_000, models: [], sessionCount: 3)
    }

    private var spending: SessionPacer.RemainderSpending {
        SessionPacer.RemainderSpending(accounts: [bytrix, hexorda, cybrio, voltrix], sessions: Set(sessions().map(\.id)))
    }

    private func rebalanceSessions(bytrixRate: Double = 52_000_000) -> [SessionPacer.RebalanceSession] {
        sessions(bytrixRate: bytrixRate).map {
            SessionPacer.RebalanceSession(id: $0.id, account: $0.account, tokensPerHour: $0.tokensPerHour,
                                          contextTokens: $0.contextTokens, model: nil, movable: true, cacheLifetime: 3600)
        }
    }

    func testAnAllowanceItsWindowsCannotDrainIsFreeUntilTheEarlierReset() throws {
        let pacer = SessionPacer()
        let byID = Dictionary(uniqueKeysWithValues: accounts().map { ($0.id, $0) })
        // bytrix: 536% of a window left in its week, 62% in its window,
        // which resets after the week does.
        XCTAssertEqual(try XCTUnwrap(pacer.useBy(byID[bytrix]!, now: now)), at(3.8))
        XCTAssertEqual(pacer.sessionCapacity(byID[bytrix]!, until: at(3.8), spent: 0, now: now), 62, accuracy: 0.001)
        // cybrio: five windows by Tuesday evening hold 464% of its 560%.
        XCTAssertEqual(try XCTUnwrap(pacer.useBy(byID[cybrio]!, now: now)), at(4.3))
        XCTAssertEqual(pacer.refills(byID[cybrio]!, before: at(23.8), now: now), 4)
        // fluxon's windows drain its week a day early, hexorda's and
        // voltrix's days early; Backup has no window to cap it.
        for id in [fluxon, hexorda, voltrix, backup] { XCTAssertNil(pacer.useBy(byID[id]!, now: now)) }
        // cf-builder alone fills bytrix's window by 10:25 pm, so none of it
        // is left free; at 3M an hour most of it would be.
        XCTAssertEqual(pacer.freeRoom(byID[bytrix]!, spent: 0, burn: byID[bytrix]!.burnPerHour, shared: nil, now: now), 0)
        let light = accounts(bytrixRate: 3_000_000)[0]
        XCTAssertEqual(pacer.freeRoom(light, spent: 0, burn: light.burnPerHour, shared: nil, now: now), 50.7, accuracy: 0.1)
    }

    func testAnAccountWhoseWeekWouldExpireFillsItsWindowInsteadOfGivingSessionsUp() {
        let plan = SessionPacer().plan(accounts: accounts(), sessions: sessions(), now: now, sharedGroup: group,
                                       remainders: spending)
        XCTAssertNil(plan.shedding[bytrix], "bytrix reaching its window's limit at 10:25 pm uses week that expires at 1:00 am")
        XCTAssertNil(plan.shedding[cybrio])
        XCTAssertNil(plan.moves["8c64c5f8"])
        XCTAssertNil(plan.moves["33962de2"])
        XCTAssertNotNil(plan.shedding[hexorda], "hexorda's week lasts to Saturday, so moving its sessions still keeps work running")
    }

    func testRebalanceNeitherMovesWorkOffNorCountsTheRunOutOfAFillingAccount() throws {
        let rebalanced = SessionPacer().rebalance(accounts: accounts(), sessions: rebalanceSessions(),
                                                  destinations: [bytrix, hexorda, cybrio, fluxon, backup, voltrix], now: now,
                                                  sharedGroup: group)
        XCTAssertNil(rebalanced.moves["8c64c5f8"])
        XCTAssertNil(rebalanced.moves["33962de2"])
        XCTAssertFalse(rebalanced.moves.values.contains(bytrix))
        XCTAssertFalse(rebalanced.moves.values.contains(cybrio))
        // The first run-out reported is hexorda's, not cybrio's window
        // filling in half an hour.
        XCTAssertGreaterThan(try XCTUnwrap(rebalanced.earliestRunOutBefore), at(1.3))
    }

    func testFreeRoomIsWhereShedAndStrandedWorkGoesFirst() throws {
        // cf-builder spends 3M an hour: half of bytrix's window would be
        // left unused at 1:00 am.
        let light = accounts(bytrixRate: 3_000_000, bytrixWeight: 2)
        let plan = SessionPacer().plan(accounts: light, sessions: sessions(bytrixRate: 3_000_000), now: now,
                                       sharedGroup: group, remainders: spending)
        XCTAssertEqual(plan.moves["19496bb9"], bytrix, "hexorda's session goes to the free room before Backup's lasting week")
        let stranded = rebalanceSessions(bytrixRate: 3_000_000).filter { $0.id == "1603da04" }
        let placed = SessionPacer().place(stranded, accounts: light,
                                          running: rebalanceSessions(bytrixRate: 3_000_000).filter { $0.id != "1603da04" },
                                          destinations: [bytrix, fluxon, backup, voltrix], now: now, sharedGroup: group)
        XCTAssertEqual(placed["1603da04"], bytrix)
        // A session that would fill the free room within the hour is not
        // sent there: 113M an hour would spend it in half an hour.
        let heavy = rebalanceSessions(bytrixRate: 3_000_000).filter { $0.id == "33962de2" }
        let heavyPlaced = SessionPacer().place(heavy, accounts: light,
                                               running: rebalanceSessions(bytrixRate: 3_000_000).filter { $0.id != "33962de2" },
                                               destinations: [bytrix, fluxon, backup, voltrix], now: now, sharedGroup: group)
        XCTAssertNotEqual(heavyPlaced["33962de2"], bytrix)
    }

    func testNewSessionsFollowHowSoonEachAllowanceMustBeSpent() {
        let pacer = SessionPacer()
        let byID = Dictionary(uniqueKeysWithValues: accounts().map { ($0.id, $0) })
        // Backup's 80% of a window over the 155 hours to next Monday is 1M
        // tokens an hour; fluxon's week resetting tomorrow night needs 59M,
        // and bytrix's window, 62% over the 3.8 hours to its weekly reset,
        // 16.5M.
        XCTAssertEqual(pacer.evenRate(byID[backup]!, spent: 0, now: now), 1.0, accuracy: 0.01)
        XCTAssertEqual(pacer.evenRate(byID[fluxon]!, spent: 0, now: now), 58.7, accuracy: 0.1)
        XCTAssertEqual(pacer.evenRate(byID[bytrix]!, spent: 0, now: now), 16.5, accuracy: 0.1)
        let plan = pacer.plan(accounts: accounts(), sessions: sessions(), now: now, sharedGroup: group,
                              remainders: spending, held: ["8c64c5f8", "33962de2"])
        XCTAssertTrue(plan.windowsOpen)
        XCTAssertEqual(plan.weights[backup] ?? 0, 1.0, accuracy: 0.01,
                       "Backup's room to the first carrier's reset, 2.6M an hour, counts at its even rate")
        XCTAssertGreaterThan(plan.weights[voltrix] ?? 0, plan.weights[backup] ?? 0,
                             "a week with 11% left and six days to go is the last place new work goes")
        XCTAssertEqual(plan.weights[bytrix], 0, "cf-builder fills bytrix's window by 10:25 pm; another session only fills it sooner")
    }

    func testFreeRoomTakesNewSessionsFirst() {
        let light = sessions(bytrixRate: 3_000_000)
        let plan = SessionPacer().plan(accounts: accounts(bytrixRate: 3_000_000, bytrixWeight: 2), sessions: light, now: now,
                                       sharedGroup: group, fixed: Set(light.map(\.id)), remainders: spending)
        XCTAssertEqual(plan.weights[bytrix] ?? 0, 13.5, accuracy: 0.1, "51M tokens of free room over 3.8 hours")
        for id in [hexorda, cybrio, fluxon, backup, voltrix] { XCTAssertEqual(plan.weights[id], 0) }
    }
}
