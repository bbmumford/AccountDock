import XCTest
@testable import AccountDock

/// An account's learned token cost checked against its plan size
/// (`TurnCostModel.ratio(for:sizes:plans:)`), and forgotten when its plan
/// changes (`TurnCostModel.notePlan`).
final class PlanRatioTests: XCTestCase {
    let fluxon = UUID(), backup = UUID(), hexorda = UUID(), bytrix = UUID(), cybrio = UUID()

    /// fluxon and Backup on Max 20x, the rest on Max 5x.
    var sizes: [UUID: Double] { [fluxon: 20, backup: 20, hexorda: 5, bytrix: 5, cybrio: 5] }

    /// The learned costs: fluxon 0.97, hexorda 3.25, bytrix 2.25, and
    /// cybrio 1.05, about what a Max 20x account costs although cybrio is
    /// a Max 5x one, a quarter of the size.
    func learned() -> TurnCostModel {
        var model = TurnCostModel()
        model.accountPercentPerMillion = [fluxon: 0.97, hexorda: 3.25, bytrix: 2.25, cybrio: 1.05]
        return model
    }

    func testACostThatDisagreesWithItsPlanSizeIsBlendedTowardItUntilEnoughReadings() {
        var model = learned()
        // The others make a Max 5x account cost 3.88, 3.25 and 2.25: 3.25 in
        // the middle, three times cybrio's.
        let unread = model.ratio(for: cybrio, sizes: sizes)
        XCTAssertEqual(unread.ratio, 3.25, accuracy: 0.001, "with no reading counted, the plan size decides")
        XCTAssertEqual(unread.source, .blendedWithPlanSize)
        model.accountReadings = [cybrio: 5]
        XCTAssertEqual(model.ratio(for: cybrio, sizes: sizes).ratio, sqrt(1.05 * 3.25), accuracy: 0.001)
        model.accountReadings = [cybrio: TurnCostModel.trustedReadings]
        let trusted = model.ratio(for: cybrio, sizes: sizes)
        XCTAssertEqual(trusted.ratio, 1.05, accuracy: 0.0001, "enough readings: its own cost stands")
        XCTAssertEqual(trusted.source, .learned)

        // The accounts within twice their expectation keep their own cost,
        // cybrio's stray one setting no expectation for them.
        for (id, own) in [(fluxon, 0.97), (hexorda, 3.25), (bytrix, 2.25)] {
            let ratio = model.ratio(for: id, sizes: sizes)
            XCTAssertEqual(ratio.ratio, own, accuracy: 0.0001)
            XCTAssertEqual(ratio.source, .learned)
        }
        // An account of unknown size has nothing to be checked against.
        XCTAssertEqual(model.ratio(for: cybrio, sizes: [fluxon: 20]).source, .learned)
    }

    /// The night every account reached its limit: fluxon, a Max 20x
    /// account, had learned 0.176% of its window per million weighted tokens
    /// from 21 readings when one reading of 7.5% per million, its window
    /// moved by use AccountDock did not count, took it to 2.37%, against
    /// 4.25% for hexorda, a Max 5x account a quarter its size, and fluxon
    /// was then planned for nearly seven times the work its window holds.
    func testOneStrayReadingIsBlendedTowardThePlanSizeUntilReadingsAgreeAgain() {
        var model = TurnCostModel()
        model.accountPercentPerMillion = [fluxon: 0.176, hexorda: 4.25]
        model.accountReadings = [fluxon: 21, hexorda: 28]
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        model.recordReading(account: fluxon, session: 40)
        model.recordRequest(session: nil, account: fluxon, context: 0, cacheWrite: 0, output: 80_000, at: now)
        model.recordReading(account: fluxon, session: 43)
        XCTAssertEqual(model.accountPercentPerMillion?[fluxon] ?? 0, 2.373, accuracy: 0.001)
        XCTAssertEqual(model.accountReadings?[fluxon], 1, "a reading 42 times its learned cost starts its count again")

        let sizes: [UUID: Double] = [fluxon: 20, hexorda: 5]
        let blended = model.ratio(for: fluxon, sizes: sizes)
        XCTAssertEqual(blended.source, .blendedWithPlanSize)
        XCTAssertEqual(blended.ratio, exp(0.1 * log(2.373) + 0.9 * log(4.25 * 5 / 20)), accuracy: 0.001)
        XCTAssertLessThan(blended.ratio, 4.25 / 2, "a Max 20x percent holds more work than half a Max 5x one")

        // Readings that agree with each other count again, and with
        // `trustedReadings` of them the account's own cost stands.
        model.accountReadings = [fluxon: TurnCostModel.trustedReadings, hexorda: 28]
        XCTAssertEqual(model.ratio(for: fluxon, sizes: sizes).source, .learned)
    }

    func testAReadingNearTheLearnedCostKeepsCounting() {
        var model = TurnCostModel()
        model.accountPercentPerMillion = [fluxon: 0.5]
        model.accountReadings = [fluxon: 12]
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        model.recordReading(account: fluxon, session: 40)
        model.recordRequest(session: nil, account: fluxon, context: 0, cacheWrite: 0, output: 500_000, at: now)
        model.recordReading(account: fluxon, session: 42)
        XCTAssertEqual(model.accountReadings?[fluxon], 13, "0.8% per million is within four times 0.5%")
    }

    func testAfterAPlanChangeACostThatDisagreesWithItsSizeIsBlendedUntilEnoughReadings() {
        // fluxon's plan changed to Max 20x and it has learned 2.37% from
        // three readings since; hexorda, on Max 5x, has 4.25%.
        var model = TurnCostModel()
        let max20x = TurnCostModel.LearnedPlan(plan: "max", tier: "default_claude_max_20x")
        let max5x = TurnCostModel.LearnedPlan(plan: "max", tier: "default_claude_max_5x")
        model.accountPercentPerMillion = [fluxon: 0.9, hexorda: 4.25]
        model.notePlan(max5x, for: fluxon)
        model.notePlan(max5x, for: hexorda)
        XCTAssertTrue(model.notePlan(max20x, for: fluxon))
        model.accountPercentPerMillion?[fluxon] = 2.37
        model.accountReadings = [fluxon: 3, hexorda: 28]
        let plans = [fluxon: max20x, hexorda: max5x]
        let ratio = model.ratio(for: fluxon, sizes: [fluxon: 20, hexorda: 5], plans: plans)
        XCTAssertEqual(ratio.source, .blendedWithPlanSize)
        XCTAssertEqual(ratio.ratio, exp(0.3 * log(2.37) + 0.7 * log(4.25 * 5 / 20)), accuracy: 0.001)
    }

    func testEachLearnedReadingIsCounted() {
        var model = TurnCostModel()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        model.recordReading(account: cybrio, session: 10)
        model.recordRequest(session: nil, account: cybrio, context: 0, cacheWrite: 0, output: 100_000, at: now)
        model.recordReading(account: cybrio, session: 14)
        XCTAssertEqual(model.accountReadings?[cybrio], 1)
        XCTAssertNotNil(model.accountPercentPerMillion?[cybrio])
    }

    func testAPlanChangeForgetsTheAccountsLearnedCost() {
        var model = learned()
        let pro = TurnCostModel.LearnedPlan(plan: "pro", tier: "default_claude_pro")
        let max5x = TurnCostModel.LearnedPlan(plan: "max", tier: "default_claude_max_5x")
        let max20x = TurnCostModel.LearnedPlan(plan: "max", tier: "default_claude_max_20x")
        XCTAssertFalse(model.notePlan(pro, for: cybrio), "the first plan noted is the one its cost was learned on")
        model.accountReadings = [cybrio: 12]

        // Upgraded to Max 5x: its Pro cost is not its own until a reading
        // notes the change, and then it is forgotten.
        let plans = [cybrio: max5x, fluxon: max20x]
        let seeded = model.ratio(for: cybrio, sizes: [cybrio: 5, fluxon: 20], plans: plans)
        XCTAssertEqual(seeded.source, .seededFromLearned)
        XCTAssertEqual(seeded.ratio, 0.97 * 20 / 5, accuracy: 0.0001)
        XCTAssertTrue(model.notePlan(max5x, for: cybrio))
        XCTAssertNil(model.accountPercentPerMillion?[cybrio])
        XCTAssertNil(model.accountReadings?[cybrio])
        XCTAssertEqual(model.accountPlans?[cybrio], max5x)

        // A tier read after the cost was learned is the same plan.
        XCTAssertFalse(model.notePlan(TurnCostModel.LearnedPlan(plan: "max", tier: nil), for: hexorda))
        XCTAssertFalse(model.notePlan(max5x, for: hexorda))
        XCTAssertEqual(model.accountPercentPerMillion?[hexorda], 3.25)
        XCTAssertEqual(model.accountPlans?[hexorda], max5x)
    }

    func testAModelStoredBeforeReadingsAndPlansWereKeptStillLoads() throws {
        let data = try JSONEncoder().encode(learned())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["accountReadings"] = nil
        object["accountPlans"] = nil
        let stored = try JSONSerialization.data(withJSONObject: object)
        let loaded = try JSONDecoder().decode(TurnCostModel.self, from: stored)
        XCTAssertEqual(loaded.accountPercentPerMillion?[cybrio], 1.05)
        XCTAssertNil(loaded.accountReadings)
    }
}
