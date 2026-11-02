import XCTest
@testable import AccountDock

final class SessionSlotsTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/someone")

    func testOnlyProvidersWithSessionSlotsHaveThem() {
        XCTAssertNotNil(SessionSlots(.claudeCode, home: home))
        XCTAssertNil(SessionSlots(.codex, home: home))
        XCTAssertNil(SessionSlots(.kimi, home: home))
    }

    func testKeychainServiceIsTheDefaultServiceAndEightHexDigitsOfThePathDigest() {
        let service = SessionSlots.keychainService(base: "Claude Code-credentials", directory: "/tmp/slot")
        XCTAssertTrue(service.hasPrefix("Claude Code-credentials-"))
        let suffix = service.dropFirst("Claude Code-credentials-".count)
        XCTAssertEqual(suffix.count, 8)
        XCTAssertTrue(suffix.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        XCTAssertEqual(service, SessionSlots.keychainService(base: "Claude Code-credentials", directory: "/tmp/slot"))
        XCTAssertNotEqual(service, SessionSlots.keychainService(base: "Claude Code-credentials", directory: "/tmp/slot2"))
    }

    func testKeychainServiceHashesThePathInNormalizationFormC() {
        let decomposed = "/tmp/cafe\u{0301}"
        let composed = "/tmp/caf\u{00E9}"
        XCTAssertEqual(SessionSlots.keychainService(base: "s", directory: decomposed),
                       SessionSlots.keychainService(base: "s", directory: composed))
    }

    func testAccessOnlyDropsEveryRefreshToken() throws {
        let json = #"{"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":1},"refreshToken":"top"}"#
        let stripped = try XCTUnwrap(SessionSlots.accessOnly(json))
        XCTAssertFalse(stripped.contains("refreshToken"))
        XCTAssertTrue(stripped.contains(#""accessToken":"a""#))
        XCTAssertTrue(stripped.contains(#""expiresAt":1"#))
        XCTAssertNil(SessionSlots.accessOnly("not json"))
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
        XCTAssertEqual(SessionSlots.directoriesByProcess(inProcessList: list, variable: "CLAUDE_SECURESTORAGE_CONFIG_DIR", root: root),
                       [101: "\(root)/A1", 30896: "\(root)/B2"])
    }

    func testDirectoriesInUseAreReadFromProcessEnvironments() {
        let root = "/Users/someone/.accountdock/claude-slots"
        let list = """
        claude --resume HOME=/Users/someone CLAUDE_SECURESTORAGE_CONFIG_DIR=\(root)/A TERM=xterm
        node app.js CLAUDE_SECURESTORAGE_CONFIG_DIR=/elsewhere/B
        claude XCLAUDE_SECURESTORAGE_CONFIG_DIR=\(root)/C
        """
        XCTAssertEqual(SessionSlots.directories(inProcessList: list, variable: "CLAUDE_SECURESTORAGE_CONFIG_DIR", root: root),
                       ["\(root)/A"])
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
        for variable in slots.support.credentialVariables {
            XCTAssertTrue(script.contains("${\(variable):-}"), variable)
        }
        XCTAssertTrue(script.contains(slots.support.accountCommands.joined(separator: "|") + ")"))
        XCTAssertTrue(script.contains("export \(slots.support.directoryVariable)"))
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

    func testLauncherStartsTheRealCLIOnThePickedSlot() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let home = temp.appendingPathComponent("home with space", isDirectory: true)
        let realBin = temp.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: realBin, withIntermediateDirectories: true)
        let real = realBin.appendingPathComponent("claude")
        try #"""
        #!/bin/sh
        printf '%s|%s' "${CLAUDE_SECURESTORAGE_CONFIG_DIR:-}" "$*"

        """#.write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: real.path)

        let slots = try XCTUnwrap(SessionSlots(.claudeCode, home: home))
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try slots.installLauncher()
        XCTAssertTrue(slots.launcherInstalled)
        let slot = slots.directory(for: UUID())
        try FileManager.default.createDirectory(at: slot, withIntermediateDirectories: true)

        func launch(_ arguments: [String], environment: [String: String] = [:]) throws -> String {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "exec claude \"$@\"", "sh"] + arguments
            process.environment = ["PATH": slots.binDirectory.path + ":" + realBin.path + ":/usr/bin:/bin"]
                .merging(environment) { $1 }
            process.standardOutput = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }

        XCTAssertEqual(try launch(["-p", "hi"]), "|-p hi", "no pool file starts the CLI unchanged")
        slots.writePool([(slot.path, 1)])
        XCTAssertEqual(try launch(["-p", "hi"]), slot.path + "|-p hi")
        XCTAssertEqual(try launch(["auth", "status"]), "|auth status")
        XCTAssertEqual(try launch(["-p"], environment: ["CLAUDE_CONFIG_DIR": "/x"]), "|-p")
        slots.writePool([(SessionSlots.activeEntry, 1)])
        XCTAssertEqual(try launch([]), "|")
        slots.writePool([(slot.path + "-missing", 1)])
        XCTAssertEqual(try launch([]), "|")

        // A spare one-session slot for the picked account is claimed once;
        // with none left the account's own slot serves.
        let account = try XCTUnwrap(UUID(uuidString: slot.lastPathComponent))
        let spare = slots.sessionRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: spare, withIntermediateDirectories: true)
        let other = slots.sessionRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        XCTAssertTrue(slots.assign(spare, to: account))
        XCTAssertTrue(slots.assign(other, to: UUID()))
        slots.writePool([(slot.path, 1)])
        XCTAssertEqual(try launch(["-p"]), spare.path + "|-p")
        XCTAssertEqual(slots.sessionSlots().first { $0.directory.lastPathComponent == spare.lastPathComponent }?.account, account)
        XCTAssertNotNil(slots.sessionSlots().first { $0.directory.lastPathComponent == spare.lastPathComponent }?.claimedAt)
        XCTAssertNil(slots.sessionSlots().first { $0.directory.lastPathComponent == other.lastPathComponent }?.claimedAt)
        XCTAssertEqual(try launch(["-p"]), slot.path + "|-p", "a claimed spare is never handed out twice")

        // A session resumed by ID goes back to the account its history ran
        // on, whatever the weights say; an unknown ID is placed by weight.
        let home2 = slots.sessionRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home2, withIntermediateDirectories: true)
        let otherAccount = UUID()
        XCTAssertTrue(slots.assign(home2, to: otherAccount))
        slots.writeResumes([(session: "abc-123", path: slots.directory(for: otherAccount).path),
                            (session: "on-active", path: SessionSlots.activeEntry)])
        XCTAssertEqual(try launch(["--resume", "abc-123"]), home2.path + "|--resume abc-123")
        XCTAssertEqual(try launch(["-r", "on-active"]), "|-r on-active")
        XCTAssertEqual(try launch(["--resume=unknown"]), slot.path + "|--resume=unknown")

        slots.removeLauncher()
        XCTAssertFalse(slots.launcherInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: slots.launcher.path))
        XCTAssertEqual(try String(contentsOf: slots.profileURL, encoding: .utf8), "")
    }

    func testShellQuotingSurvivesSingleQuotes() {
        XCTAssertEqual(SessionSlots.shellQuoted("a'b"), #"'a'\''b'"#)
    }
}
