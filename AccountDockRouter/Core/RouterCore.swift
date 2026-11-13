import CryptoKit
import Foundation

/// State and decisions shared by the AccountDock app and the
/// `AccountDockRouter` helper.
///
/// Claude Code sends its API requests to the router (`ANTHROPIC_BASE_URL`).
/// The router speaks the Anthropic Messages protocol on both sides and knows
/// nothing about particular providers: every upstream is a `RouterBackend`
/// described by the app, so adding a provider means adding a backend entry.
///
/// - The primary backend serves requests unless the app routes elsewhere.
/// - A backend with an account pool serves each session from one of its
///   accounts, so several accounts' 5-hour windows are used at once.
/// - A fallback backend serves requests the primary refuses at a plan limit.
///
/// The app writes `RouterState` and pushes credentials over the control
/// endpoint; the router keeps credentials in memory only and writes events
/// and the usage it observes in response headers.
enum RouterConfig {
    /// `ACCOUNTDOCK_ROUTER_PORT` and `ACCOUNTDOCK_ROUTER_DIRECTORY` move a
    /// router started for testing away from the one Claude Code uses.
    static let port: UInt16 = ProcessInfo.processInfo.environment["ACCOUNTDOCK_ROUTER_PORT"].flatMap(UInt16.init) ?? 47_321
    static let version = "2"
    static var baseURL: String { "http://127.0.0.1:\(port)" }
    static let launchAgentLabel = "app.accountdock.router"

    static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["ACCOUNTDOCK_ROUTER_DIRECTORY"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AccountDock/Router", isDirectory: true)
    }
    static var stateURL: URL { directory.appendingPathComponent("state.json") }
    /// Earlier builds kept credentials here; the app removes the folder.
    static var legacyTokensDirectory: URL { directory.appendingPathComponent("tokens", isDirectory: true) }
    /// Random key the app creates; only a holder can push credentials.
    static var controlKeyURL: URL { directory.appendingPathComponent("control.key") }
    static let controlHeader = "X-AccountDock-Control"
    static var usageDirectory: URL { directory.appendingPathComponent("usage", isDirectory: true) }
    static var eventsURL: URL { directory.appendingPathComponent("events.jsonl") }
    static var signaturesURL: URL { directory.appendingPathComponent("signatures.txt") }
    static var logURL: URL {
        if ProcessInfo.processInfo.environment["ACCOUNTDOCK_ROUTER_DIRECTORY"] != nil {
            return directory.appendingPathComponent("router.log")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/AccountDock-router.log")
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// One Anthropic-compatible upstream.
struct RouterBackend: Codable, Equatable, Sendable {
    enum Auth: String, Codable, Sendable {
        /// The client's own credential is forwarded unchanged.
        case passthrough
        /// `Authorization: Bearer` with the token in `tokenFile`.
        case bearer
        /// `x-api-key` with the token in `tokenFile`.
        case apiKey
    }

    var id: String
    var displayName: String
    /// Base URL; request paths such as `/v1/messages` are appended.
    var baseURL: String
    var auth: Auth = .passthrough
    /// Name of the pushed credential for `.bearer` and `.apiKey`.
    var tokenFile: String?
    /// Model that replaces the requested one; nil forwards the request's model.
    var model: String?
    /// Whether the backend rejects thinking blocks it did not issue itself.
    var validatesThinkingSignatures = false
    /// Whether responses carry `anthropic-ratelimit-unified-*` usage headers.
    var reportsUnifiedUsage = false
    /// Whether the backend keeps conversations server-side for requests that
    /// carry `thread`. Claude Code sends only the turn's new messages in a
    /// `continue`, which a backend without the stored conversation rejects.
    var acceptsMessageThreads = false
    /// Whether the backend understands tools sent with `defer_loading` and
    /// the tool-search blocks that load them.
    var acceptsDeferredTools = false
    /// Sessions whose context exceeds this many tokens are not sent to the
    /// backend; nil sends every session.
    var maxContextTokens: Int?

    init(
        id: String, displayName: String, baseURL: String, auth: Auth = .passthrough, tokenFile: String? = nil,
        model: String? = nil, validatesThinkingSignatures: Bool = false, reportsUnifiedUsage: Bool = false,
        acceptsMessageThreads: Bool = false, acceptsDeferredTools: Bool = false, maxContextTokens: Int? = nil
    ) {
        self.id = id; self.displayName = displayName; self.baseURL = baseURL; self.auth = auth
        self.tokenFile = tokenFile; self.model = model
        self.validatesThinkingSignatures = validatesThinkingSignatures; self.reportsUnifiedUsage = reportsUnifiedUsage
        self.acceptsMessageThreads = acceptsMessageThreads; self.acceptsDeferredTools = acceptsDeferredTools
        self.maxContextTokens = maxContextTokens
    }

    /// Optional fields may be absent, so a state written by a newer or older
    /// app still loads instead of leaving the router on its previous state.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        displayName = try values.decodeIfPresent(String.self, forKey: .displayName) ?? id
        baseURL = try values.decode(String.self, forKey: .baseURL)
        auth = try values.decodeIfPresent(Auth.self, forKey: .auth) ?? .passthrough
        tokenFile = try values.decodeIfPresent(String.self, forKey: .tokenFile)
        model = try values.decodeIfPresent(String.self, forKey: .model)
        validatesThinkingSignatures = try values.decodeIfPresent(Bool.self, forKey: .validatesThinkingSignatures) ?? false
        reportsUnifiedUsage = try values.decodeIfPresent(Bool.self, forKey: .reportsUnifiedUsage) ?? false
        // A state written before these fields existed describes Anthropic,
        // which has both, and route targets, which have neither.
        let isAnthropic = id == RouterBackend.anthropic.id
        acceptsMessageThreads = try values.decodeIfPresent(Bool.self, forKey: .acceptsMessageThreads) ?? isAnthropic
        acceptsDeferredTools = try values.decodeIfPresent(Bool.self, forKey: .acceptsDeferredTools) ?? isAnthropic
        maxContextTokens = try values.decodeIfPresent(Int.self, forKey: .maxContextTokens)
    }

    var messagesURL: URL? { url("v1/messages") }

    func url(_ path: String) -> URL? {
        let base = baseURL.hasSuffix("/") ? baseURL : baseURL + "/"
        return URL(string: base + (path.hasPrefix("/") ? String(path.dropFirst()) : path))
    }
}

/// An account a pooled backend can serve sessions from.
struct RouterPoolMember: Codable, Equatable, Sendable {
    var accountID: String
    var tokenFile: String
    /// Relative share of new sessions; 0 keeps the account for sessions
    /// already assigned to it without giving it new ones.
    var weight: Double = 1
}

struct RouterState: Codable, Equatable, Sendable {
    var backends: [RouterBackend] = [RouterBackend.anthropic]
    /// Backend that serves requests while nothing is routed elsewhere.
    var primary = RouterBackend.anthropic.id
    /// Backend that new turns go to.
    var route = RouterBackend.anthropic.id
    /// Backend that serves a request the primary refuses at a plan limit.
    var fallback: String?
    /// Accounts of the primary backend; empty forwards each session's own
    /// credential.
    var pool: [RouterPoolMember] = []
    var reason: String?
    /// A session moves to the preferred pool account at its next turn
    /// rather than keeping the account it has, so a failover switch moves
    /// running sessions too.
    var sessionsFollowPreferred = false
    /// Sessions to move to another pool account at their next turn, by
    /// session ID: the account ID they move to.
    var moves: [String: String] = [:]
    /// A session's prompt cache decides where it is served: a session whose
    /// cache has expired is placed again at its next turn, and one refused
    /// at its account's limit waits for the reset when that comes before its
    /// cache expires.
    var cacheAwareSessions = false
    /// Requests to the primary backend whose context is at least this many
    /// tokens ask for the one-hour prompt cache in place of a shorter one;
    /// 0 for every request, nil leaves the client's choice. A context left
    /// idle for over five minutes is otherwise written to the cache again in
    /// full.
    var extendedCacheMinimumContext: Int?
    /// Routes for providers whose CLI reaches the router through
    /// `ProviderPassthrough`, by pause-gate key.
    var passthroughRoutes: [String: PassthroughRoute] = [:]
    var updatedAt = Date()

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        backends = try values.decodeIfPresent([RouterBackend].self, forKey: .backends) ?? [RouterBackend.anthropic]
        primary = try values.decodeIfPresent(String.self, forKey: .primary) ?? RouterBackend.anthropic.id
        route = try values.decodeIfPresent(String.self, forKey: .route) ?? primary
        fallback = try values.decodeIfPresent(String.self, forKey: .fallback)
        pool = try values.decodeIfPresent([RouterPoolMember].self, forKey: .pool) ?? []
        reason = try values.decodeIfPresent(String.self, forKey: .reason)
        sessionsFollowPreferred = try values.decodeIfPresent(Bool.self, forKey: .sessionsFollowPreferred) ?? false
        moves = try values.decodeIfPresent([String: String].self, forKey: .moves) ?? [:]
        cacheAwareSessions = try values.decodeIfPresent(Bool.self, forKey: .cacheAwareSessions) ?? false
        extendedCacheMinimumContext = try values.decodeIfPresent(Int.self, forKey: .extendedCacheMinimumContext)
        passthroughRoutes = try values.decodeIfPresent([String: PassthroughRoute].self, forKey: .passthroughRoutes) ?? [:]
        updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    func backend(_ id: String?) -> RouterBackend? {
        guard let id else { return nil }
        return backends.first { $0.id == id }
    }
}

/// Where a passthrough provider's model requests may be served besides its
/// own endpoint: a Messages backend, reached through `ResponsesBridge`.
struct PassthroughRoute: Codable, Equatable, Sendable {
    var backend: RouterBackend
    /// New turns go to the backend.
    var routed = false
    /// A request the provider's own endpoint refuses at its limit is served
    /// by the backend.
    var fallback = false
}

extension RouterBackend {
    static let anthropic = RouterBackend(
        id: "anthropic",
        displayName: "Anthropic",
        baseURL: "https://api.anthropic.com",
        auth: .passthrough,
        validatesThinkingSignatures: true,
        reportsUnifiedUsage: true,
        acceptsMessageThreads: true,
        acceptsDeferredTools: true
    )
}

struct RouterToken: Codable, Equatable, Sendable {
    var accessToken: String
    var expiresAt: Date
}

/// What the app pushes to the router: credentials by name, and the
/// fingerprints of credentials allowed to use pool accounts and route
/// targets, which are the user's own accounts' credentials.
struct RouterCredentials: Codable, Equatable, Sendable {
    var tokens: [String: RouterToken]
    var allowedCredentials: Set<String>
}

/// Usage observed in a response's `anthropic-ratelimit-unified-*` headers.
/// `credential` is the fingerprint of the token that made the request.
struct RouterUsageObservation: Codable, Equatable, Sendable {
    var credential: String
    var accountID: String?
    var sessionUtilization: Double?
    var sessionReset: Date?
    var weeklyUtilization: Double?
    var weeklyReset: Date?
    var status: String?
    var observedAt: Date
}

struct RouterEvent: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// The primary refused a request at a plan limit; another account or
        /// the fallback served it.
        case replayed
        /// A request to a non-primary backend failed.
        case backendFailed
        /// A turn was served by a non-primary backend.
        case servedByRoute
        /// A session was given an account from the pool.
        case assigned
        /// A turn's token use, for switch-cost and turn-cost learning.
        case turnUsage
        /// A session refused at its account's limit waits for the reset,
        /// given in `detail`, because it comes before its prompt cache
        /// expires.
        case held
    }

    var kind: Kind
    var at: Date
    var session: String?
    var backend: String?
    var accountID: String?
    var detail: String?
    /// Context tokens of the request: input, cache write and cache read.
    var contextTokens: Int?
    var cacheWriteTokens: Int?
    /// The part of the context read from the backend's prompt cache; nil
    /// from routers that did not report it.
    var cacheReadTokens: Int?
    var outputTokens: Int?
    /// Seconds the request asked its prompt cache to last, as sent.
    var cacheLifetime: Int?
    /// The part of `cacheWriteTokens` written to the one-hour cache.
    var cacheWriteLongTokens: Int?
    /// The router asked for the one-hour cache in place of the client's
    /// shorter one (`RouterState.extendedCacheMinimumContext`).
    var cacheExtended: Bool?
    /// The request began a turn (`RouterLogic.startsTurn`).
    var startsTurn: Bool?
    /// The pause-gate key of the passthrough provider whose request this
    /// was; nil for the routed provider's own requests.
    var client: String?
}

enum RouterLogic {
    static func safeName(_ name: String) -> String {
        String(name.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) })
    }

    /// Fingerprint of a credential, so usage can be attributed to an account
    /// without the router storing which token belongs to whom.
    static func fingerprint(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// Requests must come from a local program, not a web page: browsers add
    /// `Origin` to cross-site requests, and a host other than the loopback
    /// address means the name was rebound to reach the router.
    static func isLocalClientRequest(_ headers: [(String, String)], port: UInt16) -> Bool {
        if headers.contains(where: { $0.0.caseInsensitiveCompare("origin") == .orderedSame }) { return false }
        guard let host = headers.first(where: { $0.0.caseInsensitiveCompare("host") == .orderedSame })?.1.lowercased() else { return true }
        return ["127.0.0.1:\(port)", "localhost:\(port)", "127.0.0.1", "localhost"].contains(host)
    }

    static func bearerToken(_ headers: [(String, String)]) -> String? {
        for (name, value) in headers {
            if name.caseInsensitiveCompare("authorization") == .orderedSame,
               value.lowercased().hasPrefix("bearer ") { return String(value.dropFirst(7)) }
            if name.caseInsensitiveCompare("x-api-key") == .orderedSame { return value }
        }
        return nil
    }

    /// Claude Code identifies the session in `metadata.user_id`, which ends
    /// in `session_<id>`.
    /// Claude Code's session identifier from `metadata.user_id`, which is
    /// either a JSON object with `session_id` or a string ending in
    /// `_session_<id>`.
    static func sessionID(_ body: [String: Any]) -> String? {
        guard let metadata = body["metadata"] as? [String: Any],
              let user = metadata["user_id"] as? String else { return nil }
        if user.hasPrefix("{"),
           let object = (try? JSONSerialization.jsonObject(with: Data(user.utf8))) as? [String: Any] {
            guard let id = object["session_id"] as? String, !id.isEmpty else { return nil }
            return id
        }
        guard let range = user.range(of: "_session_", options: .backwards) else { return nil }
        let id = user[range.upperBound...]
        return id.isEmpty ? nil : String(id)
    }

    /// A request starts a turn when its last message is the user's own,
    /// rather than tool results continuing the assistant's turn.
    static func startsTurn(_ body: [String: Any]) -> Bool {
        guard let messages = body["messages"] as? [[String: Any]], let last = messages.last,
              last["role"] as? String == "user" else { return true }
        guard let blocks = last["content"] as? [[String: Any]] else { return true }
        return !blocks.contains { $0["type"] as? String == "tool_result" }
    }

    /// The backend for one request. A turn finishes on the backend it began
    /// on when the new backend would reject the turn's thinking; a backend
    /// that accepts foreign thinking can take over at any point.
    static func backend(
        desired: String,
        turnBackend: String?,
        startsTurn: Bool,
        desiredValidatesThinking: Bool
    ) -> String {
        if startsTurn || !desiredValidatesThinking { return desired }
        return turnBackend ?? desired
    }

    /// The pool account for a request. A session keeps its account within
    /// a turn; across turns it keeps it too, unless `followPreferred`, when
    /// a new turn goes to the preferred account. A new turn goes to `move`
    /// when that is usable, as does any request whose own account cannot
    /// serve it, such as a resumed session's; it is placed again like a new
    /// session when
    /// `cacheExpired`. Accounts with weight take new sessions by load;
    /// accounts without weight serve only when every weighted account is
    /// unavailable, in pool order, so a refusal falls through to the next
    /// account.
    static func poolAccount(
        current: String?,
        startsTurn: Bool,
        members: [RouterPoolMember],
        unavailable: Set<String>,
        load: [String: Int],
        followPreferred: Bool = false,
        move: String? = nil,
        cacheExpired: Bool = false
    ) -> String? {
        let usable = members.filter { !unavailable.contains($0.accountID) }
        let candidates = usable.filter { $0.weight > 0 }
        let currentUsable = current.map { id in usable.contains { $0.accountID == id } } ?? false
        if let move, startsTurn || !currentUsable, usable.contains(where: { $0.accountID == move }) { return move }
        let current = startsTurn && cacheExpired ? nil : current
        if let current, usable.contains(where: { $0.accountID == current }),
           !(followPreferred && startsTurn && !candidates.isEmpty && !candidates.contains(where: { $0.accountID == current })) {
            return current
        }
        let preferred = candidates.enumerated().min { lhs, rhs in
            let l = Double(load[lhs.element.accountID] ?? 0) / lhs.element.weight
            let r = Double(load[rhs.element.accountID] ?? 0) / rhs.element.weight
            return l == r ? lhs.offset < rhs.offset : l < r
        }?.element.accountID
        return preferred ?? usable.first?.accountID
    }

    static func withModel(_ body: [String: Any], _ model: String?) -> [String: Any] {
        guard let model else { return body }
        var body = body
        body["model"] = model
        return body
    }

    static func signatureKey(_ signature: String) -> String {
        SHA256.hash(data: Data(signature.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Removes thinking blocks the target would reject. `issuers` maps a
    /// signature key to the issuer recorded when the router saw the block:
    /// `backend` or `backend|account`. Blocks of another backend are always
    /// removed; blocks of the same backend's other accounts only when
    /// `stripOtherAccounts`. With `onlyBefore`, only messages before that
    /// index are considered, which keeps the running turn's own thinking.
    static func cleanedThinking(
        _ body: [String: Any],
        target: String,
        account: String?,
        issuers: [String: String],
        stripOtherAccounts: Bool,
        stripUnknownBefore: Int? = nil
    ) -> ([String: Any], Int) {
        guard var messages = body["messages"] as? [[String: Any]] else { return (body, 0) }
        var removed = 0
        for index in messages.indices where messages[index]["role"] as? String == "assistant" {
            guard let blocks = messages[index]["content"] as? [[String: Any]] else { continue }
            let kept = blocks.filter { block in
                guard ["thinking", "redacted_thinking"].contains(block["type"] as? String ?? "") else { return true }
                let signature = (block["signature"] as? String) ?? (block["data"] as? String) ?? ""
                let issuer = issuers[signatureKey(signature)]
                let drop: Bool
                if let issuer {
                    let parts = issuer.split(separator: "|", maxSplits: 1).map(String.init)
                    drop = parts[0] != target
                        || (stripOtherAccounts && parts.count > 1 && account != nil && parts[1] != account)
                } else {
                    drop = stripUnknownBefore.map { index < $0 } ?? false
                }
                if drop { removed += 1 }
                return !drop
            }
            if kept.count != blocks.count {
                messages[index]["content"] = kept.isEmpty ? [["type": "text", "text": "…"]] : kept
            }
        }
        var result = body
        result["messages"] = messages
        return (result, removed)
    }

    /// Index of the message that started the running turn: the last user
    /// message that is not only tool results.
    static func turnStartIndex(_ body: [String: Any]) -> Int {
        guard let messages = body["messages"] as? [[String: Any]] else { return 0 }
        for index in messages.indices.reversed() where messages[index]["role"] as? String == "user" {
            if let blocks = messages[index]["content"] as? [[String: Any]],
               blocks.contains(where: { $0["type"] as? String == "tool_result" }) { continue }
            return index
        }
        return 0
    }

    /// Whether a request was refused because the plan's usage limit is
    /// reached, as opposed to a short-term throttle the client retries.
    /// Anthropic answers 429; Kimi answers 403 "You've reached your 5-hour
    /// usage limit".
    static func isPlanLimit(status: Int, headers: [String: String], body: Data) -> Bool {
        guard status == 429 || status == 403 else { return false }
        let lowered = Dictionary(headers.map { ($0.key.lowercased(), $0.value.lowercased()) }, uniquingKeysWith: { a, _ in a })
        if status == 429, lowered["anthropic-ratelimit-unified-status"] == "rejected" { return true }
        let text = String(decoding: body.prefix(4096), as: UTF8.self).lowercased()
        return text.contains("usage limit") || text.contains("limit reached") || text.contains("out of extra usage")
    }

    /// The structure of a Messages request without any of its text, logged
    /// when a route target rejects it so the rejected shape can be found.
    static func requestShape(_ body: [String: Any]) -> String {
        var parts: [String] = []
        if let model = body["model"] as? String { parts.append("model=\(model)") }
        if let maxTokens = body["max_tokens"] as? Int { parts.append("max_tokens=\(maxTokens)") }
        if let stream = body["stream"] as? Bool { parts.append("stream=\(stream)") }
        if let thinking = body["thinking"] as? [String: Any] {
            parts.append("thinking=\(thinking["type"] as? String ?? "?")\(thinking["budget_tokens"].map { "/\($0)" } ?? "")")
        }
        if let tools = body["tools"] as? [Any] { parts.append("tools=\(tools.count)") }
        if let choice = body["tool_choice"] as? [String: Any] { parts.append("tool_choice=\(choice["type"] as? String ?? "?")") }
        if let system = body["system"] as? [Any] { parts.append("system=\(system.count) blocks") }
        if let messages = body["messages"] as? [[String: Any]] {
            parts.append("messages=\(messages.count)")
            func blocks(_ message: [String: Any]) -> String {
                let role = message["role"] as? String ?? "?"
                guard let content = message["content"] as? [[String: Any]] else { return "\(role)[text]" }
                return "\(role)[\(content.map { $0["type"] as? String ?? "?" }.joined(separator: ","))]"
            }
            parts.append("last=" + messages.suffix(2).map(blocks).joined(separator: " "))
        }
        let known: Set<String> = ["model", "max_tokens", "stream", "thinking", "tools", "tool_choice", "system", "messages", "metadata"]
        let other = body.keys.filter { !known.contains($0) }.sorted()
        if !other.isEmpty { parts.append("other=\(other.joined(separator: ","))") }
        return parts.joined(separator: " ")
    }

    static func isInvalidThinkingSignature(status: Int, body: Data) -> Bool {
        guard status == 400 else { return false }
        let text = String(decoding: body.prefix(4096), as: UTF8.self).lowercased()
        return text.contains("signature") && text.contains("thinking")
    }

    /// Usage in `anthropic-ratelimit-unified-*` headers, as percentages.
    static func unifiedUsage(_ headers: [String: String], credential: String, accountID: String?, at date: Date) -> RouterUsageObservation? {
        let lowered = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        func number(_ name: String) -> Double? { lowered["anthropic-ratelimit-unified-\(name)"].flatMap(Double.init) }
        func time(_ name: String) -> Date? { number(name).map { Date(timeIntervalSince1970: $0) } }
        let session = number("5h-utilization"), weekly = number("7d-utilization")
        guard session != nil || weekly != nil else { return nil }
        return RouterUsageObservation(
            credential: credential,
            accountID: accountID,
            sessionUtilization: session.map { $0 * 100 },
            sessionReset: time("5h-reset"),
            weeklyUtilization: weekly.map { $0 * 100 },
            weeklyReset: time("7d-reset"),
            status: lowered["anthropic-ratelimit-unified-status"],
            observedAt: date
        )
    }

    /// When a refused account becomes usable again, from its reset headers.
    /// The longest lifetime the request asks of its prompt cache, from the
    /// `cache_control` marks on its tools, system prompt and messages: an
    /// hour for `ttl` "1h", otherwise five minutes. Nil without any mark.
    static func cacheLifetime(_ body: [String: Any]) -> TimeInterval? {
        var longest: TimeInterval?
        func note(_ block: Any?) {
            guard let control = (block as? [String: Any])?["cache_control"] as? [String: Any] else { return }
            let lifetime: TimeInterval = control["ttl"] as? String == "1h" ? 60 * 60 : 5 * 60
            longest = max(longest ?? 0, lifetime)
        }
        (body["tools"] as? [Any])?.forEach(note)
        (body["system"] as? [Any])?.forEach(note)
        for message in body["messages"] as? [[String: Any]] ?? [] {
            note(message)
            (message["content"] as? [Any])?.forEach(note)
        }
        return longest
    }

    /// The longest a refused request is held for its account's reset. Claude
    /// Code keeps a streamed request that carries only comments open for
    /// over five minutes, but abandons it and sends it again within twelve.
    static let maximumHold: TimeInterval = 5 * 60

    /// When a request refused at its account's limit should be sent to the
    /// same account again: at the reset the refusal names, when that comes
    /// within `maximumHold` and at least a minute before the session's
    /// prompt cache, last used at `lastServed`, expires. Nil sends it to the
    /// next account now.
    static func holdUntil(
        _ headers: [String: String],
        lastServed: Date?,
        cacheLifetime: TimeInterval?,
        now: Date
    ) -> Date? {
        let lowered = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        guard let reset = lowered["anthropic-ratelimit-unified-reset"].flatMap(Double.init).map(Date.init(timeIntervalSince1970:)),
              let lastServed, let cacheLifetime, reset > now, reset.timeIntervalSince(now) <= maximumHold,
              reset.addingTimeInterval(60) <= lastServed.addingTimeInterval(cacheLifetime) else { return nil }
        return reset
    }

    /// Whether a failed attempt goes back to the pool instead of to the
    /// client. A route target never gives the final answer: any error reply
    /// from one, or a failure to reach it (`status` nil), is retried on the
    /// provider's own accounts, as long as this attempt has written none of
    /// its reply to the client. The pool's own failures are the answer.
    static func handsBackToPool(isRouteTarget: Bool, status: Int?, wroteReply: Bool) -> Bool {
        guard isRouteTarget, !wroteReply else { return false }
        return status.map { $0 >= 400 } ?? true
    }

    /// An error written into an event stream whose 200 head was already
    /// sent, in the Messages API's own error event shape.
    static func streamedError(_ body: Data, status: Int) -> Data {
        let parsed = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let payload = parsed?["type"] as? String == "error" && parsed?["error"] != nil
            ? body
            : errorBody(type: status == 429 ? "rate_limit_error" : "api_error",
                        message: String(decoding: body.prefix(500), as: UTF8.self))
        let line = String(decoding: payload, as: UTF8.self).replacingOccurrences(of: "\n", with: " ")
        return Data("event: error\ndata: \(line)\n\n".utf8)
    }

    /// Kept sent while a held request waits, so the client sees an open
    /// stream.
    static let streamKeepAlive = Data(": waiting for the account's limit to reset (AccountDock)\n\n".utf8)

    static func refusedUntil(_ headers: [String: String], now: Date) -> Date {
        let lowered = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        let reset = lowered["anthropic-ratelimit-unified-reset"].flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
        return max(now.addingTimeInterval(5 * 60), reset ?? now.addingTimeInterval(30 * 60))
    }

    /// Thinking signatures in a non-streamed Messages response.
    static func signatures(inResponse data: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = root["content"] as? [[String: Any]] else { return [] }
        return content.compactMap { ($0["signature"] as? String) ?? ($0["data"] as? String) }.filter { !$0.isEmpty }
    }

    /// Token use reported in a non-streamed response's `usage`.
    static func usage(inResponse data: Data) -> TokenCounts? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = root["usage"] as? [String: Any] else { return nil }
        return tokenCounts(usage)
    }

    struct TokenCounts: Equatable {
        var context = 0
        var cacheWrite = 0
        /// The part of `cacheWrite` written to the one-hour cache.
        var cacheWriteLong = 0
        var cacheRead = 0
        var output = 0
    }

    static func tokenCounts(_ usage: [String: Any]) -> TokenCounts {
        func int(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
        let write = int("cache_creation_input_tokens"), read = int("cache_read_input_tokens")
        let long = ((usage["cache_creation"] as? [String: Any])?["ephemeral_1h_input_tokens"] as? NSNumber)?.intValue ?? 0
        return TokenCounts(context: int("input_tokens") + write + read, cacheWrite: write, cacheWriteLong: min(long, write),
                           cacheRead: read, output: int("output_tokens"))
    }

    /// The request with every prompt-cache mark asking for the one-hour
    /// cache, and whether any mark changed. Every mark gets the same lifetime,
    /// which keeps the API's rule that longer-lived marks come first.
    static func withExtendedCache(_ body: [String: Any]) -> ([String: Any], Bool) {
        var changed = false
        func extend(_ block: Any) -> Any {
            guard var object = block as? [String: Any], var control = object["cache_control"] as? [String: Any] else { return block }
            guard control["ttl"] as? String != "1h" else { return block }
            control["ttl"] = "1h"
            object["cache_control"] = control
            changed = true
            return object
        }
        var body = body
        if let tools = body["tools"] as? [Any] { body["tools"] = tools.map(extend) }
        if let system = body["system"] as? [Any] { body["system"] = system.map(extend) }
        if let messages = body["messages"] as? [[String: Any]] {
            body["messages"] = messages.map { message -> [String: Any] in
                var message = extend(message) as? [String: Any] ?? message
                if let content = message["content"] as? [Any] { message["content"] = content.map(extend) }
                return message
            }
        }
        return (body, changed)
    }

    // MARK: - Requests for backends without Anthropic-only features

    /// Whether the request continues or creates a server-side conversation.
    static func carriesThread(_ body: [String: Any]) -> Bool { body["thread"] != nil }

    /// The reply that makes Claude Code resend a turn without `thread` and
    /// keep the session's requests whole for the rest of the session: a 400
    /// whose `details.error_code` is `thread_unsupported_request`.
    static func threadUnsupportedBody(backend: String) -> Data {
        let body: [String: Any] = [
            "type": "error",
            "error": [
                "type": "invalid_request_error",
                "message": "\(backend) keeps no server-side conversation; send the whole conversation",
                "details": ["error_code": "thread_unsupported_request"],
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    /// The request for a backend that knows nothing of deferred tools or
    /// Anthropic's server tools: deferred tools the conversation never used
    /// and the tool-search tools are dropped, `defer_loading` is removed from
    /// the rest, server tool blocks leave the history, and a loaded tool
    /// reference becomes a line of text.
    static func withoutDeferredTools(_ body: [String: Any]) -> [String: Any] {
        var body = body
        var messages = body["messages"] as? [[String: Any]] ?? []
        var used = Set<String>()
        for message in messages {
            for block in message["content"] as? [[String: Any]] ?? [] {
                if block["type"] as? String == "tool_use", let name = block["name"] as? String { used.insert(name) }
                for inner in block["content"] as? [[String: Any]] ?? [] where inner["type"] as? String == "tool_reference" {
                    if let name = inner["tool_name"] as? String { used.insert(name) }
                }
            }
        }
        if let tools = body["tools"] as? [[String: Any]] {
            body["tools"] = tools.compactMap { tool -> [String: Any]? in
                if (tool["type"] as? String)?.hasPrefix("tool_search_tool") == true { return nil }
                if tool["defer_loading"] as? Bool == true, !used.contains(tool["name"] as? String ?? "") { return nil }
                var kept = tool
                kept["defer_loading"] = nil
                return kept
            }
        }
        func isServerBlock(_ type: String?) -> Bool {
            guard let type else { return false }
            return type == "server_tool_use" || (type.hasSuffix("_tool_result") && type != "tool_result")
        }
        for index in messages.indices {
            guard let content = messages[index]["content"] as? [[String: Any]] else { continue }
            var cleaned = content.filter { !isServerBlock($0["type"] as? String) }.map { block -> [String: Any] in
                guard block["type"] as? String == "tool_result", let inner = block["content"] as? [[String: Any]] else { return block }
                var result = block
                result["content"] = inner.map { item -> [String: Any] in
                    guard item["type"] as? String == "tool_reference" else { return item }
                    return ["type": "text", "text": "Tool \(item["tool_name"] as? String ?? "") is available."]
                }
                return result
            }
            if cleaned.isEmpty { cleaned = [["type": "text", "text": "(server tool call omitted)"]] }
            messages[index]["content"] = cleaned
        }
        if body["messages"] != nil { body["messages"] = messages }
        return body
    }

    /// Context tokens a request is expected to carry: the session's last
    /// measured context, or the request body's size at about four bytes a
    /// token when the session has none yet.
    static func expectedContext(lastMeasured: Int?, bodyBytes: Int) -> Int {
        max(lastMeasured ?? 0, bodyBytes / 4)
    }

    /// An error body in the Messages API format, so the client reports it.
    static func errorBody(type: String, message: String) -> Data {
        let body: [String: Any] = ["type": "error", "error": ["type": type, "message": message]]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }
}

/// Collects thinking signatures and token use from a streamed Messages
/// response.
final class SSEScanner {
    private var buffer = Data()
    private var partial: [Int: String] = [:]
    private(set) var counts = RouterLogic.TokenCounts()

    func feed(_ data: Data) -> [String] {
        buffer.append(data)
        var found: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard line.starts(with: Data("data:".utf8)),
                  let text = String(data: line.dropFirst(5), encoding: .utf8),
                  text.contains("signature") || text.contains("usage") || text.contains("redacted_thinking"),
                  let event = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { continue }
            let index = event["index"] as? Int ?? 0
            switch event["type"] as? String {
            case "message_start":
                if let message = event["message"] as? [String: Any], let usage = message["usage"] as? [String: Any] {
                    counts = RouterLogic.tokenCounts(usage)
                }
            case "message_delta":
                // Some Anthropic-compatible backends report input only here.
                if let usage = event["usage"] as? [String: Any] {
                    let late = RouterLogic.tokenCounts(usage)
                    if late.context > 0 {
                        // The closing totals carry no `cache_creation`
                        // breakdown; the opening one's long part stands.
                        let long = usage["cache_creation"] != nil ? late.cacheWriteLong : counts.cacheWriteLong
                        counts.context = late.context; counts.cacheWrite = late.cacheWrite
                        counts.cacheWriteLong = min(long, late.cacheWrite); counts.cacheRead = late.cacheRead
                    }
                    if let value = (usage["output_tokens"] as? NSNumber)?.intValue { counts.output = value }
                }
            case "content_block_start":
                if let block = event["content_block"] as? [String: Any] {
                    if let signature = block["signature"] as? String, !signature.isEmpty { partial[index] = signature }
                    if block["type"] as? String == "redacted_thinking", let data = block["data"] as? String { found.append(data) }
                }
            case "content_block_delta":
                if let delta = event["delta"] as? [String: Any], delta["type"] as? String == "signature_delta",
                   let signature = delta["signature"] as? String {
                    partial[index, default: ""] += signature
                }
            case "content_block_stop":
                if let signature = partial.removeValue(forKey: index), !signature.isEmpty { found.append(signature) }
            default:
                break
            }
        }
        return found
    }

    /// Signatures of blocks the stream never closed.
    func finish() -> [String] {
        defer { partial.removeAll() }
        return partial.values.filter { !$0.isEmpty }
    }
}

// MARK: - Held provider requests

/// Requests a provider's CLI sends through the router so a pause can hold
/// them for as long as it lasts. A CLI whose hooks may only wait a short
/// time, such as Kimi Code's 600 seconds, cannot be held by the pause gate
/// alone; its model requests are sent to `/__provider/<key>/…` instead,
/// forwarded unchanged to the provider's own endpoint, and held while the
/// provider's pause holds the session.
///
/// The app writes `Router/passthrough.json` (`ProviderPassthrough.Entry`
/// per pause-gate key) and the CLI's base URL; the pause itself is read from
/// the same files the gate reads, so a session released by a step allowance
/// or resumed on its own is released here too.
enum ProviderPassthrough {
    static let prefix = "/__provider/"

    struct Entry: Codable, Equatable, Sendable {
        /// The provider's own base URL, which the CLI's setting held before
        /// it was pointed at the router; request paths are appended.
        var upstream: String
        /// The request-body field carrying the CLI's session ID.
        var sessionField: String
    }

    static var entriesURL: URL { RouterConfig.directory.appendingPathComponent("passthrough.json") }
    /// The pause gate's directory, beside the router's.
    static var pauseDirectory: URL {
        RouterConfig.directory.deletingLastPathComponent().appendingPathComponent("Pause", isDirectory: true)
    }

    /// The base URL a provider's CLI is given to send its requests here.
    static func baseURL(key: String) -> String { RouterConfig.baseURL + prefix + key }

    static func entries(at url: URL = entriesURL) -> [String: Entry] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? RouterConfig.decoder().decode([String: Entry].self, from: data)) ?? [:]
    }

    /// "/__provider/kimi/chat/completions?x" → ("kimi", "/chat/completions?x").
    static func split(_ target: String) -> (key: String, rest: String)? {
        guard target.hasPrefix(prefix) else { return nil }
        let remainder = target.dropFirst(prefix.count)
        let key = remainder.prefix { $0 != "/" && $0 != "?" }
        guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        let rest = String(remainder.dropFirst(key.count))
        return (String(key), rest.isEmpty ? "/" : rest)
    }

    static func upstreamURL(_ entry: Entry, rest: String) -> URL? {
        let base = entry.upstream.hasSuffix("/") ? String(entry.upstream.dropLast()) : entry.upstream
        return URL(string: base + rest)
    }

    static func sessionID(_ body: Data, field: String) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let value = json[field] as? String, !value.isEmpty,
              value.allSatisfy({ $0.isLetter || $0.isNumber || "._:-".contains($0) }) else { return nil }
        return value
    }

    /// The session a request names in its headers, for a CLI whose body
    /// does not carry it in a readable form: Codex sends its thread as
    /// `thread-id`, the session its hooks report.
    static func sessionID(_ headers: [(String, String)]) -> String? {
        for name in ["thread-id", "session-id"] {
            if let value = headers.first(where: { $0.0.caseInsensitiveCompare(name) == .orderedSame })?.1, !value.isEmpty,
               value.allSatisfy({ $0.isLetter || $0.isNumber || "._:-".contains($0) }) {
                return value
            }
        }
        return nil
    }

    static func isStreaming(_ body: Data) -> Bool {
        (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["stream"] as? Bool == true
    }

    /// Whether the provider's pause holds a request of `session`, by the
    /// rule the gate script applies: a pause file exists, it holds new
    /// turns or lists the session, and the user has not resumed the session.
    static func isHeld(key: String, session: String?, directory: URL = pauseDirectory) -> Bool {
        let pause = directory.appendingPathComponent("\(key).json")
        guard let data = try? Data(contentsOf: pause) else { return false }
        if let session, FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(key)-\(session).resumed").path) {
            return false
        }
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if json["holdsNewTurns"] as? Bool == true { return true }
        guard let session else { return false }
        return (json["sessions"] as? [String])?.contains(session) ?? false
    }

    /// Takes the session's one-step allowance, which AccountDock grants while
    /// the account still has room; true when there was one.
    static func takeAllowance(key: String, session: String?, directory: URL = pauseDirectory) -> Bool {
        guard let session else { return false }
        let url = directory.appendingPathComponent("\(key)-\(session).allow")
        return (try? FileManager.default.removeItem(at: url)) != nil
    }

    /// The marker that counts the session as waiting, the one the gate
    /// writes; nil when the gate already keeps one for it.
    static func markWaiting(key: String, session: String?, directory: URL = pauseDirectory) -> URL? {
        guard let session else { return nil }
        let url = directory.appendingPathComponent("\(key)-\(session).waiting")
        guard !FileManager.default.fileExists(atPath: url.path) else { return nil }
        return FileManager.default.createFile(atPath: url.path, contents: Data("router".utf8)) ? url : nil
    }

    /// A server-sent-events comment, which clients ignore, written while a
    /// streamed request waits so the connection is not timed out.
    static let keepAlive = Data(": paused by AccountDock\n\n".utf8)

    /// An error delivered inside an event stream whose 200 head was already
    /// sent while the request was held.
    static func streamError(status: Int, body: Data) -> Data {
        let message = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])
            .flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
            ?? String(decoding: body.prefix(500), as: UTF8.self)
        let payload: [String: Any] = ["error": ["message": message, "type": "upstream_error", "code": status]]
        let json = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        return Data("data: ".utf8) + json + Data("\n\n".utf8)
    }
}

/// Which upstream connection serves a request. HTTP/2 carries every request
/// on a connection over one TCP link, so when the link drops every request on
/// it fails together; `Upstream` in the router asks this pool so that link is
/// never shared beyond one client.
///
/// - A first attempt from a known client (a Claude Code session) reuses that
///   client's own connection, kept warm between its turns.
/// - A retry, or a request from no known client, gets a connection of its own
///   that is retired once its request ends, so retries after a dropped link
///   never meet each other or the link that failed.
/// - A retry also retires its client's kept connection, so the client's next
///   request opens a new link instead of the one that just failed.
/// - A connection unused for `idleLimit` is retired by `sweep`.
///
/// `make` opens a connection and `retire` closes one; both run under the
/// pool's lock and must not call back into it.
final class UpstreamConnections<Connection>: @unchecked Sendable {
    private let lock = NSLock()
    private var kept: [String: (connection: Connection, lastUsed: Date)] = [:]
    private let idleLimit: TimeInterval
    private let make: () -> Connection
    private let retire: (Connection) -> Void

    init(idleLimit: TimeInterval, make: @escaping () -> Connection, retire: @escaping (Connection) -> Void) {
        self.idleLimit = idleLimit
        self.make = make
        self.retire = retire
    }

    /// The connection for one attempt; `oneOff` connections are the caller's
    /// to retire once the request ends.
    func connection(for client: String?, attempt: Int, now: Date = Date()) -> (connection: Connection, oneOff: Bool) {
        lock.lock()
        defer { lock.unlock() }
        sweepLocked(now: now)
        guard let client else { return (make(), true) }
        if attempt > 0 {
            if let failed = kept.removeValue(forKey: client) { retire(failed.connection) }
            return (make(), true)
        }
        let connection = kept[client]?.connection ?? make()
        kept[client] = (connection, now)
        return (connection, false)
    }

    /// Retires connections idle for longer than `idleLimit`.
    func sweep(now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        sweepLocked(now: now)
    }

    var keptCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return kept.count
    }

    private func sweepLocked(now: Date) {
        for (client, entry) in kept where now.timeIntervalSince(entry.lastUsed) > idleLimit {
            kept.removeValue(forKey: client)
            retire(entry.connection)
        }
    }
}
