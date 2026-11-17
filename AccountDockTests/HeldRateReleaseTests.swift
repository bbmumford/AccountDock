import XCTest
@testable import AccountDock

/// The sessions a pause holds are weighed at what they used before it held
/// them (`AppState.heldRate`), not at what they use while held. The fixture
/// is the morning ten sessions in slots of their own were held from 6:34 am
/// on accounts at their 5-hour limits: at 8:30 am voltrix (Max 5x) resets at
/// 8:39, hexorda at 11:10, bytrix at 11:29 and cybrio, where they wait, at
/// 11:30. Weighed at the near-nothing a held session sends, all ten fitted
/// voltrix's fresh window, were moved and released there together, and were
/// refused at its limit two minutes later.
final class HeldRateReleaseTests: XCTestCase {
    /// 8:30 am.
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var pausedAt: Date { now.addingTimeInterval(-116 * 60) }
    let voltrix = UUID(), hexorda = UUID(), bytrix = UUID(), cybrio = UUID()

    func minutes(_ value: Double) -> Date { now.addingTimeInterval(value * 60) }

    func account(_ id: UUID, _ name: String, resetInMinutes: Double) -> CapacityOutlook.Account {
        CapacityOutlook.Account(
            pacer: SessionPacer.Account(id: id, utilization: 100, resetsAt: minutes(resetInMinutes), burnPerHour: 0,
                                        baseWeight: 0, weeklyRemaining: 60 * 8, weeklyResetsAt: minutes(6 * 24 * 60),
                                        percentPerMillion: 4.25),
            name: name, availability: .atLimit)
    }

    var accounts: [CapacityOutlook.Account] {
        [account(voltrix, "voltrix", resetInMinutes: 9), account(hexorda, "hexorda", resetInMinutes: 160),
         account(bytrix, "bytrix", resetInMinutes: 179), account(cybrio, "cybrio", resetInMinutes: 180)]
    }

    /// Ten sessions that each sent a request every five minutes for the hour
    /// before the pause, from 4M to 13M weighted tokens an hour.
    func rates() -> SessionRates {
        var rates = SessionRates()
        for index in 0..<10 {
            let perRequest = Double(4 + index) * 1_000_000 / 12
            for step in 0..<12 {
                let at = pausedAt.addingTimeInterval(Double(step - 11) * 300)
                rates.record(session: "s\(index)", account: cybrio, context: 0, cacheWrite: 0, output: 0,
                             cacheLifetime: 3600, at: at)
                guard var entry = rates.entries["s\(index)"], !entry.requests.isEmpty else { continue }
                entry.requests[entry.requests.count - 1].tokens = perRequest
                rates.entries["s\(index)"] = entry
            }
        }
        return rates
    }

    func held(_ rates: SessionRates, atHeldRate: Bool) -> [HeldSessionPlan.Session] {
        (0..<10).map { index in
            let id = "s\(index)"
            let entry = rates.entries[id]
            let measured = AppState.rebalanceRate(current: rates.tokensPerHour(id, now: now),
                                                  recent: rates.demand(id, until: now), lastSeen: entry?.lastSeen, now: now)
            let rate = atHeldRate ? AppState.heldRate(measured, held: rates.heldDemand(id, pausedAt: pausedAt)) : measured
            return HeldSessionPlan.Session(id: id, account: cybrio, tokensPerHour: rate, contextTokens: 300_000,
                                           cacheLifetime: 3600, lastSeen: entry?.lastSeen)
        }
    }

    func onVoltrix(_ plans: [String: HeldSessionPlan]) -> [String] {
        plans.filter { $0.value.lane == voltrix && $0.value.choice == .wait && $0.value.at < minutes(60) }.keys.sorted()
    }

    func testAHeldSessionCountsAtItsRateBeforeTheHoldNotAtWhatItSendsWhileHeld() {
        let rates = rates()
        let measured = AppState.rebalanceRate(current: rates.tokensPerHour("s9", now: now),
                                              recent: rates.demand("s9", until: now),
                                              lastSeen: rates.entries["s9"]?.lastSeen, now: now)
        XCTAssertLessThan(measured, 100_000, "held for two hours, it reads as using nearly nothing")
        let held = rates.heldDemand("s9", pausedAt: pausedAt) ?? 0
        XCTAssertEqual(held, 13_000_000, accuracy: 1_500_000, "the hour before the pause")
        XCTAssertEqual(AppState.heldRate(measured, held: held), held)
        XCTAssertEqual(AppState.heldRate(2_000_000, held: nil), 2_000_000, "a session nothing holds counts as measured")
    }

    func testAFreedWindowIsPlannedOnlyAsFullAsTheHeldSessionsFillItOnceTheyRun() {
        let rates = rates()
        var decayedLedger = LaneLedger(startedAt: now)
        let decayed = HeldSessionPlan.planTogether(held(rates, atHeldRate: false), accounts: accounts, base: [:],
                                                   lanes: [], ledger: &decayedLedger, now: now)
        XCTAssertEqual(onVoltrix(decayed).count, 10, "at what they send while held, every one fits voltrix's window")

        var ledger = LaneLedger(startedAt: now)
        let sessions = held(rates, atHeldRate: true)
        let plans = HeldSessionPlan.planTogether(sessions, accounts: accounts, base: [:], lanes: [], ledger: &ledger,
                                                 now: now)
        let taken = onVoltrix(plans)
        XCTAssertFalse(taken.isEmpty, "the fresh window still takes what it carries")
        XCTAssertLessThanOrEqual(taken.count, 3)
        // What voltrix takes fits its window for the hour after its reset.
        let pacer = SessionPacer()
        let percent = taken.reduce(0.0) { total, id in
            guard let session = sessions.first(where: { $0.id == id }) else { return total }
            return total + (session.tokensPerHour + HeldSessionPlan.arrivalTokens(session, pacer: pacer)) * 4.25 / 1_000_000
        }
        XCTAssertLessThanOrEqual(percent, 100 * SessionPacer.windowFitShare)
        // The rest wait for the next lanes, or for cybrio itself.
        XCTAssertEqual(plans.count + sessions.filter { plans[$0.id] == nil }.count, 10)
        XCTAssertTrue(plans.values.filter { !($0.lane == voltrix && $0.at < minutes(60)) }.allSatisfy { $0.at >= minutes(159) })
    }
}
