import XCTest
@testable import AccountDock

/// A session whose account reaches its limit waits there, held, when the
/// account resets before its prompt cache expires, and continues there with
/// its cache (`AppState.holdSessionsForImminentReset`).
final class CacheWaitTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let hexorda = UUID(), backup = UUID()

    private func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    private func state(_ id: UUID, session: Double, active: Bool = false, sessionReset: TimeInterval = 3 * 3600,
                       refused: Bool = false) -> QuotaAccountState {
        var state = QuotaAccountState(
            id: id,
            usage: UsageAPIResponse(
                fiveHour: UsageWindow(utilization: session, resetsAt: iso(now.addingTimeInterval(sessionReset))),
                sevenDay: UsageWindow(utilization: 40, resetsAt: iso(now.addingTimeInterval(4 * 86_400))),
                sevenDayOauthApps: nil, sevenDayOpus: nil, sevenDaySonnet: nil,
                sevenDayCowork: nil, iguanaNecktie: nil, extraUsage: nil
            ),
            observedAt: now.addingTimeInterval(-60),
            sessionBurnPerHour: 0,
            weeklyBurnPerHour: 0,
            isActive: active,
            mayBeConsumedElsewhere: false,
            credentialsUsable: true,
            resetUnverified: false
        )
        state.refusedAtLimit = refused
        return state
    }

    func testTheSessionWaitsOnlyWhenTheResetComesBeforeItsCacheExpires() {
        let lastSeen = now.addingTimeInterval(-5 * 60)
        // Its cache, written five minutes ago for the hour, lasts 55 minutes more.
        XCTAssertTrue(AppState.cacheOutlastsReset(reset: now.addingTimeInterval(20 * 60), lastSeen: lastSeen,
                                                  cacheLifetime: nil, now: now))
        XCTAssertTrue(AppState.cacheOutlastsReset(reset: now.addingTimeInterval(53 * 60), lastSeen: lastSeen,
                                                  cacheLifetime: 3600, now: now))
        XCTAssertFalse(AppState.cacheOutlastsReset(reset: now.addingTimeInterval(54.5 * 60), lastSeen: lastSeen,
                                                   cacheLifetime: 3600, now: now),
                       "its first request after the reset must still find the cache")
        XCTAssertFalse(AppState.cacheOutlastsReset(reset: now.addingTimeInterval(70 * 60), lastSeen: lastSeen,
                                                   cacheLifetime: nil, now: now), "a later reset moves it as usual")
        XCTAssertFalse(AppState.cacheOutlastsReset(reset: now.addingTimeInterval(4 * 60), lastSeen: lastSeen,
                                                   cacheLifetime: 5 * 60, now: now), "a five-minute cache has gone")
        XCTAssertFalse(AppState.cacheOutlastsReset(reset: now.addingTimeInterval(-60), lastSeen: lastSeen,
                                                   cacheLifetime: nil, now: now))
    }

    func testTheSharedSignInWaitsTogetherWhenMostOfItsContextKeepsItsCache() {
        XCTAssertTrue(AppState.sharedSignInWaits(heldContext: 600_000, totalContext: 1_000_000))
        XCTAssertTrue(AppState.sharedSignInWaits(heldContext: 500_000, totalContext: 1_000_000))
        XCTAssertFalse(AppState.sharedSignInWaits(heldContext: 400_000, totalContext: 1_000_000),
                       "most of what a switch rewrites would be rewritten anyway")
        XCTAssertFalse(AppState.sharedSignInWaits(heldContext: 0, totalContext: 0))
    }

    func testAWaitingSessionKeepsItsSlotOnAnAccountThatCannotServeIt() {
        let refuses: (UUID) -> Bool = { $0 == self.hexorda }
        let moved = AppState.slotChoice(current: hexorda, pinned: nil, requested: nil, balance: nil, cannotServe: refuses,
                                        modelSpent: false, byWeight: [backup], placed: backup, fallback: backup)
        XCTAssertEqual(moved.target, backup, "without the wait, the stranded placement moves it")
        let kept = AppState.slotChoice(current: hexorda, pinned: nil, requested: nil, balance: backup, cannotServe: refuses,
                                       modelSpent: false, byWeight: [backup], placed: backup, fallback: backup,
                                       waitsOn: hexorda)
        XCTAssertEqual(kept.target, hexorda)
        XCTAssertFalse(kept.balanced, "no balancing move takes it either")
        let asked = AppState.slotChoice(current: hexorda, pinned: nil, requested: backup, balance: nil, cannotServe: refuses,
                                        modelSpent: false, byWeight: [backup], fallback: backup, waitsOn: hexorda)
        XCTAssertEqual(asked.target, backup, "a move the user asks for is never held")
        XCTAssertTrue(asked.requested)
    }

    func testAPauseAtALimitHoldsAWaitingSessionWhereItIsInsteadOfMovingIt() {
        // Both slot sessions are on hexorda, at its limit, and backup has room.
        let sessions: [String: UUID?] = ["waits": hexorda, "moves": hexorda]
        let scope = AppState.pauseScope(sessions: sessions, active: backup, atOrNearLimit: { $0 == self.hexorda },
                                        anyRoom: true, destination: { _ in self.backup },
                                        pinnedHeld: { $0 == "waits" ? true : nil })
        XCTAssertEqual(scope.held, ["waits"])
        XCTAssertEqual(scope.moves, ["moves": backup])
        XCTAssertFalse(scope.holdsNewTurns)
    }

    func testFailoverMakesNoSwitchWhileTheSharedSignInWaitsForTheActiveAccountsReset() {
        var policy = ProviderFailoverPolicy.defaults(for: .claudeCode)
        policy.enabled = true
        var settings = FailoverPlanner.Settings(policy: policy, provider: .claudeCode)
        let current = state(hexorda, session: 99.5, active: true, sessionReset: 20 * 60)
        let roomy = state(backup, session: 10)
        XCTAssertEqual(FailoverPlanner(settings: settings).plan(current: current, ladder: [current, roomy], lastSwitch: nil,
                                                                now: now),
                       .switchTo(backup, .exhausted))
        settings.sharedSignInWaitsUntil = now.addingTimeInterval(20 * 60)
        XCTAssertEqual(FailoverPlanner(settings: settings).plan(current: current, ladder: [current, roomy], lastSwitch: nil,
                                                                now: now),
                       .stay(.waitingForResetWithCache))
        let refused = state(hexorda, session: 80, active: true, sessionReset: 20 * 60, refused: true)
        XCTAssertEqual(FailoverPlanner(settings: settings).plan(current: refused, ladder: [refused, roomy], lastSwitch: nil,
                                                                now: now),
                       .stay(.waitingForResetWithCache), "a refusal waits as the limit does")
        // A reset no reading confirms within the grace no longer holds it.
        settings.sharedSignInWaitsUntil = now.addingTimeInterval(-AppState.accountHoldGrace - 60)
        XCTAssertEqual(FailoverPlanner(settings: settings).plan(current: current, ladder: [current, roomy], lastSwitch: nil,
                                                                now: now),
                       .switchTo(backup, .exhausted))
    }

    func testTheOptionIsOnByDefaultAndKeepsItsStoredValue() throws {
        let decoded = try JSONDecoder().decode(ProviderFailoverPolicy.self, from: Data("{}".utf8))
        XCTAssertTrue(decoded.waitForResetWithinCache)
        var policy = ProviderFailoverPolicy()
        policy.waitForResetWithinCache = false
        let again = try JSONDecoder().decode(ProviderFailoverPolicy.self, from: JSONEncoder().encode(policy))
        XCTAssertFalse(again.waitForResetWithinCache)
    }

    func testTheEventSaysWhereItWaitsAndWhy() {
        let reset = now.addingTimeInterval(20 * 60)
        let event = AppState.resetHoldEvent(session: "session 1a2b3c4d in ~/x", account: "hexorda", reset: reset, now: now)
        XCTAssertTrue(event.hasPrefix("Holding session 1a2b3c4d in ~/x on hexorda until its reset at "))
        XCTAssertTrue(event.hasSuffix(": sooner than its cache expires, so it keeps its cache."))
        XCTAssertTrue(AppState.sharedResetHoldEvent(count: 3, account: "hexorda", reset: reset, now: now)
            .contains("Failover does not switch the active account until then."))
    }
}
