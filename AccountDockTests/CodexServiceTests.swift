import XCTest
@testable import AccountDock

final class CodexServiceTests: XCTestCase {
    func testIdentityReadsEmailNameAndAccountIDFromJWT() throws {
        let payload: [String: Any] = [
            "email": "dev@example.com",
            "name": "Example Developer",
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "account-123",
                "chatgpt_plan_type": "plus"
            ]
        ]
        let auth = try self.authData(payload: payload)

        let identity = try CodexService.identity(fromAuthData: auth)

        XCTAssertEqual(identity.email, "dev@example.com")
        XCTAssertEqual(identity.displayName, "Example Developer")
        XCTAssertEqual(identity.accountID, "account-123")
        XCTAssertEqual(identity.planType, "plus")
    }

    func testIdentityFallsBackToAccountIDSuffix() throws {
        let payload: [String: Any] = [
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "account-abcdefgh"
            ]
        ]
        let auth = try self.authData(payload: payload)

        let identity = try CodexService.identity(fromAuthData: auth)

        XCTAssertEqual(identity.email, "Codex abcdefgh")
        XCTAssertEqual(identity.displayName, "Codex abcdefgh")
    }

    func testIdentityRejectsCredentialsWithoutIdentity() throws {
        let auth = try self.authData(payload: ["sub": "anonymous"])
        XCTAssertThrowsError(try CodexService.identity(fromAuthData: auth))
    }

    private func authData(payload: [String: Any]) throws -> Data {
        let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let payloadPart = payloadData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let token = "header.\(payloadPart).signature"
        return try JSONSerialization.data(withJSONObject: [
            "tokens": [
                "id_token": token
            ]
        ])
    }
}
