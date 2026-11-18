import XCTest
@testable import AccountDock

/// Every program the app runs is started without the slot and home
/// variables the app inherited from a slot session's shell, so a `claude`
/// it runs reads the shared sign-in rather than that session's slot.
final class CommandRunnerEnvironmentTests: XCTestCase {
    func testChildrenLoseTheSlotVariablesTheAppInheritedButKeepTheirOwn() {
        let inherited = [
            "HOME": "/Users/u", "PATH": "/usr/bin",
            "CLAUDE_SECURESTORAGE_CONFIG_DIR": "/Users/u/.accountdock/claude-slots/session/07314A9F",
            "CLAUDE_CONFIG_DIR": "/Users/u/.claude-other", "CODEX_HOME": "/Users/u/.codex-x",
            "ACCOUNTDOCK_KIMI_SLOT": "/k", "KIMI_CODE_BASE_URL": "https://API.example", "KIMI_CODE_OAUTH_HOST": "h",
        ]
        let child = CommandRunner.childEnvironment(nil, inherited: inherited)
        XCTAssertEqual(child, ["HOME": "/Users/u", "PATH": "/usr/bin"])
        var own = inherited
        own["CLAUDE_CONFIG_DIR"] = "/tmp/login"
        own["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = "/tmp/login"
        let login = CommandRunner.childEnvironment(own, inherited: inherited)
        XCTAssertEqual(login["CLAUDE_CONFIG_DIR"], "/tmp/login", "a caller's own sign-in directory is kept")
        XCTAssertEqual(login["CLAUDE_SECURESTORAGE_CONFIG_DIR"], "/tmp/login")
        XCTAssertNil(login["CODEX_HOME"])
        XCTAssertEqual(CommandRunner.childEnvironment(nil, inherited: ["HOME": "/h"]), ["HOME": "/h"])
    }

    func testAChildTheAppStartsReadsNoInheritedSlot() throws {
        let inherited = ProcessInfo.processInfo.environment
        let result = try CommandRunner.runSynchronously(CommandRunner.Command("/usr/bin/env", errorOutput: .discarded),
                                                        timeout: 10)
        let names = Set(result.text.split(separator: "\n").compactMap { $0.split(separator: "=").first.map(String.init) })
        for name in CommandRunner.inheritedCredentialVariables where inherited[name] != nil {
            XCTAssertFalse(names.contains(name), name)
        }
        XCTAssertTrue(names.contains("PATH"))
    }

    func testAReaderRunsWhileItsProcessIDIsAliveWithTheSameStart() {
        let started = Date(timeIntervalSince1970: 1_000)
        let reader = AppState.SlotReader(pid: 77, startedAt: started)
        XCTAssertFalse(AppState.readerRuns(reader, isAlive: { _ in false }, startTime: { _ in started }))
        XCTAssertTrue(AppState.readerRuns(reader, isAlive: { _ in true }, startTime: { _ in started }))
        XCTAssertFalse(AppState.readerRuns(reader, isAlive: { _ in true }, startTime: { _ in started.addingTimeInterval(600) }),
                       "a later process given the same ID is not the reader")
        XCTAssertTrue(AppState.readerRuns(AppState.SlotReader(pid: 77, startedAt: nil), isAlive: { _ in true },
                                          startTime: { _ in nil }))
    }

    func testReadersFollowTheScanAndKeepThoseStillRunningForASlotTheScanMissed() {
        let previous: [String: [AppState.SlotReader]] = [
            "/s/A": [.init(pid: 1, startedAt: nil)],
            "/s/B": [.init(pid: 2, startedAt: nil), .init(pid: 3, startedAt: nil)],
            "/s/C": [.init(pid: 4, startedAt: nil)],
        ]
        let started = Date(timeIntervalSince1970: 5)
        let readers = AppState.slotReaders(previous: previous, byProcess: [9: "/s/A", 8: "/s/D"], startedAt: [9: started],
                                           stillRuns: { $0.pid == 3 })
        XCTAssertEqual(readers["/s/A"], [.init(pid: 9, startedAt: started)], "a slot read now has the readers seen now")
        XCTAssertEqual(readers["/s/B"], [.init(pid: 3, startedAt: nil)], "a missed slot keeps the readers still running")
        XCTAssertNil(readers["/s/C"], "a slot whose readers all ended has none")
        XCTAssertEqual(readers["/s/D"], [.init(pid: 8, startedAt: nil)])
    }
}
