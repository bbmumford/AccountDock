import XCTest
@testable import AccountDock

final class UsageDatabaseTests: XCTestCase {
    private func makeDatabase() throws -> (UsageDatabase, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AccountDockTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (UsageDatabase(url: directory.appendingPathComponent("usage.sqlite")), directory)
    }

    private func claudeFile(entries: [CachedEntry], turns: Int = 1) -> CachedFile {
        CachedFile(
            mtimeUnix: 10,
            parsedByteCount: 100,
            earliestTimestampUnix: 1,
            project: "test",
            sessionId: "session",
            isSidechain: false,
            entries: entries,
            activityByDate: [
                "2026-10-02": ActivityDayContribution(
                    turns: turns,
                    activeMinutes: 2,
                    toolCounts: ["Read": turns],
                    linesWritten: turns,
                    modelCounts: ["Sonnet": turns]
                )
            ],
            firstTimestampByDate: ["2026-10-02": 100],
            lastTimestampByDate: ["2026-10-02": 160]
        )
    }

    private func entry(hash: String, output: Int) -> CachedEntry {
        CachedEntry(
            hash: hash, date: "2026-10-02", hour: 9, model: "claude-sonnet-4-5",
            speed: nil, input: 10, output: output, cw: 0, cw1h: 0, cr: 0,
            costUSDRow: nil, tools: [:], linesWritten: 0
        )
    }

    func testClaudeRowsArePersistedAndGloballyDeduplicated() throws {
        let (database, directory) = try makeDatabase()
        defer { database.close(); try? FileManager.default.removeItem(at: directory) }

        database.replaceClaudeFile(path: "/one.jsonl", parsed: claudeFile(entries: [entry(hash: "same", output: 5)]))
        database.replaceClaudeFile(path: "/two.jsonl", parsed: claudeFile(entries: [entry(hash: "same", output: 20)]))

        var winners: [(CachedEntry, String)] = []
        database.forEachCostEntry { winners.append(($0, $1)) }
        XCTAssertEqual(winners.count, 1)
        XCTAssertEqual(winners.first?.0.output, 20)
        XCTAssertEqual(database.activity(on: "2026-10-02").conversationTurns, 2)
    }

    func testAppendUpdatesFileOffsetAndActivityWithoutRetainingParsedFiles() throws {
        let (database, directory) = try makeDatabase()
        defer { database.close(); try? FileManager.default.removeItem(at: directory) }

        database.replaceClaudeFile(path: "/one.jsonl", parsed: claudeFile(entries: [entry(hash: "one", output: 5)]))
        database.appendClaudeFile(path: "/one.jsonl", parsed: CachedFile(
            mtimeUnix: 20, parsedByteCount: 250, earliestTimestampUnix: 2,
            project: "test", sessionId: nil, isSidechain: false,
            entries: [entry(hash: "two", output: 6)],
            activityByDate: claudeFile(entries: [], turns: 2).activityByDate,
            firstTimestampByDate: ["2026-10-02": 200],
            lastTimestampByDate: ["2026-10-02": 260]
        ))

        XCTAssertEqual(database.claudeFiles()["/one.jsonl"]?.byteCount, 250)
        var costEntryCount = 0
        database.forEachCostEntry { _, _ in costEntryCount += 1 }
        XCTAssertEqual(costEntryCount, 2)
        XCTAssertEqual(database.activity(on: "2026-10-02").conversationTurns, 3)
    }

    func testCodexAggregatesShareTheDatabaseAndDeletedFilesAreEvicted() throws {
        let (database, directory) = try makeDatabase()
        defer { database.close(); try? FileManager.default.removeItem(at: directory) }
        let key = CostParser.CodexAggregateKey(day: "2026-10-02", model: "gpt-5", reasoningEffort: "high")

        database.replaceCodexFile(
            path: "/codex.jsonl", modificationTime: 1, byteCount: 42,
            aggregates: [key: .init(input: 10, cachedInput: 2, output: 3, events: 1)]
        )
        XCTAssertEqual(database.codexAggregates()[key]?.input, 10)
        XCTAssertEqual(database.removeCodexFiles(notIn: []), 1)
        XCTAssertTrue(database.codexAggregates().isEmpty)
    }
}
