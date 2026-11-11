import Foundation

private let resetShapeLog = FileLog("LimitResets")

/// The limit resets an account holds, in the same form for every provider:
/// each grant refills one or more of its limits on request, a number of
/// times before its end date. A provider's module (`AnthropicLimitResets`,
/// `CodexLimitResets`) reads its own reply into this form; the usage tiles,
/// saved readings and `AppState.refreshLimitResetsIfDue` read only this.
struct LimitResets: Codable, Equatable {
    var grants: [Grant] = []

    /// A limit a reset refills, named the way the usage bars name limits.
    enum RefilledLimit: Codable, Hashable {
        /// Every limit the account has.
        case all
        case session
        case weekly
        /// The weekly limit of one model or group of models, by display name.
        case model(String)
    }

    struct Grant: Codable, Equatable, Identifiable {
        let id: String
        /// The provider's own name for the grant.
        var label: String = ""
        var resetsTotal: Int = 0
        let resetsLeft: Int
        /// ISO 8601 time after which the grant can no longer be used.
        var endsAt: String?
        var refills: [RefilledLimit] = []
        var paused: Bool = false
        var usableNow: Bool = true

        /// What a reset refills, by its widest limit: all of them, the
        /// weekly limit (all models), one model's limit, or the session.
        var kind: String {
            if refills.contains(.all) { return "Full reset" }
            if refills.contains(.weekly) { return "All-models reset" }
            for case .model(let name) in refills { return "\(name) reset" }
            if refills.contains(.session) { return "Session reset" }
            return "Limit reset"
        }

        var endsAtDate: Date? { endsAt.flatMap(UsageWindow.parseProviderDate) }
    }

    /// A saved reading's grants, read leniently: a grant in a shape this
    /// version does not know is dropped, never the reading.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        grants = ((try? values.decodeIfPresent([Lossy<Grant>].self, forKey: .grants)) ?? []).compactMap(\.value)
    }

    init(grants: [Grant]) {
        self.grants = grants
    }

    /// Grants with a reset left, soonest to expire first.
    var available: [Grant] {
        grants.filter { $0.resetsLeft > 0 }
            .sorted { ($0.endsAtDate ?? .distantFuture) < ($1.endsAtDate ?? .distantFuture) }
    }

    /// Resets the account can use alike, counted together: a provider may
    /// issue separate grants for one offer, which refill the same limits and
    /// end the same day. Soonest to expire first.
    struct Group: Equatable, Identifiable {
        let kind: String
        let endDay: Date?
        let ready: Bool
        var resetsLeft: Int
        var resetsTotal: Int
        var labels: [String]
        var id: String { "\(kind)|\(endDay?.timeIntervalSince1970 ?? -1)|\(ready)" }
    }

    var availableGroups: [Group] {
        var groups: [Group] = []
        for grant in available {
            let endDay = grant.endsAtDate.map { Calendar.current.startOfDay(for: $0) }
            let ready = grant.usableNow && !grant.paused
            if let index = groups.firstIndex(where: { $0.kind == grant.kind && $0.endDay == endDay && $0.ready == ready }) {
                groups[index].resetsLeft += grant.resetsLeft
                groups[index].resetsTotal += max(grant.resetsTotal, grant.resetsLeft)
                if !grant.label.isEmpty { groups[index].labels.append(grant.label) }
            } else {
                groups.append(Group(kind: grant.kind, endDay: endDay, ready: ready, resetsLeft: grant.resetsLeft,
                                    resetsTotal: max(grant.resetsTotal, grant.resetsLeft),
                                    labels: grant.label.isEmpty ? [] : [grant.label]))
            }
        }
        return groups
    }
}

/// Decodes a value or nothing, so one unreadable element never fails the
/// list it is in.
struct Lossy<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

// MARK: - Anthropic

/// Claude's limit resets, which its usage endpoint lists under
/// `cedar_ember` when asked (`ClaudeService.getUsageLimits`).
enum AnthropicLimitResets {
    /// The limits a grant's `clears` names refill; a name this version does
    /// not know is left out.
    static let refilledLimits: [String: LimitResets.RefilledLimit] = [
        "five_hour": .session,
        "seven_day": .weekly,
        "seven_day_overage_included": .model("Fable"),
        "seven_day_opus": .model("Opus"),
        "seven_day_sonnet": .model("Sonnet"),
    ]

    struct Reply: Decodable {
        var grants: [Lossy<Grant>]?

        struct Grant: Decodable {
            let id: String
            let label: String?
            let resetsTotal: Int?
            let resetsLeft: Int
            let endsAt: String?
            let clears: [String]?
            let paused: Bool?
            let usableNow: Bool?

            enum CodingKeys: String, CodingKey {
                case id, label, clears, paused
                case resetsTotal = "resets_total"
                case resetsLeft = "resets_left"
                case endsAt = "ends_at"
                case usableNow = "usable_now"
            }
        }
    }

    static func resets(from reply: Reply) -> LimitResets {
        LimitResets(grants: (reply.grants ?? []).compactMap(\.value).map { grant in
            LimitResets.Grant(
                id: grant.id,
                label: grant.label ?? "",
                resetsTotal: grant.resetsTotal ?? grant.resetsLeft,
                resetsLeft: grant.resetsLeft,
                endsAt: grant.endsAt,
                refills: (grant.clears ?? []).compactMap { refilledLimits[$0] },
                paused: grant.paused ?? false,
                usableNow: grant.usableNow ?? false
            )
        })
    }
}

// MARK: - Codex

/// Codex's rate-limit reset credits, which its usage reply summarises
/// under `rate_limit_reset_credits` (`CodexService.decodeUsageSnapshot`).
/// A credit refills every Codex limit; the summary gives only how many are
/// left, so they are one grant without an end date.
enum CodexLimitResets {
    struct Summary: Decodable {
        let availableCount: Int?
        /// The credits that apply to the account's limits now; the rest are
        /// held for later.
        var applicableCount: Int? = nil

        enum CodingKeys: String, CodingKey {
            case availableCount = "available_count"
            case applicableCount = "applicable_available_count"
        }
    }

    /// The credits `/wham/rate-limit-reset-credits` lists, read when the
    /// summary counts any (`CodexService.getUsageSnapshot`). Each refills
    /// every Codex limit and can be used until it expires.
    struct Details: Decodable {
        var credits: [Lossy<Credit>]?

        struct Credit: Decodable {
            let id: String
            let resetType: String?
            let status: String?
            let expiresAt: String?

            enum CodingKeys: String, CodingKey {
                case id, status
                case resetType = "reset_type"
                case expiresAt = "expires_at"
            }

            /// The expiry as an ISO 8601 time, whether the reply gives one or
            /// a Unix time in seconds.
            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                id = try values.decode(String.self, forKey: .id)
                resetType = try? values.decodeIfPresent(String.self, forKey: .resetType)
                status = try? values.decodeIfPresent(String.self, forKey: .status)
                if let text = try? values.decodeIfPresent(String.self, forKey: .expiresAt) {
                    expiresAt = text
                } else if let seconds = try? values.decodeIfPresent(Double.self, forKey: .expiresAt) {
                    expiresAt = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: seconds))
                } else {
                    expiresAt = nil
                }
            }
        }
    }

    /// Nil when no credit could be read, so the summary's count stands.
    static func resets(from details: Details) -> LimitResets? {
        let credits = (details.credits ?? []).compactMap(\.value)
        guard !credits.isEmpty else { return nil }
        return LimitResets(grants: credits.map { credit in
            let available = credit.status == nil || credit.status == "available"
            return LimitResets.Grant(
                id: credit.id,
                label: "Codex rate-limit reset" + (credit.resetType.map { " (\($0))" } ?? ""),
                resetsTotal: 1,
                resetsLeft: available || credit.status == "redeeming" ? 1 : 0,
                endsAt: credit.expiresAt,
                refills: [.all],
                usableNow: available
            )
        })
    }

    /// Credits that apply now and credits held for later are separate rows,
    /// the latter dimmed as not usable yet.
    static func resets(from summary: Summary) -> LimitResets {
        guard let count = summary.availableCount, count > 0 else { return LimitResets(grants: []) }
        let applicable = min(count, summary.applicableCount ?? count)
        var grants: [LimitResets.Grant] = []
        if applicable > 0 {
            grants.append(LimitResets.Grant(id: "codex-reset-credits", label: "Codex rate-limit reset credits",
                                            resetsTotal: applicable, resetsLeft: applicable, refills: [.all]))
        }
        if count > applicable {
            grants.append(LimitResets.Grant(id: "codex-reset-credits-held", label: "Codex rate-limit reset credits that do not apply yet",
                                            resetsTotal: count - applicable, resetsLeft: count - applicable,
                                            refills: [.all], usableNow: false))
        }
        return LimitResets(grants: grants)
    }
}

// MARK: - Watching providers' replies

/// Records once per launch, for each provider, the shape of whatever its
/// usage reply holds about limit resets: field names, value types and list
/// lengths, never a value. A module is written or corrected from it, as for
/// a provider whose resets have not been seen yet. Fed by each provider's
/// usage request.
enum LimitResetShapes {
    /// Fields that name resets in a reply, beside the ones modules read.
    private static let hint = try? NSRegularExpression(pattern: "reset_?credit|reset_?grant|resets_?left|coupon|voucher|cedar_ember|limit_?reset", options: [.caseInsensitive])
    private static let seen = Seen()

    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var shapes: [String: String] = [:]
        func isNew(_ key: String, _ shape: String) -> Bool {
            lock.withLock {
                guard shapes[key] != shape else { return false }
                shapes[key] = shape
                return true
            }
        }
    }

    static func note(_ provider: AIProviderType, reply data: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let fields = root.keys.filter { key in
            hint?.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)) != nil
        }.sorted()
        for field in fields {
            let shape = describe(root[field] as Any)
            if seen.isNew("\(provider.rawValue).\(field)", shape) {
                resetShapeLog.info("\(provider.rawValue) usage reply field \(field): \(shape)")
            }
        }
    }

    /// Records the shape of a whole reply that is about resets, under
    /// `name`.
    static func note(_ provider: AIProviderType, whole data: Data, name: String) {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return }
        let shape = describe(root)
        if seen.isNew("\(provider.rawValue).\(name)", shape) {
            resetShapeLog.info("\(provider.rawValue) \(name) reply: \(shape)")
        }
    }

    /// The structure of a JSON value without its values.
    static func describe(_ value: Any, depth: Int = 0) -> String {
        guard depth < 4 else { return "…" }
        switch value {
        case let object as [String: Any]:
            return "{" + object.keys.sorted().map { "\($0): \(describe(object[$0] as Any, depth: depth + 1))" }.joined(separator: ", ") + "}"
        case let list as [Any]:
            return "[\(list.count)× " + (list.first.map { describe($0, depth: depth + 1) } ?? "") + "]"
        case is NSNull: return "null"
        case let number as NSNumber:
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? "bool" : "number"
        case is String: return "string"
        default: return "?"
        }
    }
}
