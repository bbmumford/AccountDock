import XCTest
@testable import AccountDock

/// A refusal belongs to the account that served the request when it was
/// refused, by the slot's history and the reset the refusal states, never to
/// the account the slot moved to after. At 12:21 am every session cybrio
/// refused ("resets 1:30am") was put down to fluxon, voltrix or Backup, the
/// accounts their slots had left 98 seconds earlier.
final class RefusalAttributionTests: XCTestCase {
    let melbourne: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Melbourne")!
        return calendar
    }()
    let fluxon = UUID(), bytrix = UUID(), cybrio = UUID(), voltrix = UUID()
    let words = "You've hit your session limit · resets 1:30am (Australia/Melbourne)"

    func time(_ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        melbourne.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: hour, minute: minute, second: second))!
    }

    /// fluxon resets at 12:49 am; bytrix and cybrio both at 1:30 am.
    var windows: [(id: UUID, resets: [Date])] {
        [(fluxon, [time(0, 49)]), (bytrix, [time(1, 30)]), (cybrio, [time(1, 30)]), (voltrix, [time(3, 40)])]
    }

    /// The slot left fluxon for cybrio at 12:20:04 am.
    var history: [AppState.SlotAssignment] {
        [AppState.SlotAssignment(account: fluxon, at: .distantPast), AppState.SlotAssignment(account: cybrio, at: time(0, 20, 4))]
    }

    func testTheSlotsHistoryNamesTheAccountsThatMayHaveServedTheRequest() {
        XCTAssertEqual(AppState.servingSlotCandidates(at: time(0, 21, 42), history: history), [fluxon, cybrio],
                       "98 seconds after the move either may have served it")
        XCTAssertEqual(AppState.servingSlotCandidates(at: time(0, 25), history: history), [cybrio])
        XCTAssertEqual(AppState.servingSlotCandidates(at: time(0, 19), history: history), [fluxon],
                       "a move after the request is none of them")
        XCTAssertEqual(AppState.servingSlotCandidates(at: time(0, 19), history: []), [])
    }

    func testARefusalGoesToTheServingAccountWhoseResetItStates() {
        let at = time(0, 21, 42)
        // The slot's settled account was still fluxon, whose window resets
        // at 12:49 am: the 1:30 am reset is cybrio's, which the slot had
        // just moved to, not bytrix's, which it never served.
        let served = AppState.servingSlotCandidates(at: at, history: history)
        let refusing = AppState.refusingAccount(words: words, at: at, attributed: fluxon, windows: windows, served: served,
                                                calendar: melbourne)
        XCTAssertEqual(refusing.account, cybrio)
        XCTAssertTrue(refusing.byReset)
        // Without the slot's history, two accounts reset at 1:30 am and the
        // attribution cannot move.
        XCTAssertEqual(AppState.refusingAccount(words: words, at: at, attributed: fluxon, windows: windows,
                                                calendar: melbourne).account, fluxon)
        // A refusal whose reset is the attributed account's stays there.
        XCTAssertEqual(AppState.refusingAccount(words: words, at: at, attributed: cybrio, windows: windows, served: served,
                                                calendar: melbourne).account, cybrio)
    }

    func testCheckingTheRefusalAgainKeepsItWithTheAccountThatServedIt() {
        let at = time(0, 21, 42)
        let served = AppState.servingSlotCandidates(at: at, history: history)
        let check = AppState.refusalVerification(words: words, at: at, attributed: fluxon, windows: windows,
                                                 wholeAt: [cybrio: time(0, 22)], inUse: [fluxon, cybrio], served: served,
                                                 calendar: melbourne)
        XCTAssertEqual(check.account, cybrio)
        XCTAssertFalse(check.doubtful)
        XCTAssertEqual(check.read, [])
    }
}
