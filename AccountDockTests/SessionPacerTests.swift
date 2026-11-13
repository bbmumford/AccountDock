import XCTest
@testable import AccountDock

final class SessionPacerTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let a = UUID(), b = UUID(), c = UUID()

    /// Accounts at one window percent per million tokens unless `ratio`
    /// says otherwise, so a session's `burn` is its percent per hour there.
    func testWhenEveryAccountRunsShortNewSessionsGoWhereTheAllowanceLastsLongest() {
        let pacer = SessionPacer()
        func short(_ id: UUID, left: Double, resetHours: Double, burn: Double) -> SessionPacer.Account {
            var a = account(id, used: 0, resetIn: nil, burn: burn)
            a.hasSessionWindow = false
            a.weeklyRemaining = left
            a.weeklyResetsAt = now.addingTimeInterval(resetHours * 3600)
            return a
        }
        let soon = UUID(), later = UUID(), empty = UUID()
        // Each would reach its limit before its reset; `later` sustains half
        // its rate until then, `soon` a fifth, `empty` nothing.
        let accounts = [short(soon, left: 100, resetHours: 100, burn: 5),
                        short(later, left: 200, resetHours: 40, burn: 10),
                        short(empty, left: 0, resetHours: 10, burn: 3)]
        let plan = pacer.plan(accounts: accounts, sessions: [], now: now)
        XCTAssertEqual(plan.weights[later] ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(plan.weights[soon] ?? 0, 0.2, accuracy: 0.001)
        XCTAssertEqual(plan.weights[empty] ?? -1, 0, accuracy: 0.001)
    }

    func testAnAccountWithoutASessionWindowIsLimitedByItsWeeklyAllowanceAlone() {
        let id = UUID()
        var open = account(id, used: 0, resetIn: nil, burn: 30)
        open.hasSessionWindow = false
        open.weeklyRemaining = 500
        open.weeklyResetsAt = now.addingTimeInterval(100 * 3600)
        let pacer = SessionPacer()
        XCTAssertEqual(pacer.outlook(open, burn: 30, now: now).windowEndsAt, open.weeklyResetsAt)
        let hours = pacer.outlook(open, burn: 30, now: now).limitAt?.timeIntervalSince(now) ?? 0
        XCTAssertEqual(hours / 3600, 500.0 / 30, accuracy: 0.01)
        XCTAssertEqual(pacer.outlook(open, burn: 30, now: now).allowedPerHour, 5, accuracy: 0.01)
    }

    func account(_ id: UUID, used: Double, resetIn hours: Double?, burn: Double = 0, weight: Double = 1,
                 ratio: Double = 1) -> SessionPacer.Account {
        SessionPacer.Account(id: id, utilization: used, resetsAt: hours.map { now.addingTimeInterval($0 * 3600) },
                             burnPerHour: burn, baseWeight: weight, percentPerMillion: ratio)
    }

    func session(_ id: String, on account: UUID, burn: Double, context: Int = 100_000,
                 idle minutes: Double = 1, cache: TimeInterval? = 3600) -> SessionPacer.Session {
        SessionPacer.Session(id: id, account: account, tokensPerHour: burn * 1_000_000, contextTokens: context,
                             lastSeen: now.addingTimeInterval(-minutes * 60), cacheLifetime: cache)
    }

    func candidate(_ id: String, burn: Double, on account: UUID? = nil) -> SessionPacer.Candidate {
        SessionPacer.Candidate(id: id, tokensPerHour: burn * 1_000_000, contextTokens: 100_000, account: account)
    }

    func testNewSessionsGoWhereTheMostRateIsUnused() {
        // a: 59% left over 1 h, using 50/h; b: 89% left over 4 h, idle.
        let plan = SessionPacer().plan(accounts: [account(a, used: 40, resetIn: 1, burn: 50), account(b, used: 10, resetIn: 4)],
                                       sessions: [], now: now)
        XCTAssertGreaterThan(plan.weights[b] ?? 0, plan.weights[a] ?? 0)
        XCTAssertTrue(plan.moves.isEmpty)
        XCTAssertTrue(plan.shedding.isEmpty)
    }

    func testAnAccountThatWouldWaitPastTheCacheGivesUpSessionsUntilItFits() {
        // a: 39% left over 4 h at 25/h reaches its limit in about 1.6 h.
        let plan = SessionPacer().plan(
            accounts: [account(a, used: 60, resetIn: 4), account(b, used: 10, resetIn: 4)],
            sessions: [session("fast", on: a, burn: 20), session("slow", on: a, burn: 5)], now: now)
        XCTAssertNotNil(plan.shedding[a])
        XCTAssertEqual(plan.moves, ["fast": b], "moving the fast session is enough; the slow one keeps its cache")
        XCTAssertEqual(plan.weights[a], 0)
    }

    func testAShortWaitAtTheLimitKeepsTheSessionsAndTheirCache() {
        // a reaches its limit 3 minutes before it resets.
        let plan = SessionPacer().plan(
            accounts: [account(a, used: 90, resetIn: 0.5), account(b, used: 0, resetIn: nil)],
            sessions: [session("s", on: a, burn: 20)], now: now)
        XCTAssertTrue(plan.shedding.isEmpty)
        XCTAssertTrue(plan.moves.isEmpty)
        XCTAssertEqual(plan.weights[a], 0, "an account that reaches its limit takes no new sessions")
        XCTAssertGreaterThan(plan.weights[b] ?? 0, 0)
    }

    func testTheWaitIsMeasuredAgainstTheSessionsOwnCacheLifetime() {
        // a reaches its limit 33 minutes before it resets.
        let accounts = [account(a, used: 90, resetIn: 1), account(b, used: 0, resetIn: 4)]
        let hour = SessionPacer().plan(accounts: accounts, sessions: [session("s", on: a, burn: 20, cache: 3600)], now: now)
        XCTAssertTrue(hour.moves.isEmpty)
        let fiveMinutes = SessionPacer().plan(accounts: accounts, sessions: [session("s", on: a, burn: 20, cache: 300)], now: now)
        XCTAssertEqual(fiveMinutes.moves, ["s": b])
    }

    func testASessionMovesOnlyToAnAccountThatCarriesItWithinItsWindow() {
        let plan = SessionPacer().plan(
            accounts: [account(a, used: 60, resetIn: 4), account(b, used: 95, resetIn: 4)],
            sessions: [session("s", on: a, burn: 30)], now: now)
        XCTAssertNotNil(plan.shedding[a])
        XCTAssertTrue(plan.moves.isEmpty, "b would reach its own limit, and the cache would be rewritten for nothing")
    }

    func testIdleSessionsAndTheObservedRateBothCount() {
        // The session is idle, but readings show the account burning fast.
        let plan = SessionPacer().plan(
            accounts: [account(a, used: 60, resetIn: 4, burn: 30), account(b, used: 0, resetIn: 4)],
            sessions: [session("idle", on: a, burn: 30, idle: 45)], now: now)
        XCTAssertNotNil(plan.shedding[a])
        XCTAssertTrue(plan.moves.isEmpty, "an idle session is placed again by the router at its next turn")
    }

    func testRatesDecayWhileASessionIsIdle() {
        var rates = SessionRates()
        rates.record(session: "s", account: a, context: 0, cacheWrite: 0, output: 100_000, cacheLifetime: 3600, at: now)
        let fresh = rates.tokensPerHour("s", now: now)
        XCTAssertEqual(fresh, 500_000 * 3, accuracy: 1)
        XCTAssertEqual(rates.tokensPerHour("s", now: now.addingTimeInterval(SessionRates.timeConstant)), fresh / M_E, accuracy: 1)
        rates.record(session: "s", account: a, context: 0, cacheWrite: 0, output: 0, cacheLifetime: nil, at: now)
        XCTAssertEqual(rates.entries["s"]?.cacheLifetime, 3600, "a request without cache marks keeps the known lifetime")
    }

    func testTheWeeklyAllowanceBindsWhenItRunsOutFirst() {
        // a has most of its 5-hour window, but 8% of a 5-hour window left this
        // week, which its session uses in about half an hour; the week resets
        // in two days.
        var weekly = account(a, used: 10, resetIn: 4)
        weekly.weeklyRemaining = 8
        weekly.weeklyResetsAt = now.addingTimeInterval(48 * 3600)
        let plan = SessionPacer().plan(accounts: [weekly, account(b, used: 10, resetIn: 4)],
                                       sessions: [session("s", on: a, burn: 15)], now: now)
        XCTAssertEqual(plan.shedding[a]?.windowEndsAt, weekly.weeklyResetsAt)
        XCTAssertEqual(plan.moves, ["s": b])
    }

    func testNewSessionsFavourAWeekThatResetsSooner() {
        // Same weekly allowance left; a's week ends in 6 hours, b's in 5 days,
        // so a's must be used faster or be lost.
        var soon = account(a, used: 0, resetIn: 5)
        soon.weeklyRemaining = 200
        soon.weeklyResetsAt = now.addingTimeInterval(6 * 3600)
        var late = account(b, used: 0, resetIn: 5)
        late.weeklyRemaining = 200
        late.weeklyResetsAt = now.addingTimeInterval(120 * 3600)
        let plan = SessionPacer().plan(accounts: [soon, late], sessions: [], now: now)
        XCTAssertGreaterThan(plan.weights[a] ?? 0, plan.weights[b] ?? 0)
    }

    func testSevenSessionsOnOneAccountSpreadOnlyAsFarAsItsWindowNeeds() {
        // a: 59% left for 3 hours, seven sessions at 6%/h reach the limit in
        // 1.4 h and would wait 1.6 h. b and c have just reset.
        let sessions = (1...7).map { session("s\($0)", on: a, burn: 6) }
        let plan = SessionPacer().plan(
            accounts: [account(a, used: 40, resetIn: 3), account(b, used: 0, resetIn: nil), account(c, used: 0, resetIn: nil)],
            sessions: sessions, now: now)
        XCTAssertEqual(plan.moves.count, 3, "three leave; at 24%/h the rest reach the limit within an hour of the reset")
        XCTAssertEqual(Set(plan.moves.values), [b, c], "the ones leaving are spread over both accounts")
        XCTAssertEqual(plan.weights[a], 0)
    }

    func testAMoveIsRememberedUntilTheReadingsCatchUp() {
        var rates = SessionRates()
        rates.record(session: "s", account: a, context: 0, cacheWrite: 0, output: 100_000, cacheLifetime: nil, at: now)
        let rate = rates.tokensPerHour("s", now: now)
        rates.record(session: "s", account: b, context: 0, cacheWrite: 0, output: 0, cacheLifetime: nil, at: now)
        XCTAssertEqual(rates.departed(a, now: now), rate, accuracy: 1)
        XCTAssertEqual(rates.departed(a, now: now.addingTimeInterval(SessionRates.timeConstant)), rate / M_E, accuracy: 1)
        XCTAssertEqual(rates.departed(b, now: now), 0)
    }

    // MARK: - Resuming as capacity allows

    func testAWorkerIsNotHeldUpByASmallSessionWhenBothFit() {
        // b has just reset: 99% for 5 hours, 19.8%/h.
        let admitted = SessionPacer().admit([candidate("small", burn: 3), candidate("worker", burn: 15)],
                                            accounts: [account(b, used: 0, resetIn: 5)], running: [], now: now)
        XCTAssertEqual(admitted, ["worker": .init(account: b), "small": .init(account: b)])
    }

    func testTheWorkerGoesFirstWhenOnlyOneFits() {
        // 76% left for 5 hours carries the worker and its cache rewrite,
        // with under 1% over.
        let admitted = SessionPacer().admit([candidate("small", burn: 8), candidate("worker", burn: 15)],
                                            accounts: [account(b, used: 23, resetIn: 5)], running: [], now: now)
        XCTAssertEqual(admitted, ["worker": .init(account: b)])
    }

    func testSessionsSpreadOverTheAccountsThatReset() {
        let admitted = SessionPacer().admit(
            [candidate("w1", burn: 15), candidate("w2", burn: 15), candidate("small", burn: 3)],
            accounts: [account(b, used: 23, resetIn: 5), account(c, used: 0, resetIn: 5)], running: [], now: now)
        XCTAssertEqual(admitted.count, 3)
        XCTAssertTrue(admitted.values.allSatisfy { !$0.surplus })
        XCTAssertEqual(Set(admitted.filter { $0.key.hasPrefix("w") }.values.map(\.account)), [b, c], "one worker on each")
    }

    func testRunningSessionsLeaveLessRoom() {
        let admitted = SessionPacer().admit([candidate("worker", burn: 15)],
                                            accounts: [account(b, used: 24, resetIn: 5)],
                                            running: [session("busy", on: b, burn: 14)], now: now)
        // 1%/h is left for the worker's 15, but 5% would go unused by the
        // reset, so it runs as surplus until the rest covers only "busy".
        XCTAssertEqual(admitted, ["worker": .init(account: b, surplus: true)])
        let pacer = SessionPacer()
        let b0 = account(b, used: 24, resetIn: 5)
        XCTAssertTrue(pacer.covers(b0, sessions: [session("busy", on: b, burn: 14)], now: now))
        let later = account(b, used: 36, resetIn: 4.6)
        XCTAssertFalse(pacer.covers(later, sessions: [session("busy", on: b, burn: 14)], now: now),
                       "once the surplus is spent the busy session needs the rest, and the surplus one is held")
    }

    func testSessionsWhoseNextTurnComesSoonLeaveBeforeOnesDeepInALongTurn() {
        // a: 39% left over 4 h at 16/h; moving either 8/h session is enough.
        var deep = session("deep", on: a, burn: 8, context: 100_000, idle: 0.2)
        deep.lastTurnStart = now.addingTimeInterval(-40 * 60)
        var fresh = session("fresh", on: a, burn: 8, context: 200_000, idle: 0.2)
        fresh.lastTurnStart = now.addingTimeInterval(-3 * 60)
        let accounts = [account(a, used: 60, resetIn: 4), account(b, used: 10, resetIn: 4)]
        let plan = SessionPacer().plan(accounts: accounts, sessions: [deep, fresh], now: now)
        XCTAssertEqual(plan.moves, ["fresh": b],
                       "the long-running turn would move only when it ends, though its smaller context relieves more per rewrite")
        let pacer = SessionPacer()
        XCTAssertFalse(pacer.movable(deep, now: now))
        var resting = deep
        resting.lastSeen = now.addingTimeInterval(-5 * 60)
        XCTAssertTrue(pacer.movable(resting, now: now), "a quiet session is between turns")
    }

    /// An account limited by its weekly allowance alone, with `fable` left
    /// of the allowance only Fable sessions draw on.
    func weekly(_ id: UUID, left: Double, fable: Double) -> SessionPacer.Account {
        var account = account(id, used: 0, resetIn: nil)
        account.hasSessionWindow = false
        account.weeklyRemaining = left
        account.weeklyResetsAt = now.addingTimeInterval(100 * 3600)
        account.scoped = ["fable": .init(remaining: fable, resetsAt: now.addingTimeInterval(100 * 3600))]
        return account
    }

    func testAModelsOwnAllowanceGivesUpOnlyThatModelsSessions() {
        var fable = session("fable", on: a, burn: 5)
        fable.model = "claude-fable-5-2[1m]"
        var opus = session("opus", on: a, burn: 1)
        opus.model = "claude-opus-5-5"
        // a has room for both sessions overall, but only two hours of Fable.
        let plan = SessionPacer().plan(accounts: [weekly(a, left: 2000, fable: 10), weekly(b, left: 2000, fable: 800)],
                                       sessions: [fable, opus], now: now)
        XCTAssertNil(plan.shedding[a], "the whole allowance carries its sessions")
        XCTAssertNotNil(plan.scopedShedding[a]?["fable"])
        XCTAssertEqual(plan.moves["fable"], b)
        XCTAssertNil(plan.moves["opus"], "a session on another model stays")
    }

    func testANewSessionOnAModelStartsWhereThatModelHasAllowanceLeft() {
        let plan = SessionPacer().plan(accounts: [weekly(a, left: 2000, fable: 0), weekly(b, left: 500, fable: 800)],
                                       sessions: [], now: now)
        XCTAssertGreaterThan(plan.weights[a] ?? 0, plan.weights[b] ?? 0, "by the whole allowance a has more unused")
        XCTAssertEqual(plan.modelWeights["fable"]?[a] ?? -1, 0, accuracy: 0.001)
        XCTAssertGreaterThan(plan.modelWeights["fable"]?[b] ?? 0, 0)
    }

    func testASessionOnlyMovesToAnAccountWithRoomForItsModel() {
        var busy = session("busy", on: a, burn: 5)
        busy.model = "Fable 5.2"
        // a runs out overall; b has the most room overall but no Fable left.
        let plan = SessionPacer().plan(accounts: [weekly(a, left: 10, fable: 800), weekly(b, left: 2000, fable: 0),
                                                  weekly(c, left: 1000, fable: 800)],
                                       sessions: [busy], now: now)
        XCTAssertNotNil(plan.shedding[a])
        XCTAssertEqual(plan.moves["busy"], c)
        var other = busy
        other.model = "claude-opus-5-5"
        let unscoped = SessionPacer().plan(accounts: [weekly(a, left: 10, fable: 800), weekly(b, left: 2000, fable: 0),
                                                      weekly(c, left: 1000, fable: 800)],
                                           sessions: [other], now: now)
        XCTAssertEqual(unscoped.moves["busy"], b, "a session on another model goes where the most is unused")
    }

    func testNewSessionsAreWeightedForTheModelMostSessionsUse() {
        let keys = ["fable"]
        XCTAssertEqual(AppState.prevailingAllowance(models: ["claude-fable-5-2[1m]", "Fable 5.2", "claude-opus-5-5"], keys: keys), "fable")
        XCTAssertNil(AppState.prevailingAllowance(models: ["claude-opus-5-5", "Sonnet 5.5", "Fable 5.2"], keys: keys))
        XCTAssertEqual(AppState.prevailingAllowance(models: ["Fable 5.2", "claude-opus-5-5"], keys: keys), "fable",
                       "a tie goes to the model with an allowance of its own")
        XCTAssertNil(AppState.prevailingAllowance(models: [], keys: keys))
    }
}
