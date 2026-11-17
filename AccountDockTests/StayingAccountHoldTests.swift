import XCTest
@testable import AccountDock

/// A morning with automatic failover off and session balancing on: the
/// active account and every other account in the failover order at their
/// 5-hour limits or out of their week, one account outside the order (where
/// the user pinned a session) with room, and twelve sessions in slots of
/// their own spread over them. Each session waits for its own account
/// (`AppState.pauseScope`, `someAccountHasRoom`), and no account's room ends
/// the pause whole (`capacityEndsPause`).
final class StayingAccountHoldTests: XCTestCase {
    let hexorda = UUID(), voltrix = UUID(), bytrix = UUID(), cybrio = UUID()
    let fluxon = UUID(), backup = UUID(), icare = UUID()

    /// The failover order: every account but the one outside it.
    var order: [UUID] { [hexorda, voltrix, bytrix, cybrio, fluxon, backup] }

    /// The slot sessions by the account each slot serves, and the session
    /// pinned to the account outside the order.
    var sessions: [String: UUID?] {
        ["19496bb9": cybrio, "33962de2": cybrio, "345dc95e": cybrio, "4822c359": cybrio, "583fb354": cybrio,
         "a78ddf66": cybrio, "8c64c5f8": bytrix, "075198d6": bytrix, "1603da04": cybrio, "5386173b": cybrio,
         "b5fd34c7": icare, "341e5695": icare]
    }

    func testAnAccountOutsideTheOrderWithRoomKeepsNewTurnsGoingAndItsSessionsRunning() {
        let full: Set<UUID> = Set(order)
        let serving = Set(sessions.values.compactMap { $0 })
        let room = AppState.someAccountHasRoom(order: order, serving: serving) { !full.contains($0) }
        XCTAssertTrue(room, "the pinned session's account has room, so not every new turn waits")

        let scope = AppState.pauseScope(sessions: sessions, active: hexorda, atOrNearLimit: { full.contains($0) },
                                        anyRoom: room, destination: { _ in nil })
        XCTAssertFalse(scope.holdsNewTurns, "the pause lists the sessions that wait rather than holding everyone")
        XCTAssertEqual(scope.held, sessions.filter { $0.value.map(full.contains) ?? true }.keys.sorted())
        XCTAssertFalse(scope.held.contains("341e5695"), "a session on an account with room never waits for another's limit")
        XCTAssertFalse(scope.held.contains("b5fd34c7"))
    }

    func testOnlyWhenNoAccountAnySessionCouldUseHasRoomDoEveryNewTurnWait() {
        let full: Set<UUID> = Set(order).union([icare])
        let serving = Set(sessions.values.compactMap { $0 })
        XCTAssertFalse(AppState.someAccountHasRoom(order: order, serving: serving) { !full.contains($0) })

        // An account outside the order that no session runs on is no room.
        XCTAssertFalse(AppState.someAccountHasRoom(order: order, serving: [cybrio]) { $0 == self.icare })
    }

    func testAResetReleasesOnlyItsOwnSessionsAndTheActiveAccountsRoomEndsNothingWhole() {
        // Every account the sessions use is out: the pause holds every turn.
        var full: Set<UUID> = Set(order).union([icare])
        let all = AppState.pauseScope(sessions: sessions, active: hexorda, atOrNearLimit: { full.contains($0) },
                                      anyRoom: false, destination: { _ in nil })
        XCTAssertTrue(all.holdsNewTurns)
        XCTAssertEqual(all.held.count, 12)

        // The active account resets first: the pause it wrote does not end
        // whole, and only the sessions whose own account has room go on.
        let pause = AgentPauseGate.PauseFile(sessions: all.held, reason: "limit", pausedAt: Date(), resumeAt: nil,
                                             holdsNewTurns: true)
        XCTAssertFalse(AppState.capacityEndsPause(pause))
        full.remove(hexorda)
        let afterActive = AppState.pauseScope(sessions: sessions, active: hexorda,
                                              atOrNearLimit: { full.contains($0) }, anyRoom: true,
                                              destination: { _ in nil })
        XCTAssertFalse(afterActive.holdsNewTurns)
        XCTAssertEqual(afterActive.held.count, 12, "every slot session is on an account still at its limit")

        // Then bytrix resets: its two sessions go on, the rest still wait.
        full.remove(bytrix)
        let afterBytrix = AppState.pauseScope(sessions: sessions, active: hexorda,
                                              atOrNearLimit: { full.contains($0) }, anyRoom: true,
                                              destination: { _ in nil })
        XCTAssertEqual(Set(all.held).subtracting(afterBytrix.held), ["8c64c5f8", "075198d6"])
    }
}
