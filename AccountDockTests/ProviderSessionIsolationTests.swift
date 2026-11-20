import XCTest
@testable import AccountDock

/// A provider whose CLI keeps its credential in a file inside the slot,
/// selected by `FAKECLI_HOME`, and resumes with a `resume <id>` subcommand:
/// nothing in `SessionSlots` knows it, so serving it shows the shared slot
/// code needs no change for a new provider.
private struct FakeFileIsolation: ProviderSessionIsolation {
    let executable = "fakecli"
    let directoryVariable = "FAKECLI_HOME"
    let passThroughVariables = ["FAKECLI_TOKEN"]
    let passThroughCommands = ["login"]
    let background: BackgroundSessionSupport? = nil
    let installDirectories: [String] = []
    let preferredExecutable: String? = nil
    let resumeArgumentScript = """
    for argument in "$@"; do
      [ "$previous" = resume ] && resumed=$argument
      previous=$argument
    done
    """

    func resumeCommand(sessionID: String) -> String { "fakecli resume \(SessionSlots.shellQuoted(sessionID))" }
    func screenReportsRunningWork(_ screen: String) -> Bool { screen.contains("[running]") }
    func screenAsksAboutRunningWork(_ screen: String) -> Bool { screen.contains("Quit anyway?") }
    let keepRunningKey = "n"

    func slotCredential(from credential: String) -> SlotCredential? {
        guard let data = credential.data(using: .utf8),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        object["refresh"] = nil
        guard let stripped = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return SlotCredential(contents: String(decoding: stripped, as: UTF8.self))
    }

    @MainActor
    func currentSlotCredential(for account: Account, minimumLifetime: TimeInterval,
                               from state: AppState) async -> SlotCredential? { nil }

    func prepareSlot(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = directory.appendingPathComponent("config.toml")
        if !FileManager.default.fileExists(atPath: config.path) {
            try Data("model = \"fake\"\n".utf8).write(to: config)
        }
    }

    func writeCredential(_ credential: SlotCredential, to directory: URL) -> Bool {
        (try? Data(credential.contents.utf8).write(to: directory.appendingPathComponent("credential.json"), options: .atomic)) != nil
    }

    func readCredential(in directory: URL) -> SlotCredential? {
        (try? String(contentsOf: directory.appendingPathComponent("credential.json"), encoding: .utf8))
            .map(SlotCredential.init(contents:))
    }

    func removeSlot(_ directory: URL) {}

    func signalReread(_ directory: URL) {
        FileManager.default.createFile(atPath: directory.appendingPathComponent("reread").path, contents: nil)
    }
}

final class ProviderSessionIsolationTests: XCTestCase {
    func testClaudeCodexAndKimiHaveSessionIsolation() {
        XCTAssertEqual(AIProviderType.isolatedProviders, [.claudeCode, .codex, .kimi])
        XCTAssertEqual(AIProviderType.claudeCode.capabilities.sessionIsolation?.executable, "claude")
        XCTAssertEqual(AIProviderType.kimi.capabilities.sessionIsolation?.executable, "kimi")
        XCTAssertEqual(AIProviderType.codex.capabilities.sessionIsolation?.executable, "codex")
    }

    func testClaudeSlotCredentialHoldsNoRefreshToken() throws {
        let claude = ClaudeSessionIsolation()
        let json = #"{"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":1,"name":"é"}}"#
        let credential = try XCTUnwrap(claude.slotCredential(from: json))
        XCTAssertFalse(credential.contents.contains("refreshToken"))
        XCTAssertTrue(credential.contents.contains(#""accessToken":"a""#))
        XCTAssertEqual(credential.contents, SecurityToolKeychain.asciiOnly(credential.contents))
        XCTAssertEqual(claude.resumeCommand(sessionID: "abc"), "claude --resume 'abc'")
    }

    func testANewProviderIsServedEndToEndByTheSharedSlotCode() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let home = temp.appendingPathComponent("home", isDirectory: true)
        let realBin = temp.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: realBin, withIntermediateDirectories: true)
        let real = realBin.appendingPathComponent("fakecli")
        try #"""
        #!/bin/sh
        credential=
        [ -n "${FAKECLI_HOME:-}" ] && credential=$(cat "$FAKECLI_HOME/credential.json")
        printf '%s|%s|%s' "${FAKECLI_HOME:-}" "$credential" "$*"

        """#.write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: real.path)

        let isolation = FakeFileIsolation()
        let slots = SessionSlots(isolation: isolation, home: home)
        XCTAssertEqual(slots.root.lastPathComponent, "fakecli-slots")
        XCTAssertEqual(slots.launcher.lastPathComponent, "fakecli")
        XCTAssertEqual(slots.realExecutable(preferred: real.path), real.path)

        // The launcher is generated from the isolation alone.
        let script = slots.launcherScript()
        XCTAssertTrue(script.contains("export FAKECLI_HOME"))
        XCTAssertTrue(script.contains("${FAKECLI_TOKEN:-}"))
        XCTAssertFalse(script.contains("CLAUDE"))
        XCTAssertFalse(script.contains("--resume"))
        XCTAssertFalse(script.contains("--bg"))
        try slots.installLauncher()
        XCTAssertTrue(slots.launcherInstalled)

        // A slot holds the access-only credential the isolation wrote.
        let account = UUID()
        let credential = try XCTUnwrap(isolation.slotCredential(from: #"{"access":"a1","refresh":"secret"}"#))
        XCTAssertFalse(credential.contents.contains("secret"))
        let other = UUID()
        let otherCredential = try XCTUnwrap(isolation.slotCredential(from: #"{"access":"b2"}"#))
        let credentials = [account: credential, other: otherCredential]

        let harness = LauncherHarness(slots: slots, realBin: realBin)
        defer { harness.stopResponding(); harness.stopDock() }
        XCTAssertEqual(try harness.launch(["chat"]), "||chat", "without AccountDock running the CLI starts unchanged")

        // AccountDock fills each launch's own slot for the account it asks for.
        try FileManager.default.createDirectory(at: slots.sessionRoot, withIntermediateDirectories: true)
        try harness.startDock()
        harness.respond(active: account) { request, id in
            guard let value = credentials[id] else { return }
            _ = slots.fill(request.directory, account: id, credential: value, reason: "test", session: request.session)
        }
        slots.writePool([(slots.directory(for: account).path, 1)])
        XCTAssertEqual(try harness.launch(["login"]), "||login")
        XCTAssertEqual(try harness.launch(["chat"], environment: ["FAKECLI_TOKEN": "t"]), "||chat")
        let chat = try harness.launch(["chat"]).split(separator: "|").map(String.init)
        XCTAssertEqual(chat.count, 3)
        let own = URL(fileURLWithPath: chat[0], isDirectory: true)
        XCTAssertEqual(own.deletingLastPathComponent().path, slots.sessionRoot.path,
                       "the launcher made the session its own slot and exports the isolation's variable")
        XCTAssertEqual(Array(chat.dropFirst()), [credential.contents, "chat"])
        XCTAssertEqual(isolation.readCredential(in: own), credential)
        XCTAssertTrue(FileManager.default.fileExists(atPath: own.appendingPathComponent("config.toml").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: own.appendingPathComponent("reread").path))
        XCTAssertEqual(slots.sessionSlots().first { $0.directory.path == own.path }?.account, account)
        XCTAssertNotNil(slots.sessionSlots().first { $0.directory.path == own.path }?.claimedAt)

        // A session resumed by ID goes back to its account, parsed by the
        // isolation's own resume lines.
        slots.writeResumes([(session: "s-1", path: slots.directory(for: other).path)])
        let resumed = try harness.launch(["resume", "s-1"]).split(separator: "|").map(String.init)
        XCTAssertEqual(Array(resumed.dropFirst()), [otherCredential.contents, "resume s-1"])
        let resumedSlot = URL(fileURLWithPath: resumed[0], isDirectory: true)
        XCTAssertNotEqual(resumedSlot.path, own.path)

        // Moving a session rewrites its slot through the isolation.
        XCTAssertTrue(slots.serve(own, credential: otherCredential, account: nil, reason: "test"))
        XCTAssertEqual(isolation.readCredential(in: own), otherCredential)

        // Each process is mapped to the slot its environment names.
        let list = """
          123   1 fakecli chat FAKECLI_HOME=\(own.path) HOME=/x
          124   1 fakecli chat HOME=/x
          125   1 fakecli resume s-1 FAKECLI_HOME=\(resumedSlot.path)
        """
        XCTAssertEqual(slots.directoriesByProcess(in: ProcessTable(listing: list, columns: .pidPPID)),
                       [123: own.path, 125: resumedSlot.path])

        slots.remove(own, reason: "test")
        XCTAssertFalse(FileManager.default.fileExists(atPath: own.path))
        slots.removeLauncher()
        XCTAssertFalse(slots.launcherInstalled)
    }
}
