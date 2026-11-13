import XCTest
@testable import AccountDock

@MainActor
final class CredentialOperationGateTests: XCTestCase {
    func testASwitchNestedInARefreshKeepsTheGateBusyUntilTheRefreshEnds() async {
        let gate = CredentialOperationGate()
        var changes: [Bool] = []
        gate.onBusyChange = { changes.append($0) }
        var busyAfterSwitch: Bool?
        let result = await gate.run { () async -> Int in
            // The switch `refresh` starts through `evaluateFailover`.
            let inner = await gate.run { () async -> Int in
                await Task.yield()
                return 1
            }
            busyAfterSwitch = gate.isBusy
            return inner + 1
        }
        XCTAssertEqual(result, 2)
        XCTAssertEqual(busyAfterSwitch, true)
        XCTAssertFalse(gate.isBusy)
        XCTAssertEqual(changes, [true, false], "the busy state changes once for the outermost run only")
    }

    func testAQuotaCycleIsSkippedWhileCredentialWorkRuns() async {
        let gate = CredentialOperationGate()
        func cycleMayStart() -> Bool {
            AppState.quotaCycleMayStart(monitoring: false, credentialWorkBusy: gate.isBusy, loggingIn: false)
        }
        XCTAssertTrue(cycleMayStart())
        var during: [Bool] = []
        await gate.run {
            during.append(cycleMayStart())
            await gate.run { during.append(cycleMayStart()) }
            during.append(cycleMayStart())
        }
        XCTAssertEqual(during, [false, false, false])
        XCTAssertTrue(cycleMayStart())
        XCTAssertFalse(AppState.quotaCycleMayStart(monitoring: true, credentialWorkBusy: false, loggingIn: false))
        XCTAssertFalse(AppState.quotaCycleMayStart(monitoring: false, credentialWorkBusy: false, loggingIn: true))
    }
}
