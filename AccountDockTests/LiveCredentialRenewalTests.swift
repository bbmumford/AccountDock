import XCTest
@testable import AccountDock

/// Answers every request the shared URL session makes during a test, so no
/// request leaves the machine; `reply` gives the status and headers per URL.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var reply: (URL) -> (status: Int, headers: [String: String], body: Data) = { _ in
        (599, [:], Data())
    }
    nonisolated(unsafe) static var requested: [URL] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        Self.requested.append(url)
        let answer = Self.reply(url)
        let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: answer.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class LiveCredentialRenewalTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveCredentialRenewalTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        StubURLProtocol.reply = { _ in (599, [:], Data()) }
        StubURLProtocol.requested = []
        URLProtocol.registerClass(StubURLProtocol.self)
    }

    override func tearDownWithError() throws {
        URLProtocol.unregisterClass(StubURLProtocol.self)
        try? FileManager.default.removeItem(at: root)
    }

    private func directory(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    // MARK: Codex

    /// An unsigned JWT whose `exp` is `expiry`, which is all the reader
    /// decodes from it.
    private func jwt(expiring expiry: Date) -> String {
        let payload = Data(#"{"exp":\#(Int(expiry.timeIntervalSince1970))}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        return "e30.\(payload).sig"
    }

    private func codexAuth(expiring expiry: Date) -> String {
        #"{"tokens":{"access_token":"\#(jwt(expiring: expiry))","refresh_token":"refresh-1","account_id":"acct"}}"#
    }

    func testCodexLeavesTheLiveCredentialToARunningCodex() async throws {
        let system = try directory("codex")
        let auth = system.appendingPathComponent("auth.json")
        try write(codexAuth(expiring: Date().addingTimeInterval(-60)), to: auth)
        let before = try Data(contentsOf: auth)
        let service = CodexService(systemHome: system, cliIsRunning: { true })

        do {
            _ = try await service.getUsageSnapshot(codexHome: nil)
            XCTFail("the expired live credential must not be renewed here")
        } catch CodexServiceError.liveCredentialExpired {
        }
        XCTAssertEqual(try Data(contentsOf: auth), before)
        XCTAssertEqual(StubURLProtocol.requested, [], "no renewal is attempted")
    }

    func testCodexStillRenewsAnotherAccountsCopyWhileCodexRuns() async throws {
        let managed = try directory("managed")
        try write(codexAuth(expiring: Date().addingTimeInterval(-60)), to: managed.appendingPathComponent("auth.json"))
        StubURLProtocol.reply = { url in url.host == "auth.openai.com" ? (401, [:], Data()) : (599, [:], Data()) }
        let service = CodexService(systemHome: try directory("codex"), cliIsRunning: { true })

        do {
            _ = try await service.getUsageSnapshot(codexHome: managed.path)
            XCTFail("the stub refuses the renewal")
        } catch CodexServiceError.credentialRejected {
        }
        XCTAssertEqual(StubURLProtocol.requested.map(\.host), ["auth.openai.com"])
    }

    func testCodexPassesOnTheTimeAThrottledReadingMayRetry() async throws {
        let managed = try directory("managed")
        try write(codexAuth(expiring: Date().addingTimeInterval(3600)), to: managed.appendingPathComponent("auth.json"))
        StubURLProtocol.reply = { url in
            url.host == "chatgpt.com" ? (429, ["Retry-After": "120"], Data()) : (599, [:], Data())
        }
        let service = CodexService(systemHome: try directory("codex"), cliIsRunning: { false })

        do {
            _ = try await service.getUsageSnapshot(codexHome: managed.path)
            XCTFail("the stub throttles the reading")
        } catch CodexServiceError.rateLimited(let retryAt) {
            let wait = try XCTUnwrap(retryAt).timeIntervalSinceNow
            XCTAssertEqual(wait, 120, accuracy: 10)
        }
    }

    // MARK: Kimi

    private struct KimiFiles {
        let service: KimiService
        let managed: URL
        let slot: URL
    }

    private func kimi(expiring expiry: Date, cliIsRunning: Bool) throws -> KimiFiles {
        let home = try directory("kimi-code")
        try write("[providers.\"managed:kimi-code\".oauth]\nstorage = \"file\"\nkey = \"oauth/kimi-code\"\n",
                  to: home.appendingPathComponent("config.toml"))
        let credential = #"{"access_token":"access","refresh_token":"refresh","expires_at":\#(expiry.timeIntervalSince1970)}"#
        let slot = home.appendingPathComponent("credentials/kimi-code.json")
        let managed = root.appendingPathComponent("managed/account/credentials.json")
        try write(credential, to: slot)
        try write(credential, to: managed)
        let service = KimiService(home: home, managedRoot: try directory("managed"), cliIsRunning: { cliIsRunning })
        return KimiFiles(service: service, managed: managed, slot: slot)
    }

    func testKimiLeavesTheActiveCredentialToARunningKimiCode() async throws {
        let files = try kimi(expiring: Date().addingTimeInterval(-60), cliIsRunning: true)
        let slotBefore = try Data(contentsOf: files.slot), managedBefore = try Data(contentsOf: files.managed)

        do {
            _ = try await files.service.getUsageLimits(location: files.managed.path, isActive: true)
            XCTFail("the expired live credential must not be renewed here")
        } catch KimiServiceError.liveCredentialExpired {
        }
        do {
            _ = try await files.service.freshAccessToken(location: files.managed.path, isActive: true, minimumLifetime: 60)
            XCTFail("the router's token must not renew the live credential either")
        } catch KimiServiceError.liveCredentialExpired {
        }
        XCTAssertEqual(try Data(contentsOf: files.slot), slotBefore)
        XCTAssertEqual(try Data(contentsOf: files.managed), managedBefore)
        XCTAssertEqual(StubURLProtocol.requested, [])
    }

    func testAKimiUsageReadRefusedWith401IsACredentialProblem() async throws {
        let files = try kimi(expiring: Date().addingTimeInterval(3600), cliIsRunning: true)
        StubURLProtocol.reply = { url in
            switch url.host {
            case "api.kimi.ai": (401, [:], Data())
            case "auth.kimi.ai": (401, [:], Data())
            default: (599, [:], Data())
            }
        }

        do {
            _ = try await files.service.getUsageLimits(location: files.managed.path, isActive: true)
            XCTFail("a refused reading must fail")
        } catch KimiServiceError.liveCredentialExpired {
        }

        let idle = KimiService(home: try directory("kimi-code"), managedRoot: try directory("managed"), cliIsRunning: { false })
        do {
            _ = try await idle.getUsageLimits(location: files.managed.path, isActive: false)
            XCTFail("a refused reading must fail")
        } catch KimiServiceError.credentialRejected {
        }
    }

    // MARK: Process scan

    func testTheProcessScanFindsTheProvidersCLIOnly() {
        let listing = """
          101 /usr/bin/vim notes-about-codex.txt
          202 /Users/me/.local/bin/codex resume 0199
          303 /Users/me/.kimi-code/bin/kimi
        """
        XCTAssertTrue(CLIProcessScan.isRunning(.codex, inListing: listing, excluding: 1))
        XCTAssertTrue(CLIProcessScan.isRunning(.kimi, inListing: listing, excluding: 1))
        XCTAssertFalse(CLIProcessScan.isRunning(.codex, inListing: listing, excluding: 202))
        XCTAssertFalse(CLIProcessScan.isRunning(.claudeCode, inListing: listing, excluding: 1))
    }
}
