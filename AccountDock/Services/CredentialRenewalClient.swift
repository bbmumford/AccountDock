import Foundation

/// A provider's OAuth token endpoint, as its service describes it
/// (`ClaudeService.tokenEndpoint`, `CodexService.tokenEndpoint`,
/// `KimiService.tokenEndpoint`), for `CredentialRenewalClient`.
struct TokenEndpoint: Sendable {
    /// How the request body is written.
    enum Encoding: Sendable {
        /// `application/x-www-form-urlencoded`, fields in name order.
        case form
        /// A JSON object.
        case json
    }

    var url: URL
    var encoding: Encoding
    /// Sent with `grant_type=refresh_token` and the refresh token.
    var fields: [String: String]
    var headers: [String: String] = [:]
    /// The request's time limit; nil leaves the session's.
    var timeout: TimeInterval?
    /// Whether a failed reply refuses the grant itself: the refresh token
    /// is dead and the account needs signing in again. Any other failure
    /// leaves the stored credential usable later.
    var refusesGrant: @Sendable (_ status: Int, _ body: Data) -> Bool
    /// Statuses that mean the provider is throttling renewals, answered
    /// with the reply's `Retry-After`; other failures carry their status.
    var throttledStatuses: Set<Int> = []
    /// The statuses that carry a renewed credential.
    var accepted: ClosedRange<Int> = 200...299

    /// A refused grant answered with 400 or 401, as Codex and Kimi answer
    /// one; any other failure says nothing about the refresh token.
    static let badRequestOrUnauthorizedRefuses: @Sendable (Int, Data) -> Bool = { status, _ in
        status == 400 || status == 401
    }
}

/// Why a renewal did not give a credential.
enum CredentialRenewalFailure: Error {
    /// The provider refused the grant (`TokenEndpoint.refusesGrant`).
    case refused
    /// The provider is throttling renewals until `retryAt`, when it says.
    case throttled(retryAt: Date?)
    /// Any other reply that is no success.
    case status(Int)
    /// The request did not complete.
    case transport(any Error)
}

/// The one client for every provider's OAuth token renewal: it writes the
/// refresh-token request a `TokenEndpoint` describes, sends it, classifies
/// the reply (`CredentialRenewalFailure`: a refused grant apart from every
/// transient failure), runs the renewals of one credential one after another
/// (`SingleFlight`), and records each attempt in the credential audit with
/// the outcome the classification gives. Each provider's service reads the
/// renewed credential from the reply's body and keeps it where it belongs.
struct CredentialRenewalClient: Sendable {
    /// Sends one request; replaced in tests.
    var send: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }

    /// The request presenting `refreshToken` to `endpoint`.
    static func request(_ endpoint: TokenEndpoint, refreshToken: String) throws -> URLRequest {
        var request = URLRequest(url: endpoint.url)
        request.httpMethod = "POST"
        if let timeout = endpoint.timeout { request.timeoutInterval = timeout }
        var fields = endpoint.fields
        fields["grant_type"] = "refresh_token"
        fields["refresh_token"] = refreshToken
        switch endpoint.encoding {
        case .form:
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(fields.map { "\(formEncode($0.key))=\(formEncode($0.value))" }.sorted()
                .joined(separator: "&").utf8)
        case .json:
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        }
        for (name, value) in endpoint.headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    /// Presents `refreshToken` to `endpoint` and returns the body of a
    /// successful reply; throws a `CredentialRenewalFailure` otherwise. A
    /// renewal asked for while another presenting the same refresh token to
    /// the same endpoint is under way waits for that one's reply rather
    /// than presenting the token again: providers that rotate refresh
    /// tokens refuse a token presented twice, which would mark the account
    /// as needing sign-in.
    func exchange(_ endpoint: TokenEndpoint, refreshToken: String) async throws -> Data {
        let request = try Self.request(endpoint, refreshToken: refreshToken)
        let key = endpoint.url.absoluteString + "|" + CredentialAudit.fingerprint(ofAccessToken: refreshToken)
        let send = self.send
        return try await Self.inFlight.run(key) {
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await send(request)
            } catch {
                throw CredentialRenewalFailure.transport(error)
            }
            if let failure = Self.failure(endpoint, response: response, body: data) { throw failure }
            return data
        }
    }

    /// The renewals under way, shared by every client.
    private static let inFlight = InFlight()

    /// One task per key while it runs; a caller asking for a running key
    /// gets that task's result.
    private actor InFlight {
        private var running: [String: Task<Data, Error>] = [:]

        func run(_ key: String, _ operation: @escaping @Sendable () async throws -> Data) async throws -> Data {
            if let task = running[key] { return try await task.value }
            let task = Task { try await operation() }
            running[key] = task
            defer { running[key] = nil }
            return try await task.value
        }
    }

    /// How a reply fails, or nil when it carries a credential.
    static func failure(_ endpoint: TokenEndpoint, response: URLResponse, body: Data) -> CredentialRenewalFailure? {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if endpoint.accepted.contains(status) { return nil }
        if endpoint.refusesGrant(status, body) { return .refused }
        if endpoint.throttledStatuses.contains(status) { return .throttled(retryAt: RetryAfter.date(in: response)) }
        return .status(status)
    }

    /// The audit outcome of a failed renewal: `rejected` when the grant was
    /// refused, else `unavailable`; `refused` names a provider's own errors
    /// that mean the same.
    static func auditOutcome(_ error: Error, refused: (Error) -> Bool = { _ in false }) -> String {
        if case CredentialRenewalFailure.refused = error { return "rejected" }
        return refused(error) ? "rejected" : "unavailable"
    }

    /// What one renewal is recorded under in the audit.
    struct AuditSubject {
        var provider: AIProviderType
        var account: UUID?
        var location: String?
        var live = false
    }

    /// The token a renewal presented or received, as the audit takes it.
    enum AuditToken {
        /// A whole credential document, whose access token and plan fields
        /// the audit reads.
        case credential(String)
        case accessToken(String)
    }

    private static func formEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }

    /// Runs the operations given for one key one after another, in the
    /// order they arrive; operations for different keys run at the same
    /// time. `KimiService` keys the renewals of each managed credential by
    /// it, so the one that waited reads the credential the first left
    /// before presenting its own refresh token.
    actor Queue {

        private var last: [String: Task<Void, Never>] = [:]

        func run<T: Sendable>(_ key: String, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
            let previous = last[key]
            let task = Task<T, Error> {
                await previous?.value
                return try await operation()
            }
            last[key] = Task { _ = try? await task.value }
            return try await task.value
        }
    }
}

/// How every provider's renewal is written to the credential audit, so each
/// entry has the same shape and the same outcomes: `renewed`, `rejected` for
/// a refused grant, `unavailable` for any other failure, or the provider's
/// reason for not presenting a token at all.
extension CredentialAudit {
    /// Records one renewal entry: of `subject`, by `reason`, with the token
    /// it received (`token`) and the one it presented (`previous`).
    func recordRenewal(_ subject: CredentialRenewalClient.AuditSubject, token: CredentialRenewalClient.AuditToken?,
                       previous: CredentialRenewalClient.AuditToken?, outcome: String, reason: String) {
        func credential(_ token: CredentialRenewalClient.AuditToken?) -> String? {
            if case .credential(let text) = token { text } else { nil }
        }
        func accessToken(_ token: CredentialRenewalClient.AuditToken?) -> String? {
            if case .accessToken(let text) = token { text } else { nil }
        }
        record(.renewal, subject.provider, account: subject.account, location: subject.location, live: subject.live,
               credential: credential(token), accessToken: accessToken(token),
               previousCredential: credential(previous), previousAccessToken: accessToken(previous),
               outcome: outcome, reason: reason)
    }

    /// Runs `renew`, which presents `presented`, and records it as a
    /// renewal of `subject` by `reason`, whatever its outcome: `renewed`
    /// with the token `received` names, or the outcome
    /// `CredentialRenewalClient.auditOutcome` gives the error, which is
    /// rethrown.
    func recordingRenewal<T>(_ subject: CredentialRenewalClient.AuditSubject,
                             presented: CredentialRenewalClient.AuditToken?, reason: String,
                             refused: (Error) -> Bool = { _ in false },
                             received: (T) -> CredentialRenewalClient.AuditToken?,
                             _ renew: () async throws -> T) async throws -> T {
        do {
            let value = try await renew()
            recordRenewal(subject, token: received(value), previous: presented, outcome: "renewed", reason: reason)
            return value
        } catch {
            recordRenewal(subject, token: presented, previous: nil,
                          outcome: CredentialRenewalClient.auditOutcome(error, refused: refused), reason: reason)
            throw error
        }
    }
}

