import XCTest
@testable import AccountDock

final class KimiServiceTests: XCTestCase {
    func testOAuthLogicalKeyMapsToFlatCredentialFile() {
        XCTAssertEqual(
            KimiService.credentialStorageName(for: "oauth/kimi-code-env-abc123"),
            "kimi-code-env-abc123"
        )
    }

    func testCredentialStorageNameRejectsNestedOrEmptyPaths() {
        XCTAssertNil(KimiService.credentialStorageName(for: "oauth/"))
        XCTAssertNil(KimiService.credentialStorageName(for: "oauth/nested/name"))
        XCTAssertNil(KimiService.credentialStorageName(for: "../credential"))
    }
}
