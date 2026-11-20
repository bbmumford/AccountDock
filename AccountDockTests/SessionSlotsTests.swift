import XCTest
@testable import AccountDock

final class SessionSlotsTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/someone")

    func testOnlyProvidersWithSessionSlotsHaveThem() {
        XCTAssertNotNil(SessionSlots(.claudeCode, home: home))
        XCTAssertNotNil(SessionSlots(.codex, home: home))
        XCTAssertNil(SessionSlots(.gemini, home: home))
        XCTAssertNotNil(SessionSlots(.kimi, home: home))
    }

    func testKeychainServiceIsTheDefaultServiceAndEightHexDigitsOfThePathDigest() {
        let service = ClaudeSessionIsolation.keychainService(base: "Claude Code-credentials", directory: "/tmp/slot")
        XCTAssertTrue(service.hasPrefix("Claude Code-credentials-"))
        let suffix = service.dropFirst("Claude Code-credentials-".count)
        XCTAssertEqual(suffix.count, 8)
        XCTAssertTrue(suffix.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        XCTAssertEqual(service, ClaudeSessionIsolation.keychainService(base: "Claude Code-credentials", directory: "/tmp/slot"))
        XCTAssertNotEqual(service, ClaudeSessionIsolation.keychainService(base: "Claude Code-credentials", directory: "/tmp/slot2"))
    }

    func testKeychainServiceHashesThePathInNormalizationFormC() {
        let decomposed = "/tmp/cafe\u{0301}"
        let composed = "/tmp/caf\u{00E9}"
        XCTAssertEqual(ClaudeSessionIsolation.keychainService(base: "s", directory: decomposed),
                       ClaudeSessionIsolation.keychainService(base: "s", directory: composed))
    }

    func testAccessOnlyDropsEveryRefreshToken() throws {
        let json = #"{"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":1},"refreshToken":"top"}"#
        let stripped = try XCTUnwrap(ClaudeSessionIsolation.accessOnly(json))
        XCTAssertFalse(stripped.contains("refreshToken"))
        XCTAssertTrue(stripped.contains(#""accessToken":"a""#))
        XCTAssertTrue(stripped.contains(#""expiresAt":1"#))
        XCTAssertNil(ClaudeSessionIsolation.accessOnly("not json"))
    }

    func testPoolTextListsOnlyPositiveWeights() {
        let text = SessionSlots.poolText([("-", 2), ("/a", 0.5), ("/b", 0)])
        XCTAssertEqual(text, "2\t-\n0.5\t/a\n")
    }

    func testSlotDirectoriesAreMappedToTheirProcesses() {
        let root = "/Users/u/.accountdock/claude-slots"
        let list = """
          101 /opt/homebrew/bin/claude CLAUDE_SECURESTORAGE_CONFIG_DIR=\(root)/A1 HOME=/Users/u
          102 /opt/homebrew/bin/claude HOME=/Users/u
        30896 /opt/homebrew/bin/claude --resume x CLAUDE_SECURESTORAGE_CONFIG_DIR=\(root)/B2
        """
        XCTAssertEqual(SessionSlots.directoriesByProcess(in: ProcessTable(listing: list, columns: .pid),
                                                         variable: "CLAUDE_SECURESTORAGE_CONFIG_DIR", root: root),
                       [101: "\(root)/A1", 30896: "\(root)/B2"])
    }

    func testDirectoriesInUseAreReadFromProcessEnvironments() {
        let root = "/Users/someone/.accountdock/claude-slots"
        let list = """
        1 claude --resume HOME=/Users/someone CLAUDE_SECURESTORAGE_CONFIG_DIR=\(root)/A TERM=xterm
        2 node app.js CLAUDE_SECURESTORAGE_CONFIG_DIR=/elsewhere/B
        3 claude XCLAUDE_SECURESTORAGE_CONFIG_DIR=\(root)/C
        """
        XCTAssertEqual(SessionSlots.directoriesByProcess(in: ProcessTable(listing: list, columns: .pid),
                                                         variable: "CLAUDE_SECURESTORAGE_CONFIG_DIR", root: root),
                       [1: "\(root)/A"])

    }

    func testAccountForDirectoryAcceptsOnlySlotsUnderTheRoot() throws {
        let slots = try XCTUnwrap(SessionSlots(.claudeCode, home: home))
        let id = UUID()
        XCTAssertEqual(slots.account(forDirectory: slots.directory(for: id).path), id)
        XCTAssertNil(slots.account(forDirectory: "/tmp/\(id.uuidString)"))
        XCTAssertNil(slots.account(forDirectory: slots.root.appendingPathComponent("pool.tsv").path))
    }

    func testLauncherPassesThroughLaunchesThatChooseTheirCredential() throws {
        let slots = try XCTUnwrap(SessionSlots(.claudeCode, home: home))
        let script = slots.launcherScript()
        XCTAssertTrue(script.hasPrefix("#!/bin/sh\n"))
        for variable in slots.isolation.passThroughVariables {
            XCTAssertTrue(script.contains("${\(variable):-}"), variable)
        }
        XCTAssertTrue(script.contains(slots.isolation.passThroughCommands.joined(separator: "|") + ")"))
        XCTAssertTrue(script.contains("export \(slots.isolation.directoryVariable)"))
        XCTAssertTrue(script.contains("-mmin -\(SessionSlots.poolLifetimeMinutes)"))
        XCTAssertTrue(script.contains(SessionSlots.shellQuoted(slots.poolFile.path)))
    }

    func testProfileLineIsAddedOnceAndRemovedWithoutTouchingTheRest() throws {
        let slots = try XCTUnwrap(SessionSlots(.claudeCode, home: home))
        let line = slots.profileLine
        let original = "export PATH=/a:$PATH\nalias x=y"
        let added = SessionSlots.addingLine(line, to: original)
        XCTAssertTrue(SessionSlots.profileHasLine(added, line: line))
        XCTAssertFalse(SessionSlots.profileHasLine(original, line: line))
        XCTAssertTrue(added.hasSuffix(line + "\n"))
        XCTAssertEqual(SessionSlots.removingLine(line, from: added), original + "\n")
        XCTAssertEqual(SessionSlots.addingLine(line, to: ""), line + "\n")
    }

    func testTheLauncherLineGoesWhereEveryZshReadsItAndLeavesTheRestUntouched() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let slots = try XCTUnwrap(SessionSlots(.claudeCode, home: temp))
        XCTAssertEqual(slots.profileURL.lastPathComponent, ".zshenv")
        let rc = "eval \"$(/opt/homebrew/bin/brew shellenv)\"\nalias ll='ls -l'\n# no newline at the end"
        try rc.write(to: slots.interactiveProfileURL, atomically: true, encoding: .utf8)
        let env = "export EDITOR=vim\n"
        try env.write(to: slots.profileURL, atomically: true, encoding: .utf8)

        try slots.installLauncher()
        XCTAssertTrue(slots.launcherInstalled)
        XCTAssertEqual(try String(contentsOf: slots.profileURL, encoding: .utf8), env + slots.profileLine + "\n")
        XCTAssertEqual(try String(contentsOf: slots.interactiveProfileURL, encoding: .utf8), rc + "\n" + slots.profileLine + "\n")
        try slots.installLauncher()
        XCTAssertEqual(try String(contentsOf: slots.profileURL, encoding: .utf8), env + slots.profileLine + "\n", "added once")

        // A shell that is not interactive finds the launcher first.
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", "command -v claude"]
        process.environment = ["HOME": temp.path, "ZDOTDIR": temp.path, "PATH": "/usr/bin:/bin"]
        process.standardOutput = pipe
        try process.run()
        let found = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(found.trimmingCharacters(in: .whitespacesAndNewlines), slots.launcher.path)

        slots.removeLauncher()
        XCTAssertEqual(try String(contentsOf: slots.profileURL, encoding: .utf8), env)
        XCTAssertEqual(try String(contentsOf: slots.interactiveProfileURL, encoding: .utf8), rc + "\n")
    }

    func testARenewedTokenGoesToEverySlotHoldingTheAccountsPreviousOne() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let slots = try XCTUnwrap(SessionSlots(.claudeCode, home: temp))
        let account = UUID(), other = UUID()
        let fm = FileManager.default
        for id in [account, other] { try fm.createDirectory(at: slots.directory(for: id), withIntermediateDirectories: true) }
        func sessionSlot(_ id: UUID, claimed: Bool) throws -> String {
            let directory = slots.sessionRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            XCTAssertTrue(slots.assign(directory, to: id, reason: "test"))
            if claimed { try fm.createDirectory(at: directory.appendingPathComponent(SessionSlots.claimedMarker), withIntermediateDirectories: true) }
            return directory.path
        }
        let offered = try sessionSlot(account, claimed: true)
        XCTAssertTrue(slots.markReclaimable(URL(fileURLWithPath: offered)))
        _ = try sessionSlot(account, claimed: false)
        let claimedHere = try sessionSlot(account, claimed: true)
        let claimedElsewhere = try sessionSlot(account, claimed: true)
        _ = try sessionSlot(other, claimed: false)
        let own = slots.directory(for: account).path
        let otherOwn = slots.directory(for: other).path

        // A claimed slot holds the account it serves now, which may not be
        // the one its account file names before the cycle that moves it.
        let serving = [claimedHere: account, claimedElsewhere: other, otherOwn: account]
        XCTAssertEqual(slots.directories(holding: account, serving: serving), [own, offered, claimedHere, otherOwn])
        // An account's own slot serving another account holds that one's token.
        XCTAssertEqual(slots.directories(holding: account, serving: [own: other]), [offered])
    }

    func testShellQuotingSurvivesSingleQuotes() {
        XCTAssertEqual(SessionSlots.shellQuoted("a'b"), #"'a'\''b'"#)
    }

    @MainActor
    func testASlotClaimedOnRequestIsKnownAsSuchAndNeverClaimedTwice() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let slots = try XCTUnwrap(SessionSlots(.claudeCode, home: temp))
        let account = UUID()
        let directory = slots.sessionRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertTrue(slots.assign(directory, to: account, reason: "test"))
        XCTAssertEqual(slots.sessionSlots().first?.requested, false)
        XCTAssertNil(slots.sessionSlots().first?.claimedAt)

        XCTAssertTrue(slots.claimRequested(directory))
        let slot = try XCTUnwrap(slots.sessionSlots().first)
        XCTAssertEqual(slot.account, account)
        XCTAssertTrue(slot.requested)
        XCTAssertNotNil(slot.claimedAt, "the launcher cannot claim it for another session")
        XCTAssertFalse(slots.claimRequested(directory), "a claimed slot is not claimed again")
        XCTAssertGreaterThan(AppState.requestedClaimGrace, AppState.slotClaimGrace)
    }

    func testARequestedSessionRunsTheCLIItselfNotTheLauncher() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let home = temp.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let slots = try XCTUnwrap(SessionSlots(.claudeCode, home: home))
        try slots.installLauncher()
        let real = temp.appendingPathComponent("claude")
        try "#!/bin/sh\n".write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: real.path)

        XCTAssertEqual(slots.realExecutable(preferred: real.path), real.path)
        XCTAssertNotEqual(slots.realExecutable(preferred: slots.launcher.path), slots.launcher.path)
    }

    func testShellQuotingSurvivesQuotesAndSpaces() throws {
        let text = "/Users/me/it's a \"folder\" $HOME"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf %s " + AppState.shellQuoted(text)]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), text)
    }

    func testTheLiveCredentialIsRenewedEarlyOnlyWhileSlotsHoldItsToken() {
        let now = Date()
        XCTAssertTrue(AppState.liveRenewalIsDue(expiry: now.addingTimeInterval(20 * 60), slotsHoldIt: true, now: now))
        XCTAssertFalse(AppState.liveRenewalIsDue(expiry: now.addingTimeInterval(20 * 60), slotsHoldIt: false, now: now),
                       "sessions on the default credential renew it themselves")
        XCTAssertFalse(AppState.liveRenewalIsDue(expiry: now.addingTimeInterval(3 * 60 * 60), slotsHoldIt: true, now: now))
    }

    func testASlotMadeOnRequestIsClaimedBeforeAnythingElseCanTakeIt() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let slots = try XCTUnwrap(SessionSlots(.claudeCode, home: temp))
        let directory = slots.sessionRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Claimed while still empty: no account file yet, so no pass takes
        // it for a slot no launch claimed.
        XCTAssertTrue(slots.claimRequested(directory))
        let slot = try XCTUnwrap(slots.sessionSlots().first)
        XCTAssertNil(slot.account)
        XCTAssertNotNil(slot.claimedAt)
        XCTAssertTrue(slot.requested)
        XCTAssertFalse(slots.removeUnclaimed(directory, reason: "test"), "a claimed slot is not removed as one no launch claimed")
        XCTAssertTrue(slots.assign(directory, to: UUID(), reason: "test"))
    }

    func testEventsNameEachSessionApart() {
        func session(_ id: String, _ directory: String?) -> AgentSession {
            AgentSession(sessionID: id, provider: "claude", event: "Stop", workingDirectory: directory,
                         processID: 1, host: nil, observedAt: nil)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(AppState.eventName(of: session("8c64c5f8-45c6", home + "/Work")), "session 8c64c5f8 in ~/Work")
        XCTAssertEqual(AppState.eventName(of: session("583fb354-740e", nil)), "session 583fb354")
        XCTAssertEqual(AppState.eventName(of: nil), "a run with no session record")
    }

    func testASessionIsListedByItsOwnNameThenItsFolderThenItsID() {
        XCTAssertEqual(AppState.sessionLabel(id: "8c64c5f8-45c6", name: "cf-builder", directory: "/Users/a/ORBTR", model: "Fable 5.2"),
                       "cf-builder · Fable 5.2")
        XCTAssertEqual(AppState.sessionLabel(id: "8c64c5f8-45c6", name: nil, directory: "/Users/a/ORBTR", model: nil), "ORBTR")
        XCTAssertEqual(AppState.sessionLabel(id: "8c64c5f8-45c6", name: nil, directory: nil, model: nil), "session 8c64c5f8")
    }
}
