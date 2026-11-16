import XCTest
@testable import AccountDock

/// The active account (moved by failover and weekly balancing), session
/// balancing and pausing are separate: one switch says whether the active
/// account moves automatically, and every event names which of them acted.
final class ActiveAccountSeparationTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testTheMasterSwitchIsTheStoredLockInverted() throws {
        var policy = ProviderFailoverPolicy.defaults(for: .claudeCode)
        XCTAssertTrue(policy.movesActiveAccountAutomatically, "on unless the active account is locked")
        policy.movesActiveAccountAutomatically = false
        XCTAssertTrue(policy.activeAccountLocked)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(policy)) as? [String: Any])
        XCTAssertEqual(json["activeAccountLocked"] as? Bool, true, "the switch is stored under the lock's own key")
        XCTAssertNil(json["movesActiveAccountAutomatically"])
        let decoded = try JSONDecoder().decode(ProviderFailoverPolicy.self, from: JSONEncoder().encode(policy))
        XCTAssertFalse(decoded.movesActiveAccountAutomatically)
        // With it off, failover projects no switch for the shared group.
        policy.enabled = true
        XCTAssertFalse(AppState.failoverMovesActiveAccount(policy, monitored: true))
    }

    func testAWithheldSwitchNamesWhoAskedForIt() {
        let failover = AppState.lockedSwitchEvent(source: "hexorda", target: "cybrio", reason: .exhausted)
        XCTAssertTrue(failover.hasPrefix("Failover would switch the active account from hexorda to cybrio, but moving the active account automatically is off, so it stays on hexorda."))
        XCTAssertTrue(failover.contains("the rest wait for hexorda to reset or for you to move them"))
        let weekly = AppState.lockedSwitchEvent(source: "hexorda", target: "cybrio", reason: .balance(advantageHours: 12))
        XCTAssertEqual(weekly, "Weekly balancing would switch the active account from hexorda to cybrio, but moving the active account automatically is off, so it stays on hexorda.")
    }

    func testSwitchEventsNameFailoverOrWeeklyBalancing() {
        XCTAssertTrue(AppState.exhaustedSwitchEvent(source: "hexorda", target: "cybrio", modelLimit: nil)
            .hasPrefix("Failover switches the active account from hexorda to cybrio: "))
        XCTAssertTrue(AppState.balanceSwitchEvent(source: "hexorda", target: "cybrio", hours: 8)
            .hasPrefix("Weekly balancing switches the active account from hexorda to cybrio: "))
        XCTAssertTrue(AppState.windowMoveEvent(session: "session 1", from: "fluxon", account: "voltrix",
                                               until: now.addingTimeInterval(3600), now: now)
            .hasPrefix("Session balancing moved session 1 from fluxon to voltrix"))
        XCTAssertTrue(AppState.heldMoveEvent(session: "session 1", account: "voltrix", destination: "fluxon", rule: "pacing",
                                             movedAt: now, until: now.addingTimeInterval(3600), now: now)
            .hasPrefix("Session balancing kept session 1 on voltrix"))
    }

    func testTheStayingAccountEventSaysWhatRestartsAndWhatWaits() {
        let reset = now.addingTimeInterval(40 * 60)
        let event = AppState.stayingAccountEvent(account: "hexorda", waiting: 3, restarted: 2, reset: reset, now: now)
        XCTAssertTrue(event.hasPrefix("hexorda stays the active account at its limit: moving the active account automatically is off, so failover moves none of the sessions on the shared sign-in."))
        XCTAssertTrue(event.contains("2 restart(s) in a slot of their own, so session balancing can place them on an account with room."))
        XCTAssertTrue(event.contains("3 wait(s) for its reset at \(UsageFormat.clock(reset, now: now)), or for you to move them."))
        XCTAssertFalse(AppState.stayingAccountEvent(account: "hexorda", waiting: 1, restarted: 0, reset: reset, now: now)
            .contains("restart(s)"))
    }
}
