import XCTest
@testable import AccountDock

/// Playing a held session while no account has room takes two presses
/// (`AppState.playPress`): the first leaves it held and says why for
/// `playNoteLifetime`, a second while that shows runs it anyway, and with
/// room one press releases it. The fixture is cf-designer (session
/// a78ddf66) held on cybrio at 11:17:18 pm on 19 November, every account
/// spent, its plan waiting for cybrio's new week at 9 pm on 24 November.
final class PlayPressTests: XCTestCase {
    let designer = "a78ddf66-0a33-4161-b945-8c6dd6f3b17d"
    let now = ISO8601DateFormatter().date(from: "2026-11-19T23:17:18+11:00")!
    let newWeek = ISO8601DateFormatter().date(from: "2026-11-24T21:00:00+11:00")!

    private var reason: String {
        AppState.noRoomPlayNote(resume: (account: "cybrio", at: newWeek, newWeek: true), now: now)
    }

    private func press(carried: Bool, note: AppState.PlayNote?, at time: Date) -> (press: AppState.PlayPress, note: AppState.PlayNote?) {
        AppState.playPress(carried: carried, note: note, provider: .claudeCode, session: designer, label: "cf-designer",
                           text: { self.reason }, now: time)
    }

    func testTheFirstPressWithoutRoomHoldsItAndSaysWhy() throws {
        let first = press(carried: false, note: nil, at: now)
        XCTAssertEqual(first.press, .explain)
        let note = try XCTUnwrap(first.note)
        XCTAssertEqual(note.text, reason)
        XCTAssertEqual(note.label, "cf-designer")
        XCTAssertEqual(note.until, now.addingTimeInterval(AppState.playNoteLifetime))
        XCTAssertTrue((5...8).contains(AppState.playNoteLifetime), "it shows for a few seconds")
        XCTAssertEqual(reason, "No account has room; it resumes about \(UsageFormat.clock(newWeek, now: now)) (cybrio's new week). Press again to run it anyway.")
    }

    func testASecondPressWhileTheNoteShowsRunsItAnyway() {
        let first = press(carried: false, note: nil, at: now)
        let second = press(carried: false, note: first.note, at: now.addingTimeInterval(3))
        XCTAssertEqual(second.press, .runAnyway)
        XCTAssertNil(second.note, "the note goes with the release")
        XCTAssertEqual(AppState.playAnywayEvent("cf-designer"),
                       "Resumed cf-designer at your request although no account has room; it will be refused at the limit and wait there.")
    }

    func testAPressAfterTheNoteClearsIsAFirstPressAgain() throws {
        let first = press(carried: false, note: nil, at: now)
        let later = now.addingTimeInterval(AppState.playNoteLifetime + 1)
        let again = press(carried: false, note: first.note, at: later)
        XCTAssertEqual(again.press, .explain)
        XCTAssertEqual(try XCTUnwrap(again.note).until, later.addingTimeInterval(AppState.playNoteLifetime))
        XCTAssertEqual(press(carried: false, note: again.note, at: later.addingTimeInterval(1)).press, .runAnyway)
    }

    func testWithRoomOnePressReleasesIt() {
        XCTAssertEqual(press(carried: true, note: nil, at: now).press, .release)
        let first = press(carried: false, note: nil, at: now)
        let roomy = press(carried: true, note: first.note, at: now.addingTimeInterval(2))
        XCTAssertEqual(roomy.press, .release, "room that came since the first press releases it as one play")
        XCTAssertNil(roomy.note)
    }

    func testAnotherSessionsNoteIsNoSecondPress() {
        let other = AppState.PlayNote(provider: .claudeCode, session: "19496bb9", label: "platform", text: reason,
                                      until: now.addingTimeInterval(5))
        XCTAssertEqual(press(carried: false, note: other, at: now).press, .explain)
    }

    func testTheNoteNamesTheResetItWaitsFor() {
        let window = ISO8601DateFormatter().date(from: "2026-11-19T23:50:00+11:00")!
        XCTAssertEqual(AppState.noRoomPlayNote(resume: (account: "hexorda", at: window, newWeek: false), now: now),
                       "No account has room; it resumes about \(UsageFormat.clock(window, now: now)) (hexorda's fresh window). Press again to run it anyway.")
        XCTAssertEqual(AppState.noRoomPlayNote(resume: nil, now: now),
                       "No account has room; it resumes when one has room. Press again to run it anyway.")
    }
}
