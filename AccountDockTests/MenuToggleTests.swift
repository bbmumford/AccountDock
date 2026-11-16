import XCTest
@testable import AccountDock

/// The menu's Failover and Balancing switches over every provider: on, off
/// or mixed, a mixed one turning all on, and session balancing restoring a
/// provider's own settings when it is turned on again.
final class MenuToggleTests: XCTestCase {
    func testTheSwitchShowsOnOffOrMixed() {
        XCTAssertEqual(AppState.toggleState([true, true, true]), .on)
        XCTAssertEqual(AppState.toggleState([false, false]), .off)
        XCTAssertEqual(AppState.toggleState([true, false, false]), .mixed)
        XCTAssertEqual(AppState.toggleState([]), .off)
    }

    func testClickingAMixedSwitchTurnsEveryProviderOn() {
        XCTAssertTrue(AppState.toggleTarget(.mixed))
        XCTAssertTrue(AppState.toggleTarget(.off))
        XCTAssertFalse(AppState.toggleTarget(.on))
    }

    func testTheTooltipListsEachProvidersState() {
        XCTAssertEqual(AppState.toggleSummary([(name: "Claude Code", on: true), (name: "Codex", on: false),
                                               (name: "Kimi Code", on: false)]),
                       "Claude Code on · Codex off · Kimi Code off")
        XCTAssertEqual(AppState.toggleEvent("Failover", on: false, providers: ["Claude Code", "Codex", "Kimi Code"],
                                            from: "the menu"),
                       "Failover turned off from the menu for Claude Code, Codex and Kimi Code.")
        XCTAssertEqual(AppState.toggleEvent("Session balancing", on: true, providers: ["Codex"], from: "the menu"),
                       "Session balancing turned on from the menu for Codex.")
    }

    func testTurningSessionBalancingOffAndOnRestoresTheProvidersOwnSettings() {
        var policy = ProviderFailoverPolicy.defaults(for: .claudeCode)
        policy.distributeSessions = true
        policy.paceSessions = false
        policy.rebalanceAutomatically = true
        policy.resumeSessionsLeftWaiting = false
        policy.noRoomModelFallback = "claude-sonnet"
        let off = AppState.withSessionBalancing(policy, on: false)
        XCTAssertFalse(off.distributeSessions)
        XCTAssertEqual(AppState.withSessionBalancing(off, on: true), policy, "every other setting is as it was")
        // A provider that never had it on keeps its own pacing choices too.
        var never = ProviderFailoverPolicy.defaults(for: .codex)
        never.rebalanceAutomatically = false
        let on = AppState.withSessionBalancing(never, on: true)
        XCTAssertTrue(on.distributeSessions)
        XCTAssertEqual(on.paceSessions, never.paceSessions)
        XCTAssertFalse(on.rebalanceAutomatically)
    }

    func testOneProvidersSwitchMakesTheFooterMixedAndSaysWhereItWasSet() {
        // Claude Code's heading turns failover off while Codex and Kimi Code keep it.
        XCTAssertEqual(AppState.toggleState([false, true, true]), .mixed)
        XCTAssertEqual(AppState.toggleEvent("Failover", on: false, providers: ["Claude Code"], from: "the Sessions page"),
                       "Failover turned off from the Sessions page for Claude Code.")
    }

    func testFailoverIsTheMoveTheActiveAccountSwitch() {
        var policy = ProviderFailoverPolicy.defaults(for: .claudeCode)
        policy.enabled = true
        policy.intelligentBalancingEnabled = true
        policy.movesActiveAccountAutomatically = false
        XCTAssertTrue(policy.activeAccountLocked)
        XCTAssertTrue(policy.enabled, "failover's and weekly balancing's own settings are kept")
        XCTAssertTrue(policy.intelligentBalancingEnabled)
    }
}
