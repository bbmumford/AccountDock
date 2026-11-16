import XCTest
@testable import AccountDock

/// A run whose process left no session record, as every session is for the
/// first cycle after AccountDock restarts, is weighed with the sessions in
/// the cycle's ledger, kept on its account by its slot while admission
/// leaves it waiting, and named by the folder it runs in. On the night every
/// account reached its limit, seven such runs went to cybrio in one second
/// and their plans read "session /Users/l waits…".
final class UnrecordedRunTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let home = NSHomeDirectory()

    func testARunIsNamedByTheFolderItRunsInNotItsSlotPath() {
        let slotRoot = "/private/tmp/accountdock-slots"
        let table = ProcessTable(entries: [
            ProcessTable.Entry(pid: 300, command: "claude", environment: "CLAUDE_CONFIG_DIR=\(slotRoot)/a PWD=\(home)/ORBTR"),
            ProcessTable.Entry(pid: 301, command: "claude", environment: "CLAUDE_CONFIG_DIR=\(slotRoot)/b"),
        ])
        let folders = AppState.slotFolders([300: slotRoot + "/a", 301: slotRoot + "/b"], table: table)
        XCTAssertEqual(folders, [slotRoot + "/a": home + "/ORBTR"])
        XCTAssertEqual(AppState.runName(folder: folders[slotRoot + "/a"]), "a run in ~/ORBTR")
        XCTAssertEqual(AppState.runName(folder: folders[slotRoot + "/b"]), "a run with no session record")
        XCTAssertFalse(AppState.runName(folder: folders[slotRoot + "/a"]).contains("/Users/"))
    }

    func testARunIsKeyedApartFromSessions() {
        XCTAssertTrue(AppState.isUnrecordedRun(home + "/Library/Application Support/AccountDock/Slots/claude/a"))
        XCTAssertFalse(AppState.isUnrecordedRun("583fb354-1111-2222-3333-444455556666"))
    }

    func testRunsAreChargedAndSpreadByTheLedgerNotSentToOneLane() {
        // cybrio's fresh window at 4.25% per million holds 21M tokens an
        // hour with its margin; seven runs at a new session's assumed rate
        // each ask 20M.
        let cybrio = UUID(), hexorda = UUID(), voltrix = UUID()
        func fresh(_ id: UUID) -> SessionPacer.Account {
            SessionPacer.Account(id: id, utilization: 0, resetsAt: now.addingTimeInterval(5 * 3600), burnPerHour: 0,
                                 baseWeight: 1, weeklyRemaining: 400, weeklyResetsAt: now.addingTimeInterval(4 * 86_400),
                                 percentPerMillion: 4.25)
        }
        let runs = (1...7).map { index in
            SessionPacer.RebalanceSession(id: "/slots/run-\(index)", account: voltrix,
                                          tokensPerHour: SessionPacer.defaultSessionRate, contextTokens: 0, model: nil,
                                          movable: true)
        }
        let admission = SessionPacer().admitToLanes(runs, accounts: [fresh(cybrio), fresh(hexorda)], running: [],
                                                    destinations: [cybrio, hexorda], now: now)
        let placed = admission?.placements ?? [:]
        XCTAssertEqual(placed.count, 2, "one run fills each fresh window for the hour")
        XCTAssertEqual(Set(placed.values), [cybrio, hexorda])
        XCTAssertEqual(admission?.waiting.count, 5, "the rest wait where they are")
        // A run admission left waiting keeps its slot on its own account:
        // the slot path never sends it to the pool's fallback.
        let kept = AppState.slotChoice(current: voltrix, pinned: nil, requested: nil, balance: nil,
                                       cannotServe: { $0 == voltrix }, modelSpent: false, byWeight: [cybrio],
                                       placed: nil, fallback: cybrio, heldOn: voltrix)
        XCTAssertEqual(kept.target, voltrix)
    }
}
