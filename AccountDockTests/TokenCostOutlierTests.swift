import XCTest
@testable import AccountDock

/// A learned token cost far off what its plan size makes of several other
/// accounts' (`TurnCostModel.ratio(for:sizes:plans:)`,
/// `RatioSource.heldTowardPlanSize`), and the seeds of the accounts with
/// none, made from the costs as those rules leave them. Pacing to the resets
/// sizes each account's room by these costs.
final class TokenCostOutlierTests: XCTestCase {
    let personal = UUID(), backup = UUID(), hstles = UUID()
    let hexorda = UUID(), voltrix = UUID(), bytrix = UUID(), cybrio = UUID(), fluxon = UUID()

    /// Learned costs of five Max 5x accounts, four of them agreeing:
    /// hexorda 8.87% of its window per million weighted tokens, voltrix
    /// 1.19, bytrix 1.72, cybrio 2.12 and fluxon 1.55; Personal and Backup
    /// (Max 20x) and HSTLES (Max 5x) have none.
    func learnedCosts(hexordaReadings: Int) -> (model: TurnCostModel, sizes: [UUID: Double]) {
        var model = TurnCostModel()
        model.accountPercentPerMillion = [hexorda: 8.87, voltrix: 1.19, bytrix: 1.72, cybrio: 2.12, fluxon: 1.55]
        model.accountReadings = [hexorda: hexordaReadings, voltrix: 20, bytrix: 20, cybrio: 20, fluxon: 20]
        let sizes: [UUID: Double] = [personal: 20, backup: 20, hstles: 5, hexorda: 5, voltrix: 5, bytrix: 5, cybrio: 5,
                                     fluxon: 5]
        return (model, sizes)
    }

    func testAnOutlierLikeHexordaIsHeldTowardItsPlanSizeHoweverManyReadingsItHas() {
        // The others make a Max 5x account cost 1.19, 1.55, 1.72 and 2.12:
        // about 1.63 in the middle, a fifth of hexorda's.
        let reference = sqrt(1.55 * 1.72)
        let trusted = learnedCosts(hexordaReadings: 28)
        let held = trusted.model.ratio(for: hexorda, sizes: trusted.sizes)
        XCTAssertEqual(held.source, .heldTowardPlanSize)
        XCTAssertEqual(held.ratio, sqrt(8.87 * reference), accuracy: 0.001, "halfway, in log terms")
        XCTAssertEqual(held.ratio, 3.81, accuracy: 0.01)
        // With few readings, the readings' own blend pulls it further.
        let fresh = learnedCosts(hexordaReadings: 2)
        let blended = fresh.model.ratio(for: hexorda, sizes: fresh.sizes)
        XCTAssertEqual(blended.source, .blendedWithPlanSize)
        XCTAssertEqual(blended.ratio, exp(0.2 * log(8.87) + 0.8 * log(reference)), accuracy: 0.001)
        // The accounts that agree with each other keep their own costs.
        for (id, own) in [(voltrix, 1.19), (bytrix, 1.72), (cybrio, 2.12), (fluxon, 1.55)] {
            XCTAssertEqual(trusted.model.ratio(for: id, sizes: trusted.sizes).ratio, own, accuracy: 0.0001)
            XCTAssertEqual(trusted.model.ratio(for: id, sizes: trusted.sizes).source, .learned)
        }
        // With one other account to compare with, either could be the
        // stray: a trusted cost stands.
        var pair = TurnCostModel()
        pair.accountPercentPerMillion = [hexorda: 8.87, bytrix: 1.72]
        pair.accountReadings = [hexorda: 28, bytrix: 20]
        XCTAssertEqual(pair.ratio(for: hexorda, sizes: [hexorda: 5, bytrix: 5]).source, .learned)
    }

    func testAccountsWithNoLearnedCostAreSeededFromThePlanSizeOfTheCheckedCosts() {
        let (model, sizes) = learnedCosts(hexordaReadings: 28)
        let hexordaHeld = sqrt(8.87 * sqrt(1.55 * 1.72))
        let costs = [hexordaHeld, 1.19, 1.72, 2.12, 1.55]
        let fiveX = exp(costs.map(log).reduce(0, +) / Double(costs.count))
        for (id, size) in [(personal, 20.0), (backup, 20.0), (hstles, 5.0)] {
            let seeded = model.ratio(for: id, sizes: sizes)
            XCTAssertEqual(seeded.source, .seededFromLearned)
            XCTAssertEqual(seeded.ratio, fiveX * 5 / size, accuracy: 0.0001)
        }
        // Seeded from the raw 8.87 instead, Personal's cost would be the
        // fifth root of hexorda's excess, 18%, higher.
        let raw = exp([8.87, 1.19, 1.72, 2.12, 1.55].map(log).reduce(0, +) / 5) / 4
        XCTAssertEqual(raw / model.ratio(for: personal, sizes: sizes).ratio, pow(8.87 / hexordaHeld, 0.2), accuracy: 0.0001)
        XCTAssertGreaterThan(raw / model.ratio(for: personal, sizes: sizes).ratio, 1.18)
    }

    func testTheLearningLogSaysWhereAHeldCostComesFrom() {
        XCTAssertEqual(AppState.ratioOrigin(.heldTowardPlanSize),
                       "learned far from what its plan size makes of the other accounts' costs, so blended halfway toward that")
    }
}
