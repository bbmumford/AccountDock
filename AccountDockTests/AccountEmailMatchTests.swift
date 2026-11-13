import XCTest
@testable import AccountDock

final class AccountEmailMatchTests: XCTestCase {
    private let source = Account(email: "Dev.Person@Example.com", displayName: "Dev")
    private let target = Account(email: "other@example.com", displayName: "Other")

    private func status(loggedIn: Bool = true, email: String?) -> AuthStatus {
        AuthStatus(loggedIn: loggedIn, authMethod: "claude.ai", apiProvider: "firstParty",
                   email: email, orgId: nil, orgName: nil, subscriptionType: "max")
    }

    func testAnAddressMatchesItsAccountWhateverItsCase() {
        XCTAssertTrue(source.matches(email: "dev.person@example.com"))
        XCTAssertTrue(source.matches(email: " DEV.PERSON@EXAMPLE.COM\n"))
        XCTAssertFalse(source.matches(email: "dev.person@example.org"))
        XCTAssertFalse(source.matches(email: nil))
        XCTAssertFalse(source.matches(email: ""))
    }

    func testTheOutgoingAccountIsBackedUpWhenTheLiveIdentityDiffersOnlyInCase() {
        XCTAssertTrue(ClaudeService.backsUpLiveCredential(liveEmail: "dev.person@example.com", from: source, to: target))
        XCTAssertFalse(ClaudeService.backsUpLiveCredential(liveEmail: "someone@example.com", from: source, to: target))
        XCTAssertFalse(ClaudeService.backsUpLiveCredential(liveEmail: "?", from: source, to: target))
        XCTAssertFalse(ClaudeService.backsUpLiveCredential(liveEmail: source.email, from: source, to: source),
                       "restoring the same account never overwrites the backup being restored")
    }

    func testASwitchReportedInAnotherCaseIsConfirmed() {
        XCTAssertNil(ClaudeService.verificationFailure(of: status(email: "OTHER@example.com"), switchingTo: target))
    }

    func testASwitchToAnotherAccountOrNoneIsRefused() {
        guard case .switchWrongAccount(let expected, let actual)? =
                ClaudeService.verificationFailure(of: status(email: "dev.person@example.com"), switchingTo: target) else {
            return XCTFail("another account's address must fail verification")
        }
        XCTAssertEqual(expected, target.email)
        XCTAssertEqual(actual, "dev.person@example.com")

        guard case .switchVerificationFailed? =
                ClaudeService.verificationFailure(of: status(loggedIn: false, email: target.email), switchingTo: target) else {
            return XCTFail("a signed-out status must fail verification")
        }
        guard case .switchWrongAccount? = ClaudeService.verificationFailure(of: status(email: nil), switchingTo: target) else {
            return XCTFail("a status without an address must fail verification")
        }
    }
}
