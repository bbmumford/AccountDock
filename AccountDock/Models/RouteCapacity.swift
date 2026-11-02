import Foundation

/// What routed requests cost a route target's window, learned from the
/// tokens the router reports for the target and the target account's usage
/// readings that follow.
///
/// Tokens are counted raw, context plus output: a route target's own quota
/// accounting is not known, and the ratio absorbs whatever discount it gives
/// cached context.
struct RouteTargetCostModel: Codable, Equatable {
    /// Window percent per million routed tokens.
    var percentPerMillion: Double?
    /// Routed tokens since the target account's last reading.
    var pendingTokens: Double = 0
    var lastSession: Double?

    static let smoothing = 0.3

    mutating func recordRouted(tokens: Int) {
        pendingTokens += Double(max(0, tokens))
    }

    /// Learns from a new reading of the target's window. A fall is a new
    /// window and restarts the measurement.
    mutating func recordReading(session: Double) {
        defer { lastSession = session }
        guard let previous = lastSession, session >= previous else { pendingTokens = 0; return }
        guard session - previous >= 2, pendingTokens >= 500_000 else { return }
        let sample = (session - previous) / (pendingTokens / 1_000_000)
        if sample.isFinite, sample > 0 {
            percentPerMillion = percentPerMillion.map { $0 * (1 - Self.smoothing) + sample * Self.smoothing } ?? sample
        }
        pendingTokens = 0
    }

    func ratio(default fallback: Double) -> Double { percentPerMillion ?? fallback }

    /// The window now: the last reading plus the routed tokens since, so a
    /// fast-burning target is judged between readings.
    func estimatedSession(reading: Double, defaultRatio: Double) -> Double {
        min(100, reading + pendingTokens * ratio(default: defaultRatio) / 1_000_000)
    }
}

/// One request the router served, kept for a few minutes to measure the
/// demand a route target would take over.
struct RecentRouterRequest: Equatable {
    var at: Date
    var session: String?
    var backend: String
    var context: Int
    var output: Int
}

/// Whether a route target can take the current demand, from its window, the
/// share kept for its provider's own sessions, the tokens per minute that
/// would move to it and what a million tokens cost its window.
enum RouteCapacity {
    struct Verdict: Equatable {
        var serves: Bool
        /// Minutes the target is expected to carry the demand; nil when the
        /// demand is not yet measured.
        var minutes: Double?
        var reason: String?
    }

    static let demandWindow: TimeInterval = 5 * 60
    /// How far back the busiest stretch of demand is looked for, so a target
    /// is judged by the work that paused sessions will resume, not by the
    /// quiet while they wait.
    static let demandLookback: TimeInterval = 60 * 60

    /// Tokens per minute of the recent requests a target would serve: those
    /// within its context cap, from sessions on any backend.
    static func tokensPerMinute(_ requests: [RecentRouterRequest], maxContext: Int?, now: Date) -> Double {
        let since = now.addingTimeInterval(-demandWindow)
        let total = requests
            .filter { request in request.at >= since && maxContext.map { request.context <= $0 } ?? true }
            .reduce(0) { $0 + $1.context + $1.output }
        return Double(total) / (demandWindow / 60)
    }

    /// The busiest five minutes of the last hour, in tokens per minute, of
    /// requests within the context cap.
    static func peakTokensPerMinute(_ requests: [RecentRouterRequest], maxContext: Int?, now: Date) -> Double {
        let since = now.addingTimeInterval(-demandLookback)
        var buckets: [Int: Int] = [:]
        for request in requests where request.at >= since && maxContext.map({ request.context <= $0 }) ?? true {
            buckets[Int(request.at.timeIntervalSince(since) / 60), default: 0] += request.context + request.output
        }
        let minutes = Int(demandLookback / 60), span = Int(demandWindow / 60)
        var best = 0
        for start in 0...max(0, minutes - span) {
            best = max(best, (start..<(start + span)).reduce(0) { $0 + (buckets[$1] ?? 0) })
        }
        return Double(best) / Double(span)
    }

    static func evaluate(
        targetName: String,
        sessionPercent: Double,
        reservePercent: Double,
        tokensPerMinute: Double,
        percentPerMillion: Double,
        minimumMinutes: Double
    ) -> Verdict {
        let room = 100 - reservePercent - sessionPercent
        guard room > 0 else {
            return Verdict(serves: false, minutes: 0,
                           reason: "\(targetName) keeps its last \(Int(reservePercent))% for its own sessions")
        }
        let burn = tokensPerMinute * percentPerMillion / 1_000_000
        guard burn > 0 else { return Verdict(serves: true, minutes: nil, reason: nil) }
        let minutes = room / burn
        guard minutes >= minimumMinutes else {
            return Verdict(serves: false, minutes: minutes,
                           reason: "\(targetName) would last about \(Int(minutes.rounded())) min at the current demand")
        }
        return Verdict(serves: true, minutes: minutes, reason: nil)
    }
}
