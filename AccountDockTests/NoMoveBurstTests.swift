import XCTest
@testable import AccountDock

/// The sessions an account that can no longer serve gives up go through the
/// cycle's ledger one at a time, and an account itself at its limit is never
/// where they go. At 12:21:45 am cybrio refused its thirteen sessions and
/// all thirteen moved to fluxon in one second, though fluxon was at 100%
/// until 12:49 am.
final class NoMoveBurstTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let fluxon = UUID(), hexorda = UUID(), cybrio = UUID()

    func minutes(_ value: Double) -> Date { now.addingTimeInterval(value * 60) }

    func account(_ id: UUID, used: Double, resetIn: Double, ratio: Double,
                 availability: CapacityOutlook.Availability) -> CapacityOutlook.Account {
        CapacityOutlook.Account(
            pacer: SessionPacer.Account(id: id, utilization: used, resetsAt: minutes(resetIn), burnPerHour: 0, baseWeight: 1,
                                        weeklyRemaining: 400, weeklyResetsAt: minutes(4 * 24 * 60), percentPerMillion: ratio),
            name: "", availability: availability)
    }

    /// fluxon at its limit until 12:49 am; hexorda's window fresh after
    /// its reset, at 4.25% per million weighted tokens.
    var accounts: [CapacityOutlook.Account] {
        [account(fluxon, used: 100, resetIn: 27, ratio: 2.37, availability: .atLimit),
         account(hexorda, used: 0, resetIn: 300, ratio: 4.25, availability: .serves)]
    }

    /// The thirteen sessions cybrio refused, in millions of weighted tokens
    /// an hour.
    var refused: [SessionPacer.RebalanceSession] {
        [35, 32, 30, 28, 26, 22, 20, 18, 17, 15, 15, 10, 10].enumerated().map { index, rate in
            SessionPacer.RebalanceSession(id: "session-\(index)", account: cybrio, tokensPerHour: rate * 1_000_000,
                                          contextTokens: 100_000, model: nil, movable: true, cacheLifetime: 3600,
                                          lastSeen: minutes(-1))
        }
    }

    /// Each session's fallback in turn, the ledger charged with every move.
    func fallBack(candidates: [UUID], usable: (UUID) -> Bool) -> [String: UUID] {
        var ledger = LaneLedger(startedAt: now)
        var moved: [String: UUID] = [:]
        for session in refused {
            guard let fallen = AppState.fallbackLane(session, from: cybrio, candidates: candidates, usable: usable,
                                                     running: refused, accounts: accounts, ledger: ledger, now: now,
                                                     pacer: SessionPacer()) else { continue }
            ledger.charge(fallen.charge)
            moved[session.id] = fallen.lane
        }
        return moved
    }

    func testAnAccountAtItsLimitTakesNoneOfThem() {
        // Even taken to have room, fluxon carries nothing before 12:49 am.
        XCTAssertEqual(fallBack(candidates: [fluxon], usable: { _ in true }), [:])
    }

    func testAnAccountWithRoomTakesOnlyWhatItCarries() {
        let moved = fallBack(candidates: [fluxon, hexorda], usable: { _ in true })
        // 21M tokens an hour fit hexorda's fresh window with its margin: the
        // first session of 20M an hour and its arrival; the twelve others
        // stay where they are.
        XCTAssertEqual(moved, ["session-6": hexorda])
        XCTAssertEqual(fallBack(candidates: [fluxon, hexorda], usable: { $0 != self.hexorda }), [:],
                       "an account without a fresh reading takes none")
    }

    func testTheSlotPathMovesNoSessionOntoAnAccountAtItsLimit() {
        let cannotServe: (UUID) -> Bool = { $0 == self.cybrio || $0 == self.fluxon }
        let stays = AppState.slotChoice(current: cybrio, pinned: nil, requested: nil, balance: nil, cannotServe: cannotServe,
                                        modelSpent: false, byWeight: [fluxon], placed: nil, fallback: fluxon)
        XCTAssertNil(stays.target, "the slot keeps cybrio rather than moving to fluxon")
        let balanced = AppState.slotChoice(current: hexorda, pinned: nil, requested: nil, balance: fluxon,
                                           cannotServe: cannotServe, modelSpent: false, byWeight: [hexorda],
                                           placed: nil, fallback: hexorda)
        XCTAssertEqual(balanced.target, hexorda)
        XCTAssertFalse(balanced.balanced, "no balancing move goes to an account at its limit")
        let placed = AppState.slotChoice(current: cybrio, pinned: nil, requested: nil, balance: nil,
                                         cannotServe: cannotServe, modelSpent: false, byWeight: [hexorda],
                                         placed: fluxon, fallback: hexorda)
        XCTAssertEqual(placed.target, hexorda)
        // The user's own move still goes where it is asked to.
        let asked = AppState.slotChoice(current: cybrio, pinned: nil, requested: fluxon, balance: nil,
                                        cannotServe: cannotServe, modelSpent: false, byWeight: [hexorda],
                                        placed: nil, fallback: hexorda)
        XCTAssertEqual(asked.target, fluxon)
        XCTAssertTrue(asked.requested)
    }
}
