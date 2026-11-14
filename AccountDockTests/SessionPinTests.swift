import XCTest
@testable import AccountDock

final class SessionPinTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let a = UUID(), b = UUID(), c = UUID()

    // MARK: - Nothing automatic moves a pinned session

    func testFailoverKeepsAPinnedSessionOnItsAccountEvenAtTheLimit() {
        func choice(pinned: UUID?, requested: UUID? = nil, balance: UUID? = nil,
                    spent: Set<UUID> = [], modelSpent: Bool = false) -> AppState.SlotChoice {
            AppState.slotChoice(current: a, pinned: pinned, requested: requested, balance: balance,
                                cannotServe: { spent.contains($0) }, modelSpent: modelSpent, byWeight: [b, c], fallback: c)
        }
        // Unpinned: an account that cannot serve gives the slot up, a
        // request or a balancing move takes it elsewhere.
        XCTAssertEqual(choice(pinned: nil, spent: [a]).target, c)
        XCTAssertEqual(choice(pinned: nil, spent: [a], modelSpent: true).target, b)
        XCTAssertEqual(choice(pinned: nil, requested: b), AppState.SlotChoice(target: b, requested: true))
        XCTAssertEqual(choice(pinned: nil, balance: b), AppState.SlotChoice(target: b, balanced: true))
        // Pinned: none of these moves it.
        XCTAssertEqual(choice(pinned: a, spent: [a]), AppState.SlotChoice(target: a, keptPinned: true))
        XCTAssertEqual(choice(pinned: a, spent: [a], modelSpent: true).target, a)
        XCTAssertEqual(choice(pinned: a, requested: b), AppState.SlotChoice(target: a))
        XCTAssertEqual(choice(pinned: a, balance: b), AppState.SlotChoice(target: a))
    }

    private func account(_ id: UUID, used: Double, resetIn hours: Double) -> SessionPacer.Account {
        SessionPacer.Account(id: id, utilization: used, resetsAt: now.addingTimeInterval(hours * 3600),
                             burnPerHour: 0, baseWeight: 1, percentPerMillion: 1)
    }

    private func session(_ id: String, on account: UUID, burn: Double) -> SessionPacer.Session {
        SessionPacer.Session(id: id, account: account, tokensPerHour: burn * 1_000_000, contextTokens: 100_000,
                             lastSeen: now.addingTimeInterval(-60), cacheLifetime: 3600)
    }

    func testPacingMovesNoPinnedSessionButCountsItsLoad() {
        let pacer = SessionPacer()
        // a reaches its limit in under an hour and would wait there past
        // the sessions' cache: it gives sessions up.
        let accounts = [account(a, used: 60, resetIn: 4), account(b, used: 0, resetIn: 2)]
        let sessions = [session("pinned", on: a, burn: 30), session("free", on: a, burn: 30)]
        let unpinned = pacer.plan(accounts: accounts, sessions: sessions, now: now)
        XCTAssertNotNil(unpinned.moves["pinned"] ?? unpinned.moves["free"])
        let plan = pacer.plan(accounts: accounts, sessions: sessions, now: now, fixed: ["pinned"])
        XCTAssertNil(plan.moves["pinned"])
        XCTAssertEqual(plan.moves["free"], b)

        // Alone and pinned, its load still makes a shed and take no new
        // session, while b, with the same room and nothing on it, takes them.
        let alone = pacer.plan(accounts: accounts, sessions: [session("pinned", on: a, burn: 60)], now: now, fixed: ["pinned"])
        XCTAssertTrue(alone.moves.isEmpty)
        XCTAssertNotNil(alone.shedding[a])
        XCTAssertEqual(alone.weights[a] ?? -1, 0, accuracy: 0.0001)
        XCTAssertGreaterThan(alone.weights[b] ?? 0, 0)
    }

    func testRebalancingLeavesAPinnedSessionWhereItIs() {
        // A pinned session reaches `rebalance` as one that cannot move, like
        // one mid-turn, permanently; its rate still counts on its account.
        let busy = account(a, used: 50, resetIn: 4)
        let idle = account(b, used: 10, resetIn: 4)
        let pinned = SessionPacer.RebalanceSession(id: "pinned", account: a, tokensPerHour: 20_000_000,
                                                   contextTokens: 100_000, model: nil, movable: false)
        let free = SessionPacer.RebalanceSession(id: "free", account: a, tokensPerHour: 20_000_000,
                                                 contextTokens: 100_000, model: nil, movable: true)
        let plan = SessionPacer().rebalance(accounts: [busy, idle], sessions: [pinned, free], destinations: [a, b], now: now)
        XCTAssertEqual(plan.moves, ["free": b])
        let onlyPinned = SessionPacer().rebalance(accounts: [busy, idle], sessions: [pinned], destinations: [a, b], now: now)
        XCTAssertTrue(onlyPinned.moves.isEmpty)
        XCTAssertNotNil(onlyPinned.earliestRunOutBefore, "its load still runs a out before its reset")
    }

    func testTheModelFallbackSkipsAPinnedSession() {
        var pins = SessionPins()
        _ = pins.pin("pinned", slotAccount: a, provider: .claudeCode, at: now)
        let pending = ["pinned": "claude-sonnet-5-5", "free": "claude-sonnet-5-5"]
        XCTAssertEqual(pins.applicableFallbacks(pending), ["free": "claude-sonnet-5-5"])
    }

    // MARK: - Setting a pin

    func testASessionOpenedFromATileIsPinnedUnlessOptionClickedOrKeepHereIsOff() {
        XCTAssertTrue(SessionPins.pinsOpenedSession(keepHere: true, optionHeld: false))
        XCTAssertFalse(SessionPins.pinsOpenedSession(keepHere: true, optionHeld: true))
        XCTAssertFalse(SessionPins.pinsOpenedSession(keepHere: false, optionHeld: false))

        // The slot made for it is pinned first; the session reading it
        // takes the pin once it starts.
        var pins = SessionPins()
        pins.pinSlot("/slots/session/X", account: b, provider: .claudeCode, at: now)
        XCTAssertFalse(pins.isPinned("s1"))
        XCTAssertEqual(pins.adopt(sessionsBySlot: ["/slots/session/Y": "s2"]), [])
        XCTAssertEqual(pins.adopt(sessionsBySlot: ["/slots/session/X": "s1"]), ["s1"])
        XCTAssertEqual(pins.account(of: "s1"), b)
        XCTAssertTrue(pins.slots.isEmpty)
        XCTAssertFalse(pins.isPinned("s2"), "an option-clicked session's slot carries no pin")
    }

    func testASessionOnTheSharedSignInCannotBePinned() {
        var pins = SessionPins()
        XCTAssertEqual(pins.pin("shared", slotAccount: nil, provider: .claudeCode, at: now), .notInSlot)
        XCTAssertFalse(pins.isPinned("shared"))
        XCTAssertFalse(AppState.pinRequestOutcome(.notInSlot) { _ in "A" }.ok)
    }

    func testPinAndUnpinThroughTheRequestsInterface() throws {
        let pin = try JSONDecoder().decode(AppState.ExternalRequest.self,
                                           from: Data(#"{"action":"pin","session":"s1"}"#.utf8))
        XCTAssertEqual(pin.action, "pin")
        XCTAssertEqual(pin.session, "s1")
        var pins = SessionPins()
        let name: (UUID) -> String = { $0 == self.a ? "Work" : "?" }
        let pinned = pins.pin("s1", slotAccount: a, provider: .claudeCode, at: now)
        XCTAssertEqual(pinned, .pinned(a))
        XCTAssertEqual(AppState.pinRequestOutcome(pinned, name: name).ok, true)
        XCTAssertTrue(AppState.pinRequestOutcome(pinned, name: name).detail.contains("Work"))
        XCTAssertEqual(pins.pin("s1", slotAccount: a, provider: .claudeCode, at: now), .alreadyPinned(a))
        let unpinned = pins.unpin("s1")
        XCTAssertEqual(unpinned, .unpinned(a))
        XCTAssertTrue(AppState.pinRequestOutcome(unpinned, name: name).ok)
        XCTAssertFalse(pins.isPinned("s1"))
        XCTAssertFalse(AppState.pinRequestOutcome(pins.unpin("s1"), name: name).ok)
    }

    func testAPinSurvivesAResumeOfTheSameSessionAndGoesWithItsRecord() throws {
        let suite = "SessionPinTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var pins = SessionPins()
        _ = pins.pin("s1", slotAccount: a, provider: .claudeCode, at: now)
        pins.save(defaults)

        // After a restart and `--resume s1`, the same ID is pinned, and its
        // new slot, filled for another account, goes back to the pinned one.
        var loaded = SessionPins.load(defaults)
        XCTAssertEqual(loaded.account(of: "s1"), a)
        let resumed = AppState.slotChoice(current: b, pinned: loaded.account(of: "s1"), requested: nil, balance: nil,
                                          cannotServe: { _ in false }, modelSpent: false, byWeight: [b], fallback: b)
        XCTAssertEqual(resumed.target, a)

        // While its record stays the pin stays; once the record is gone
        // (archived), the pin goes too, after a grace for a new record.
        XCTAssertEqual(loaded.prune(.claudeCode, recorded: ["s1"], now: now.addingTimeInterval(3600)), [])
        XCTAssertEqual(loaded.prune(.claudeCode, recorded: [], now: now.addingTimeInterval(60)), [], "within the grace")
        XCTAssertEqual(loaded.prune(.claudeCode, recorded: [], now: now.addingTimeInterval(3600)), ["s1"])
        XCTAssertFalse(loaded.isPinned("s1"))
    }
}
