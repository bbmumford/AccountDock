import XCTest
@testable import AccountDock

final class UpstreamConnectionsTests: XCTestCase {
    private final class Ledger: @unchecked Sendable {
        var opened = 0
        var retired: [Int] = []
    }

    private func pool(_ ledger: Ledger, idleLimit: TimeInterval = 600) -> UpstreamConnections<Int> {
        UpstreamConnections(idleLimit: idleLimit, make: {
            ledger.opened += 1
            return ledger.opened
        }, retire: { ledger.retired.append($0) })
    }

    func testEachClientKeepsItsOwnConnection() {
        let ledger = Ledger()
        let connections = pool(ledger)
        let a = connections.connection(for: "a", attempt: 0)
        let b = connections.connection(for: "b", attempt: 0)
        XCTAssertNotEqual(a.connection, b.connection, "two sessions never share a link")
        XCTAssertEqual(connections.connection(for: "a", attempt: 0).connection, a.connection)
        XCTAssertFalse(a.oneOff)
        XCTAssertEqual(ledger.opened, 2)
    }

    func testEveryRetryOpensAFreshConnectionAndRetiresTheFailedOne() {
        let ledger = Ledger()
        let connections = pool(ledger)
        let first = connections.connection(for: "a", attempt: 0).connection
        let retryA = connections.connection(for: "a", attempt: 1)
        let retryB = connections.connection(for: "b", attempt: 1)
        XCTAssertTrue(retryA.oneOff)
        XCTAssertNotEqual(retryA.connection, first)
        XCTAssertNotEqual(retryA.connection, retryB.connection, "retries after one dropped link never share one")
        XCTAssertEqual(ledger.retired, [first])
        XCTAssertNotEqual(connections.connection(for: "a", attempt: 0).connection, first,
                          "the next request after a failure opens a new link")
    }

    func testRequestsFromNoKnownClientGetAConnectionOfTheirOwn() {
        let ledger = Ledger()
        let connections = pool(ledger)
        let one = connections.connection(for: nil, attempt: 0)
        let two = connections.connection(for: nil, attempt: 0)
        XCTAssertTrue(one.oneOff)
        XCTAssertNotEqual(one.connection, two.connection)
        XCTAssertEqual(connections.keptCount, 0)
    }

    func testIdleConnectionsAreRetired() {
        let ledger = Ledger()
        let connections = pool(ledger, idleLimit: 60)
        let start = Date()
        let a = connections.connection(for: "a", attempt: 0, now: start).connection
        _ = connections.connection(for: "b", attempt: 0, now: start.addingTimeInterval(50))
        connections.sweep(now: start.addingTimeInterval(90))
        XCTAssertEqual(ledger.retired, [a])
        XCTAssertEqual(connections.keptCount, 1)
    }
}
