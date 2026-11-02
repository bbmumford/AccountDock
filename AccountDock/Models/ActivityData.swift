import Foundation

/// Today's coding activity stats parsed from Claude Code session JSONL files.
struct ActivityStats: Sendable {
    var conversationTurns: Int = 0
    var activeCodingMinutes: Int = 0
    var toolUsage: [String: Int] = [:]
    var linesWritten: Int = 0
    var modelUsage: [String: Int] = [:]

    static let empty = ActivityStats()

    /// Top tools sorted by count descending.
    var topTools: [(name: String, count: Int)] {
        toolUsage.sorted { $0.value > $1.value }.map { (name: $0.key, count: $0.value) }
    }

    /// Model usage sorted by count descending.
    var topModels: [(name: String, count: Int)] {
        modelUsage.sorted { $0.value > $1.value }.map { (name: $0.key, count: $0.value) }
    }

    var totalToolCalls: Int {
        toolUsage.values.reduce(0, +)
    }

    var activeCodingTimeString: String {
        if activeCodingMinutes < 60 {
            return "\(activeCodingMinutes)m"
        }
        let hours = activeCodingMinutes / 60
        let mins = activeCodingMinutes % 60
        return mins > 0 ? "\(hours)h \(mins)m" : "\(hours)h"
    }
}
