import XCTest
@testable import AccountDock

/// Counts the requests a fake token endpoint answers.
private final class FakeEndpoint: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    let status: Int
    let body: Data
    let headers: [String: String]
    let delay: UInt64

    init(status: Int, body: String = "{}", headers: [String: String] = [:], delayMilliseconds: UInt64 = 0) {
        self.status = status
        self.body = Data(body.utf8)
        self.headers = headers
        delay = delayMilliseconds
    }

    var count: Int { lock.withLock { requests.count } }

    var client: CredentialRenewalClient {
        CredentialRenewalClient(send: { [self] request in
            lock.withLock { requests.append(request) }
            if delay > 0 { try await Task.sleep(nanoseconds: delay * 1_000_000) }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
            return (body, response)
        })
    }
}

final class CredentialRenewalClientTests: XCTestCase {
    private func response(_ status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://example.invalid")!, statusCode: status, httpVersion: nil, headerFields: headers)!
    }

    func testEachProvidersRequestIsWrittenAsItsEndpointDescribes() throws {
        let claude = try CredentialRenewalClient.request(ClaudeService.tokenEndpoint, refreshToken: "r-1")
        XCTAssertEqual(claude.httpMethod, "POST")
        XCTAssertEqual(claude.timeoutInterval, 30)
        XCTAssertEqual(claude.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertEqual(claude.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(String(decoding: try XCTUnwrap(claude.httpBody), as: UTF8.self),
                       "client%5Fid=9d1c250a%2De61b%2D44d9%2D88ed%2D5944d1962f5e&grant%5Ftype=refresh%5Ftoken&refresh%5Ftoken=r%2D1")

        let codex = try CredentialRenewalClient.request(CodexService.tokenEndpoint, refreshToken: "r-2")
        XCTAssertEqual(codex.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(codex.httpBody)) as? [String: String])
        XCTAssertEqual(fields, ["client_id": "app_EMoamEEZ73f0CkXaXp7hrann", "grant_type": "refresh_token",
                                "refresh_token": "r-2", "scope": "openid profile email"])
    }

    func testARefusedGrantIsToldApartFromEveryTransientFailure() {
        func failure(_ endpoint: TokenEndpoint, _ status: Int, _ body: String = "{}",
                     headers: [String: String] = [:]) -> CredentialRenewalFailure? {
            CredentialRenewalClient.failure(endpoint, response: response(status, headers: headers), body: Data(body.utf8))
        }
        func refused(_ failure: CredentialRenewalFailure?) -> Bool {
            if case .refused = failure { true } else { false }
        }
        let claude = ClaudeService.tokenEndpoint
        XCTAssertNil(failure(claude, 200))
        XCTAssertTrue(refused(failure(claude, 401)))
        XCTAssertTrue(refused(failure(claude, 400, #"{"error":"invalid_grant"}"#)))
        XCTAssertFalse(refused(failure(claude, 400, #"{"error":"invalid_request"}"#)))
        guard case .status(429)? = failure(claude, 429) else { return XCTFail("Claude's throttling is a transient status") }

        let codex = CodexService.tokenEndpoint
        XCTAssertTrue(refused(failure(codex, 400)))
        XCTAssertTrue(refused(failure(codex, 401)))
        guard case .throttled(let retryAt)? = failure(codex, 429, headers: ["Retry-After": "120"]) else {
            return XCTFail("Codex's 429 is throttling")
        }
        XCTAssertNotNil(retryAt)
        guard case .status(503)? = failure(codex, 503) else { return XCTFail("a server error is transient") }

        var kimi = TokenEndpoint(url: URL(string: "https://auth.example.invalid/api/oauth/token")!, encoding: .form,
                                 fields: [:], refusesGrant: TokenEndpoint.badRequestOrUnauthorizedRefuses)
        kimi.accepted = 200...200
        guard case .status(201)? = failure(kimi, 201) else { return XCTFail("only 200 carries Kimi's credential") }

        XCTAssertEqual(CredentialRenewalClient.auditOutcome(CredentialRenewalFailure.refused), "rejected")
        XCTAssertEqual(CredentialRenewalClient.auditOutcome(CredentialRenewalFailure.status(500)), "unavailable")
        XCTAssertEqual(CredentialRenewalClient.auditOutcome(URLError(.timedOut), refused: { $0 is URLError }), "rejected")
    }

    func testASuccessfulReplysBodyIsReturnedAndATransportFailureSaysSo() async throws {
        let ok = FakeEndpoint(status: 200, body: #"{"access_token":"a"}"#)
        let body = try await ok.client.exchange(CodexService.tokenEndpoint, refreshToken: "r-\(UUID().uuidString)")
        XCTAssertEqual(String(decoding: body, as: UTF8.self), #"{"access_token":"a"}"#)

        let offline = CredentialRenewalClient(send: { _ in throw URLError(.notConnectedToInternet) })
        do {
            _ = try await offline.exchange(CodexService.tokenEndpoint, refreshToken: "r-\(UUID().uuidString)")
            XCTFail("a failed request must throw")
        } catch CredentialRenewalFailure.transport(let error) {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
    }

    /// Two renewals presenting one refresh token at once send it once and
    /// share the reply: a provider that rotates refresh tokens would refuse
    /// the second.
    func testOneRefreshTokenIsPresentedOnceAtATime() async throws {
        let endpoint = FakeEndpoint(status: 200, body: #"{"access_token":"a"}"#, delayMilliseconds: 300)
        let client = endpoint.client
        let token = "r-\(UUID().uuidString)"
        async let first = client.exchange(CodexService.tokenEndpoint, refreshToken: token)
        async let second = client.exchange(CodexService.tokenEndpoint, refreshToken: token)
        let replies = try await [first, second]
        XCTAssertEqual(replies[0], replies[1])
        XCTAssertEqual(endpoint.count, 1)
        _ = try await client.exchange(CodexService.tokenEndpoint, refreshToken: "r-\(UUID().uuidString)")
        XCTAssertEqual(endpoint.count, 2, "another token is its own renewal")
    }

    func testEveryRenewalIsRecordedWithItsOutcome() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RenewalAudit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let audit = CredentialAudit(directory: directory)
        let subject = CredentialRenewalClient.AuditSubject(provider: .codex, location: "/managed/a")
        let renewed = try await audit.recordingRenewal(subject, presented: .accessToken("old"), reason: "test",
                                                       received: { .accessToken($0) }) { "new" }
        XCTAssertEqual(renewed, "new")
        do {
            _ = try await audit.recordingRenewal(subject, presented: .accessToken("new"), reason: "test",
                                                 received: { (_: String) in nil }) {
                throw CredentialRenewalFailure.refused
            }
            XCTFail("the failure is rethrown")
        } catch CredentialRenewalFailure.refused {}
        let entries = audit.entries().filter { $0.action == .renewal }
        XCTAssertEqual(entries.map(\.outcome), ["renewed", "rejected"])
        XCTAssertEqual(entries.map(\.provider), [AIProviderType.codex.rawValue, AIProviderType.codex.rawValue])
        XCTAssertEqual(entries.first?.fingerprint, CredentialAudit.fingerprint(ofAccessToken: "new"))
        XCTAssertEqual(entries.first?.previousFingerprint, CredentialAudit.fingerprint(ofAccessToken: "old"))
    }
}
