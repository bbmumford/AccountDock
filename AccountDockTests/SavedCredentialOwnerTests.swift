import XCTest
@testable import AccountDock

final class SavedCredentialOwnerTests: XCTestCase {
    func testASavedSignInIsJudgedByWhoseTheProviderSaysItIs() {
        let backup = Account(email: "backup@mail.example", displayName: "B", provider: .claudeCode)
        let work = Account(email: "work@mail.example", displayName: "W", provider: .claudeCode)
        let codex = Account(email: "work@mail.example", displayName: "W", provider: .codex)
        let all = [backup, work, codex]
        XCTAssertEqual(AppState.savedCopyOwner(profileEmail: "Backup@Mail.example", account: backup, accounts: all), .own)
        XCTAssertEqual(AppState.savedCopyOwner(profileEmail: "work@mail.example", account: backup, accounts: all), .other(work.id),
                       "another account of the same provider, never one of another provider")
        XCTAssertEqual(AppState.savedCopyOwner(profileEmail: "nobody@mail.example", account: backup, accounts: all), .stranger)
    }
}
