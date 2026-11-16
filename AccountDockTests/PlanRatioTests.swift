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
