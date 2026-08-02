import Foundation

/// Provides cost summaries from Claude Code session JSONL files.
/// All actual parsing is done by `SessionParseCacheV2`; this is a thin facade.
final class CostParser: Sendable {
    struct CodexCostHistory: Sendable {
        let dailyCosts: [String: Double]
        let todayModelActivity: [String: Int]
        let todayModelCosts: [String: Double]
    }
    static let shared = CostParser()
    private init() {}

    /// Compute cost summary from the in-memory parse cache.
    /// Caller must ensure `SessionParseCacheV2.shared.refreshFromFilesystem()`
    /// has been awaited at least once this cycle.
    func getCostSummary() async -> CostSummary {
        return await SessionParseCacheV2.shared.costSummary()
    }

    /// Native Codex JSONL aggregation. This reads ~/.codex/sessions directly;
    /// AccountDock does not invoke CodexBar.
    func getCodexCostHistory() async -> CodexCostHistory {
        await PricingService.shared.ensureLoaded()
        let samples = await Task.detached(priority: .utility) {
            Self.scanCodexSamples()
        }.value
        let today = DateFormatter.codexDay.string(from: Date())
        var dailyCosts: [String: Double] = [:]
        var todayModelCosts: [String: Double] = [:]
        for sample in samples {
            guard let price = await PricingService.shared.pricing(
                for: sample.model,
                provider: .codex,
                reasoningEffort: sample.reasoningEffort
            ) else { continue }
            let uncachedInput = max(0, sample.input - sample.cachedInput)
            let cost = price.cost(
                input: uncachedInput,
                output: sample.output,
                cacheCreate: 0,
                cacheCreate1h: 0,
                cacheRead: sample.cachedInput,
                isFast: false
            )
            guard cost > 0 else { continue }
            dailyCosts[sample.day, default: 0] += cost
            if sample.day == today {
                todayModelCosts[sample.displayKey, default: 0] += cost
            }
        }
        let modelActivity = samples
            .filter { $0.day == today }
            .reduce(into: [String: Int]()) { counts, sample in
                counts[sample.displayKey, default: 0] += 1
            }
        return CodexCostHistory(
            dailyCosts: dailyCosts,
            todayModelActivity: modelActivity,
            todayModelCosts: todayModelCosts
        )
    }

    private struct CodexCostSample: Sendable {
        let day: String
        let model: String
        let reasoningEffort: String?
        let input: Int
        let cachedInput: Int
        let output: Int

        var displayKey: String {
            guard let reasoningEffort, !reasoningEffort.isEmpty else { return model }
            return "\(model) · \(reasoningEffort)"
        }
    }

    private static func scanCodexSamples() -> [CodexCostSample] {
        let root = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var samples: [CodexCostSample] = []
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"

        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            var model: String?
            var reasoningEffort: String?
            for line in text.split(separator: "\n") {
                guard let data = line.data(using: .utf8),
                      let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let payload = row["payload"] as? [String: Any] else { continue }
                if row["type"] as? String == "turn_context",
                   let value = payload["model"] as? String {
                    let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    model = Self.isDisplayableCodexModel(cleaned) ? cleaned : nil
                    reasoningEffort = (payload["effort"] as? String)
                        ?? (payload["reasoning_effort"] as? String)
                    continue
                }
                guard payload["type"] as? String == "token_count",
                      let info = payload["info"] as? [String: Any],
                      let usage = info["last_token_usage"] as? [String: Any],
                      let model,
                      let rawTimestamp = row["timestamp"] as? String,
                      let date = iso.date(from: rawTimestamp) else { continue }
                samples.append(CodexCostSample(
                    day: dayFormatter.string(from: date),
                    model: model,
                    reasoningEffort: reasoningEffort,
                    input: usage["input_tokens"] as? Int ?? 0,
                    cachedInput: usage["cached_input_tokens"] as? Int ?? 0,
                    output: usage["output_tokens"] as? Int ?? 0
                ))
            }
        }
        return samples
    }

    private static func isDisplayableCodexModel(_ model: String) -> Bool {
        !model.isEmpty &&
        !model.localizedCaseInsensitiveContains("synthetic") &&
        model != "<unknown>"
    }

    // MARK: - Helpers

    /// "claude-opus-4-6" → "Opus", "claude-fable-5" → "Fable"
    static func shortModelName(_ model: String) -> String {
        if model.contains("fable") { return "Fable" }
        if model.contains("opus") { return "Opus" }
        if model.contains("sonnet") { return "Sonnet" }
        if model.contains("haiku") { return "Haiku" }
        return model
    }
}

private extension DateFormatter {
    static let codexDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
