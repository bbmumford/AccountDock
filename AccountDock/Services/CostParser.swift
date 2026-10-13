import Foundation

/// Provides cost summaries from Claude Code session JSONL files.
/// All actual parsing is done by the unified `UsageIndex`; this is a thin facade.
final class CostParser: Sendable {
    struct CodexCostHistory: Sendable {
        let dailyCosts: [String: Double]
        let todayModelActivity: [String: Int]
        let todayModelCosts: [String: Double]
    }
    static let shared = CostParser()
    private init() {}

    /// Compute cost summary from the persistent usage index.
    /// Caller must ensure `UsageIndex.shared.refreshFromFilesystem()`
    /// has been awaited at least once this cycle.
    func getCostSummary() async -> CostSummary {
        return await UsageIndex.shared.costSummary()
    }

    /// Native Codex JSONL aggregation. This reads ~/.codex/sessions directly;
    /// AccountDock does not invoke CodexBar.
    func getCodexCostHistory() async -> CodexCostHistory {
        await PricingService.shared.ensureLoaded()
        let aggregates = await UsageIndex.shared.codexAggregates()
        let today = DateFormatter.codexDay.string(from: Date())
        var dailyCosts: [String: Double] = [:]
        var todayModelCosts: [String: Double] = [:]
        var modelActivity: [String: Int] = [:]
        for (key, aggregate) in aggregates {
            guard let price = await PricingService.shared.pricing(
                for: key.model,
                provider: .codex,
                reasoningEffort: key.reasoningEffort
            ) else { continue }
            let uncachedInput = max(0, aggregate.input - aggregate.cachedInput)
            let cost = price.cost(
                input: uncachedInput,
                output: aggregate.output,
                cacheCreate: 0,
                cacheCreate1h: 0,
                cacheRead: aggregate.cachedInput,
                isFast: false
            )
            guard cost > 0 else { continue }
            dailyCosts[key.day, default: 0] += cost
            if key.day == today {
                todayModelCosts[key.displayKey, default: 0] += cost
                modelActivity[key.displayKey, default: 0] += aggregate.events
            }
        }
        return CodexCostHistory(
            dailyCosts: dailyCosts,
            todayModelActivity: modelActivity,
            todayModelCosts: todayModelCosts
        )
    }

    struct CodexAggregateKey: Hashable, Codable, Sendable {
        let day: String
        let model: String
        let reasoningEffort: String?

        var displayKey: String {
            guard let reasoningEffort, !reasoningEffort.isEmpty else { return model }
            return "\(model) · \(reasoningEffort)"
        }
    }

    struct CodexTokenAggregate: Codable, Sendable {
        var input = 0
        var cachedInput = 0
        var output = 0
        var events = 0
    }

    static func scanCodexFile(_ url: URL) -> [CodexAggregateKey: CodexTokenAggregate] {
        var aggregates: [CodexAggregateKey: CodexTokenAggregate] = [:]
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"

        var model: String?
        var reasoningEffort: String?
        JSONLStreamReader.read(path: url.path) { data in
                guard let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let payload = row["payload"] as? [String: Any] else { return }
                if row["type"] as? String == "turn_context",
                   let value = payload["model"] as? String {
                    let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    model = Self.isDisplayableCodexModel(cleaned) ? cleaned : nil
                    reasoningEffort = (payload["effort"] as? String)
                        ?? (payload["reasoning_effort"] as? String)
                    return
                }
                guard payload["type"] as? String == "token_count",
                      let info = payload["info"] as? [String: Any],
                      let usage = info["last_token_usage"] as? [String: Any],
                      let model,
                      let rawTimestamp = row["timestamp"] as? String,
                      let date = iso.date(from: rawTimestamp) else { return }
                let key = CodexAggregateKey(
                    day: dayFormatter.string(from: date),
                    model: model,
                    reasoningEffort: reasoningEffort
                )
                var aggregate = aggregates[key] ?? CodexTokenAggregate()
                aggregate.input += usage["input_tokens"] as? Int ?? 0
                aggregate.cachedInput += usage["cached_input_tokens"] as? Int ?? 0
                aggregate.output += usage["output_tokens"] as? Int ?? 0
                aggregate.events += 1
                aggregates[key] = aggregate
        }
        return aggregates
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

/// Small persistent index of per-file token totals. It prevents every refresh
/// from walking gigabytes of immutable Codex transcript history and deliberately
/// contains no prompts, responses, tool payloads, or credentials.
private actor CodexCostIndex {
    static let shared = CodexCostIndex()

    private struct CachedFile: Codable {
        let modificationTime: Double
        let byteCount: UInt64
        let aggregates: [CostParser.CodexAggregateKey: CostParser.CodexTokenAggregate]
    }

    private struct Envelope: Codable {
        var files: [String: CachedFile]
    }

    private var files: [String: CachedFile] = [:]
    private var loaded = false
    private var lastScan: Date?
    private let minimumScanInterval: TimeInterval = 15 * 60

    func aggregates() async -> [CostParser.CodexAggregateKey: CostParser.CodexTokenAggregate] {
        loadIfNeeded()
        if lastScan.map({ Date().timeIntervalSince($0) >= minimumScanInterval }) ?? true {
            await refresh()
        }
        return combined()
    }

    private func refresh() async {
        let root = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        let previous = files
        let updated = await Task.detached(priority: .utility) { () -> [String: CachedFile] in
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { return [:] }
            var result: [String: CachedFile] = [:]
            while let url = enumerator.nextObject() as? URL {
                guard url.pathExtension == "jsonl" else { continue }
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                      let modified = values.contentModificationDate else { continue }
                let byteCount = UInt64(values.fileSize ?? 0)
                let mtime = modified.timeIntervalSince1970
                if let cached = previous[url.path],
                   cached.modificationTime == mtime,
                   cached.byteCount == byteCount {
                    result[url.path] = cached
                } else {
                    result[url.path] = CachedFile(
                        modificationTime: mtime,
                        byteCount: byteCount,
                        aggregates: CostParser.scanCodexFile(url)
                    )
                }
            }
            return result
        }.value
        let changed = updated.keys != files.keys || updated.contains { files[$0.key]?.modificationTime != $0.value.modificationTime }
        files = updated
        lastScan = Date()
        if changed { save() }
    }

    private func combined() -> [CostParser.CodexAggregateKey: CostParser.CodexTokenAggregate] {
        var result: [CostParser.CodexAggregateKey: CostParser.CodexTokenAggregate] = [:]
        for file in files.values {
            for (key, value) in file.aggregates {
                var total = result[key] ?? .init()
                total.input += value.input
                total.cachedInput += value.cachedInput
                total.output += value.output
                total.events += value.events
                result[key] = total
            }
        }
        return result
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: cacheURL),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return }
        files = envelope.files
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Envelope(files: files)) else { return }
        let directory = cacheURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }

    private var cacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AccountDock", isDirectory: true)
            .appendingPathComponent("codex-cost-index-v1.json")
    }
}

private extension DateFormatter {
    static let codexDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
