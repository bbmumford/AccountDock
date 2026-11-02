import XCTest
@testable import AccountDock

final class ProviderRequestHoldTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testAProviderPathSplitsIntoItsKeyAndUpstreamPath() {
        XCTAssertEqual(ProviderPassthrough.split("/__provider/kimi/chat/completions?x=1")?.key, "kimi")
        XCTAssertEqual(ProviderPassthrough.split("/__provider/kimi/chat/completions?x=1")?.rest, "/chat/completions?x=1")
        XCTAssertEqual(ProviderPassthrough.split("/__provider/kimi")?.rest, "/")
        XCTAssertNil(ProviderPassthrough.split("/v1/messages"))
        XCTAssertNil(ProviderPassthrough.split("/__provider/../x"))
        let entry = ProviderPassthrough.Entry(upstream: "https://api.kimi.ai/coding/v1/", sessionField: "prompt_cache_key")
        XCTAssertEqual(ProviderPassthrough.upstreamURL(entry, rest: "/chat/completions")?.absoluteString,
                       "https://api.kimi.ai/coding/v1/chat/completions")
    }

    func testTheSessionIsReadFromTheRequestBody() {
        let body = Data(#"{"model":"k3","stream":true,"prompt_cache_key":"session_81c9-ab"}"#.utf8)
        XCTAssertEqual(ProviderPassthrough.sessionID(body, field: "prompt_cache_key"), "session_81c9-ab")
        XCTAssertTrue(ProviderPassthrough.isStreaming(body))
        XCTAssertNil(ProviderPassthrough.sessionID(Data(#"{"prompt_cache_key":"a/b"}"#.utf8), field: "prompt_cache_key"))
    }

    func testARequestIsHeldByTheRuleTheGateApplies() throws {
        XCTAssertFalse(ProviderPassthrough.isHeld(key: "kimi", session: "s", directory: directory), "no pause, no hold")
        AgentPauseGate.write(.init(sessions: ["listed"], reason: "limit", pausedAt: Date(), resumeAt: nil), for: .kimi, directory: directory)
        XCTAssertTrue(ProviderPassthrough.isHeld(key: "kimi", session: "listed", directory: directory))
        XCTAssertFalse(ProviderPassthrough.isHeld(key: "kimi", session: "other", directory: directory), "only listed sessions without the flag")
        AgentPauseGate.write(.init(sessions: [], reason: "limit", pausedAt: Date(), resumeAt: nil, holdsNewTurns: true), for: .kimi, directory: directory)
        XCTAssertTrue(ProviderPassthrough.isHeld(key: "kimi", session: "other", directory: directory))
        XCTAssertTrue(ProviderPassthrough.isHeld(key: "kimi", session: nil, directory: directory))

        AgentPauseGate.allowStep(.kimi, session: "other", directory: directory)
        XCTAssertTrue(ProviderPassthrough.takeAllowance(key: "kimi", session: "other", directory: directory))
        XCTAssertFalse(ProviderPassthrough.takeAllowance(key: "kimi", session: "other", directory: directory), "one step only")

        AgentPauseGate.resume(.kimi, session: "other", directory: directory)
        XCTAssertFalse(ProviderPassthrough.isHeld(key: "kimi", session: "other", directory: directory), "a resumed session goes on")
        AgentPauseGate.release(.kimi, directory: directory)
        XCTAssertFalse(ProviderPassthrough.isHeld(key: "kimi", session: "listed", directory: directory))
    }

    func testAWaitingMarkerIsWrittenOnlyWhenTheGateKeepsNone() throws {
        let marker = try XCTUnwrap(ProviderPassthrough.markWaiting(key: "kimi", session: "s", directory: directory))
        XCTAssertTrue(AgentPauseGate.waitingSessions(.kimi, directory: directory).contains("s"))
        XCTAssertNil(ProviderPassthrough.markWaiting(key: "kimi", session: "s", directory: directory))
        try FileManager.default.removeItem(at: marker)
    }

    func testAnErrorAfterAHeldStreamIsAnEvent() throws {
        let event = String(decoding: ProviderPassthrough.streamError(status: 429, body: Data(#"{"error":{"message":"limit"}}"#.utf8)), as: UTF8.self)
        XCTAssertTrue(event.hasPrefix("data: "))
        XCTAssertTrue(event.hasSuffix("\n\n"))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(event.dropFirst(6).utf8)) as? [String: Any])
        let error = try XCTUnwrap(json["error"] as? [String: Any])
        XCTAssertEqual(error["message"] as? String, "limit")
        XCTAssertEqual(error["code"] as? Int, 429)
    }

    func testTheBaseURLIsSetAndRestoredInItsTableOnly() throws {
        let url = directory.appendingPathComponent("config.toml")
        let original = """
        default_model = "kimi-code/k3"

        [providers."managed:kimi-code"]
        type = "kimi"
        api_key = ""
        base_url = "https://api.kimi.ai/coding/v1"

        [providers."managed:kimi-code".oauth]
        storage = "file"

        [providers.other]
        base_url = "https://example.invalid"
        """
        try original.write(to: url, atomically: true, encoding: .utf8)
        let table = #"providers."managed:kimi-code""#
        XCTAssertEqual(TOMLHookConfig.value(at: url, table: table, key: "base_url"), "https://api.kimi.ai/coding/v1")
        try TOMLHookConfig.setValue(at: url, table: table, key: "base_url", value: "http://127.0.0.1:47321/__provider/kimi", comment: "# accountdock-router")
        XCTAssertEqual(TOMLHookConfig.value(at: url, table: table, key: "base_url"), "http://127.0.0.1:47321/__provider/kimi")
        XCTAssertEqual(TOMLHookConfig.value(at: url, table: "providers.other", key: "base_url"), "https://example.invalid")
        try TOMLHookConfig.setValue(at: url, table: table, key: "base_url", value: "https://api.kimi.ai/coding/v1", comment: nil)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original, "restoring gives back the file as it was")
        XCTAssertThrowsError(try TOMLHookConfig.setValue(at: url, table: "providers.missing", key: "base_url", value: "x", comment: nil))
    }

    func testKimiIsNeverPointedAtTheRouter() {
        // Kimi Code drops its sign-in for a base URL outside its own hosts.
        XCTAssertEqual(AIProviderType.kimi.capabilities.requestHold?.keepsCredentialAtRouter, false)
    }
}
