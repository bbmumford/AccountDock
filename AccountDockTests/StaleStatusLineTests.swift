import XCTest
@testable import AccountDock

/// A slot session's status line repeats the resets of its last reply. The
/// fixture is platform-execution (session 583fb354): it waited on its user's
/// answer from 12:03 pm, its slot moved from cybrio to hexorda at 4:12 pm,
/// and when its user answered at 6:04 pm the CLI redrew its status line,
/// still showing cybrio's resets, before its first request on hexorda.
/// platform-engineer (session 33962de2) moved with it and kept working.
final class StaleStatusLineTests: XCTestCase {
    /// 4:12:03 pm, when both slots moved.
    let moved = Date(timeIntervalSince1970: 1_800_000_000)

    func minutes(_ value: Double) -> Date { moved.addingTimeInterval(value * 60) }

    func testAStatusLineWhoseSessionSentNothingSinceItsSlotMovedSpeaksForNoAccount() {
        XCTAssertTrue(AppState.statusLinePredatesMove(lastRequest: minutes(-249), movedAt: moved),
                      "platform-execution's last request was at 12:03 pm, before the move")
        XCTAssertTrue(AppState.statusLinePredatesMove(lastRequest: nil, movedAt: moved),
                      "no request seen at all")
        XCTAssertTrue(AppState.statusLinePredatesMove(lastRequest: minutes(1), movedAt: moved),
                      "a request while the move settles may still have used the token read before")
    }

    func testAStatusLineAfterARequestSinceTheMoveIsEvidence() {
        XCTAssertFalse(AppState.statusLinePredatesMove(lastRequest: minutes(112.7), movedAt: moved),
                       "platform-execution's first request on hexorda, at 6:04:46 pm")
        XCTAssertFalse(AppState.statusLinePredatesMove(lastRequest: minutes(8), movedAt: moved),
                       "platform-engineer worked on hexorda from 4:20 pm")
    }
}
