import XCTest
@testable import AccountDock

final class UsageLevelTests: XCTestCase {
    func testUnknownUtilizationReadsAsADashNeverZero() {
        let level = UsageLevel(utilization: nil)
        XCTAssertEqual(level.percentText, "—")
        XCTAssertNil(level.percent)
        XCTAssertEqual(level.severity, .unknown)
        XCTAssertFalse(level.isKnown)
        XCTAssertEqual(UsageLevel(utilization: .nan).percentText, "—")
        XCTAssertEqual(UsageLevel(utilization: 0).percentText, "0%")
    }

    func testPercentRoundsToTheNearestWholePercent() {
        XCTAssertEqual(UsageLevel(utilization: 41.4).percentText, "41%")
        XCTAssertEqual(UsageLevel(utilization: 41.5).percentText, "42%")
        XCTAssertEqual(UsageLevel(utilization: 99.6).percentText, "100%")
        XCTAssertEqual(UsageLevel(utilization: 112).percentText, "112%")
    }

    func testSeverityFollowsTheRoundedPercent() {
        XCTAssertEqual(UsageLevel(utilization: 69.4).severity, .normal)
        XCTAssertEqual(UsageLevel(utilization: 69.5).severity, .high)
        XCTAssertEqual(UsageLevel(utilization: 89.4).severity, .high)
        XCTAssertEqual(UsageLevel(utilization: 89.5).severity, .critical)
        XCTAssertEqual(UsageLevel(utilization: 140).severity, .critical)
    }

    func testFractionIsClampedToTheBar() {
        XCTAssertEqual(UsageLevel(utilization: 50).fraction, 0.5, accuracy: 1e-9)
        XCTAssertEqual(UsageLevel(utilization: 150).fraction, 1)
        XCTAssertEqual(UsageLevel(utilization: -3).fraction, 0)
        XCTAssertEqual(UsageLevel(utilization: nil).fraction, 0)
    }
}
