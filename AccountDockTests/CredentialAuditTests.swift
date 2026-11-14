import CryptoKit
import XCTest
@testable import AccountDock

/// A CLI that keeps a slot's credential in a file inside the slot, named by
/// no provider, so `SessionSlots` names the provider by the slot's account.
private struct AuditFakeIsolation: ProviderSessionIsolation {
    let executable = "auditfakecli"
    let directoryVariable = "AUDITFAKE_HOME"
    let passThroughVariables: [String] = []
    let passThroughCommands: [String] = []
    let background: BackgroundSessionSupport? = nil
    let installDirectories: [String] = []
    let preferredExecutable: String? = nil
    let resumeArgumentScript = ""
    let keepRunningKey = "n"

    func resumeCommand(sessionID: String) -> String { "auditfakecli \(sessionID)" }
    func screenReportsRunningWork(_ screen: String) -> Bool { false }
    func screenAsksAboutRunningWork(_ screen: String) -> Bool { false }
    func slotCredential(from credential: String) -> SlotCredential? { SlotCredential(contents: credential) }

    @MainActor
    func currentSlotCredential(for account: Account, minimumLifetime: TimeInterval,
                               from state: AppState) async -> SlotCredential? { nil }

    func prepareSlot(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func writeCredential(_ credential: SlotCredential, to directory: URL) -> Bool {
        (try? Data(credential.contents.utf8).write(to: directory.appendingPathComponent("credential.json"), options: .atomic)) != nil
    }

    func readCredential(in directory: URL) -> SlotCredential? {
        (try? String(contentsOf: directory.appendingPathComponent("credential.json"), encoding: .utf8))
            .map(SlotCredential.init(contents:))
    }

    func removeSlot(_ directory: URL) {}
    func signalReread(_ directory: URL) {}
}

/// The credential audit trail: an entry for every kind of action, no
/// credential text in the file, owners learned and mismatches reported,
/// rotation, serving records and the query.
final class CredentialAuditTests: XCTestCase {
    private var root: URL!
    private var audit: CredentialAudit!

    private let alpha = UUID()
    private let beta = UUID()
    private let kimiAccount = UUID()
    private let codexAccount = UUID()
    private var kimiLocation: URL { root.appendingPathComponent("kimi-managed/\(kimiAccount.uuidString)/credentials.json") }
    private var codexHome: URL { root.appendingPathComponent("codex-managed/home", isDirectory: true) }

    /// Fake secrets, each distinctive enough that any part of it found in
    /// the trail is a leak.
    private let claudeAccess = "sk-ant-oat01-FAKEACCESSalphaQ7mZ2pL9xK4vN8rT1wY6sD3fG5hJ0kAAA"
    private let claudeRefresh = "sk-ant-ort01-FAKEREFRESHalphaB2nM5qW8eR1tY4uI7oP0aS3dF6gH9jBBB"
    private let claudeAccessTwo = "sk-ant-oat01-FAKEACCESSbetaZ9xC6vB3nM0qW7eR4tY1uI8oP5aS2dCCC"
    private let claudeRefreshTwo = "sk-ant-ort01-FAKEREFRESHbetaL4kJ7hG0fD3sA6pO9iU2yT5rE8wQ1DDD"
    private let kimiAccess = "kimi-FAKEACCESS-3f9a1c7e5b2d8f4a6c0e9b7d5f3a1c8e6b4d2f0a9c7eEEE"
    private let kimiRefresh = "kimi-FAKEREFRESH-8e2c4a6f0b9d7e5c3a1f8b6d4e2c0a9f7d5b3e1c8a6FFF"
    private let codexAccess = "codex-FAKEACCESS-b1d3f5a7c9e2b4d6f8a0c2e4b6d8f0a1c3e5b7d9f2aGGG"
    private let codexRefresh = "codex-FAKEREFRESH-c4e6a8b0d2f4c6e8a0b2d4f6c8e0a2b4d6f8c0e2a4bHHH"

    private var secrets: [String] {
        [claudeAccess, claudeRefresh, claudeAccessTwo, claudeRefreshTwo, kimiAccess, kimiRefresh, codexAccess, codexRefresh]
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CredentialAuditTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        audit = CredentialAudit(directory: root.appendingPathComponent("Logs", isDirectory: true))
        audit.updateAccounts([
            .init(id: alpha, provider: .claudeCode, label: "Alpha", email: "alpha@example.com", isActive: true),
            .init(id: beta, provider: .claudeCode, label: "Beta", email: "beta@example.com", isActive: false),
            .init(id: kimiAccount, provider: .kimi, label: "Kimi One", email: "kimi@example.com", isActive: true,
                  location: kimiLocation.path),
            .init(id: codexAccount, provider: .codex, label: "Codex One", email: "codex@example.com", isActive: true,
                  location: codexHome.path),
        ])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func claudeJSON(_ access: String, _ refresh: String, plan: String = "pro") -> String {
        #"{"claudeAiOauth":{"accessToken":"\#(access)","refreshToken":"\#(refresh)","expiresAt":4102444800000,"#
            + #""scopes":["user:inference"],"subscriptionType":"\#(plan)","rateLimitTier":"default_claude_ai"}}"#
    }

    private func kimiJSON() -> String {
        #"{"access_token":"\#(kimiAccess)","refresh_token":"\#(kimiRefresh)","expires_at":4102444800}"#
    }

    /// Every byte the audit wrote, its rotated files and owner map included.
    private func everythingWritten() throws -> String {
        let directory = audit.fileURL.deletingLastPathComponent()
        return try FileManager.default.contentsOfDirectory(atPath: directory.path).map { name in
            String(decoding: try Data(contentsOf: directory.appendingPathComponent(name)), as: UTF8.self)
        }.joined(separator: "\n")
    }

    private func assertNoSecretText(file: StaticString = #filePath, line: UInt = #line) throws {
        let text = try everythingWritten()
        XCTAssertFalse(text.isEmpty, file: file, line: line)
        for secret in secrets {
            let characters = Array(secret)
            for start in 0...(characters.count - 12) {
                let part = String(characters[start..<start + 12])
                XCTAssertFalse(text.contains(part), "the trail holds part of a credential: \(part)", file: file, line: line)
            }
        }
        XCTAssertFalse(text.contains("FAKEACCESS"), file: file, line: line)
        XCTAssertFalse(text.contains("FAKEREFRESH"), file: file, line: line)
    }

    // MARK: - Every action

    func testEveryActionKindIsRecordedThroughFakesAndNoCredentialTextReachesTheFile() async throws {
        let first = claudeJSON(claudeAccess, claudeRefresh)
        let second = claudeJSON(claudeAccessTwo, claudeRefreshTwo, plan: "max")

        // Session slots, through a fake isolation.
        let slots = SessionSlots(isolation: AuditFakeIsolation(), home: root.appendingPathComponent("home"), audit: audit)
        let slot = try XCTUnwrap(slots.makeSlot(for: kimiAccount, credential: SlotCredential(contents: kimiJSON()),
                                                reason: "test.makeSlot"))
        XCTAssertTrue(slots.serve(slot, credential: SlotCredential(contents: second), account: alpha, reason: "test.move",
                                  session: "session-1", process: 4242))
        slots.remove(slot, reason: "test.remove")

        // Kimi's managed copy made live, then removed.
        let kimiHome = root.appendingPathComponent("kimi-home", isDirectory: true)
        try FileManager.default.createDirectory(at: kimiHome, withIntermediateDirectories: true)
        try Data("[providers.\"managed:kimi-code\".oauth]\nkey = \"oauth/kimi-code\"\n".utf8)
            .write(to: kimiHome.appendingPathComponent("config.toml"))
        try FileManager.default.createDirectory(at: kimiLocation.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(kimiJSON().utf8).write(to: kimiLocation)
        let kimi = KimiService(home: kimiHome, managedRoot: root.appendingPathComponent("kimi-managed"),
                               cliIsRunning: { false }, audit: audit)
        try kimi.promoteToSystem(location: kimiLocation.path, reason: "test.promote")
        try kimi.removeManagedAccount(location: kimiLocation.path, reason: "test.removeKimi")

        // Codex's managed copy written.
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try CodexService.writePrivateAuth(["tokens": ["access_token": codexAccess, "refresh_token": codexRefresh]],
                                          to: codexHome.appendingPathComponent("auth.json"), live: false,
                                          reason: "test.codex", audit: audit)

        // The rest, as their callers record them.
        audit.record(.liveRead, .claudeCode, live: true, credential: first, outcome: "ok", reason: "test.liveRead")
        audit.record(.liveWrite, .claudeCode, account: alpha, live: true, credential: first, previousCredential: second,
                     outcome: "ok", reason: "test.liveWrite")
        audit.record(.savedCopyRead, .claudeCode, account: alpha, credential: first, outcome: "ok", reason: "test.read")
        audit.record(.savedCopyWrite, .claudeCode, account: alpha, credential: first, outcome: "ok", reason: "test.write")
        audit.record(.savedCopyRemove, .claudeCode, account: beta, credential: second, outcome: "ok", reason: "test.remove")
        audit.record(.savedCopyPersist, .claudeCode, account: alpha, credential: first, outcome: "ok", reason: "test.persist")
        audit.record(.capture, .claudeCode, account: alpha, accessToken: claudeAccess, outcome: "ownerAnswered",
                     reason: "test.capture", owner: "alpha@example.com")
        audit.record(.isolatedLogin, .claudeCode, account: beta, credential: second, outcome: "add",
                     reason: "test.login", owner: "beta@example.com")
        audit.record(.renewal, .claudeCode, account: alpha, credential: first, previousCredential: second,
                     outcome: "renewed", reason: "test.renewal")
        audit.record(.ownershipCheck, .claudeCode, live: true, credential: first, outcome: "answered",
                     reason: "test.owner", owner: "alpha@example.com")
        audit.record(.switch, .claudeCode, account: beta, outcome: "ok", reason: "test.switch")
        audit.record(.signalSessions, .claudeCode, live: true, credential: first, outcome: "touched", reason: "test.signal")
        audit.record(.warmup, .claudeCode, account: alpha, accessToken: claudeAccess, outcome: "ok", reason: "test.warmup")
        audit.record(.probe, .claudeCode, account: alpha, accessToken: claudeAccess, outcome: "ok", reason: "test.probe")
        audit.recordServed(.claudeCode, session: "session-1", account: alpha, source: "lastServed", model: "claude-opus")
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        audit.noteRequest(.claudeCode, session: "session-1", agent: nil, account: alpha, source: "slot",
                          sample: .init(at: start, contextTokens: 50_000, cacheReadTokens: 49_000, cacheWriteTokens: 500),
                          cacheLifetime: 300)
        audit.noteRequest(.claudeCode, session: "session-1", agent: nil, account: alpha, source: "slot",
                          sample: .init(at: start.addingTimeInterval(30), contextTokens: 50_500, cacheReadTokens: 0,
                                        cacheWriteTokens: 50_400), cacheLifetime: 300)
        audit.recordProcessCredential(.claudeCode, session: "session-2", process: 99, observed: beta, believed: alpha,
                                      source: "statusLineResets", believedSource: "liveCredential", observedAt: start)

        let entries = audit.entries()
        XCTAssertEqual(Set(entries.map(\.action)), Set(CredentialAuditAction.allCases))
        try assertNoSecretText()

        let slotWrite = try XCTUnwrap(entries.first { $0.action == .slotWrite && $0.reason == "test.move" })
        XCTAssertEqual(slotWrite.slot, slot.path)
        XCTAssertEqual(slotWrite.session, "session-1")
        XCTAssertEqual(slotWrite.process, 4242)
        XCTAssertEqual(slotWrite.provider, AIProviderType.claudeCode.rawValue, "named by the slot's account")
        XCTAssertEqual(slotWrite.subscriptionType, "max")
        XCTAssertNotNil(slotWrite.previousFingerprint, "the token it replaced")
        let assign = try XCTUnwrap(entries.first { $0.action == .slotAssign })
        XCTAssertEqual(assign.accountID, kimiAccount.uuidString)
        let removed = try XCTUnwrap(entries.first { $0.action == .slotRemove })
        XCTAssertEqual(removed.fingerprint, CredentialAudit.fingerprint(ofAccessToken: claudeAccessTwo))

        let promote = try XCTUnwrap(entries.first { $0.reason == "test.promote" })
        XCTAssertEqual(promote.action, .liveWrite)
        XCTAssertEqual(promote.accountID, kimiAccount.uuidString, "attributed to the account whose copy went live")
        XCTAssertEqual(promote.fingerprint, CredentialAudit.fingerprint(ofAccessToken: kimiAccess))
        XCTAssertEqual(entries.first { $0.reason == "test.removeKimi" }?.action, .savedCopyRemove)
        let codex = try XCTUnwrap(entries.first { $0.reason == "test.codex" })
        XCTAssertEqual(codex.action, .savedCopyWrite)
        XCTAssertEqual(codex.accountID, codexAccount.uuidString)

        let liveRead = try XCTUnwrap(entries.first { $0.action == .liveRead })
        XCTAssertEqual(liveRead.accountID, alpha.uuidString, "the live credential is attributed to the active account")
        XCTAssertEqual(liveRead.subscriptionType, "pro")
        XCTAssertEqual(liveRead.rateLimitTier, "default_claude_ai")
        XCTAssertEqual(entries.first { $0.action == .servedChange }?.session, "session-1")
    }

    func testTheFingerprintIsTheFirstTwelveHexDigitsOfTheAccessTokensSHA256() {
        let expected = SHA256.hash(data: Data(claudeAccess.utf8)).map { String(format: "%02x", $0) }.joined().prefix(12)
        XCTAssertEqual(CredentialAudit.fingerprint(ofAccessToken: claudeAccess), String(expected))
        XCTAssertEqual(CredentialAudit.accessToken(in: claudeJSON(claudeAccess, claudeRefresh)), claudeAccess)
        XCTAssertEqual(CredentialAudit.accessToken(in: kimiJSON()), kimiAccess)
        XCTAssertEqual(CredentialAudit.accessToken(in: #"{"tokens":{"access_token":"\#(codexAccess)"}}"#), codexAccess)
        XCTAssertNil(CredentialAudit.accessToken(in: #"{"refresh_token":"\#(kimiRefresh)"}"#),
                     "a refresh token is never taken for the access token")
    }

    func testFileIsOwnerOnly() throws {
        audit.record(.switch, .claudeCode, account: alpha, outcome: "ok", reason: "test")
        let mode = try FileManager.default.attributesOfItem(atPath: audit.fileURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }

    // MARK: - Owners and mismatches

    func testAWriteAttributedToAnotherAccountThanTheTokensOwnerIsAMismatchReportedOnce() throws {
        let cybrio = claudeJSON(claudeAccessTwo, claudeRefreshTwo)
        let notices = NoticeBox()
        audit.onMismatch { provider, message in notices.append(provider, message) }
        let check = try XCTUnwrap(audit.record(.ownershipCheck, .claudeCode, account: beta, credential: cybrio,
                                               outcome: "own", reason: "savedCopyIsOwn", owner: "Beta@Example.com"))
        XCTAssertNil(check.mismatch)
        XCTAssertEqual(check.ownerVerified, true)
        XCTAssertEqual(check.ownerEmail, "Bet*@*.com")

        let write = try XCTUnwrap(audit.record(.savedCopyWrite, .claudeCode, account: alpha, credential: cybrio,
                                               outcome: "ok", reason: "switchTo.backupCurrent.capture"))
        XCTAssertEqual(write.mismatch, true)
        XCTAssertEqual(write.ownerAccountID, beta.uuidString)
        XCTAssertEqual(write.ownerLabel, "Beta")
        XCTAssertNil(write.ownerVerified, "the owner came from the earlier answer")
        XCTAssertEqual(notices.messages.count, 1)
        XCTAssertEqual(notices.providers, [.claudeCode])
        XCTAssertTrue(notices.messages[0].hasPrefix("The credential saved as Alpha's is Beta's (switchTo.backupCurrent.capture"),
                      notices.messages[0])

        audit.record(.savedCopyWrite, .claudeCode, account: alpha, credential: cybrio, outcome: "ok", reason: "again")
        XCTAssertEqual(notices.messages.count, 1, "one event per token and account")
        XCTAssertEqual(audit.record(.liveRead, .claudeCode, account: beta, credential: cybrio, outcome: "ok",
                                    reason: "own")?.mismatch, nil)

        let restarted = CredentialAudit(directory: audit.fileURL.deletingLastPathComponent())
        XCTAssertEqual(restarted.owner(ofFingerprint: CredentialAudit.fingerprint(ofAccessToken: claudeAccessTwo))?.accountID,
                       beta.uuidString, "the owner map outlives the app")
        try assertNoSecretText()
    }

    func testAnOwnerNoSavedAccountHasStillMarksAMismatch() throws {
        audit.record(.ownershipCheck, .claudeCode, account: alpha, accessToken: claudeAccess, outcome: "notOwn",
                     reason: "capture", owner: "stranger@example.org")
        let read = try XCTUnwrap(audit.record(.liveRead, .claudeCode, account: alpha, accessToken: claudeAccess,
                                              outcome: "ok", reason: "read"))
        XCTAssertEqual(read.mismatch, true)
        XCTAssertNil(read.ownerAccountID)
        XCTAssertEqual(read.ownerEmail, "str*@*.org")
    }

    // MARK: - Reads, rotation, query

    func testARepeatedReadOfTheSameTokenIsWrittenOnceAndEveryChangeIsWritten() {
        let now = Date()
        XCTAssertNotNil(audit.record(.liveRead, .claudeCode, accessToken: claudeAccess, outcome: "ok", reason: "r", now: now))
        XCTAssertNil(audit.record(.liveRead, .claudeCode, accessToken: claudeAccess, outcome: "ok", reason: "r",
                                  now: now.addingTimeInterval(60)))
        XCTAssertNotNil(audit.record(.liveRead, .claudeCode, accessToken: claudeAccessTwo, outcome: "ok", reason: "r",
                                     now: now.addingTimeInterval(61)))
        XCTAssertNotNil(audit.record(.liveRead, .claudeCode, accessToken: claudeAccessTwo, outcome: "ok", reason: "r",
                                     now: now.addingTimeInterval(61 + CredentialAudit.readRepeatInterval)))
    }

    func testTheFileRotatesKeepingThreeEarlierFilesAllOwnerOnly() throws {
        let small = CredentialAudit(directory: root.appendingPathComponent("Rotating"), maxBytes: 2_000, keepRotated: 3)
        for index in 0..<120 {
            small.record(.switch, .claudeCode, account: alpha, outcome: "ok", reason: "rotation-\(index)")
        }
        let fm = FileManager.default
        for index in 1...3 {
            let url = small.rotatedURL(index)
            XCTAssertTrue(fm.fileExists(atPath: url.path), url.lastPathComponent)
            let attributes = try fm.attributesOfItem(atPath: url.path)
            XCTAssertLessThanOrEqual((attributes[.size] as? NSNumber)?.intValue ?? .max, 2_000)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
        XCTAssertFalse(fm.fileExists(atPath: small.rotatedURL(4).path))
        let reasons = small.entries().map(\.reason)
        XCTAssertEqual(reasons.last, "rotation-119")
        XCTAssertEqual(reasons, reasons.sorted { Int($0.dropFirst(9))! < Int($1.dropFirst(9))! }, "oldest first")
        XCTAssertLessThan(reasons.count, 120, "the oldest entries were dropped")
    }

    func testTheQueryFiltersByTimeAndByAttributedOrOwningAccount() throws {
        let early = Date(timeIntervalSince1970: 1_800_000_000)
        audit.record(.switch, .claudeCode, account: alpha, outcome: "ok", reason: "early", now: early)
        audit.record(.ownershipCheck, .claudeCode, account: beta, accessToken: claudeAccessTwo, outcome: "own",
                     reason: "learn", owner: "beta@example.com", now: early.addingTimeInterval(10))
        audit.record(.savedCopyWrite, .claudeCode, account: alpha, accessToken: claudeAccessTwo, outcome: "ok",
                     reason: "late", now: early.addingTimeInterval(600))
        XCTAssertEqual(audit.entries(since: early.addingTimeInterval(300)).map(\.reason), ["late"])
        XCTAssertEqual(audit.entries(account: "Alpha").map(\.reason), ["early", "late"])
        XCTAssertEqual(audit.entries(account: "beta@example.com").map(\.reason), ["learn", "late"],
                       "the write names Beta as the token's owner")
        XCTAssertEqual(audit.entries(account: beta.uuidString, limit: 1).map(\.reason), ["late"])
    }

    // MARK: - Serving records

    func testServedIsWrittenOncePerSessionPerAccountChangeAndAgentsNameTheirParent() throws {
        XCTAssertNotNil(audit.recordServed(.claudeCode, session: "s", account: alpha, source: "slot"))
        XCTAssertNil(audit.recordServed(.claudeCode, session: "s", account: alpha, source: "slot"))
        XCTAssertNotNil(audit.recordServed(.claudeCode, session: "s", account: beta, source: "lastServed"))
        let agent = try XCTUnwrap(audit.recordServed(.claudeCode, session: "s", agent: "agent-a1", account: alpha,
                                                     source: "slot"))
        XCTAssertEqual(agent.session, "agent-a1")
        XCTAssertEqual(agent.parentSession, "s")
    }

    func testACacheRebuiltWholeRightAfterAWarmReadIsAChangeOfAccount() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let warm = CredentialAudit.CacheSample(at: at, contextTokens: 80_000, cacheReadTokens: 79_000, cacheWriteTokens: 600)
        let rebuilt = CredentialAudit.CacheSample(at: at.addingTimeInterval(20), contextTokens: 80_400,
                                                  cacheReadTokens: 0, cacheWriteTokens: 80_300)
        XCTAssertTrue(CredentialAudit.isAccountChange(previous: warm, current: rebuilt, cacheLifetime: 300))
        XCTAssertFalse(CredentialAudit.isAccountChange(previous: warm, current: rebuilt, cacheLifetime: 10),
                       "past the cache lifetime the cache expired")
        var compacted = rebuilt
        compacted.contextTokens = 20_000
        compacted.cacheWriteTokens = 19_900
        XCTAssertFalse(CredentialAudit.isAccountChange(previous: warm, current: compacted, cacheLifetime: 300))
        var otherModel = rebuilt
        otherModel.model = "claude-haiku"
        var warmModel = warm
        warmModel.model = "claude-opus"
        XCTAssertFalse(CredentialAudit.isAccountChange(previous: warmModel, current: otherModel, cacheLifetime: 300))
        var cold = warm
        cold.cacheReadTokens = 100
        XCTAssertFalse(CredentialAudit.isAccountChange(previous: cold, current: rebuilt, cacheLifetime: 300),
                       "nothing was warm before")
    }

    func testAnAgentsCacheRebuiltWhileItsParentWasIdleIsRecordedWithBothTimes() throws {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        audit.noteRequest(.claudeCode, session: "parent", agent: nil, account: alpha, source: "slot",
                          sample: .init(at: at.addingTimeInterval(-100), contextTokens: 9_000, cacheReadTokens: 8_000,
                                        cacheWriteTokens: 100), cacheLifetime: 3600)
        audit.noteRequest(.claudeCode, session: "parent", agent: "agent-x", account: alpha, source: "slot",
                          sample: .init(at: at, contextTokens: 40_000, cacheReadTokens: 39_000, cacheWriteTokens: 300),
                          cacheLifetime: 3600)
        audit.noteRequest(.claudeCode, session: "parent", agent: "agent-x", account: alpha, source: "slot",
                          sample: .init(at: at.addingTimeInterval(52), contextTokens: 40_300, cacheReadTokens: 0,
                                        cacheWriteTokens: 40_200), cacheLifetime: 3600)
        let change = try XCTUnwrap(audit.entries().first { $0.action == .servedChange })
        XCTAssertEqual(change.session, "agent-x")
        XCTAssertEqual(change.parentSession, "parent")
        XCTAssertNotNil(change.before)
        XCTAssertNotNil(change.after)
        XCTAssertTrue(change.detail?.contains("parent session made no request") == true, change.detail ?? "")
        let served = audit.entries().filter { $0.action == .served }
        XCTAssertEqual(served.map(\.session), ["parent", "agent-x"], "one per stream until the account changes")
    }

    // MARK: - Process evidence

    func testAProcessHoldingAnotherAccountsTokenThanBelievedIsFlaggedOnce() throws {
        let notices = NoticeBox()
        audit.onMismatch { provider, message in notices.append(provider, message) }
        let flagged = try XCTUnwrap(audit.recordProcessCredential(
            .claudeCode, session: "4822c359-0000", process: 7, observed: beta, believed: alpha,
            source: "refusalReset", believedSource: "liveCredential", observedAt: Date()))
        XCTAssertEqual(flagged.mismatch, true)
        XCTAssertEqual(flagged.ownerAccountID, beta.uuidString)
        XCTAssertEqual(flagged.accountID, alpha.uuidString)
        XCTAssertEqual(notices.messages.count, 1)
        XCTAssertTrue(notices.messages[0].contains("signalSessions"), "the event offers the signal")
        XCTAssertNil(audit.recordProcessCredential(.claudeCode, session: "4822c359-0000", process: 7, observed: beta,
                                                   believed: alpha, source: "statusLineResets",
                                                   believedSource: "liveCredential", observedAt: Date()))
        XCTAssertNil(audit.recordProcessCredential(.claudeCode, session: "other", process: 8, observed: alpha,
                                                   believed: alpha, source: "statusLineResets",
                                                   believedSource: "slot", observedAt: Date()),
                     "a process holding what AccountDock believes is recorded, not flagged")
        XCTAssertEqual(audit.entries().filter { $0.action == .processCredential }.count, 2)
    }

    func testARefusalsResetTimeNamesTheOneAccountResettingThen() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let refusedAt = try XCTUnwrap(CredentialAudit.date("2026-11-15T23:10:00Z"))
        let reset = try XCTUnwrap(AppState.refusalResetDate("You've hit your limit · resets 2am (Australia/Melbourne)",
                                                            at: refusedAt, calendar: calendar))
        XCTAssertEqual(reset, CredentialAudit.date("2026-11-16T15:00:00Z"), "2am in Melbourne, the next one after the refusal")
        let utc = try XCTUnwrap(AppState.refusalResetDate("5-hour limit reached ∙ resets 1:30am", at: refusedAt, calendar: calendar))
        XCTAssertEqual(utc, CredentialAudit.date("2026-11-16T01:30:00Z"))
        XCTAssertNil(AppState.refusalResetDate("Request failed", at: refusedAt))
        let windows = [(id: alpha, resets: [utc.addingTimeInterval(3 * 3600)]), (id: beta, resets: [utc.addingTimeInterval(120)])]
        XCTAssertEqual(AppState.account(resettingAt: utc, among: windows), beta)
        XCTAssertNil(AppState.account(resettingAt: utc, among: windows + [(id: kimiAccount, resets: [utc])]),
                     "two accounts resetting then name neither")
    }

    /// A weekly limit's refusal names its reset by day: a background
    /// session on the shared sign-in, attributed to the active account
    /// (Personal), was refused "resets Nov 20 at 12pm", which is HSTLES's
    /// weekly reset and none of Personal's, so HSTLES refused it.
    func testAWeeklyRefusalNamesItsResetByDayAndTheAccountResettingThen() throws {
        var melbourne = Calendar(identifier: .gregorian)
        melbourne.timeZone = try XCTUnwrap(TimeZone(identifier: "Australia/Melbourne"))
        let refused = try XCTUnwrap(CredentialAudit.date("2026-11-14T18:16:00Z"))
        let words = "You've hit your weekly limit · resets Nov 20 at 12pm"
        XCTAssertEqual(AppState.refusalResetDate(words, at: refused, calendar: melbourne),
                       CredentialAudit.date("2026-11-20T01:00:00Z"), "noon on 20 November in Melbourne")
        XCTAssertEqual(AppState.refusalResetDate("Weekly limit reached ∙ resets Nov 20, 12:30pm (UTC)", at: refused,
                                                 calendar: melbourne),
                       CredentialAudit.date("2026-11-20T12:30:00Z"), "the named time zone wins")
        XCTAssertEqual(AppState.refusalResetDate("resets Jan 2 at 9am", at: refused, calendar: melbourne),
                       CredentialAudit.date("2027-01-01T22:00:00Z"), "a day already past this year is next year's")
        XCTAssertEqual(AppState.refusalResetDate("limit reached · resets Mon 7:59am", at: refused, calendar: melbourne),
                       CredentialAudit.date("2026-11-15T20:59:00Z"), "the Monday after the refusal, a Sunday in Melbourne")
        XCTAssertEqual(AppState.refusalResetDate("Your limit will reset at 2pm (Australia/Melbourne).", at: refused),
                       CredentialAudit.date("2026-11-15T03:00:00Z"))

        let personal = UUID(), hstles = UUID()
        let windows = [
            (id: personal, resets: [try XCTUnwrap(CredentialAudit.date("2026-11-15T04:00:00Z")),
                                    try XCTUnwrap(CredentialAudit.date("2026-11-18T09:00:00Z"))]),
            (id: hstles, resets: [try XCTUnwrap(CredentialAudit.date("2026-11-20T00:59:59Z"))]),
        ]
        let refusing = AppState.refusingAccount(words: words, at: refused, attributed: personal, windows: windows,
                                                calendar: melbourne)
        XCTAssertEqual(refusing.account, hstles)
        XCTAssertTrue(refusing.byReset)
        let reset = try XCTUnwrap(AppState.refusalResetDate(words, at: refused, calendar: melbourne))
        XCTAssertEqual(AppState.account(resettingAt: reset, among: windows), hstles)
    }

    /// A slot moved from cybrio (Pro, five-hour window resetting 3:20am) to

    /// Personal (Max, no five-hour window) at 02:15:04; at 02:15:27 the
    /// session was refused "resets 3:20am". The CLI had not read its slot
    /// again, so cybrio refused it, not Personal.
    func testARefusalJustAfterASlotMoveIsTheAccountItLeftsAndItsResetConfirmsIt() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let cybrio = UUID(), personal = UUID(), hstles = UUID()
        let claimed = try XCTUnwrap(CredentialAudit.date("2026-11-16T01:40:00Z"))
        let moved = try XCTUnwrap(CredentialAudit.date("2026-11-16T02:15:04Z"))
        let refused = try XCTUnwrap(CredentialAudit.date("2026-11-16T02:15:27Z"))
        let history = [AppState.SlotAssignment(account: cybrio, at: claimed), AppState.SlotAssignment(account: personal, at: moved)]

        XCTAssertEqual(AppState.servingSlotAccount(at: refused, history: history, rebuiltAt: nil), cybrio,
                       "within the settling time with no cache rebuilt, the slot's session is still on the account it left")
        XCTAssertEqual(AppState.servingSlotAccount(at: moved.addingTimeInterval(AppState.slotMoveSettling + 1),
                                                   history: history, rebuiltAt: nil), personal)
        XCTAssertEqual(AppState.servingSlotAccount(at: moved.addingTimeInterval(40), history: history,
                                                   rebuiltAt: moved.addingTimeInterval(36)), personal,
                       "a request rebuilding its cache after the move shows the move took effect")
        XCTAssertEqual(AppState.servingSlotAccount(at: claimed.addingTimeInterval(60), history: history, rebuiltAt: nil), cybrio)

        let windows = [
            (id: cybrio, resets: [try XCTUnwrap(CredentialAudit.date("2026-11-16T03:20:00Z"))]),
            (id: personal, resets: [try XCTUnwrap(CredentialAudit.date("2026-11-20T09:00:00Z"))]),
            (id: hstles, resets: [try XCTUnwrap(CredentialAudit.date("2026-11-16T06:00:00Z"))]),
        ]
        let words = "You've hit your session limit · resets 3:20am"
        let onPersonal = AppState.refusingAccount(words: words, at: refused, attributed: personal, windows: windows,
                                                  calendar: calendar)
        XCTAssertEqual(onPersonal.account, cybrio, "the stated reset is cybrio's window, which Personal does not have")
        XCTAssertTrue(onPersonal.byReset)
        let onCybrio = AppState.refusingAccount(words: words, at: refused, attributed: cybrio, windows: windows,
                                                calendar: calendar)
        XCTAssertEqual(onCybrio.account, cybrio)
        XCTAssertFalse(onCybrio.byReset)
        XCTAssertEqual(AppState.refusingAccount(words: "You've hit your limit", at: refused, attributed: personal,
                                                windows: windows, calendar: calendar).account, personal,
                       "a refusal naming no reset stays with the attributed account")
    }
}

/// Collects mismatch notices from the audit's handler.
private final class NoticeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [(AIProviderType, String)] = []
    func append(_ provider: AIProviderType, _ message: String) { lock.withLock { stored.append((provider, message)) } }
    var messages: [String] { lock.withLock { stored.map(\.1) } }
    var providers: [AIProviderType] { lock.withLock { stored.map(\.0) } }
}
