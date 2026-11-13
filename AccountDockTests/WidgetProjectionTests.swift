import XCTest
@testable import AccountDock

final class WidgetProjectionTests: XCTestCase {
    private let iso = ISO8601DateFormatter()

    private func emptySummary(hidden: Set<AIProviderType> = []) -> TodaySummary {
        TodaySummary.make(days: [:], hidden: hidden)
    }

    func testAKimiAccountShowsItsMonthlyWindowAndItsOwnIcon() throws {
        let reset = Date(timeIntervalSince1970: 4_000_000_000)
        let usage = UsageAPIResponse(
            fiveHour: UsageWindow(utilization: 12, resetsAt: iso.string(from: reset), windowSeconds: 18_000),
            sevenDay: UsageWindow(utilization: 40, resetsAt: nil),
            sevenDayOauthApps: nil, sevenDayOpus: nil, sevenDaySonnet: nil, sevenDayCowork: nil,
            iguanaNecktie: nil, extraUsage: nil
        )
        let account = Account(email: "k@mail.example", displayName: "K", provider: .kimi, isActive: true)
        let projected = WidgetProjection.account(account, usage: usage, errorMessage: nil, obfuscated: true)

        XCTAssertEqual(projected.providerName, AIProviderType.kimi.capabilities.displayName)
        XCTAssertEqual(projected.iconName, AIProviderType.kimi.capabilities.iconName)
        XCTAssertNotEqual(projected.iconName, AIProviderType.claudeCode.capabilities.iconName)
        XCTAssertEqual(projected.windows, [
            WidgetWindow(label: "5-hour", utilization: 12, resetsAt: reset),
            WidgetWindow(label: "Monthly limit", utilization: 40, resetsAt: nil),
        ])
        XCTAssertFalse(projected.hasError)
    }

    func testAnAccountWithoutASessionWindowHasOneWindow() {
        let usage = UsageAPIResponse(
            fiveHour: nil,
            sevenDay: UsageWindow(utilization: nil, resetsAt: nil, windowSeconds: 30 * 86_400),
            sevenDayOauthApps: nil, sevenDayOpus: nil, sevenDaySonnet: nil, sevenDayCowork: nil,
            iguanaNecktie: nil, extraUsage: nil
        )
        let windows = WidgetProjection.windows(usage, provider: .codex)
        XCTAssertEqual(windows, [WidgetWindow(label: "30-day quota", utilization: nil, resetsAt: nil)])
        XCTAssertEqual(WidgetProjection.windows(nil, provider: .codex), [])
    }

    func testAModelsOwnWeeklyLimitIsAWindowOfItsOwn() throws {
        let json = """
        {"five_hour": {"utilization": 5, "resets_at": null},
         "seven_day": {"utilization": 30, "resets_at": null},
         "limits": [{"kind": "weekly_scoped", "percent": 64, "resets_at": "2099-10-22T13:00:00+00:00",
                     "scope": {"model": {"id": "fable", "display_name": "Fable"}}}]}
        """
        let usage = try JSONDecoder().decode(UsageAPIResponse.self, from: Data(json.utf8))
        let windows = WidgetProjection.windows(usage, provider: .claudeCode)
        XCTAssertEqual(windows.map(\.label), ["Session", "Weekly limit", "Fable weekly"])
        XCTAssertEqual(windows.last?.utilization, 64)
        XCTAssertEqual(windows.last?.resetsAt, iso.date(from: "2099-10-22T13:00:00Z"))
    }

    func testHiddenProvidersAreLeftOutAndProvidersKeepTheAccountsOrder() {
        let accounts = [
            Account(email: "x@mail.example", displayName: "X", provider: .codex, isActive: true),
            Account(email: "c@mail.example", displayName: "C", isActive: true),
            Account(email: "k@mail.example", displayName: "K", provider: .kimi, isActive: true),
        ]
        let data = WidgetProjection.make(accounts: accounts, usage: [:], errorMessages: [accounts[1].id: "Signed out"],
                                         summary: emptySummary(hidden: [.kimi]), obfuscated: true, now: Date())
        XCTAssertEqual(data.providerOrder, [AIProviderType.codex.rawValue, AIProviderType.claudeCode.rawValue])
        XCTAssertEqual(data.accounts.count, 2)
        XCTAssertTrue(data.accounts[1].hasError)
        XCTAssertEqual(data.providerAccounts.map(\.providerName), ["Codex", "Claude"])
    }

    func testAFileWithOneSessionAndOneWeeklyReadingStillLoads() throws {
        let json = """
        {"selectedProvider": null, "todayCost": 3.5, "conversationTurns": 4, "activeCodingTime": "1h",
         "linesWritten": 10, "modelUsage": {"Opus": 2}, "lastUpdated": 700000000,
         "accounts": [
           {"provider": "Codex", "email": "a***", "displayName": "A", "subscriptionType": "Plus", "isActive": true,
            "sessionUtilization": null, "sessionResetTime": null, "weeklyUtilization": 14,
            "weeklyResetTime": "in 6 days", "extraUsageEnabled": null, "hasError": false, "errorMessage": null},
           {"provider": "Claude Code", "email": "b***", "displayName": "B", "subscriptionType": null, "isActive": false,
            "sessionUtilization": 42, "sessionResetTime": "2 hr", "weeklyUtilization": null,
            "weeklyResetTime": null, "extraUsageEnabled": true, "hasError": false, "errorMessage": null}
         ]}
        """
        let data = try JSONDecoder().decode(WidgetData.self, from: Data(json.utf8))
        XCTAssertEqual(data.orderedProviders, ["Codex", "Claude Code"])
        XCTAssertEqual(data.accounts[0].displayWindows, [WidgetWindow(label: "Weekly", utilization: 14, resetsAt: nil)])
        XCTAssertEqual(data.accounts[1].displayWindows, [
            WidgetWindow(label: "Session", utilization: 42, resetsAt: nil),
            WidgetWindow(label: "Weekly", utilization: nil, resetsAt: nil),
        ])
        XCTAssertEqual(data.accounts[1].tightestWindow?.utilization, 42)
        XCTAssertEqual(data.accounts[0].displayProviderName, "Codex")
        XCTAssertNil(data.accounts[0].iconName)
    }

    func testTheWrittenFileReadsBack() throws {
        let window = WidgetWindow(label: "Monthly limit", utilization: nil, resetsAt: Date(timeIntervalSince1970: 1_900_000_000))
        let account = WidgetAccountData(provider: "Kimi", providerName: "Kimi", iconName: "moon.stars", email: "e",
                                        displayName: "D", subscriptionType: nil, isActive: true, windows: [window],
                                        hasError: false, errorMessage: nil)
        let data = WidgetData(providerOrder: ["Kimi"], accounts: [account], todayCost: 0, conversationTurns: 0,
                              activeCodingTime: "0m", linesWritten: 0, modelUsage: [:], lastUpdated: Date())
        let decoded = try JSONDecoder().decode(WidgetData.self, from: JSONEncoder().encode(data))
        XCTAssertEqual(decoded.accounts.first?.displayWindows, [window])
        XCTAssertEqual(decoded.providerOrder, ["Kimi"])
    }
}
