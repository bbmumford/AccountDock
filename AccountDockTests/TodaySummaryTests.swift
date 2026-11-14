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

    /// Times and spans read the same in every row, banner, status and event.
    func testTimesAndSpansHaveOneFormat() throws {
        XCTAssertEqual(UsageFormat.duration(40 * 60), "40 min")
        XCTAssertEqual(UsageFormat.duration(2 * 3600), "2 hr")
        XCTAssertEqual(UsageFormat.duration(2 * 3600 + 14 * 60 + 20), "2 hr 14 min")
        XCTAssertEqual(UsageFormat.duration(10), "1 min", "a span above zero is never read as none")
        XCTAssertEqual(UsageFormat.duration(3 * 86_400 + 6 * 3600), "3 d 6 hr")
        XCTAssertEqual(UsageFormat.compactDuration(5 * 60 + 30), "5m")
        XCTAssertEqual(UsageFormat.compactDuration(2 * 3600 + 14 * 60), "2h 14m")
        XCTAssertEqual(UsageFormat.compactDuration(4 * 86_400 + 6 * 3600 + 59), "4d 6h")
        XCTAssertEqual(UsageFormat.compactDuration(20), "1m")
        XCTAssertEqual(UsageFormat.compactDuration(0), "0m")

        let calendar = Calendar.current
        let noon = try XCTUnwrap(calendar.date(bySettingHour: 12, minute: 0, second: 0, of: Date()))
        let later = noon.addingTimeInterval(2 * 3600)
        XCTAssertEqual(UsageFormat.clock(later, now: noon), later.formatted(date: .omitted, time: .shortened))
        XCTAssertEqual(UsageFormat.atClock(later, now: noon), "at " + UsageFormat.clock(later, now: noon))
        let tomorrow = noon.addingTimeInterval(86_400)
        XCTAssertEqual(UsageFormat.clock(tomorrow, now: noon),
                       tomorrow.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
        XCTAssertTrue(UsageFormat.atClock(tomorrow, now: noon).hasPrefix("on "))
        let dated = tomorrow.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
        XCTAssertEqual(UsageFormat.clock(tomorrow, now: noon, dated: true), dated)
        let nextMonth = noon.addingTimeInterval(20 * 86_400)
        XCTAssertEqual(UsageFormat.clock(nextMonth, now: noon),
                       nextMonth.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()),
                       "a weekday more than six days off names its date")

        XCTAssertEqual(UsageFormat.until(noon.addingTimeInterval(10), now: noon), "now")
        XCTAssertEqual(UsageFormat.until(later, now: noon), "in about 2 hr (\(UsageFormat.clock(later, now: noon)))")
        XCTAssertEqual(UsageFormat.until(noon.addingTimeInterval(2 * 86_400), now: noon),
                       "around \(UsageFormat.clock(noon.addingTimeInterval(2 * 86_400), now: noon))")
        XCTAssertEqual(UsageFormat.reset(noon.addingTimeInterval(-1), now: noon), "Resets now")
        XCTAssertEqual(UsageFormat.reset(noon.addingTimeInterval(3 * 3600 + 5 * 60), now: noon), "Resets in 3 hr 5 min")
        XCTAssertEqual(UsageFormat.reset(tomorrow.addingTimeInterval(60), now: noon),
                       "Resets on \(UsageFormat.clock(tomorrow.addingTimeInterval(60), now: noon, dated: true))")
    }

    /// The allowance arithmetic the planner, the pacer and the simulator
    /// share.
    func testAllowanceArithmetic() {
        XCTAssertEqual(Allowance.millions(10, percentPerMillion: 0.5), 20)
        XCTAssertEqual(Allowance.millions(10, percentPerMillion: 0), 10, "an unknown token cost compares by percent")
        XCTAssertEqual(Allowance.percent(millions: 20, percentPerMillion: 0.5), 10)
        XCTAssertEqual(Allowance.converted(10, from: 0.5, to: 10), 200, "a plan a twentieth the size spends twenty times the percent")
        XCTAssertEqual(Allowance.converted(10, from: 0, to: 10), 10)
        XCTAssertEqual(Allowance.sessionRoom(sessionUsed: 40, weeklyUsed: 95, sessionPerWeekly: 8), 40)
        XCTAssertEqual(Allowance.sessionRoom(sessionUsed: nil, weeklyUsed: 50, sessionPerWeekly: 8), 400)
        XCTAssertEqual(Allowance.sessionRoom(sessionUsed: nil, weeklyUsed: 50, sessionPerWeekly: 8, sessionRoomWhenUnread: 0), 0)
        XCTAssertEqual(Allowance.weeklyRoom(sessionUsed: 60, weeklyUsed: 90, sessionPerWeekly: 8), 5)
        let now = Date(timeIntervalSinceReferenceDate: 0)
        XCTAssertEqual(Allowance.left(used: 30, resetsAt: now.addingTimeInterval(60), now: now), 70)
        XCTAssertEqual(Allowance.left(used: 30, resetsAt: now.addingTimeInterval(-60), now: now), 100, "a passed window is unused")
        XCTAssertEqual(Allowance.spent(perHour: 10, from: now, until: now.addingTimeInterval(1800)), 5)
        XCTAssertEqual(Allowance.spent(perHour: 10, from: now, until: now.addingTimeInterval(-1800)), 0)
        XCTAssertEqual(Allowance.runOut(left: 20, perHour: 10, now: now), now.addingTimeInterval(7200))
        XCTAssertNil(Allowance.runOut(left: 20, perHour: 0, now: now))
        let reset = now.addingTimeInterval(7 * 86_400)
        XCTAssertEqual(Allowance.latestStart(weeklyUsed: 60, resetsAt: reset, sessionPerWeekly: 8),
                       reset.addingTimeInterval(-40 / 2.5 * 3600), "one session window drains 12.5% of the week")
        XCTAssertEqual(Allowance.latestStart(weeklyUsed: 60, resetsAt: reset, sessionPerWeekly: nil), reset)
        XCTAssertEqual(Allowance.weeklyPace(sessionPerHour: 16, weeklyPerHour: 1, sessionPerWeekly: 8), 2)
    }
}
