import XCTest
@testable import AccountDock

/// A session's rate is what it uses while it works, not its work spread over
/// an hour it mostly waited through. The fixture is hexorda's limit at
/// 6:05 pm: platform-execution (session 583fb354) had waited on its user
/// since 12:03 pm and sent 3.5M weighted tokens in the 32 seconds after its
/// user answered; platform-engineer (session 33962de2) sent a few small
/// requests an hour before and 9.2M in its last two minutes. Averaged over
/// the hour they read as 3.5M and 9.3M an hour, and the plan made at
/// 6:05:37 pm put both on voltrix's fresh window at 6:39 pm as lasting
/// about 130 minutes; once moved, platform-engineer alone used 77M an hour.
final class WorkingDemandTests: XCTestCase {
    /// 6:05:37 pm.
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var pausedAt: Date { now.addingTimeInterval(-5) }
    let voltrix = UUID(), hexorda = UUID()

    func seconds(_ value: Double) -> Date { now.addingTimeInterval(value) }

    /// Records a request of `tokens` weighted tokens, all output.
    func record(_ rates: inout SessionRates, _ session: String, at: Date, tokens: Double, account: UUID) {
        rates.record(session: session, account: account, context: 0, cacheWrite: 0, output: Int(tokens / 5),
                     cacheLifetime: 3600, at: at)
    }

    func rates() -> SessionRates {
        var rates = SessionRates()
        // Both were seen hours before, so neither is new.
        record(&rates, "583fb354", at: seconds(-6 * 3600), tokens: 500_000, account: hexorda)
        record(&rates, "33962de2", at: seconds(-6 * 3600), tokens: 500_000, account: hexorda)
        for index in 0..<12 {
            record(&rates, "583fb354", at: seconds(-51 + Double(index) * 3), tokens: 3_470_000 / 12, account: hexorda)
        }
        for minute in [58.0, 57, 56] {
            record(&rates, "33962de2", at: seconds(-minute * 60), tokens: 33_000, account: hexorda)
        }
        for index in 0..<40 {
            record(&rates, "33962de2", at: seconds(-117 + Double(index) * 2.75), tokens: 9_200_000 / 40,
                   account: hexorda)
        }
        return rates
    }

    func testABurstAfterAQuietHourCountsAtTheBurstsRate() throws {
        let rates = rates()
        let execution = try XCTUnwrap(rates.demand("583fb354", until: pausedAt))
        XCTAssertEqual(execution, 3_470_000, accuracy: 100_000, "spread over the hour it waited through")
        XCTAssertEqual(try XCTUnwrap(rates.heldDemand("583fb354", pausedAt: pausedAt)), 3_470_000 * 6,
                       accuracy: 300_000, "its 32 seconds of work count as the ten minutes a run lasts at least")
        let engineer = try XCTUnwrap(rates.heldDemand("33962de2", pausedAt: pausedAt))
        XCTAssertEqual(engineer, 9_299_000 * 6, accuracy: 500_000)
        XCTAssertGreaterThan(engineer, try XCTUnwrap(rates.demand("33962de2", until: pausedAt)) * 5)
    }

    func testASteadySessionsWorkingDemandIsItsDemand() throws {
        var rates = SessionRates()
        for step in 0..<12 {
            record(&rates, "steady", at: seconds(Double(step - 11) * 300), tokens: 1_000_000, account: hexorda)
        }
        XCTAssertEqual(try XCTUnwrap(rates.workingDemand("steady", until: now)),
                       try XCTUnwrap(rates.demand("steady", until: now)), accuracy: 1,
                       "a request every five minutes all hour leaves no gap out")
    }

    func held(_ rates: SessionRates, working: Bool) -> [HeldSessionPlan.Session] {
        [("583fb354", 811_551), ("33962de2", 400_000)].map { id, context in
            let entry = rates.entries[id]
            let measured = AppState.rebalanceRate(current: rates.tokensPerHour(id, now: now),
                                                  recent: rates.demand(id, until: now), lastSeen: entry?.lastSeen,
                                                  now: now)
            let before = working ? rates.heldDemand(id, pausedAt: pausedAt) : rates.demand(id, until: pausedAt)
            return HeldSessionPlan.Session(id: id, account: hexorda, tokensPerHour: AppState.heldRate(measured, held: before),
                                           contextTokens: context, cacheLifetime: 3600, lastSeen: entry?.lastSeen)
        }
    }

    var accounts: [CapacityOutlook.Account] {
        func account(_ id: UUID, _ name: String, resetIn minutes: Double, ratio: Double) -> CapacityOutlook.Account {
            CapacityOutlook.Account(
                pacer: SessionPacer.Account(id: id, utilization: 100, resetsAt: seconds(minutes * 60), burnPerHour: 0,
                                            baseWeight: 0, weeklyRemaining: 60 * 8, weeklyResetsAt: seconds(6 * 86_400),
                                            percentPerMillion: ratio),
                name: name, availability: .atLimit)
        }
        return [account(voltrix, "voltrix", resetIn: 33.4, ratio: 1.176),
                account(hexorda, "hexorda", resetIn: 184.4, ratio: 2.545)]
    }

    func onVoltrix(_ plans: [String: HeldSessionPlan]) -> [String] {
        plans.filter { $0.value.lane == voltrix && $0.value.at < seconds(40 * 60) }.keys.sorted()
    }

    func testVoltrixsFreshWindowIsPlannedOnlyForTheWorkItCarries() {
        let rates = rates()
        var averaged = LaneLedger(startedAt: now)
        let before = HeldSessionPlan.planTogether(held(rates, working: false), accounts: accounts, base: [:], lanes: [],
                                                  ledger: &averaged, now: now)
        XCTAssertEqual(onVoltrix(before), ["33962de2", "583fb354"], "at their hourly averages both fit voltrix's window")

        var ledger = LaneLedger(startedAt: now)
        let sessions = held(rates, working: true)
        let plans = HeldSessionPlan.planTogether(sessions, accounts: accounts, base: [:], lanes: [], ledger: &ledger,
                                                 now: now)
        let taken = onVoltrix(plans)
        XCTAssertLessThanOrEqual(taken.count, 1, "at their working rates together they spend voltrix's window within the hour")
        let pacer = SessionPacer()
        let percent = taken.reduce(0.0) { total, id in
            guard let session = sessions.first(where: { $0.id == id }) else { return total }
            return total + (session.tokensPerHour + HeldSessionPlan.arrivalTokens(session, pacer: pacer)) * 1.176 / 1_000_000
        }
        XCTAssertLessThanOrEqual(percent, 100 * SessionPacer.windowFitShare)
    }

    /// Two sessions quiet for four hours, each working at 26M an hour before
    /// its user stopped answering, leave an account that can no longer serve
    /// them. hexorda's fresh window holds 39M weighted tokens.
    func testTwoQuietHeavySessionsAreNotBothSentToOneFreshWindow() throws {
        let fallback = Date(timeIntervalSince1970: 1_800_000_000)
        let cybrio = UUID()
        var rates = SessionRates()
        for id in ["583fb354", "33962de2"] {
            for step in 0..<12 {
                rates.record(session: id, account: cybrio, context: 0, cacheWrite: 0, output: 2_200_000 / 5,
                             cacheLifetime: 3600, at: fallback.addingTimeInterval(-4 * 3600 + Double(step - 11) * 300))
            }
        }
        let quiet = ["583fb354", "33962de2"].map { id -> SessionPacer.RebalanceSession in
            let measured = AppState.rebalanceRate(current: rates.tokensPerHour(id, now: fallback),
                                                  recent: rates.demand(id, until: fallback),
                                                  lastSeen: rates.entries[id]?.lastSeen, now: fallback)
            return SessionPacer.RebalanceSession(id: id, account: cybrio, tokensPerHour: measured, contextTokens: 300_000,
                                                 model: nil, movable: true, cacheLifetime: 3600,
                                                 lastSeen: rates.entries[id]?.lastSeen)
        }
        XCTAssertLessThan(quiet[0].tokensPerHour, 100_000, "quiet for four hours, it reads as using nothing where it is")
        XCTAssertEqual(rates.arrivalRate("583fb354", measured: quiet[0].tokensPerHour), 26_400_000, accuracy: 2_500_000,
                       "where it is sent it works at its rate before it went quiet")

        func lane(_ id: UUID, _ name: String, ratio: Double) -> CapacityOutlook.Account {
            CapacityOutlook.Account(
                pacer: SessionPacer.Account(id: id, utilization: 0, resetsAt: nil, burnPerHour: 0, baseWeight: 1,
                                            weeklyRemaining: 60 * 8, weeklyResetsAt: fallback.addingTimeInterval(5 * 86_400),
                                            percentPerMillion: ratio),
                name: name)
        }
        let outlook = [lane(hexorda, "hexorda", ratio: 2.545), lane(voltrix, "voltrix", ratio: 1.176)]
        func send(_ sessions: [SessionPacer.RebalanceSession]) -> [String: UUID] {
            var ledger = LaneLedger(startedAt: fallback)
            var lanes: [String: UUID] = [:]
            for session in sessions {
                guard let fallen = AppState.fallbackLane(session, from: cybrio, candidates: [hexorda, voltrix],
                                                         usable: { _ in true }, running: sessions, accounts: outlook,
                                                         ledger: ledger, now: fallback, pacer: SessionPacer())
                else { continue }
                ledger.charge(fallen.charge)
                lanes[session.id] = fallen.lane
            }
            return lanes
        }
        XCTAssertEqual(send(quiet), ["583fb354": hexorda, "33962de2": hexorda],
                       "weighed at what they send while quiet, both go to the first fresh window")
        let arriving = quiet.map { session -> SessionPacer.RebalanceSession in
            var arriving = session
            arriving.tokensPerHour = rates.arrivalRate(session.id, measured: session.tokensPerHour)
            return arriving
        }
        let lanes = send(arriving)
        XCTAssertEqual(lanes.values.filter { $0 == hexorda }.count, 1, "hexorda's window carries one of them for the hour")
        XCTAssertEqual(Set(lanes.values), [hexorda, voltrix])
    }
}
