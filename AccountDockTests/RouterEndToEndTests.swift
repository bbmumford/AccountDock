import XCTest
@testable import AccountDock

/// Codex requests through a whole router (`RouterService` behind its HTTP
/// listener) on a temporary directory and port, to fake upstreams on
/// local listeners: no real credential, endpoint or router is involved.
final class RouterEndToEndTests: XCTestCase {
    /// What a fake upstream received.
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var received: [HTTPRequest] = []
        func add(_ request: HTTPRequest) { lock.withLock { received.append(request) } }
        var requests: [HTTPRequest] { lock.withLock { received } }
    }

    private final class ServiceBox: @unchecked Sendable { var service: RouterService? }

    private var listeners: [RouterListener] = []
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("router-e2e-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Router", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        listeners.forEach { $0.cancel() }
        listeners = []
    }

    /// A local listener answering with `handler`; its port.
    private func listen(_ handler: @escaping ClientConnection.Handler) throws -> UInt16 {
        let listener = try RouterListener(port: 0, handler: handler)
        listeners.append(listener)
        return try XCTUnwrap(listener.startAndWait(), "the listener started")
    }

    /// A router on the test directory and its own port.
    private func startRouter() throws -> (service: RouterService, port: UInt16) {
        let box = ServiceBox()
        let port = try listen { request, writer in await box.service?.handle(request, writer) }
        let service = RouterService(environment: RouterEnvironment(directory: directory, port: port,
                                                                   logURL: directory.appendingPathComponent("router.log")))
        box.service = service
        return (service, port)
    }

    /// A fake upstream that records each request and answers with `events`
    /// as a stream, one chunk each.
    private func fakeStream(_ recorder: Recorder, events: [String]) throws -> UInt16 {
        try listen { request, writer in
            recorder.add(request)
            await writer.head(200, [("Content-Type", "text/event-stream")])
            for event in events {
                await writer.chunk(Data(event.utf8))
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            await writer.finish()
        }
    }

    private func writePassthrough(_ entries: [String: ProviderPassthrough.Entry]) throws {
        try RouterConfig.encoder().encode(entries).write(to: directory.appendingPathComponent("passthrough.json"))
    }

    private func post(_ port: UInt16, path: String, headers: [(String, String)], body: [String: Any]) async throws -> (Int, String, String?) {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)\(path)")))
        request.httpMethod = "POST"
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        return (http.statusCode, String(decoding: data, as: UTF8.self), http.value(forHTTPHeaderField: "Content-Type"))
    }

    /// An unsigned token shaped like a ChatGPT sign-in's access token.
    private let signInToken = CodexSessionIsolationTests.token(account: "acct-1", expires: Date().addingTimeInterval(3600))

    private let codexRequest: [String: Any] = [
        "model": "gpt-5-codex", "stream": true, "prompt_cache_key": "thread-1",
        "input": [["type": "message", "role": "user", "content": [["type": "input_text", "text": "hello"]]]],
    ]

    func testAChatGPTSignInStreamsThroughTheRouterWithItsTokenAndAccount() async throws {
        let events = [
            "event: response.created\ndata: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_1\"}}\n\n",
            "event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"hi\"}\n\n",
            "event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\"}}\n\n",
        ]
        let chatGPT = Recorder(), api = Recorder()
        let chatGPTPort = try fakeStream(chatGPT, events: events)
        let apiPort = try fakeStream(api, events: ["data: {\"type\":\"response.completed\"}\n\n"])
        try writePassthrough(["codex": ProviderPassthrough.Entry(
            upstream: "http://127.0.0.1:\(chatGPTPort)/backend-api/codex", sessionField: "prompt_cache_key",
            holdsRequests: false, apiKeyUpstream: "http://127.0.0.1:\(apiPort)/v1")])
        let router = try startRouter()

        let (status, body, type) = try await post(router.port, path: "/__provider/codex/responses", headers: [
            ("Authorization", "Bearer \(signInToken)"), ("ChatGPT-Account-ID", "acct-1"), ("thread-id", "thread-1"),
        ], body: codexRequest)

        XCTAssertEqual(status, 200)
        XCTAssertEqual(type, "text/event-stream")
        XCTAssertEqual(body, events.joined(), "every event, in order, unchanged")
        let received = try XCTUnwrap(chatGPT.requests.first)
        XCTAssertEqual(chatGPT.requests.count, 1)
        XCTAssertTrue(api.requests.isEmpty, "a sign-in never reaches the API endpoint")
        XCTAssertEqual(received.method, "POST")
        XCTAssertEqual(received.target, "/backend-api/codex/responses")
        XCTAssertEqual(received.header("authorization"), "Bearer \(signInToken)")
        XCTAssertEqual(received.header("chatgpt-account-id"), "acct-1")
        XCTAssertEqual(received.header("thread-id"), "thread-1")
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: received.body) as? [String: Any])
        XCTAssertEqual(sent["prompt_cache_key"] as? String, "thread-1")
        XCTAssertEqual(sent["stream"] as? Bool, true)
    }

    func testAnAPIKeyGoesToTheOpenAIEndpointThroughTheRouter() async throws {
        let chatGPT = Recorder(), api = Recorder()
        let chatGPTPort = try fakeStream(chatGPT, events: ["data: {}\n\n"])
        let apiPort = try fakeStream(api, events: ["data: {\"type\":\"response.completed\"}\n\n"])
        try writePassthrough(["codex": ProviderPassthrough.Entry(
            upstream: "http://127.0.0.1:\(chatGPTPort)/backend-api/codex", sessionField: "prompt_cache_key",
            holdsRequests: false, apiKeyUpstream: "http://127.0.0.1:\(apiPort)/v1")])
        let router = try startRouter()

        let (status, body, _) = try await post(router.port, path: "/__provider/codex/responses",
                                               headers: [("Authorization", "Bearer sk-test-not-a-real-key")], body: codexRequest)

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body, "data: {\"type\":\"response.completed\"}\n\n")
        XCTAssertTrue(chatGPT.requests.isEmpty)
        XCTAssertEqual(api.requests.first?.target, "/v1/responses")
        XCTAssertEqual(api.requests.first?.header("authorization"), "Bearer sk-test-not-a-real-key")
    }

    func testARequestFromAWebPageIsRefused() async throws {
        let router = try startRouter()
        let (status, _, _) = try await post(router.port, path: "/__provider/codex/responses",
                                            headers: [("Origin", "https://example.com")], body: codexRequest)
        XCTAssertEqual(status, 403)
    }
}
