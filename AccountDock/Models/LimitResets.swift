import Foundation

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

        enum CodingKeys: String, CodingKey {
            case availableCount = "available_count"
        }
    }

    static func resets(from summary: Summary) -> LimitResets {
        guard let count = summary.availableCount, count > 0 else { return LimitResets(grants: []) }
        return LimitResets(grants: [
            LimitResets.Grant(id: "codex-reset-credits", label: "Codex rate-limit reset credits",
                              resetsTotal: count, resetsLeft: count, refills: [.all]),
        ])
    }
}
