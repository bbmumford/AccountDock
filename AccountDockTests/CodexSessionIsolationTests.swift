import XCTest
@testable import AccountDock

final class CodexSessionIsolationTests: XCTestCase {
    private let isolation = CodexSessionIsolation()

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// An unsigned access token with the claims Codex's carry.
    static func token(account: String, expires: Date) -> String {
        func part(_ object: [String: Any]) -> String {
            try! JSONSerialization.data(withJSONObject: object).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let claims: [String: Any] = ["exp": Int(expires.timeIntervalSince1970),
                                     "https://api.openai.com/auth": ["chatgpt_account_id": account]]
        return part(["alg": "none"]) + "." + part(claims) + ".sig"
    }

    static func auth(account: String, expires: Date, refresh: String = "fake-refresh") -> String {
        let object: [String: Any] = ["auth_mode": "chatgpt",
                                     "tokens": ["access_token": token(account: account, expires: expires),
                                                "refresh_token": refresh, "id_token": "fake.id.token",
                                                "account_id": account]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    // MARK: - Launcher

    /// The lines the launcher runs once it has a slot: exactly these, so a
    /// change to what Codex is started with is made on purpose.
    func testLauncherExportLinesAreGolden() {
        let script = #"f="$ACCOUNTDOCK_CODEX_SLOT/credential.json"; [ "$(/usr/bin/plutil -extract account_id raw -o - "$f")" = "$ACCOUNTDOCK_CODEX_ACCOUNT_ID" ] && exec /usr/bin/plutil -extract access_token raw -o - "$f""#
        let expectedArguments = [
            #"model_provider="accountdock""#,
            #"model_providers.accountdock.name="OpenAI""#,
            #"model_providers.accountdock.base_url="https://chatgpt.com/backend-api/codex""#,
            #"model_providers.accountdock.wire_api="responses""#,
            #"model_providers.accountdock.requires_openai_auth=false"#,
            #"model_providers.accountdock.auth.command="/bin/sh""#,
            "model_providers.accountdock.auth.args=['-c','\(script)']",
            #"model_providers.accountdock.auth.refresh_interval_ms=60000"#,
            #"model_providers.accountdock.env_http_headers.ChatGPT-Account-ID="ACCOUNTDOCK_CODEX_ACCOUNT_ID""#,
            #"cli_auth_credentials_store="ephemeral""#,
        ].flatMap { ["-c", $0] }
        XCTAssertEqual(CodexSessionIsolation.slotArguments, expectedArguments)
        XCTAssertEqual(isolation.launcherExportLines(slot: "$spare"), [
            "ACCOUNTDOCK_CODEX_SLOT=$spare",
            #"ACCOUNTDOCK_CODEX_ACCOUNT_ID=$(/usr/bin/plutil -extract account_id raw -o - "$spare/credential.json" 2>/dev/null) || exec "$real" "$@""#,
            #"[ -n "$ACCOUNTDOCK_CODEX_ACCOUNT_ID" ] || exec "$real" "$@""#,
            "export ACCOUNTDOCK_CODEX_SLOT ACCOUNTDOCK_CODEX_ACCOUNT_ID",
            "set -- " + expectedArguments.map(SessionSlots.shellQuoted).joined(separator: " ") + #" "$@""#,
        ])
    }

    /// Runs the installed launcher in front of a stand-in `codex` that
    /// prints its arguments and slot environment.
    private func runLauncher(home: URL, arguments: [String]) throws -> String {
        let slots = SessionSlots(isolation: isolation, home: home)
        try slots.installLauncher()
        let bin = home.appendingPathComponent("realbin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let fake = bin.appendingPathComponent("codex")
        try """
        #!/bin/sh
        echo "slot=${ACCOUNTDOCK_CODEX_SLOT:-none} account=${ACCOUNTDOCK_CODEX_ACCOUNT_ID:-none}"
        for a in "$@"; do echo "arg=$a"; done
        """.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let process = Process()
        process.executableURL = slots.launcher
        process.arguments = arguments
        process.environment = ["PATH": "\(slots.binDirectory.path):\(bin.path):/usr/bin:/bin", "HOME": home.path,
                               SessionSlots.spareWaitVariable: "0"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    func testTheLauncherStartsCodexOnTheSlotWithItsArgumentsFirst() throws {
        let home = try temporaryDirectory()
        let slots = SessionSlots(isolation: isolation, home: home)
        let account = UUID()
        let credential = try XCTUnwrap(isolation.slotCredential(from: Self.auth(account: "acct-1", expires: Date().addingTimeInterval(3600))))
        XCTAssertTrue(slots.serve(slots.directory(for: account), credential: credential, account: account, reason: "test"))
        slots.writePool([(slots.directory(for: account).path, 1)])

        let output = try runLauncher(home: home, arguments: ["exec", "say ok"])
        let lines = output.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "slot=\(slots.directory(for: account).path) account=acct-1")
        XCTAssertEqual(Array(lines.dropFirst()), (CodexSessionIsolation.slotArguments + ["exec", "say ok"]).map { "arg=" + $0 })
    }

    func testSignInAndManagementCommandsRunCodexUnchanged() throws {
        let home = try temporaryDirectory()
        let slots = SessionSlots(isolation: isolation, home: home)
        let account = UUID()
        let credential = try XCTUnwrap(isolation.slotCredential(from: Self.auth(account: "acct-1", expires: Date().addingTimeInterval(3600))))
        XCTAssertTrue(slots.serve(slots.directory(for: account), credential: credential, account: account, reason: "test"))
        slots.writePool([(slots.directory(for: account).path, 1)])
        for command in ["login", "logout", "mcp", "app"] {
            let output = try runLauncher(home: home, arguments: [command, "--help"])
            XCTAssertEqual(output, "slot=none account=none\narg=\(command)\narg=--help\n", command)
        }
    }

    func testAResumeIsRoutedToTheSlotItsSessionRanOn() throws {
        let home = try temporaryDirectory()
        let slots = SessionSlots(isolation: isolation, home: home)
        let (pooled, resumedOn) = (UUID(), UUID())
        let credential = try XCTUnwrap(isolation.slotCredential(from: Self.auth(account: "acct-1", expires: Date().addingTimeInterval(3600))))
        let other = try XCTUnwrap(isolation.slotCredential(from: Self.auth(account: "acct-2", expires: Date().addingTimeInterval(3600))))
        XCTAssertTrue(slots.serve(slots.directory(for: pooled), credential: credential, account: pooled, reason: "test"))
        XCTAssertTrue(slots.serve(slots.directory(for: resumedOn), credential: other, account: resumedOn, reason: "test"))
        slots.writePool([(slots.directory(for: pooled).path, 1)])
        slots.writeResumes([("019a-session", slots.directory(for: resumedOn).path)])

        let output = try runLauncher(home: home, arguments: ["resume", "019a-session"])
        XCTAssertTrue(output.hasPrefix("slot=\(slots.directory(for: resumedOn).path) account=acct-2\n"), output)
        XCTAssertTrue(output.hasSuffix("arg=resume\narg=019a-session\n"))
        XCTAssertEqual(isolation.resumeCommand(sessionID: "019a-session"), "codex resume '019a-session'")

        slots.addResume(session: "019a-session", path: slots.directory(for: pooled).path)
        let moved = try runLauncher(home: home, arguments: ["resume", "019a-session"])
        XCTAssertTrue(moved.hasPrefix("slot=\(slots.directory(for: pooled).path) account=acct-1\n"),
                      "a restart names its new slot at once: \(moved)")
    }

    func testTheResumeArgumentIsTheFirstNonOptionAfterResume() throws {
        func resumed(_ arguments: [String]) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "resumed=; previous=\n" + isolation.resumeArgumentScript + "\nprintf %s \"$resumed\"", "sh"] + arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            process.waitUntilExit()
            return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        XCTAssertEqual(try resumed(["resume", "abc"]), "abc")
        XCTAssertEqual(try resumed(["exec", "resume", "abc", "go on"]), "abc")
        XCTAssertEqual(try resumed(["resume", "--last"]), "")
        XCTAssertEqual(try resumed(["say resume"]), "")
    }

    // MARK: - Credential

    func testASlotHoldsTheAccessTokenItsAccountAndExpiryAndNoRefreshToken() throws {
        let expires = Date(timeIntervalSince1970: 1_900_000_000)
        let auth = Self.auth(account: "acct-1", expires: expires)
        let slot = try XCTUnwrap(isolation.slotCredential(from: auth))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(slot.contents.utf8)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["access_token", "account_id", "expires_at"])
        XCTAssertEqual(object["account_id"] as? String, "acct-1")
        XCTAssertEqual((object["expires_at"] as? NSNumber)?.intValue, 1_900_000_000)
        XCTAssertFalse(slot.contents.contains("fake-refresh"))
        XCTAssertNil(isolation.slotCredential(from: #"{"tokens":{"refresh_token":"r"}}"#), "no access token")

        let directory = try temporaryDirectory().appendingPathComponent("slot", isDirectory: true)
        try isolation.prepareSlot(directory)
        XCTAssertTrue(isolation.writeCredential(slot, to: directory))
        XCTAssertEqual(isolation.readCredential(in: directory), slot)
        let mode = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("credential.json").path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        XCTAssertEqual(isolation.launchAssignments(forSlot: directory).map(\.value), [directory.path, "acct-1"])
        XCTAssertEqual(isolation.launchArguments(forSlot: directory), CodexSessionIsolation.slotArguments)
    }

    func testTheActiveAccountsSlotsReadWhicheverCopyLastsLongestOfItsOwnAccount() throws {
        let root = try temporaryDirectory()
        let live = root.appendingPathComponent("live", isDirectory: true)
        let managed = root.appendingPathComponent("managed", isDirectory: true)
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
        let service = CodexService(systemHome: live, cliIsRunning: { false })
        let older = Self.auth(account: "acct-1", expires: Date().addingTimeInterval(600))
        let newer = Self.auth(account: "acct-1", expires: Date().addingTimeInterval(7200))
        try older.write(to: managed.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)
        try newer.write(to: live.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)
        func token(_ text: String?) -> String? { text.flatMap(CodexService.accessToken(inAuth:)) }
        XCTAssertEqual(token(service.slotSourceCredential(codexHome: managed.path, isActive: false, reason: "test")), token(older))
        XCTAssertEqual(token(service.slotSourceCredential(codexHome: managed.path, isActive: true, reason: "test")), token(newer))
        XCTAssertEqual(token(try String(contentsOf: managed.appendingPathComponent("auth.json"), encoding: .utf8)), token(newer),
                       "the live copy Codex renewed becomes the managed copy, refresh token and all")
        try Self.auth(account: "acct-9", expires: Date().addingTimeInterval(9000))
            .write(to: live.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(token(service.slotSourceCredential(codexHome: managed.path, isActive: true, reason: "test")), token(newer),
                       "a live sign-in of another account is never served")
        XCTAssertTrue(CodexSessionIsolation.lasts(newer, for: 3600))
        XCTAssertFalse(CodexSessionIsolation.lasts(older, for: 3600))
    }

    // MARK: - Processes

    func testSlotProcessesAreMappedAndLeftOutOfAuthSwitchRestarts() {
        let root = "/Users/me/.accountdock/codex-slots"
        let list = """
        101 1 /Users/me/.local/bin/codex -c model_provider="accountdock" resume x ACCOUNTDOCK_CODEX_SLOT=\(root)/session/AAA TERM=xterm
        102 1 /Users/me/.local/bin/codex HOME=/Users/me
        """
        XCTAssertEqual(SessionSlots.directoriesByProcess(in: ProcessTable(listing: list, columns: .pidPPID), variable: isolation.directoryVariable, root: root),
                       [101: "\(root)/session/AAA"])
        XCTAssertFalse(CodexService.isRestartableCodexCommand(#"/Users/me/.local/bin/codex -c model_provider="accountdock" resume x"#))
        XCTAssertTrue(CodexService.isRestartableCodexCommand("/Users/me/.local/bin/codex resume x"))
    }

    // MARK: - Moves

    private func session(_ id: String, event: String, pid: Int32?) throws -> AgentSession {
        var record: [String: Any] = ["sessionID": id, "event": event]
        if let pid { record["processID"] = pid }
        return try JSONDecoder().decode(AgentSession.self, from: JSONSerialization.data(withJSONObject: record))
    }

    func testCodexMovesByRestartingOnlyIdleUnpinnedSessions() {
        let (a, b) = (UUID(), UUID())
        XCTAssertTrue(AIProviderType.codex.capabilities.sessionMovesNeedRestart)
        XCTAssertFalse(AIProviderType.claudeCode.capabilities.sessionMovesNeedRestart)
        XCTAssertFalse(AIProviderType.kimi.capabilities.sessionMovesNeedRestart)
        XCTAssertEqual(AppState.slotMove(current: a, target: b, needsRestart: true, pinned: false, idle: true, working: false), .restart)
        XCTAssertEqual(AppState.slotMove(current: a, target: b, needsRestart: true, pinned: false, idle: false, working: false), .wait,
                       "not yet stopped")
        XCTAssertEqual(AppState.slotMove(current: a, target: b, needsRestart: true, pinned: false, idle: true, working: true), .wait,
                       "mid-turn")
        XCTAssertEqual(AppState.slotMove(current: a, target: b, needsRestart: true, pinned: true, idle: true, working: false), .wait,
                       "pinned")
        XCTAssertEqual(AppState.slotMove(current: a, target: a, needsRestart: true, pinned: false, idle: true, working: false), .none)
        XCTAssertEqual(AppState.slotMove(current: a, target: b, needsRestart: false, pinned: false, idle: false, working: true), .rewrite)
    }

    func testARestartTypesCodexsExitThenItsResume() async throws {
        let terminal = FakeTerminal(sessions: [42: "agt-1"], screens: ["› \n  gpt-5.6-sol default · ~/work\n"])
        let idle = try session("019a-abc", event: "Stop", pid: 42)
        let outcome = await SessionTerminalActions.restartInOwnSlot(idle, isolation: isolation, terminal: terminal, pause: 0)
        XCTAssertEqual(outcome, .typed)
        XCTAssertEqual(terminal.log.map(\.text),
                       ["/exit", SessionTerminalCommand.enter, "codex resume '019a-abc'", SessionTerminalCommand.enter])

        let working = try session("019a-abc", event: "UserPromptSubmit", pid: 42)
        let quiet = FakeTerminal(sessions: [42: "agt-1"])
        let notIdle = await SessionTerminalActions.restartInOwnSlot(working, isolation: isolation, terminal: quiet, pause: 0)
        XCTAssertEqual(notIdle, .notIdle)
        XCTAssertTrue(quiet.log.isEmpty, "nothing is typed mid-turn")
    }

    func testARestartWaitsWhileCodexReportsRunningWork() async throws {
        let footer = "› \n  1 background terminal running · /ps to view · /stop to close\n  gpt-5.6-sol default · ~/work\n"
        let terminal = FakeTerminal(sessions: [42: "agt-1"], screens: [footer])
        let outcome = await SessionTerminalActions.restartInOwnSlot(try session("s", event: "Stop", pid: 42),
                                                                    isolation: isolation, terminal: terminal, pause: 0)
        XCTAssertEqual(outcome, .busy)
        XCTAssertTrue(terminal.log.isEmpty)
        XCTAssertTrue(isolation.screenReportsRunningWork("• Working (3s • esc to interrupt)\n"))
        XCTAssertFalse(isolation.screenReportsRunningWork("No background terminals running.\n" + String(repeating: "x\n", count: 9)))
        XCTAssertFalse(isolation.screenAsksAboutRunningWork(footer))
    }

    func testARestartThatCannotBeMadeIsRecordedButWaitingIsNot() {
        XCTAssertNil(AppState.slotRestartEvent(.notIdle, session: "s", to: "B", why: "x"))
        XCTAssertNil(AppState.slotRestartEvent(.busy, session: "s", to: "B", why: "x"))
        XCTAssertNotNil(AppState.slotRestartEvent(.notInTerminal, session: "s", to: "B", why: "x"))
    }

    func testARestartMoveCostsThePacerMoreThanARewrite() {
        let account = SessionPacer.Account(id: UUID(), utilization: 10, resetsAt: nil, burnPerHour: 0, baseWeight: 1)
        let rewrite = SessionPacer().moveCost(100_000, to: account)
        let restart = SessionPacer(moveCostFactor: AIProviderType.codex.capabilities.sessionMoveCostFactor).moveCost(100_000, to: account)
        XCTAssertEqual(restart, rewrite * 3, accuracy: 1e-9)
        XCTAssertEqual(AIProviderType.kimi.capabilities.sessionMoveCostFactor, 1)
    }
}
