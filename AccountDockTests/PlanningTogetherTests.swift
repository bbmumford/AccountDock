import XCTest
@testable import AccountDock

/// Every session one cycle sends or plans somewhere is charged to that
/// account in one ledger (`LaneLedger`), so the sessions held while every
/// account is at its limit are planned together: each lane's fresh window
/// takes only what it carries for the hour, the next sessions go to the
/// next lane by its reset, and the rest wait for their own accounts.
///
/// The fixture is the night every Claude account reached its 5-hour limit:
/// at 12:21 am fluxon (Max 20x) resets at 12:49 am, hexorda (Max 5x) at
/// 1:10 am, bytrix and cybrio (Max 5x) at 1:30 am and voltrix (Max 5x) at
/// 3:40 am, and Backup's week is at 99%. Thirteen sessions, two of them runs
/// with no session record, use about 278M weighted tokens an hour; fluxon's
/// learned cost was 2.37% of its window per million and hexorda's 4.25%.
final class PlanningTogetherTests: XCTestCase {
    /// 12:21:45 am.
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let fluxon = UUID(), hexorda = UUID(), bytrix = UUID(), cybrio = UUID(), voltrix = UUID(), backup = UUID()

    func minutes(_ value: Double) -> Date { now.addingTimeInterval(value * 60) }

    func account(_ id: UUID, _ name: String, ratio: Double, resetInMinutes: Double, weeklyUsed: Double = 40,
                 weeklyResetInMinutes: Double = 5 * 24 * 60,
                 availability: CapacityOutlook.Availability = .atLimit) -> CapacityOutlook.Account {
        CapacityOutlook.Account(
            pacer: SessionPacer.Account(id: id, utilization: 100, resetsAt: minutes(resetInMinutes), burnPerHour: 0,
                                        baseWeight: 0, weeklyRemaining: (SessionPacer().limit - weeklyUsed) * 8,
                                        weeklyResetsAt: minutes(weeklyResetInMinutes), percentPerMillion: ratio),
            name: name, availability: availability)
    }

    /// Every account at its limit, each with its own reset.
    func tonight(fluxonRatio: Double = 2.37) -> [CapacityOutlook.Account] {
        [account(fluxon, "fluxon", ratio: fluxonRatio, resetInMinutes: 27),
         account(hexorda, "hexorda", ratio: 4.25, resetInMinutes: 48),
         account(bytrix, "bytrix", ratio: 4.25, resetInMinutes: 68),
         account(cybrio, "cybrio", ratio: 4.25, resetInMinutes: 68),
         account(voltrix, "voltrix", ratio: 4.25, resetInMinutes: 198),
         account(backup, "Backup", ratio: 1.06, resetInMinutes: 240, weeklyUsed: 99,
                 weeklyResetInMinutes: (6 * 24 + 7) * 60 + 27)]
    }

    func held(_ id: String, on account: UUID, millionsPerHour rate: Double, context: Int) -> HeldSessionPlan.Session {
        HeldSessionPlan.Session(id: id, account: account, tokensPerHour: rate * 1_000_000, contextTokens: context,
                                cacheLifetime: 3600, lastSeen: minutes(-1))
    }

    /// The thirteen sessions cybrio refused at 12:21 am, 278M tokens an
    /// hour together, with the context each would rewrite on arrival.
    func refusedOnCybrio() -> [HeldSessionPlan.Session] {
        [held("platform-execution", on: cybrio, millionsPerHour: 35, context: 555_000),
         held("cf-builder", on: cybrio, millionsPerHour: 32, context: 890_000),
         held("continues-field", on: cybrio, millionsPerHour: 30, context: 348_000),
         held("platform-engineer", on: cybrio, millionsPerHour: 28, context: 392_000),
         held("cf-designer", on: cybrio, millionsPerHour: 26, context: 152_000),
         held("platform-app", on: cybrio, millionsPerHour: 22, context: 722_000),
         held("ion-ga", on: cybrio, millionsPerHour: 20, context: 574_000),
         held("AccountDock", on: cybrio, millionsPerHour: 18, context: 54_000),
         held("075198d6", on: cybrio, millionsPerHour: 17, context: 300_000),
         held("AreaShare", on: cybrio, millionsPerHour: 15, context: 200_000),
         held("Mother", on: cybrio, millionsPerHour: 15, context: 250_000),
         held("/slots/run-1", on: cybrio, millionsPerHour: 10, context: 0),
         held("/slots/run-2", on: cybrio, millionsPerHour: 10, context: 0)]
    }

    func plan(_ sessions: [HeldSessionPlan.Session], accounts: [CapacityOutlook.Account],
              ledger: inout LaneLedger) -> [String: HeldSessionPlan] {
        HeldSessionPlan.planTogether(sessions, accounts: accounts, base: [:], lanes: [], ledger: &ledger, now: now)
    }

    /// Whether every lane's planned sessions fit its fresh window together
    /// for the hour after its reset, by the ledger's charges.
    func assertEachLaneHoldsWhatIsPlannedOntoIt(_ plans: [String: HeldSessionPlan], ledger: LaneLedger,
                                                accounts: [CapacityOutlook.Account],
                                                file: StaticString = #filePath, line: UInt = #line) {
        let pacer = SessionPacer()
        for account in accounts {
            let waits = plans.values.filter { $0.lane == account.id && $0.choice == .wait }
            guard let at = waits.map(\.at).min() else { continue }
            let charges = ledger.charges(on: account.id).filter { $0.kind == .planned && $0.from == at }
            let rate = charges.reduce(0) { $0 + $1.tokensPerHour }
            let arrivals = charges.reduce(0) { $0 + $1.arrivalTokens }
            let use = (rate + arrivals) / 1_000_000 * account.pacer.percentPerMillion
            XCTAssertLessThanOrEqual(use, pacer.limit * SessionPacer.windowFitShare + 0.01,
                                     "\(account.name)'s fresh window at \(at) holds its planned sessions for the hour",
                                     file: file, line: line)
        }
    }

    func testHeldSessionsArePlannedTogetherLaneByLaneByTheirResets() throws {
        let accounts = tonight()
        var ledger = LaneLedger(startedAt: now)
        let plans = plan(refusedOnCybrio(), accounts: accounts, ledger: &ledger)
        assertEachLaneHoldsWhatIsPlannedOntoIt(plans, ledger: ledger, accounts: accounts)
        let onFluxon = plans.filter { $0.value.lane == fluxon }.keys.sorted()
        // fluxon's fresh window holds 41.8M tokens: one session of 35M an
        // hour, not the thirteen sent there one by one.
        XCTAssertEqual(onFluxon, ["platform-execution"])
        XCTAssertEqual(try XCTUnwrap(plans["platform-execution"]).at, minutes(27))
        // The next lanes by their resets each take what they carry: hexorda
        // at 1:10 am, bytrix at 1:30 am, voltrix at 3:40 am.
        XCTAssertEqual(plans.filter { $0.value.lane == hexorda }.keys.sorted(), ["AccountDock"])
        XCTAssertEqual(plans["AccountDock"]?.at, minutes(48))
        XCTAssertEqual(plans.filter { $0.value.lane == bytrix }.keys.sorted(), ["075198d6"])
        XCTAssertEqual(plans["075198d6"]?.at, minutes(68))
        XCTAssertEqual(plans.filter { $0.value.lane == voltrix }.keys.sorted(), ["AreaShare"])
        XCTAssertEqual(plans["AreaShare"]?.at, minutes(198))
        for (id, plan) in plans { XCTAssertEqual(plan.choice, .wait, id) }
        // The rest, which no lane carries for an hour beside those (over
        // 21M tokens an hour on a Max 5x window at 4.25% per million), wait
        // for their own account, cybrio, which is charged with them.
        let rest = ["cf-builder", "continues-field", "platform-engineer", "cf-designer", "platform-app", "ion-ga", "Mother",
                    "/slots/run-1", "/slots/run-2"]
        for id in rest {
            XCTAssertNil(plans[id], id)
            XCTAssertEqual(ledger.charge(of: id)?.lane, cybrio, id)
            XCTAssertEqual(ledger.charge(of: id)?.kind, .held, id)
            XCTAssertEqual(ledger.charge(of: id)?.from, minutes(68), id)
        }
        XCTAssertEqual(ledger.charges.count, refusedOnCybrio().count, "every session is charged somewhere")
    }

    func testTheSecondLanesSessionsComeOnlyAfterTheFirstIsFull() throws {
        // At a cost of 1.15% per million, fluxon's fresh window holds 86M
        // tokens: two heavy sessions for the hour, and the next goes on.
        let accounts = tonight(fluxonRatio: 1.15)
        var ledger = LaneLedger(startedAt: now)
        let plans = plan(refusedOnCybrio(), accounts: accounts, ledger: &ledger)
        assertEachLaneHoldsWhatIsPlannedOntoIt(plans, ledger: ledger, accounts: accounts)
        XCTAssertEqual(plans.filter { $0.value.lane == fluxon && $0.value.at == minutes(27) }.keys.sorted(),
                       ["cf-builder", "platform-execution"])
        // A light run fits beside them only in fluxon's next window, which
        // comes within a window of its own account's reset.
        XCTAssertEqual(plans["/slots/run-1"]?.lane, fluxon)
        XCTAssertEqual(plans["/slots/run-1"]?.at, minutes(327))
        let names = plans.map { (name: $0.key, plan: $0.value) }.sorted { $0.name < $1.name }
        let lasting = [fluxon: TimeInterval(61 * 60)]
        let summary = try XCTUnwrap(HeldSessionPlan.summary(names, lasting: lasting,
                                                            unplanned: refusedOnCybrio().count - plans.count, now: now))
        func clock(_ value: Double) -> String { UsageFormat.clock(minutes(value), now: now) }
        XCTAssertEqual(summary, "At \(clock(27)) fluxon's fresh window takes cf-builder and platform-execution "
                       + "(≈ 60 min of its window); 4 others wait for hexorda at \(clock(48)), bytrix at \(clock(68)), "
                       + "voltrix at \(clock(198)), fluxon at \(clock(327)); 7 wait for their own accounts.")
        // Two lanes freed by the same reset are named together.
        var cybrioPlan = try XCTUnwrap(plans["075198d6"])
        cybrioPlan.lane = cybrio
        cybrioPlan.laneName = "cybrio"
        cybrioPlan.ownName = "voltrix"
        let together = try XCTUnwrap(HeldSessionPlan.summary(names + [(name: "x", plan: cybrioPlan)], lasting: lasting,
                                                             unplanned: 0, now: now))
        XCTAssertTrue(together.contains("5 others wait for hexorda at \(clock(48)), bytrix and cybrio at \(clock(68)), "),
                      together)
    }

    func testAPlannedWaitChargesItsLaneFromTheReset() {
        let accounts = tonight()
        var ledger = LaneLedger(startedAt: now)
        let one = [held("platform-execution", on: cybrio, millionsPerHour: 35, context: 555_000)]
        _ = plan(one, accounts: accounts, ledger: &ledger)
        let charge = ledger.charge(of: "platform-execution")
        XCTAssertEqual(charge?.lane, fluxon)
        XCTAssertEqual(charge?.from, minutes(27))
        XCTAssertEqual(charge?.kind, .planned)
        XCTAssertEqual(charge?.arrivalTokens ?? 0, 1_110_000, accuracy: 1)
        // Nothing of it counts before fluxon's reset.
        XCTAssertEqual(ledger.tokensPerHour(on: fluxon, at: minutes(26)), 0)
        XCTAssertEqual(ledger.tokensPerHour(on: fluxon, at: minutes(27)), 35_000_000)
        // A second session weighed against that ledger finds fluxon full.
        let next = held("continues-field", on: cybrio, millionsPerHour: 30, context: 348_000)
        XCTAssertNotEqual(HeldSessionPlan.decide(next, accounts: accounts, base: [:], lanes: [], ledger: ledger, now: now)?.lane,
                          fluxon)
        // Weighed alone, as before, it would have gone there too.
        XCTAssertEqual(HeldSessionPlan.decide(next, accounts: accounts, base: [:], lanes: [], now: now)?.lane, fluxon)
    }

    func testAnAccountAtItsLimitCarriesNothingBeforeItsReset() {
        let fluxonAtLimit = tonight()[0]
        let pacer = SessionPacer()
        let session = CapacityOutlook.Load(from: now, tokensPerHour: 10_000_000)
        XCTAssertFalse(CapacityOutlook.carries(fluxonAtLimit, base: 0, loads: [], adding: session,
                                               until: minutes(60), now: now, pacer: pacer),
                       "at 100% until 12:49 am, fluxon is no destination now")
        let atReset = CapacityOutlook.Load(from: minutes(27), tokensPerHour: 10_000_000)
        XCTAssertTrue(CapacityOutlook.carries(fluxonAtLimit, base: 0, loads: [], adding: atReset,
                                              until: minutes(87), now: now, pacer: pacer))
        // Thirteen sessions moved onto it at once do not fit its fresh window.
        let thirteen = refusedOnCybrio().map {
            CapacityOutlook.Load(from: minutes(27), tokensPerHour: $0.tokensPerHour,
                                 arrivalTokens: HeldSessionPlan.arrivalTokens($0, pacer: pacer))
        }
        XCTAssertFalse(CapacityOutlook.carries(fluxonAtLimit, base: 0, loads: Array(thirteen.dropLast()),
                                               adding: thirteen[thirteen.count - 1], until: minutes(87), now: now,
                                               pacer: pacer))
    }

    func testLaneAdmissionChargesWhatTheCycleAlreadySentToTheLane() {
        // cybrio's fresh window, at 4.25% per million, holds 23M tokens.
        let fresh = SessionPacer.Account(id: cybrio, utilization: 0, resetsAt: minutes(300), burnPerHour: 0, baseWeight: 1,
                                         weeklyRemaining: 400, weeklyResetsAt: minutes(4 * 24 * 60), percentPerMillion: 4.25)
        let session = SessionPacer.RebalanceSession(id: "AccountDock", account: fluxon, tokensPerHour: 15_000_000,
                                                    contextTokens: 54_000, model: nil, movable: true, cacheLifetime: 3600,
                                                    lastSeen: minutes(-1))
        let pacer = SessionPacer()
        let alone = pacer.admitToLanes([session], accounts: [fresh], running: [], destinations: [cybrio], now: now)
        XCTAssertNil(alone, "alone it fits, and the usual spread places it")
        var ledger = LaneLedger(startedAt: now)
        ledger.charge(LaneLedger.Charge(session: "run", lane: cybrio, tokensPerHour: 10_000_000, arrivalTokens: 0,
                                        from: now, kind: .placed))
        let charged = pacer.admitToLanes([session], accounts: [fresh], running: [], destinations: [cybrio], now: now,
                                         ledger: ledger)
        XCTAssertEqual(charged?.waiting, ["AccountDock"], "beside the run already sent there it no longer fits")
        let placed = pacer.place([session], accounts: [fresh], running: [], destinations: [cybrio], now: now, ledger: ledger)
        XCTAssertEqual(placed["AccountDock"], cybrio)
    }

    func testTheLedgerCountsAChargedSessionOnItsLaneOnly() {
        var ledger = LaneLedger(startedAt: now)
        ledger.charge(LaneLedger.Charge(session: "a", lane: fluxon, tokensPerHour: 5, from: now, kind: .placed))
        ledger.charge(LaneLedger.Charge(session: "a", lane: hexorda, tokensPerHour: 7, from: now, kind: .placed))
        XCTAssertTrue(ledger.charges(on: fluxon).isEmpty, "a later charge replaces the earlier one")
        XCTAssertEqual(ledger.tokensPerHour(on: hexorda, at: now), 7)
        let running = [SessionPacer.RebalanceSession(id: "a", account: fluxon, tokensPerHour: 5, contextTokens: 0,
                                                     model: nil, movable: true),
                       SessionPacer.RebalanceSession(id: "b", account: fluxon, tokensPerHour: 3, contextTokens: 0,
                                                     model: nil, movable: true)]
        XCTAssertEqual(ledger.excluding(running).map(\.id), ["b"])
        XCTAssertEqual(ledger.started(by: now, on: [hexorda]).map(\.id), ["a"])
    }
}
