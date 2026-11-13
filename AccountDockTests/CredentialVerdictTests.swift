import XCTest
@testable import AccountDock

final class CredentialVerdictTests: XCTestCase {
    func testOnlyARefusedGrantMeansTheSavedSignInIsDead() {
        XCTAssertTrue(ClaudeService.refreshRejectsGrant(status: 401, body: Data()))
        XCTAssertTrue(ClaudeService.refreshRejectsGrant(status: 400, body: Data(#"{"error":"invalid_grant","error_description":"Refresh token not found"}"#.utf8)))
        XCTAssertFalse(ClaudeService.refreshRejectsGrant(status: 400, body: Data(#"{"error":"invalid_request"}"#.utf8)))
        XCTAssertFalse(ClaudeService.refreshRejectsGrant(status: 400, body: Data("<html>".utf8)))
        for status in [403, 404, 408, 429, 500, 502, 503] {
            XCTAssertFalse(ClaudeService.refreshRejectsGrant(status: status, body: Data(#"{"error":"invalid_grant"}"#.utf8)), "\(status)")
        }
    }
}
