import XCTest
@testable import AccountDock

/// The sessions on the shared sign-in, counted as one group on the account
/// carrying it now and on the account failover would make active next.
final class SharedGroupTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let a = UUID(), b = UUID(), c = UUID()

    /// Accounts at one window percent per million tokens, so a rate in
    /// millions of tokens per hour is percent per hour.
    func account(_ id: UUID, used: Double, resetIn hours: Double?, burn: Double = 0) -> SessionPacer.Account {
        SessionPacer.Account(id: id, utilization: used, resetsAt: hours.map { now.addingTimeInterval($0 * 3600) },
                             burnPerHour: burn, baseWeight: 1, percentPerMillion: 1)
    }

    func group(on account: UUID, burn: Double, next: UUID? = nil, inHours hours: Double? = nil,
               sessions: Int = 4) -> SessionPacer.SharedGroup {
        SessionPacer.SharedGroup(account: account, tokensPerHour: burn * 1_000_000, contextTokens: 100_000, models: [],
                                 nextAccount: next, switchAt: hours.map { now.addingTimeInterval($0 * 3600) },
                                 sessionCount: sessions)
    }

    private func running(_ id: String, on account: UUID, burn: Double) -> SessionPacer.RebalanceSession {
        SessionPacer.RebalanceSession(id: id, account: account, tokensPerHour: burn * 1_000_000, contextTokens: 100_000,
                                      model: nil, movable: true)
    }

    // MARK: - Pacing

    func testTheAccountTheGroupSwitchesToTakesNoNewSessionThatWouldLeaveItShort() {
        let pacer = SessionPacer()
        // The active account's readings include the group's 20%/h.
        let accounts = [account(a, used: 20, resetIn: 4, burn: 20), account(b, used: 50, resetIn: 4),
                        account(c, used: 50, resetIn: 4)]
        let alone = pacer.plan(accounts: accounts, sessions: [], now: now)
        XCTAssertGreaterThan(alone.weights[b] ?? 0, 0, "without the group, the next account has room")

        // The group arrives on b in an hour and would spend its 49% left
        // before b's reset; c, with the same room, keeps taking sessions.
        let plan = pacer.plan(accounts: accounts, sessions: [], now: now,
                              sharedGroup: group(on: a, burn: 20, next: b, inHours: 1))
        XCTAssertEqual(plan.weights[b] ?? -1, 0, accuracy: 0.0001)
        XCTAssertGreaterThan(plan.weights[c] ?? 0, 0)
        XCTAssertGreaterThan(plan.weights[a] ?? 0, 0, "the active account carries the group only until the switch")
    }

    func testWithFailoverLockedTheGroupStaysOnTheActiveAccountAndTheNextIsFree() {
        let pacer = SessionPacer()
        let accounts = [account(a, used: 20, resetIn: 4, burn: 20), account(b, used: 50, resetIn: 4)]
        // A locked active account, or failover off, projects no switch.
        let plan = pacer.plan(accounts: accounts, sessions: [], now: now, sharedGroup: group(on: a, burn: 20))
        XCTAssertGreaterThan(plan.weights[b] ?? 0, 0)
        let shares = pacer.shares(group(on: a, burn: 20), accounts: accounts, now: now)
        XCTAssertEqual(Set(shares.keys), [a])
        XCTAssertNil(shares[a]?.until, "the group stays on the active account for the whole horizon")
        // 20%/h over the 4 hours to a's reset spends more than its 79%.
        let outlook = pacer.outlook(accounts[0], burn: 0, now: now, shared: shares[a])
        XCTAssertEqual(outlook.limitAt?.timeIntervalSince(now) ?? 0, 79.0 / 20 * 3600, accuracy: 1)

        var locked = ProviderFailoverPolicy.defaults(for: .claudeCode)
        locked.enabled = true
        XCTAssertTrue(AppState.failoverMovesActiveAccount(locked, monitored: true))
        locked.activeAccountLocked = true
        XCTAssertFalse(AppState.failoverMovesActiveAccount(locked, monitored: true))
        var off = ProviderFailoverPolicy.defaults(for: .claudeCode)
        off.enabled = false
        off.intelligentBalancingEnabled = false
        XCTAssertFalse(AppState.failoverMovesActiveAccount(off, monitored: true))
    }

    func testTheGroupsShareSplitsAtTheSwitch() {
        let pacer = SessionPacer()
        let accounts = [account(a, used: 0, resetIn: 4), account(b, used: 0, resetIn: 4)]
        let shares = pacer.shares(group(on: a, burn: 10, next: b, inHours: 1), accounts: accounts, now: now)
        let end = now.addingTimeInterval(4 * 3600)
        XCTAssertEqual(shares[a]?.percent(from: now, until: end) ?? 0, 10, accuracy: 0.001)
        // Three hours on b, and the cache rewrite of its 100k context.
        XCTAssertEqual(shares[b]?.percent(from: now, until: end) ?? 0, 30 + 0.115, accuracy: 0.001)
        // b reaches 99% at 1 h + (99 − 0.115) / 10 h, past its reset.
        XCTAssertNil(pacer.outlook(accounts[1], burn: 0, now: now, shared: shares[b]).limitAt)
        var tight = accounts[1]
        tight.utilization = 80
        let limitAt = pacer.outlook(tight, burn: 0, now: now, shared: shares[b]).limitAt
        XCTAssertEqual(limitAt?.timeIntervalSince(now) ?? 0, (1 + (19 - 0.115) / 10) * 3600, accuracy: 1)
    }

    func testRebalanceMovesNoSlotSessionOntoTheNextActiveAccountWhenTheGroupNeedsItsRoom() {
        let busy = account(a, used: 50, resetIn: 4)
        let next = account(b, used: 10, resetIn: 4)
        let sessions = [running("s1", on: a, burn: 20), running("s2", on: a, burn: 20)]
        let alone = SessionPacer().rebalance(accounts: [busy, next], sessions: sessions, destinations: [a, b], now: now)
        XCTAssertEqual(alone.moves.values.first, b, "without the group a session moves to b")

        // The group, now on an account outside these, moves to b in half an
        // hour at 100%/h: b would run out sooner than a does now.
        let plan = SessionPacer().rebalance(accounts: [busy, next], sessions: sessions, destinations: [a, b], now: now,
                                            sharedGroup: group(on: c, burn: 100, next: b, inHours: 0.5))
        XCTAssertTrue(plan.moves.isEmpty)
    }

    func testThePacerNeverMovesTheGroupsSessions() {
        let members = AppState.sharedSessions(
            [SessionPacer.Session(id: "slot", account: a, tokensPerHour: 1, contextTokens: 0, lastSeen: now, cacheLifetime: nil),
             SessionPacer.Session(id: "shared", account: a, tokensPerHour: 1, contextTokens: 0, lastSeen: now, cacheLifetime: nil),
             SessionPacer.Session(id: "ide", account: b, tokensPerHour: 1, contextTokens: 0, lastSeen: now, cacheLifetime: nil),
             SessionPacer.Session(id: "ended", account: a, tokensPerHour: 1, contextTokens: 0, lastSeen: now, cacheLifetime: nil),
             SessionPacer.Session(id: "other", account: c, tokensPerHour: 1, contextTokens: 0, lastSeen: now, cacheLifetime: nil)],
            own: [a, b], slotted: ["slot"], live: ["slot", "shared"], recorded: ["slot", "shared", "ended"])
        XCTAssertEqual(members, ["shared", "ide"], "outside a slot, running or leaving no record, on this provider's accounts")
    }

    // MARK: - Failover

    private func planner(session: Double = 90) -> FailoverPlanner {
        var policy = ProviderFailoverPolicy.defaults(for: .claudeCode)
        policy.enabled = true
        policy.sessionThreshold = session
        policy.weeklyThreshold = 90
        policy.intelligentBalancingEnabled = false
        policy.balancingMinimumDwellMinutes = 30
        policy.waitForImminentReset = false
        return FailoverPlanner(settings: .init(policy: policy, provider: .claudeCode))
    }

    private func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    private func state(_ id: UUID, session: Double, active: Bool = false, burn: Double = 0, staying: Double = 0,
                       consumedElsewhere: Bool = false) -> QuotaAccountState {
        var state = QuotaAccountState(
            id: id,
            usage: UsageAPIResponse(
                fiveHour: UsageWindow(utilization: session, resetsAt: iso(now.addingTimeInterval(4 * 3600))),
                sevenDay: UsageWindow(utilization: 20, resetsAt: iso(now.addingTimeInterval(4 * 86_400))),
                sevenDayOauthApps: nil, sevenDayOpus: nil, sevenDaySonnet: nil,
                sevenDayCowork: nil, iguanaNecktie: nil, extraUsage: nil
            ),
            observedAt: now.addingTimeInterval(-60),
            sessionBurnPerHour: burn,
            weeklyBurnPerHour: burn / 8,
            isActive: active,
            mayBeConsumedElsewhere: consumedElsewhere
        )
        state.stayingSessionBurnPerHour = staying
        return state
    }

    func testTheNextActiveAccountIsNotOneItsSlotSessionsAreAboutToExhaust() {
        let p = planner()
        let current = state(a, session: 92, active: true, burn: 20)
        let roomy = state(c, session: 60)
        XCTAssertEqual(p.plan(current: current, ladder: [current, state(b, session: 60), roomy], lastSwitch: nil, now: now),
                       .switchTo(b, .threshold), "the first in the order, while nothing else runs on it")
        // b's own slot sessions spend 70%/h; with the 20%/h that moves, it
        // could not stay below its threshold for the dwell.
        let busy = state(b, session: 60, staying: 70, consumedElsewhere: true)
        XCTAssertEqual(p.plan(current: current, ladder: [current, busy, roomy], lastSwitch: nil, now: now),
                       .switchTo(c, .threshold))
        XCTAssertEqual(p.expectedBurn(movingFrom: current, to: busy).session, 90, accuracy: 0.001)
        // The active account's own slot sessions stay behind.
        var shared = current
        shared.stayingSessionBurnPerHour = 15
        XCTAssertEqual(p.expectedBurn(movingFrom: shared, to: roomy).session, 5, accuracy: 0.001)
    }

    func testTheNextSwitchIsTheAccountPlanWouldChooseWhenTheActiveOneCrossesItsThreshold() throws {
        let p = planner()
        // 50% at 20%/h crosses 90% in two hours.
        let current = state(a, session: 50, active: true, burn: 20)
        let next = try XCTUnwrap(p.nextSwitch(current: current, ladder: [current, state(b, session: 30), state(c, session: 30)],
                                              now: now))
        XCTAssertEqual(next.account, b)
        XCTAssertEqual(next.at.timeIntervalSince(now), 2 * 3600, accuracy: 120)

        // b's slot sessions will have taken it to 90% by then.
        let filling = state(b, session: 30, burn: 30, staying: 30, consumedElsewhere: true)
        let avoided = try XCTUnwrap(p.nextSwitch(current: current, ladder: [current, filling, state(c, session: 30)], now: now))
        XCTAssertEqual(avoided.account, c)

        XCTAssertNil(p.nextSwitch(current: state(a, session: 50, active: true), ladder: [state(b, session: 30)], now: now),
                     "an account not being used is not projected to switch")
    }
}
