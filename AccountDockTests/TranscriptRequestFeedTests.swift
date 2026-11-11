import XCTest
@testable import AccountDock

final class TranscriptRequestFeedTests: XCTestCase {
    private func row(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self) + "\n"
    }

    private func assistant(_ id: String, at: String, read: Int, write: Int = 0, output: Int = 10, sidechain: Bool = false,
                           session: String = "s1") -> String {
        row(["type": "assistant", "isSidechain": sidechain, "timestamp": at, "requestId": "r-" + id, "sessionId": session,
             "message": ["id": id, "model": "claude-opus-5-5",
                         "usage": ["input_tokens": 1, "cache_read_input_tokens": read, "cache_creation_input_tokens": write,
                                   "cache_creation": ["ephemeral_1h_input_tokens": write], "output_tokens": output]]])
    }

    func testSubagentRequestsAreCreditedToTheirSessionAndStartNoTurn() async throws {
        let config = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: config) }
        let project = config.appendingPathComponent("projects/p", isDirectory: true)
        let subagents = project.appendingPathComponent("s1/subagents/workflows/run", isDirectory: true)
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        let now = Date()
        let stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-60))
        let prompt = row(["type": "user", "message": ["content": "do it"]])
        try (prompt + assistant("m1", at: stamp, read: 100, write: 5) + assistant("m1", at: stamp, read: 100, write: 5)
             + assistant("side", at: stamp, read: 7, sidechain: true))
            .write(to: project.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8)
        try (row(["type": "user", "isSidechain": true, "message": ["content": "task"]])
             + assistant("a1", at: stamp, read: 900_000, write: 20_000, sidechain: true, session: "agent-own-id"))
            .write(to: subagents.appendingPathComponent("agent-x.jsonl"), atomically: true, encoding: .utf8)

        let feed = TranscriptRequestFeed()
        let requests = await feed.newRequests(.claudeCode, configDirectory: config.path, now: now)
        XCTAssertEqual(requests.count, 2, "a streamed message counts once; a sidechain row in the session's own file is not its request")
        XCTAssertEqual(Set(requests.map(\.session)), ["s1"])
        let main = try XCTUnwrap(requests.first { $0.contextTokens == 106 })
        XCTAssertTrue(main.startsTurn)
        XCTAssertEqual(main.cacheLifetime, 3600)
        let sub = try XCTUnwrap(requests.first { $0.contextTokens == 920_001 })
        XCTAssertFalse(sub.startsTurn)
        let again = await feed.newRequests(.claudeCode, configDirectory: config.path, now: now)
        XCTAssertTrue(again.isEmpty, "each line is read once")
    }

    func testATranscriptAddedUnderAQuietSubagentDirectoryIsStillRead() async throws {
        let fm = FileManager.default
        let config = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: config) }
        let subagents = config.appendingPathComponent("projects/p/s1/subagents", isDirectory: true)
        let run = subagents.appendingPathComponent("workflows/run", isDirectory: true)
        try fm.createDirectory(at: run, withIntermediateDirectories: true)
        let now = Date()
        let old = now.addingTimeInterval(-3 * 60 * 60)
        let oldStamp = ISO8601DateFormatter().string(from: old)
        let stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-60))
        for (directory, name) in [(subagents, "agent-old.jsonl"), (run, "agent-old-run.jsonl")] {
            let file = directory.appendingPathComponent(name)
            try assistant(name, at: oldStamp, read: 1, sidechain: true).write(to: file, atomically: true, encoding: .utf8)
            try fm.setAttributes([.modificationDate: old], ofItemAtPath: file.path)
        }

        let feed = TranscriptRequestFeed()
        let first = await feed.newRequests(.claudeCode, configDirectory: config.path, now: now)
        XCTAssertTrue(first.isEmpty, "transcripts older than the lookback hold nothing current")

        try assistant("n1", at: stamp, read: 300, sidechain: true)
            .write(to: run.appendingPathComponent("agent-new-run.jsonl"), atomically: true, encoding: .utf8)
        let nested = await feed.newRequests(.claudeCode, configDirectory: config.path, now: now.addingTimeInterval(20))
        XCTAssertEqual(nested.map(\.contextTokens), [301], "a quiet directory's subdirectories are still visited")

        try assistant("n2", at: stamp, read: 500, sidechain: true)
            .write(to: subagents.appendingPathComponent("agent-new.jsonl"), atomically: true, encoding: .utf8)
        let added = await feed.newRequests(.claudeCode, configDirectory: config.path, now: now.addingTimeInterval(40))
        XCTAssertEqual(added.map(\.contextTokens), [501], "a file added to a quiet directory changes its time, so it is listed again")
        XCTAssertEqual(Set(added.map(\.session)), ["s1"])
    }
}
