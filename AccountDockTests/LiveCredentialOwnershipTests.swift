import XCTest
@testable import AccountDock

/// Which copy of an account's credential AccountDock reads, serves and
/// warms: `AppState.readsLiveCredential` decides it for `readClaudeUsage`,
/// `claudeCredential`, `currentAccessToken` and `quotaWindowProbe`.
final class LiveCredentialOwnershipTests: XCTestCase {
    private func account(active: Bool) -> Account {
        Account(email: "a@example.com", displayName: "A", provider: .claudeCode, isActive: active)
    }

    func testOnlyTheActiveOwnerOfTheLiveCredentialReadsIt() {
        let active = account(active: true)
        let idle = account(active: false)
        XCTAssertTrue(AppState.readsLiveCredential(active, liveOwner: active.id))
        XCTAssertTrue(AppState.readsLiveCredential(active, liveOwner: nil), "an unknown owner is the active account")
        XCTAssertFalse(AppState.readsLiveCredential(active, liveOwner: UUID()), "another account owns the live credential")
        XCTAssertFalse(AppState.readsLiveCredential(idle, liveOwner: idle.id))
        XCTAssertFalse(AppState.readsLiveCredential(idle, liveOwner: nil))
    }

    /// The account is active but the live credential is another account's:
    /// the probe, like every other path, uses the account's saved copy.
    func testActiveAccountWhoseLiveCredentialIsAnothersUsesItsSavedCopy() {
        let active = account(active: true)
        var liveReads = 0
        let readsLive = AppState.readsLiveCredential(active, liveOwner: UUID())
        let credential = QuotaWindowProbe.credential(
            readsLive: readsLive,
            live: {
                liveReads += 1
                return "live"
            },
            saved: { "saved" }
        )
        XCTAssertEqual(credential, "saved")
        XCTAssertEqual(liveReads, 0)
        XCTAssertEqual(QuotaWindowProbe.credential(readsLive: AppState.readsLiveCredential(active, liveOwner: active.id),
                                                   live: { "live" }, saved: { "saved" }), "live")
    }
}
