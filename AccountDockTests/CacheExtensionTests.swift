import XCTest
@testable import AccountDock

final class CacheExtensionTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testEveryCacheMarkAsksForTheHour() {
        let body: [String: Any] = [
            "tools": [["name": "t", "cache_control": ["type": "ephemeral"]]],
            "system": [["type": "text", "text": "s", "cache_control": ["type": "ephemeral"]]],
            "messages": [["role": "user", "content": [
                ["type": "text", "text": "a"],
                ["type": "text", "text": "b", "cache_control": ["type": "ephemeral"]],
            ]]],
        ]
        let (extended, changed) = RouterLogic.withExtendedCache(body)
        XCTAssertTrue(changed)
        XCTAssertEqual(RouterLogic.cacheLifetime(extended), 3600)
        let content = ((extended["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]]) ?? []
        XCTAssertNil(content.first?["cache_control"], "blocks without a mark get none")
        XCTAssertEqual((content.last?["cache_control"] as? [String: Any])?["ttl"] as? String, "1h")
        XCTAssertEqual((content.last?["cache_control"] as? [String: Any])?["type"] as? String, "ephemeral")
        XCTAssertFalse(RouterLogic.withExtendedCache(extended).1, "a request already on the hour is left alone")
        XCTAssertFalse(RouterLogic.withExtendedCache(["messages": [["role": "user", "content": "hi"]]]).1)
    }

    func testOneHourWritesAreCountedAndPricedHigher() {
        let usage: [String: Any] = [
            "input_tokens": 10, "cache_creation_input_tokens": 1000, "cache_read_input_tokens": 5000, "output_tokens": 20,
            "cache_creation": ["ephemeral_5m_input_tokens": 400, "ephemeral_1h_input_tokens": 600],
        ]
        let counts = RouterLogic.tokenCounts(usage)
        XCTAssertEqual(counts.cacheWriteLong, 600)
        XCTAssertEqual(counts.context, 6010)
        let short = TurnCostModel.weighted(context: 6010, cacheWrite: 1000, output: 20)
        let long = TurnCostModel.weighted(context: 6010, cacheWrite: 1000, output: 20, cacheWriteLong: 600)
        XCTAssertEqual(long - short, 600 * (2 - 1.25), accuracy: 0.001)
        XCTAssertEqual(TurnCostModel.weighted(context: 6010, cacheWrite: 1000, output: 20, cacheWriteLong: 5000),
                       TurnCostModel.weighted(context: 6010, cacheWrite: 1000, output: 20, cacheWriteLong: 1000),
                       "long writes are at most the whole write")
    }

    func testTheLedgerCountsReadsAfterAPauseAndTheLongWritePremium() {
        func event(at date: Date, read: Int, long: Int) -> RouterEvent {
            RouterEvent(kind: .turnUsage, at: date, session: "s", cacheReadTokens: read, cacheWriteLongTokens: long)
        }
        var ledger = CacheExtensionLedger()
        ledger.record(event(at: now, read: 100_000, long: 0), after: now.addingTimeInterval(-2 * 60))
        XCTAssertEqual(ledger.saved, 0, "within five minutes the short cache would have served too")
        ledger.record(event(at: now, read: 100_000, long: 1000), after: now.addingTimeInterval(-20 * 60))
        XCTAssertEqual(ledger.saved, 100_000 * 1.15, accuracy: 0.01)
        XCTAssertEqual(ledger.premium, 750, accuracy: 0.01)
        ledger.record(event(at: now, read: 100_000, long: 0), after: now.addingTimeInterval(-2 * 60 * 60))
        XCTAssertEqual(ledger.saved, 100_000 * 1.15, accuracy: 0.01, "past the hour no cache would have served")
        ledger.record(event(at: now.addingTimeInterval(9 * 24 * 3600), read: 0, long: 100), after: nil)
        XCTAssertEqual(ledger.days.count, 1, "days older than a week are dropped")
    }

    func testSessionRatesSurviveARestart() throws {
        var rates = SessionRates()
        let account = UUID()
        rates.record(session: "s", account: account, context: 200_000, cacheWrite: 1000, output: 500,
                     cacheLifetime: 3600, startsTurn: true, at: now)
        rates.record(session: "s", account: account, context: 201_000, cacheWrite: 1000, output: 500,
                     cacheLifetime: 3600, startsTurn: false, at: now.addingTimeInterval(30))
        XCTAssertEqual(rates.entries["s"]?.lastTurnStart, now, "a request inside the turn keeps its start")
        let decoded = try JSONDecoder().decode(SessionRates.self, from: JSONEncoder().encode(rates))
        XCTAssertEqual(decoded, rates)
        XCTAssertEqual(decoded.tokensPerHour("s", now: now.addingTimeInterval(60)), rates.tokensPerHour("s", now: now.addingTimeInterval(60)))
    }

    func testAResumedSessionHeldAgainIsForecastFromItsOwnLastHour() {
        var rates = SessionRates()
        let account = UUID()
        let pausedAt = now
        // Held at the pause, resumed ten hours later, held again after two
        // hours of work.
        rates.record(session: "s", account: account, context: 100_000, cacheWrite: 0, output: 0,
                     cacheLifetime: 3600, at: pausedAt.addingTimeInterval(-10 * 60))
        let resumed = pausedAt.addingTimeInterval(10 * 3600)
        for minute in stride(from: 0, through: 120, by: 2) {
            rates.record(session: "s", account: account, context: 500_000, cacheWrite: 0, output: 0,
                         cacheLifetime: 3600, at: resumed.addingTimeInterval(Double(minute) * 60))
        }
        XCTAssertEqual(rates.demand("s", until: pausedAt), 0, "the hour before the pause is no longer kept")
        let held = rates.heldDemand("s", pausedAt: pausedAt) ?? 0
        XCTAssertEqual(held, 30 * 50_000, accuracy: 50_000, "thirty requests an hour of 50,000 weighted tokens each")
    }

    func testAPausedSessionKeepsItsHistoryForDays() {
        var rates = SessionRates()
        rates.record(session: "held", account: UUID(), context: 100_000, cacheWrite: 0, output: 0, cacheLifetime: nil, at: now)
        rates.record(session: "other", account: UUID(), context: 100_000, cacheWrite: 0, output: 0, cacheLifetime: nil,
                     at: now.addingTimeInterval(3 * 24 * 3600))
        XCTAssertNotNil(rates.entries["held"])
        XCTAssertGreaterThan(rates.heldDemand("held", pausedAt: now) ?? 0, 0)
    }

    func testOneHourWritesInAStreamSurviveItsClosingTotals() {
        let scanner = SSEScanner()
        let start = #"{"type":"message_start","message":{"usage":{"input_tokens":5,"cache_creation_input_tokens":1000,"cache_read_input_tokens":9000,"output_tokens":1,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":1000}}}}"#
        let delta = #"{"type":"message_delta","usage":{"input_tokens":5,"cache_creation_input_tokens":1000,"cache_read_input_tokens":9000,"output_tokens":40}}"#
        _ = scanner.feed(Data("data: \(start)\n\ndata: \(delta)\n\n".utf8))
        XCTAssertEqual(scanner.counts.cacheWriteLong, 1000)
        XCTAssertEqual(scanner.counts.output, 40)
    }
}
