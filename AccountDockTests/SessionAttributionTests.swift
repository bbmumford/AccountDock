import XCTest
@testable import AccountDock

@MainActor
final class SessionAttributionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let session = "session-1"
    private let process: Int32 = 4242
    private let slotAccount = UUID()
    private let routerAccount = UUID()
    private let servedAccount = UUID()
    private let recordedAccount = UUID()
    private let ownerAccount = UUID()
    private let activeAccount = UUID()

    private func observation(_ account: UUID, ago: TimeInterval) -> SessionAttribution.Observation {
        SessionAttribution.Observation(account: account, at: now.addingTimeInterval(-ago))
    }

    /// Every source knows the session; `drop` removes the strongest ones.
    private func attribution(dropping drop: Int) -> SessionAttribution {
        var attribution = SessionAttribution(now: now)
        if drop < 1 { attribution.slotAccounts = [process: slotAccount] }
        if drop < 2 { attribution.routerSeen = [session: observation(routerAccount, ago: 60)] }
        if drop < 3 { attribution.lastServed = [session: observation(servedAccount, ago: 120)] }
        if drop < 4 { attribution.recordedRequests = [session: observation(recordedAccount, ago: 180)] }
        let owner = ownerAccount
        if drop < 5 { attribution.liveCredentialOwner = { owner } }
        if drop < 6 { attribution.activeAccount = activeAccount }
        return attribution
    }

    func testPrecedenceTable() {
        let expected: [(UUID?, SessionAttribution.Source?)] = [
            (slotAccount, .slot),
            (routerAccount, .router),
            (servedAccount, .lastServed),
            (recordedAccount, .recordedRequest),
            (ownerAccount, .liveCredential),
            (activeAccount, .activeAccount),
            (nil, nil),
        ]
        for (drop, (account, source)) in expected.enumerated() {
            let decision = attribution(dropping: drop).decide(session: session, process: process)
            XCTAssertEqual(decision?.account, account, "dropping \(drop) sources")
            XCTAssertEqual(decision?.source, source, "dropping \(drop) sources")
        }
    }

    func testRouterCountsOnlyWithinItsWindow() {
        var attribution = attribution(dropping: 4)
        attribution.routerSeen = [session: observation(routerAccount, ago: SessionAttribution.routerWindow - 1)]
        XCTAssertEqual(attribution.decide(session: session, process: nil)?.source, .router)
        attribution.routerSeen = [session: observation(routerAccount, ago: SessionAttribution.routerWindow + 1)]
        XCTAssertEqual(attribution.decide(session: session, process: nil)?.source, .liveCredential)
    }

    func testObservationsExpireAfterTheirLifetime() {
        var attribution = attribution(dropping: 2)
        attribution.lastServed = [session: observation(servedAccount, ago: SessionAttribution.servedLifetime + 1)]
        attribution.recordedRequests = [session: observation(recordedAccount, ago: SessionAttribution.servedLifetime + 1)]
        XCTAssertEqual(attribution.decide(session: session, process: nil)?.source, .liveCredential)
    }

    func testTheLiveCredentialIsReadOnlyWhenNoStrongerSourceDecides() {
        var reads = 0
        var attribution = SessionAttribution(now: now)
        attribution.slotAccounts = [process: slotAccount]
        attribution.liveCredentialOwner = {
            reads += 1
            return nil
        }
        XCTAssertEqual(attribution.decide(session: session, process: process)?.source, .slot)
        XCTAssertEqual(reads, 0)
    }

    /// A session on the shared sign-in whose status line named the account
    /// active before a switch stays on it until its sessions are signalled
    /// after that reading, then follows the active account.
    func testSharedSignInSessionStaysOnTheEarlierAccountUntilSignalled() {
        let earlier = UUID()
        let active = UUID()
        let observedAt = now.addingTimeInterval(-300)
        var attribution = SessionAttribution(now: now)
        attribution.lastServed = [session: SessionAttribution.Observation(account: earlier, at: observedAt)]
        attribution.activeAccount = active

        XCTAssertEqual(attribution.decide(session: session, process: process)?.account, earlier)

        attribution.signalledAt = observedAt.addingTimeInterval(-60)
        XCTAssertEqual(attribution.decide(session: session, process: process)?.account, earlier,
                       "a signal before the reading does not move the session")

        attribution.signalledAt = observedAt.addingTimeInterval(60)
        let decision = attribution.decide(session: session, process: process)
        XCTAssertEqual(decision?.account, active)
        XCTAssertEqual(decision?.source, .activeAccount)
    }

    func testEvidenceCarriesWhenItWasSeen() {
        let decision = attribution(dropping: 2).decide(session: session, process: nil)
        XCTAssertEqual(decision?.observedAt, now.addingTimeInterval(-120))
        XCTAssertNil(attribution(dropping: 4).decide(session: session, process: nil)?.observedAt)
    }
}
