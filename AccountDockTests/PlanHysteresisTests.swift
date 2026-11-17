import XCTest
@testable import AccountDock

/// The held sessions planned onto a lane stay the same set from one cycle
/// to the next (`HeldSessionPlan.planTogether`'s `previous`). The fixture is
/// the hour before voltrix's 8:39 am reset, when the plan for its fresh
/// window was recorded again every few minutes with a different set of four
/// to six sessions, as their rates drifted by a few percent: voltrix (Max
/// 5x) resets in 10 minutes, hexorda in 160, and cybrio, where the sessions
/// wait, in 180.
final class PlanHysteresisTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let voltrix = UUID(), hexorda = UUID(), cybrio = UUID()

    func minutes(_ value: Double) -> Date { now.addingTimeInterval(value * 60) }

    func account(_ id: UUID, _ name: String, resetInMinutes: Double) -> CapacityOutlook.Account {
        CapacityOutlook.Account(
            pacer: SessionPacer.Account(id: id, utilization: 100, resetsAt: minutes(resetInMinutes), burnPerHour: 0,
                                        baseWeight: 0, weeklyRemaining: 60 * 8, weeklyResetsAt: minutes(6 * 24 * 60),
                                        percentPerMillion: 4.25),
            name: name, availability: .atLimit)
    }

    var accounts: [CapacityOutlook.Account] {
        [account(voltrix, "voltrix", resetInMinutes: 10), account(hexorda, "hexorda", resetInMinutes: 160),
         account(cybrio, "cybrio", resetInMinutes: 180)]
    }

    func sessions(_ millionsPerHour: [String: Double]) -> [HeldSessionPlan.Session] {
        millionsPerHour.map { id, rate in
            HeldSessionPlan.Session(id: id, account: cybrio, tokensPerHour: rate * 1_000_000, contextTokens: 0,
                                    cacheLifetime: 3600, lastSeen: minutes(-120))
        }
    }

    func onVoltrix(_ plans: [String: HeldSessionPlan]) -> Set<String> {
        Set(plans.filter { $0.value.lane == voltrix && $0.value.at < minutes(60) }.keys)
    }

    func plan(_ rates: [String: Double], previous: [String: HeldSessionPlan] = [:]) -> [String: HeldSessionPlan] {
        var ledger = LaneLedger(startedAt: now)
        return HeldSessionPlan.planTogether(sessions(rates), accounts: accounts, base: [:], lanes: [], ledger: &ledger,
                                            now: now, previous: previous)
    }

    /// Nine sessions near 6M weighted tokens an hour: voltrix's window holds
    /// three of them for the hour.
    let first: [String: Double] = ["a": 6.0, "b": 5.9, "c": 5.8, "d": 5.7, "e": 5.6, "f": 5.5, "g": 5.4, "h": 5.3,
                                   "i": 5.2]

    func testDriftingRatesKeepTheLanesSet() {
        let initial = plan(first)
        XCTAssertEqual(onVoltrix(initial), ["a", "b", "c"], "the heaviest that fit, heaviest first")

        // A few percent of drift reorders them: made afresh, the set changes.
        var drifted = first
        drifted["d"] = 6.05
        drifted["a"] = 5.95
        XCTAssertEqual(onVoltrix(plan(drifted)), ["a", "b", "d"])

        // Planned against the last cycle's plan, it stays.
        let steady = plan(drifted, previous: initial)
        XCTAssertEqual(onVoltrix(steady), ["a", "b", "c"], "a swap that fits under a tenth of the window more waits")
        XCTAssertEqual(Set(steady.filter { $0.value.lane == hexorda }.keys),
                       Set(initial.filter { $0.value.lane == hexorda }.keys), "the next lane keeps its set too")

        // And again, the same.
        XCTAssertEqual(onVoltrix(plan(drifted, previous: steady)), ["a", "b", "c"])
    }

    func testAPlannedSessionThatGoesLeavesItsRoomToTheNextByRate() {
        let initial = plan(first)
        var without = first
        without["c"] = nil
        let after = plan(without, previous: initial)
        XCTAssertEqual(onVoltrix(after), ["a", "b", "d"], "a and b keep their place; d, the heaviest left, takes c's")
    }

    func testAChangeThatFitsATenthOfTheWindowMoreIsTaken() {
        let initial = plan(first)
        // A heavier session now waits too: a set with it puts about 14% more of
        // voltrix's window to work.
        var heavier = first
        heavier["x"] = 9.0
        let after = plan(heavier, previous: initial)
        XCTAssertEqual(onVoltrix(after), ["a", "b", "x"])

        // One only slightly heavier than the set's lightest does not.
        var slightly = first
        slightly["y"] = 6.1
        XCTAssertEqual(onVoltrix(plan(slightly, previous: initial)), ["a", "b", "c"])
        XCTAssertEqual(onVoltrix(plan(slightly)), ["a", "b", "y"], "made afresh it would be taken")
    }

    func testTheSummaryKeepsOneResetReportedEitherSideOfAMinute() {
        let reset = Date(timeIntervalSince1970: 1_800_000_000 - 1_800_000_000.truncatingRemainder(dividingBy: 300))
        XCTAssertEqual(HeldSessionPlan.summaryMinute(reset.addingTimeInterval(-1)), HeldSessionPlan.summaryMinute(reset))
        XCTAssertEqual(HeldSessionPlan.summaryMinute(reset.addingTimeInterval(59)), HeldSessionPlan.summaryMinute(reset))
        XCTAssertNotEqual(HeldSessionPlan.summaryMinute(reset.addingTimeInterval(600)),
                          HeldSessionPlan.summaryMinute(reset))
    }
}
