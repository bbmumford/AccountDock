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

    /// Codex's cost history reads the rollouts of its own home and of every
    /// managed home, each home once however it is named and each rollout
    /// once, the longest copy standing.
    func testCodexRolloutsComeFromEveryHomeEachOnce() throws {
        let (_, root) = try makeDatabase()
        func write(_ home: String, _ name: String, bytes: Int) throws -> URL {
            let day = root.appendingPathComponent("\(home)/sessions/2026/11/15", isDirectory: true)
            try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
            let url = day.appendingPathComponent(name)
            try Data(repeating: 0x7B, count: bytes).write(to: url)
            return url
        }
        let shared = "rollout-2026-11-15T09-00-00-11111111-1111-1111-1111-111111111111.jsonl"
        let own = "rollout-2026-11-15T10-00-00-22222222-2222-2222-2222-222222222222.jsonl"
        _ = try write("codex", shared, bytes: 10)
        let resumed = try write("managed-a", shared, bytes: 25)
        let managed = try write("managed-a", own, bytes: 5)
        _ = try write("managed-a", "notes.txt", bytes: 5)
        let homes = [root.appendingPathComponent("codex", isDirectory: true),
                     root.appendingPathComponent("managed-a", isDirectory: true),
                     root.appendingPathComponent("codex/../codex", isDirectory: true),
                     root.appendingPathComponent("managed-b", isDirectory: true)]

        let rollouts = UsageIndex.codexRollouts(homes: homes)
        XCTAssertEqual(rollouts.map(\.url.lastPathComponent).sorted(), [shared, own].sorted(),
                       "a rollout in two homes, and a home named twice, count once; other files none")
        XCTAssertEqual(rollouts.first { $0.url.lastPathComponent == shared }?.url.standardizedFileURL,
                       resumed.standardizedFileURL, "the longer copy stands")
        XCTAssertEqual(rollouts.first { $0.url.lastPathComponent == own }?.byteCount, 5)
        XCTAssertEqual(rollouts.first { $0.url.lastPathComponent == own }?.url.standardizedFileURL,
                       managed.standardizedFileURL, "a managed home's own rollout is read")
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
