import XCTest
@testable import AccountDock

/// Where the router sends a Codex request it does not bridge.
final class CodexBridgeTests: XCTestCase {
    private let chatGPT = "https://chatgpt.com/backend-api/codex"
    private let openAI = "https://api.openai.com/v1"
    private let signIn = [("Authorization", "Bearer eyJhbGciOiJub25lIn0.eyJleHAiOjF9.sig"), ("ChatGPT-Account-ID", "acct-1")]
    private let apiKey = [("Authorization", "Bearer sk-test-not-a-real-key")]

    private var hold: RequestHoldSupport { AIProviderType.codex.capabilities.requestHold! }

    // MARK: - Upstream by credential

    func testASignInGoesToTheChatGPTEndpointAndAnAPIKeyToTheOpenAIAPI() {
        let entry = ProviderRequestHold.entry(hold, upstream: hold.defaultUpstream)
        XCTAssertEqual(entry.apiKeyUpstream, openAI)
        XCTAssertEqual(ProviderPassthrough.clientAuth(signIn), .signIn)
        XCTAssertEqual(ProviderPassthrough.clientAuth(apiKey), .apiKey)
        XCTAssertEqual(ProviderPassthrough.clientAuth([("Authorization", "Bearer eyJa.eyJb.c")]), .signIn, "a JWT without the header")
        XCTAssertEqual(ProviderPassthrough.upstreamURL(entry, rest: "/responses", headers: signIn)?.absoluteString,
                       chatGPT + "/responses")
        XCTAssertEqual(ProviderPassthrough.upstreamURL(entry, rest: "/responses", headers: apiKey)?.absoluteString,
                       openAI + "/responses")
        XCTAssertEqual(ProviderPassthrough.upstreamURL(entry, rest: "/models?client_version=1", headers: apiKey)?.absoluteString,
                       openAI + "/models?client_version=1")
    }

    func testABaseURLTheUserSetTakesEveryRequest() {
        let entry = ProviderRequestHold.entry(hold, upstream: "https://proxy.example/v1")
        XCTAssertNil(entry.apiKeyUpstream)
        XCTAssertEqual(ProviderPassthrough.upstreamURL(entry, rest: "/responses", headers: apiKey)?.absoluteString,
                       "https://proxy.example/v1/responses")
        XCTAssertEqual(ProviderPassthrough.upstreamURL(entry, rest: "/responses", headers: signIn)?.absoluteString,
                       "https://proxy.example/v1/responses")
    }

    func testAnEntryRecordedBeforeAPIKeyUpstreamsSendsEverythingToItsUpstream() throws {
        let data = Data(#"{"codex":{"upstream":"https://chatgpt.com/backend-api/codex","sessionField":"prompt_cache_key"}}"#.utf8)
        let entry = try XCTUnwrap(RouterConfig.decoder().decode([String: ProviderPassthrough.Entry].self, from: data)["codex"])
        XCTAssertNil(entry.apiKeyUpstream)
        XCTAssertEqual(ProviderPassthrough.upstream(entry, headers: apiKey), chatGPT)
    }
}
