import XCTest
@testable import AccountDock

final class TodaySummaryTests: XCTestCase {
    private let days: [AIProviderType: TodaySummary.ProviderDay] = [
        .claudeCode: .init(cost: 10, tokens: 1_000, turns: 4, linesChanged: 30, activeMinutes: 50,
                           modelActivity: ["claude-opus": 4]),
        .codex: .init(cost: 2.5, tokens: 500, turns: 6, linesChanged: 12, activeMinutes: 99),
        .kimi: .init(cost: 1, tokens: 250, turns: 3, linesChanged: 7, activeMinutes: 20),
    ]

    func testHiddenProvidersAreLeftOutOfEveryTotal() {
        let summary = TodaySummary.make(days: days, hidden: [.codex])
        XCTAssertEqual(summary.included, [.claudeCode, .kimi])
        XCTAssertEqual(summary.byProvider.map(\.provider), [.claudeCode, .kimi])
        XCTAssertEqual(summary.cost, 11, accuracy: 1e-9)
        XCTAssertEqual(summary.tokens, 1_250)
        XCTAssertEqual(summary.turns, 7)
        XCTAssertEqual(summary.day(for: .codex), TodaySummary.ProviderDay())
    }

    func testEachMetricCountsOnlyProvidersThatReportIt() {
        let summary = TodaySummary.make(days: days, hidden: [])
        // Active time is reported by Claude Code alone, lines by Claude Code and Codex.
        XCTAssertEqual(summary.activeMinutes, 50)
        XCTAssertEqual(summary.linesChanged, 42)
        XCTAssertEqual(summary.cost, 13.5, accuracy: 1e-9)
        XCTAssertEqual(summary.tokens, 1_750)
        XCTAssertEqual(summary.reporting(.activeTime), [.claudeCode])
    }

    func testProvidersWithoutActivityAreNotListed() {
        var quiet = days
        quiet[.codex] = TodaySummary.ProviderDay()
        let summary = TodaySummary.make(days: quiet, hidden: [])
        XCTAssertEqual(summary.byProvider.map(\.provider), [.claudeCode, .kimi])
        XCTAssertEqual(summary.included, AIProviderType.implementedProviders)
    }

    func testCostAndTokensHaveOneFormat() {
        XCTAssertEqual(UsageFormat.cost(0), "$0.00")
        XCTAssertEqual(UsageFormat.cost(0.001), "<$0.01")
        XCTAssertEqual(UsageFormat.cost(12.346), "$12.35")
        XCTAssertEqual(UsageFormat.cost(12.6, wholeDollars: true), "$13")
        XCTAssertEqual(UsageFormat.tokens(950), "950")
        XCTAssertEqual(UsageFormat.tokens(12_340), "12.3K")
        XCTAssertEqual(UsageFormat.tokens(4_500_000), "4.5M")
        XCTAssertEqual(UsageFormat.tokens(1_200_000_000), "1.2B")
    }
}
