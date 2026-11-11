import XCTest
@testable import AccountDock

final class KimiServiceTests: XCTestCase {
    func testOAuthLogicalKeyMapsToFlatCredentialFile() {
        XCTAssertEqual(
            KimiService.credentialStorageName(for: "oauth/kimi-code-env-abc123"),
            "kimi-code-env-abc123"
        )
    }

    func testCredentialStorageNameRejectsNestedOrEmptyPaths() {
        XCTAssertNil(KimiService.credentialStorageName(for: "oauth/"))
        XCTAssertNil(KimiService.credentialStorageName(for: "oauth/nested/name"))
        XCTAssertNil(KimiService.credentialStorageName(for: "../credential"))
    }
}

final class KimiCostTests: XCTestCase {
    func testUsageRecordsAggregateByDayAndModelWithCacheReadsCountedAsInput() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("wire.jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let rows = [
            #"{"type":"usage.record","model":"kimi-code/kimi-for-coding","usage":{"inputOther":100,"output":20,"inputCacheRead":900,"inputCacheCreation":5},"time":1791445605491}"#,
            #"{"type":"usage.record","model":"kimi-for-coding","usage":{"inputOther":10,"output":2,"inputCacheRead":0,"inputCacheCreation":0},"time":1791445705491}"#,
            #"{"type":"llm.request","model":"kimi-for-coding","time":1791445705491}"#,
        ]
        try Data(rows.joined(separator: "\n").utf8).write(to: file)

        let result = CostParser.scanKimiFile(file)

        XCTAssertEqual(result.count, 1)
        let aggregate = try XCTUnwrap(result.values.first)
        XCTAssertEqual(result.keys.first?.model, "kimi-for-coding")
        XCTAssertEqual(aggregate.input, 1010)
        XCTAssertEqual(aggregate.cachedInput, 900)
        XCTAssertEqual(aggregate.cacheWrite, 5)
        XCTAssertEqual(aggregate.output, 22)
        XCTAssertEqual(aggregate.events, 2)
    }

    func testKimiAliasesResolveToPublishedMoonshotPrices() async {
        await PricingService.shared.ensureLoaded()
        let k3 = await PricingService.shared.pricing(for: "k3", provider: .kimi)
        let coding = await PricingService.shared.pricing(for: "kimi-for-coding", provider: .kimi)
        XCTAssertNotNil(k3)
        XCTAssertNotNil(coding)
        XCTAssertGreaterThan(k3?.outputPerToken ?? 0, coding?.outputPerToken ?? 0)
    }

    func testCostHistoryCarriesTheTokensEachCostWasPricedFrom() async {
        await PricingService.shared.ensureLoaded()
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let today = dayFormatter.string(from: Date())
        let aggregate = CostParser.CodexTokenAggregate(input: 1_000, cachedInput: 400, cacheWrite: 50, output: 200, events: 1)
        let history = await CostParser.costHistory(
            [
                CostParser.CodexAggregateKey(day: today, model: "k3", reasoningEffort: nil): aggregate,
                CostParser.CodexAggregateKey(day: "2026-10-17", model: "k3", reasoningEffort: nil): aggregate,
            ],
            provider: .kimi
        )
        XCTAssertEqual(history.dailyTokens, [today: 1_250, "2026-10-17": 1_250])
        XCTAssertEqual(history.todayModelTokens, ["k3": 1_250])
        XCTAssertEqual(history.todayTokens, 1_250)
        XCTAssertGreaterThan(history.dailyCosts[today] ?? 0, 0)
    }

    func testProviderAggregatesArePersistedPerProviderAndEvicted() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AccountDockKimi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = UsageDatabase(url: directory.appendingPathComponent("usage.sqlite"))
        defer { database.close(); try? FileManager.default.removeItem(at: directory) }
        let key = CostParser.CodexAggregateKey(day: "2026-10-17", model: "k3", reasoningEffort: nil)
        database.replaceProviderFile(
            .kimi, path: "/wire.jsonl", modificationTime: 1, byteCount: 10,
            aggregates: [key: .init(input: 10, cachedInput: 4, cacheWrite: 1, output: 3, events: 1)]
        )
        XCTAssertEqual(database.providerAggregates(.kimi)[key]?.cacheWrite, 1)
        XCTAssertTrue(database.providerAggregates(.codex).isEmpty)
        XCTAssertEqual(database.removeProviderFiles(.kimi, notIn: []), 1)
        XCTAssertTrue(database.providerAggregates(.kimi).isEmpty)
    }
}
