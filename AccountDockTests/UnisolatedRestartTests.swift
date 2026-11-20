import XCTest
@testable import AccountDock

/// A session outside a slot of its own is restarted in one without being
/// asked, once it is idle between turns in agterm, at most once every ten
/// minutes, on its pin when pinned, else back in the slot it had or on the
/// account whose sign-in it shares.
final class UnisolatedRestartTests: XCTestCase {
    private let now = Date()

    private func session(_ id: String, event: String) -> AgentSession {
        AgentSession(sessionID: id, provider: "claude", event: event, workingDirectory: "/Users/a/ORBTR", processID: 4242,
                     host: nil, observedAt: now)
    }

    func testOnlyIdleSessionsInAgtermOutsideTheBackgroundServiceAreRestartedEveryTenMinutesAtMost() {
        let idle = session("idle", event: "Stop")
        let working = session("working", event: "UserPromptSubmit")
        let fresh = session("fresh", event: "SessionStart")
        let elsewhere = session("elsewhere", event: "Stop")
        let background = session("background", event: "Stop")
        let recent = session("recent", event: "Stop")
        let earlier = session("earlier", event: "Stop")
        let terminals = ["idle": "agt-1", "working": "agt-2", "fresh": "agt-3", "background": "agt-4", "recent": "agt-5",
                         "earlier": "agt-6"]
        let restarted = ["recent": now.addingTimeInterval(-60),
                         "earlier": now.addingTimeInterval(-AppState.stuckRestartSpacing - 1)]
        XCTAssertEqual(AppState.automaticRestarts([idle, working, fresh, elsewhere, background, recent, earlier],
                                                  background: ["background"], terminals: terminals,
                                                  lastRestart: restarted, now: now),
                       ["idle", "earlier"])
    }

    func testAPinnedSessionIsRestartedOnItsPinAndAnyOtherWhereItRan() {
        let (pin, shared) = (UUID(), UUID())
        XCTAssertEqual(AppState.automaticRestartAccount(pinned: pin, takesBack: false, shared: shared), pin)
        XCTAssertNil(AppState.automaticRestartAccount(pinned: pin, takesBack: true, shared: shared),
                     "the slot offered back to a pinned session already serves its pin")
        XCTAssertEqual(AppState.automaticRestartAccount(pinned: nil, takesBack: false, shared: shared), shared)
        XCTAssertNil(AppState.automaticRestartAccount(pinned: nil, takesBack: true, shared: shared),
                     "it takes back the slot it had")
    }

    func testEachRestartSaysWhereTheSessionContinues() {
        XCTAssertEqual(AppState.automaticRestartEvent(session: "session 8c64c5f8 in ~/ORBTR", takesBack: true, account: nil,
                                                      pinned: false),
                       "Restarted session 8c64c5f8 in ~/ORBTR in a slot of its own without being asked: it ran on the shared sign-in, so it could not be moved on its own; it continues in the slot it had before.")
        XCTAssertTrue(AppState.automaticRestartEvent(session: "s", takesBack: false, account: "ICARE", pinned: true)
            .hasSuffix("it continues on ICARE, where it is pinned."))
        XCTAssertTrue(AppState.automaticRestartEvent(session: "s", takesBack: false, account: "HSTLES", pinned: false)
            .hasSuffix("it continues on HSTLES."))
    }
}
