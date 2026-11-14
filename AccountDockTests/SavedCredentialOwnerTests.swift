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

    func testAReadingWithACopyNotYetCheckedIsNotRecorded() {
        XCTAssertTrue(AppState.recordsReading(after: .own))
        XCTAssertFalse(AppState.recordsReading(after: .unchecked), "it may be another account's usage")
        XCTAssertFalse(AppState.recordsReading(after: .notOwn))
    }

    func testAccountsSharingTheirResetsTakeNoReadingByResetsAlone() {
        let hstles = UUID(), hexorda = UUID(), personal = UUID()
        let week = Date(timeIntervalSince1970: 1_800_500_000)
        let other = week.addingTimeInterval(86_400)
        let candidates = [AppState.ResetsCandidate(id: hstles, weeklyReset: week, sessionReset: nil),
                          AppState.ResetsCandidate(id: hexorda, weeklyReset: week.addingTimeInterval(30), sessionReset: nil),
                          AppState.ResetsCandidate(id: personal, weeklyReset: other, sessionReset: nil)]
        XCTAssertNil(AppState.matchByResets(weeklyReset: week, sessionReset: nil, candidates: candidates,
                                            active: hstles, activeHasWeekly: true))
        // A session reset contradicting one of them does not make the other
        // the reading's account.
        var contradicted = candidates
        contradicted[1].sessionReset = week.addingTimeInterval(-7200)
        XCTAssertNil(AppState.matchByResets(weeklyReset: week, sessionReset: week.addingTimeInterval(-3600),
                                            candidates: contradicted, active: hstles, activeHasWeekly: true))
        // A session reset matching one of them alone decides.
        var matched = candidates
        matched[0].sessionReset = week.addingTimeInterval(-3600)
        XCTAssertEqual(AppState.matchByResets(weeklyReset: week, sessionReset: week.addingTimeInterval(-3600),
                                              candidates: matched, active: hstles, activeHasWeekly: true)?.account, hstles)
        XCTAssertEqual(AppState.matchByResets(weeklyReset: other, sessionReset: nil, candidates: candidates,
                                              active: hstles, activeHasWeekly: true)?.account, personal)
    }
}

/// Saving the live sign-in as an account's copy while running sessions
/// rewrite the CLI's Keychain slot and identity file.
@MainActor
final class LiveCredentialCaptureTests: XCTestCase {
    let hstles = Account(email: "hstles@mail.example", displayName: "HSTLES", provider: .claudeCode)
    let personal = Account(email: "personal@mail.example", displayName: "Personal", provider: .claudeCode)
    let hexorda = Account(email: "hexorda@mail.example", displayName: "hexorda", provider: .claudeCode)

    /// The slot's successive values, the identity file, the copies, and
    /// what was saved.
    final class Fake {
        var liveTokens: [String]
        var identity: [String: AnyCodable]?
        var held: [UUID: AccountBackup] = [:]
        var saved: [(token: String, id: UUID)] = []
        var reads = 0
        init(liveTokens: [String], identityEmail: String?) {
            self.liveTokens = liveTokens
            identity = identityEmail.map { ["emailAddress": AnyCodable($0)] }
        }
    }

    /// A complete credential whose access token is `access`, expiring at `expires`.
    private func token(_ access: String, expires: Double = 2_000_000_000_000) -> String {
        #"{"claudeAiOauth":{"accessToken":"\#(access)","refreshToken":"r-\#(access)","expiresAt":\#(Int(expires))}}"#
    }

    private func io(_ fake: Fake, owners: [String: String]) -> AppState.CredentialCaptureIO {
        AppState.CredentialCaptureIO(
            liveToken: {
                let value = fake.liveTokens[min(fake.reads, fake.liveTokens.count - 1)]
                fake.reads += 1
                return value
            },
            liveIdentity: { fake.identity },
            profileEmail: { owners[$0] },
            held: { fake.held[$0] },
            save: { token, identity, id in
                fake.saved.append((token, id))
                fake.held[id] = AccountBackup(token: token, oauthAccount: identity)
                return true
            },
            pause: {}
        )
    }

    private let owners = ["tok-hstles": "hstles@mail.example", "tok-hexorda": "hexorda@mail.example",
                          "tok-personal": "personal@mail.example"]

    func testASessionOverwritingTheSlotAfterALoginNeverGivesTheNewAccountAnothersToken() async {
        // The login wrote hexorda's credential; a session on the shared
        // sign-in renewed HSTLES's and wrote it back before the capture.
        let raced = Fake(liveTokens: [token("tok-hstles", expires: 2_100_000_000_000), token("tok-hexorda")],
                         identityEmail: "hexorda@mail.example")
        raced.held[hstles.id] = AccountBackup(token: token("tok-hstles"), oauthAccount: ["emailAddress": AnyCodable(hstles.email)])
        let result = await AppState.captureLiveCredential(for: hexorda, accounts: [hstles, personal], io: io(raced, owners: owners))
        XCTAssertEqual(result.outcome, .saved)
        XCTAssertEqual(raced.held[hexorda.id]?.token, token("tok-hexorda"))
        XCTAssertEqual(result.handedTo, [hstles.id], "HSTLES's newer credential is saved for HSTLES")
        XCTAssertFalse(raced.saved.contains { $0.id == hexorda.id && $0.token.contains("tok-hstles") })

        // A slot that holds HSTLES's credential at every read fails the
        // login instead of saving it for hexorda.
        let held = Fake(liveTokens: [token("tok-hstles")], identityEmail: "hexorda@mail.example")
        let failed = await AppState.captureLiveCredential(for: hexorda, accounts: [hstles, personal], io: io(held, owners: owners))
        XCTAssertEqual(failed.outcome, .anotherAccounts("hstles@mail.example"))
        XCTAssertNil(held.held[hexorda.id])
        XCTAssertEqual(held.reads, AppState.captureAttempts)
        XCTAssertTrue(AppState.captureFailure(failed.outcome, account: hexorda).contains("hstles@mail.example"))
    }

    func testTheBackupBeforeASwitchNeverSavesAnotherAccountsTokenAsTheOutgoingOnes() async {
        // HSTLES is active, but Personal's credential is in the slot and
        // the identity file names HSTLES.
        let fake = Fake(liveTokens: [token("tok-personal")], identityEmail: "hstles@mail.example")
        let result = await AppState.captureLiveCredential(for: hstles, accounts: [hstles, personal], io: io(fake, owners: owners))
        XCTAssertEqual(result.outcome, .anotherAccounts("personal@mail.example"))
        XCTAssertFalse(fake.saved.contains { $0.id == hstles.id })
        XCTAssertTrue(result.handedTo.isEmpty, "Personal holds no copy to replace")
    }

    func testAnOwnCredentialBesideAnotherAccountsIdentityKeepsTheSavedIdentity() async {
        let fake = Fake(liveTokens: [token("tok-hstles")], identityEmail: "personal@mail.example")
        fake.held[hstles.id] = AccountBackup(token: token("tok-hstles", expires: 1_000), oauthAccount: [
            "emailAddress": AnyCodable(hstles.email), "accountUuid": AnyCodable("uuid-hstles")
        ])
        let result = await AppState.captureLiveCredential(for: hstles, accounts: [hstles, personal], io: io(fake, owners: owners))
        XCTAssertEqual(result.outcome, .saved)
        XCTAssertEqual(fake.held[hstles.id]?.oauthAccount["accountUuid"]?.value as? String, "uuid-hstles")

        // Without an identity naming the account the capture saves nothing.
        let bare = Fake(liveTokens: [token("tok-hexorda")], identityEmail: "personal@mail.example")
        let unconfirmed = await AppState.captureLiveCredential(for: hexorda, accounts: [hstles, personal],
                                                               io: io(bare, owners: owners))
        XCTAssertEqual(unconfirmed.outcome, .unconfirmed)
        XCTAssertTrue(bare.saved.isEmpty)
    }

    func testAProviderThatDoesNotAnswerSavesNothing() async {
        let fake = Fake(liveTokens: [token("tok-hexorda")], identityEmail: "hexorda@mail.example")
        var calls = io(fake, owners: owners)
        calls.profileEmail = { _ in throw ClaudeService.UsageError.network("offline") }
        let result = await AppState.captureLiveCredential(for: hexorda, accounts: [hstles], io: calls)
        XCTAssertEqual(result.outcome, .unconfirmed)
        XCTAssertTrue(fake.saved.isEmpty)
        XCTAssertEqual(fake.reads, 1, "re-reading cannot outlast a provider that does not answer")
    }
}
