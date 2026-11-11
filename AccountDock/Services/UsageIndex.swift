import Foundation
import Darwin

private let log = FileLog("UsageIndex")

// MARK: - Indexed usage models
//
// The index stores deduped entries per file (not only pre-aggregated day
// buckets) so duplicates across resumed or forked sessions can be resolved
// globally at query time.
//
//   2. Each entry carries enough metadata (date, hour, model, speed, hash,
//      4 token types, tools, lines) that future per-project / per-hour /
//      per-sidechain slices need no schema change. File-level metadata
//      (project, sessionId, isSidechain) is hoisted to avoid per-entry
//      redundancy.
//
//   3. The pricing data the entries are valued against is tracked in the
//      envelope so divergent answers between users can be traced to the
//      specific snapshot in play.

/// One assistant row after per-file `(message.id, requestId)` dedup.
/// Multiple of these may share a `hash`, but only across files; at query
/// time they get deduped globally max-output-wins (matches ccusage 20.x).
struct CachedEntry: Codable, Sendable {
    /// "messageId:requestId", or nil if either id was missing.
    /// nil-hash entries are NEVER deduped — every occurrence is kept.
    let hash: String?
    let date: String        // local "yyyy-MM-dd"
    let hour: Int           // local 0–23
    let model: String       // raw model id from JSONL, including dated suffixes
    let speed: String?      // nil / "standard" / "fast"
    let input: Int
    let output: Int
    let cw: Int             // cache_creation_input_tokens (total)
    let cw1h: Int           // cache_creation.ephemeral_1h_input_tokens (1-hour TTL portion)
    let cr: Int             // cache_read_input_tokens
    let costUSDRow: Double? // value of `costUSD` if present in the JSONL row
    let tools: [String: Int]
    let linesWritten: Int
}

/// One JSONL file's parse result.
///
/// Cost data lives in `entries` (subject to global dedup).
/// Activity data lives in `activityByDate` as already-summed per-day
/// totals — activity counts (turns, active-minutes, tool counts, lines)
/// don't have the cross-file resume-duplicate problem cost has, so
/// per-file aggregation is correct and cheap.
struct CachedFile: Codable, Sendable {
    let mtimeUnix: Double               // bit-equal-comparable with FS mtime
    let parsedByteCount: UInt64          // append-only JSONL resume offset
    let earliestTimestampUnix: Double   // for cross-file sort order; .greatestFiniteMagnitude = "no timestamp, sorts last" (must stay finite — see save())
    let project: String                 // dir name under ~/.claude/projects/
    let sessionId: String?              // from the file's first row, if present
    let isSidechain: Bool               // true if path contains /subagents/
    let entries: [CachedEntry]
    let activityByDate: [String: ActivityDayContribution]
    let firstTimestampByDate: [String: Double]
    let lastTimestampByDate: [String: Double]
}

struct ActivityDayContribution: Codable, Sendable {
    let turns: Int
    let activeMinutes: Int
    let toolCounts: [String: Int]
    let linesWritten: Int
    let modelCounts: [String: Int]  // short name (Opus/Sonnet/Haiku)
}

/// What pricing snapshot is currently driving cost output. Stamped on
/// the envelope so it's debuggable from outside the app.
struct PricingMeta: Codable, Sendable {
    let source: String          // "bundle:abc1234" or "fresh:2026-05-15T03:00Z"
    let fetchedAt: Date?
}

// MARK: - UsageIndex

actor UsageIndex {
    static let shared = UsageIndex()

    private let claudeProjectsDir: String
    private let codexSessionsDir: URL
    private let kimiSessionsDir: URL
    private let database: UsageDatabase

    private var pricingMeta: PricingMeta = .init(source: "unknown", fetchedAt: nil)
    private var lastFilesystemRefresh: Date?
    private let minimumRefreshInterval: TimeInterval = 15 * 60

    /// Results computed from the index, which change only when
    /// `refreshFromFilesystem` rewrites it or the local day turns. Each
    /// `AppState.refresh` asks for all of them, and computing them reads
    /// every cost row in the database.
    private struct IndexSummaries {
        var indexedAt: Date?
        var day: String
        var cost: CostSummary?
        var activity: ActivityStats?
        var routed: [AIProviderType: [CostParser.CodexAggregateKey: CostParser.CodexTokenAggregate]] = [:]
    }

    private var summaries = IndexSummaries(indexedAt: nil, day: "")

    /// Drops the kept results when the index or the day has changed.
    private func currentSummaries() {
        let day = Self.localDateString(Date())
        if summaries.indexedAt != lastFilesystemRefresh || summaries.day != day {
            summaries = IndexSummaries(indexedAt: lastFilesystemRefresh, day: day)
        }
    }

    private init() {
        self.claudeProjectsDir = NSHomeDirectory() + "/.claude/projects"
        self.codexSessionsDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        self.kimiSessionsDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".kimi-code/sessions", isDirectory: true)

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        let dir = appSupport.appendingPathComponent("AccountDock", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.database = UsageDatabase(url: dir.appendingPathComponent("usage.sqlite"))
    }

    // MARK: Public API

    /// Walk `~/.claude/projects/**/*.jsonl`, re-parse any file whose mtime
    /// has changed, evict missing files, persist the result. All work runs
    /// on the actor's executor; the actor is on the cooperative pool, not
    /// the main thread, so the UI is never blocked.
    func refreshFromFilesystem() async {
        if let lastFilesystemRefresh,
           Date().timeIntervalSince(lastFilesystemRefresh) < minimumRefreshInterval {
            log.debug("refresh: skipped; compact index is less than 15 minutes old")
            return
        }
        await PricingService.shared.ensureLoaded()
        // Pick up a newer pricing snapshot the background download may have
        // written since launch — otherwise a long-lived session prices any
        // model released mid-session at $0. Runs before stamping/pricing so
        // this cycle's cost output already reflects the reloaded table.
        await PricingService.shared.reloadIfFreshChanged()
        // Capture the current pricing source for the envelope stamp.
        let src = await PricingService.shared.currentSource()
        pricingMeta = stampFor(source: src)
        // Trigger a TTL'd background refresh of the LiteLLM JSON. No-op if fresh.
        PricingService.shared.refreshInBackground()

        let start = Date()
        let result = Self.scanAndPersist(
            projectsDir: claudeProjectsDir,
            cachedFiles: database.claudeFiles(),
            database: database
        )
        let evicted = database.removeClaudeFiles(notIn: result.livePaths)
        let codexResult = Self.scanCodexAndPersist(
            sessionsDir: codexSessionsDir,
            cachedFiles: database.codexFiles(),
            database: database
        )
        let codexEvicted = database.removeCodexFiles(notIn: codexResult.livePaths)
        let kimiResult = Self.scanProviderAndPersist(
            .kimi,
            root: kimiSessionsDir,
            fileName: "wire.jsonl",
            cachedFiles: database.providerFiles(.kimi),
            database: database,
            scan: CostParser.scanKimiFile
        )
        _ = database.removeProviderFiles(.kimi, notIn: kimiResult.livePaths)

        let totalMs = Int(Date().timeIntervalSince(start) * 1000)
        lastFilesystemRefresh = Date()
        log.info(
            "refresh: scanned=\(result.livePaths.count) "
            + "hit=\(result.hits) miss=\(result.missesNew + result.missesMtime) "
            + "(new=\(result.missesNew), mtime=\(result.missesMtime)) "
            + "evicted=\(evicted) parse_total=\(result.parseElapsedMs)ms total=\(totalMs)ms "
            + "codex_scanned=\(codexResult.livePaths.count) codex_changed=\(codexResult.changed) "
            + "codex_evicted=\(codexEvicted) kimi_scanned=\(kimiResult.livePaths.count) kimi_changed=\(kimiResult.changed) "
            + "database=\(database.databasePageBytes())B pricing=\(pricingMeta.source)"
        )
    }

    /// Per-day, per-model cost summary. Applies global max-output-wins dedup
    /// across all cached files (keeping the largest-output copy of each
    /// duplicated message) to match ccusage 20.x's behavior.
    ///
    /// Each kept row is priced individually so the 200k-tier threshold
    /// and the fast multiplier apply per-request — not at the aggregated
    /// (date, model) level — which would let one fast or one 200k+ row
    /// contaminate every other row in its bucket.
    func costSummary() async -> CostSummary {
        currentSummaries()
        if let cost = summaries.cost { return cost }
        let indexedAt = lastFilesystemRefresh
        let cost = await computeCostSummary()
        // The await lets a refresh run; its index is not what was summed.
        currentSummaries()
        if indexedAt != nil, indexedAt == lastFilesystemRefresh { summaries.cost = cost }
        return cost
    }

    private func computeCostSummary() async -> CostSummary {
        await PricingService.shared.ensureLoaded()

        // (date, model) → running totals; cost is summed per-row.
        struct Acc {
            var input = 0, output = 0, cw = 0, cr = 0
            var cost: Double = 0
        }
        var bucket: [String: [String: Acc]] = [:]
        var sessionsByDate: [String: Set<String>] = [:]
        // Resolve every model's price in a single actor hop up front. Doing
        // this atomically — rather than awaiting `pricing(for:)` per row —
        // means a concurrent `reloadIfFreshChanged()` can't swap the pricing
        // table mid-summary and leave one result mixing old and new prices.
        let priceCache = await PricingService.shared.prices(
            for: database.distinctClaudeModels(),
            provider: .claudeCode
        )

        let routed = RouteTarget.allRoutedModels
        database.forEachCostEntry { e, sessionKey in
            // ccusage strips `<synthetic>` from modelBreakdowns at aggregation
            // time. These rows are zero-token / zero-cost anyway (compaction
            // events, internal errors), so skipping them changes no numbers —
            // only removes a meaningless entry from the UI's model column.
            if e.model == "<synthetic>" { return }
            // Turns the router served from a route target are that target's
            // provider's usage; `routedAggregates` reports them there.
            if routed.contains(e.model) { return }
            sessionsByDate[e.date, default: []].insert(sessionKey)

            // priceCache holds every model seen above; `?? nil` flattens
            // the optional-of-optional for a model with no pricing entry.
            let price = priceCache[e.model] ?? nil
            let rowCost = price?.cost(
                input: e.input, output: e.output,
                cacheCreate: e.cw, cacheCreate1h: e.cw1h, cacheRead: e.cr,
                isFast: e.speed == "fast"
            ) ?? 0

            var byModel = bucket[e.date] ?? [:]
            var acc = byModel[e.model] ?? Acc()
            acc.input += e.input
            acc.output += e.output
            acc.cw += e.cw
            acc.cr += e.cr
            acc.cost += rowCost
            byModel[e.model] = acc
            bucket[e.date] = byModel
        }

        var dailyCosts: [DailyCost] = []
        for (date, byModel) in bucket {
            var totalCost: Double = 0
            var modelBreakdown: [String: Double] = [:]
            var sumIn = 0, sumOut = 0, sumCW = 0, sumCR = 0
            for (model, acc) in byModel {
                totalCost += acc.cost
                let short = CostParser.shortModelName(model)
                modelBreakdown[short, default: 0] += acc.cost
                sumIn += acc.input; sumOut += acc.output
                sumCW += acc.cw; sumCR += acc.cr
            }
            dailyCosts.append(DailyCost(
                date: date,
                totalCost: totalCost,
                modelBreakdown: modelBreakdown,
                sessionCount: sessionsByDate[date]?.count ?? 0,
                inputTokens: sumIn,
                outputTokens: sumOut,
                cacheWriteTokens: sumCW,
                cacheReadTokens: sumCR
            ))
        }
        dailyCosts.sort { $0.date > $1.date }

        let todayStr = Self.localDateString(Date())
        let todayCost = dailyCosts.first(where: { $0.date == todayStr })?.totalCost ?? 0
        log.info("costSummary: \(dailyCosts.count) days, today=$\(String(format: "%.2f", todayCost))")
        return CostSummary(todayCost: todayCost, dailyCosts: dailyCosts)
    }

    /// Today's activity stats. Sidechain (subagent) files are excluded to
    /// avoid subagent tool calls inflating the headline.
    func activityStatsToday() -> ActivityStats {
        let today = Self.localDateString(Date())
        var stats = database.activity(on: today)
        stats.modelUsage = stats.modelUsage.filter { Self.isDisplayableModel($0.key) }
        log.info("activityStatsToday: turns=\(stats.conversationTurns) active=\(stats.activeCodingMinutes)m lines=\(stats.linesWritten)")
        return stats
    }

    func codexAggregates() -> [CostParser.CodexAggregateKey: CostParser.CodexTokenAggregate] {
        database.codexAggregates()
    }

    func providerAggregates(_ provider: AIProviderType) -> [CostParser.CodexAggregateKey: CostParser.CodexTokenAggregate] {
        database.providerAggregates(provider)
    }

    /// Whether `provider`'s usage is indexed as per-day, per-model
    /// aggregates. Claude Code's is indexed per request for `costSummary`.
    func aggregatesUsage(_ provider: AIProviderType) -> Bool {
        switch provider {
        case .codex, .kimi: true
        case .claudeCode, .gemini: false
        }
    }

    /// The per-day, per-model aggregates of a provider that has them.
    func aggregates(_ provider: AIProviderType) -> [CostParser.CodexAggregateKey: CostParser.CodexTokenAggregate] {
        switch provider {
        case .codex: database.codexAggregates()
        case .kimi: database.providerAggregates(provider)
        case .claudeCode, .gemini: [:]
        }
    }

    /// Claude Code turns the router served from a route target of
    /// `provider`, by day and model, in the provider aggregate form: input
    /// includes cached input.
    func routedAggregates(_ provider: AIProviderType) -> [CostParser.CodexAggregateKey: CostParser.CodexTokenAggregate] {
        currentSummaries()
        if let routed = summaries.routed[provider] { return routed }
        let routed = computeRoutedAggregates(provider)
        if lastFilesystemRefresh != nil { summaries.routed[provider] = routed }
        return routed
    }

    private func computeRoutedAggregates(_ provider: AIProviderType) -> [CostParser.CodexAggregateKey: CostParser.CodexTokenAggregate] {
        let models = RouteTarget.routedModels(for: provider)
        guard !models.isEmpty else { return [:] }
        var result: [CostParser.CodexAggregateKey: CostParser.CodexTokenAggregate] = [:]
        database.forEachCostEntry { entry, _ in
            guard models.contains(entry.model) else { return }
            let key = CostParser.CodexAggregateKey(day: entry.date, model: entry.model, reasoningEffort: nil)
            var aggregate = result[key] ?? CostParser.CodexTokenAggregate()
            aggregate.input += entry.input + entry.cr
            aggregate.cachedInput += entry.cr
            aggregate.cacheWrite += entry.cw + entry.cw1h
            aggregate.output += entry.output
            aggregate.events += 1
            result[key] = aggregate
        }
        return result
    }

    private static func isDisplayableModel(_ model: String) -> Bool {
        let cleaned = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return !cleaned.isEmpty &&
            !cleaned.localizedCaseInsensitiveContains("synthetic") &&
            cleaned != "<unknown>"
    }

    /// Read-only view of the pricing snapshot in use. Surfaced for
    /// debugging UIs and the Cost tab's "How We Calculate" line.
    func pricingMetaSnapshot() -> PricingMeta { pricingMeta }

    // MARK: - Scan & parse

    private struct ScanResult {
        let livePaths: Set<String>
        let hits: Int
        let missesNew: Int
        let missesMtime: Int
        let parseElapsedMs: Int
    }

    private static func scanAndPersist(
        projectsDir: String,
        cachedFiles: [String: StoredFileMetadata],
        database: UsageDatabase
    ) -> ScanResult {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: projectsDir, isDirectory: true)
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            log.warning("scan: cannot enumerate \(projectsDir)")
            return ScanResult(livePaths: [], hits: 0, missesNew: 0, missesMtime: 0, parseElapsedMs: 0)
        }

        var live: Set<String> = []
        var hits = 0, missesNew = 0, missesMtime = 0, parseMs = 0
        var filesParsed = 0

        while let url = enumerator.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { continue }
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard values.isRegularFile == true, url.pathExtension == "jsonl" else { continue }
            let filePath = url.path
            let rel = String(filePath.dropFirst(projectsDir.count + 1))
            guard let attrs = try? fm.attributesOfItem(atPath: filePath),
                  let mtimeDate = attrs[.modificationDate] as? Date,
                  let fileSizeNumber = attrs[.size] as? NSNumber else { continue }
            let mtime = mtimeDate.timeIntervalSince1970
            let fileSize = fileSizeNumber.uint64Value
            live.insert(filePath)

            if let cached = cachedFiles[filePath], cached.modificationTime == mtime {
                hits += 1
                continue
            }
            if cachedFiles[filePath] == nil { missesNew += 1 } else { missesMtime += 1 }

            let t0 = Date()
            autoreleasepool {
                if let cached = cachedFiles[filePath],
                   fileSize >= cached.byteCount,
                   cached.byteCount > 0,
                   let delta = parseFile(
                       at: filePath,
                       relativePath: rel,
                       mtime: mtime,
                       fileSize: fileSize,
                       startingAt: cached.byteCount
                   ) {
                    database.appendClaudeFile(path: filePath, parsed: delta)
                } else if let parsed = parseFile(
                    at: filePath,
                    relativePath: rel,
                    mtime: mtime,
                    fileSize: fileSize
                ) {
                    database.replaceClaudeFile(path: filePath, parsed: parsed)
                }
            }
            filesParsed += 1
            if filesParsed.isMultiple(of: 100) {
                // JSONSerialization creates many short-lived allocations. The
                // autorelease pool releases them; pressure relief returns the
                // now-empty allocator pages during a large first-run import.
                malloc_zone_pressure_relief(nil, 0)
            }
            parseMs += Int(Date().timeIntervalSince(t0) * 1000)
        }

        return ScanResult(livePaths: live, hits: hits,
                          missesNew: missesNew, missesMtime: missesMtime,
                          parseElapsedMs: parseMs)
    }

    private struct CodexScanResult {
        let livePaths: Set<String>
        let changed: Int
    }

    private static func scanCodexAndPersist(
        sessionsDir: URL,
        cachedFiles: [String: StoredFileMetadata],
        database: UsageDatabase
    ) -> CodexScanResult {
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return CodexScanResult(livePaths: [], changed: 0) }

        var live: Set<String> = []
        var changed = 0
        while let url = enumerator.nextObject() as? URL {
            guard let values = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
                  ) else { continue }
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard values.isRegularFile == true,
                  url.pathExtension == "jsonl",
                  let modified = values.contentModificationDate else { continue }
            let mtime = modified.timeIntervalSince1970
            let byteCount = UInt64(values.fileSize ?? 0)
            live.insert(url.path)
            if let cached = cachedFiles[url.path],
               cached.modificationTime == mtime,
               cached.byteCount == byteCount { continue }
            autoreleasepool {
                database.replaceCodexFile(
                    path: url.path,
                    modificationTime: mtime,
                    byteCount: byteCount,
                    aggregates: CostParser.scanCodexFile(url)
                )
            }
            changed += 1
            if changed.isMultiple(of: 100) { malloc_zone_pressure_relief(nil, 0) }
        }
        return CodexScanResult(livePaths: live, changed: changed)
    }

    /// Indexes one provider's transcript files named `fileName` under `root`.
    /// A file is rescanned only when its modification time or size changed.
    private static func scanProviderAndPersist(
        _ provider: AIProviderType,
        root: URL,
        fileName: String,
        cachedFiles: [String: StoredFileMetadata],
        database: UsageDatabase,
        scan: (URL) -> [CostParser.CodexAggregateKey: CostParser.CodexTokenAggregate]
    ) -> CodexScanResult {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return CodexScanResult(livePaths: [], changed: 0) }
        var live: Set<String> = []
        var changed = 0
        while let url = enumerator.nextObject() as? URL {
            guard let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
            ) else { continue }
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard values.isRegularFile == true, url.lastPathComponent == fileName,
                  let modified = values.contentModificationDate else { continue }
            let mtime = modified.timeIntervalSince1970
            let byteCount = UInt64(values.fileSize ?? 0)
            live.insert(url.path)
            if let cached = cachedFiles[url.path],
               cached.modificationTime == mtime,
               cached.byteCount == byteCount { continue }
            autoreleasepool {
                database.replaceProviderFile(
                    provider,
                    path: url.path,
                    modificationTime: mtime,
                    byteCount: byteCount,
                    aggregates: scan(url)
                )
            }
            changed += 1
        }
        return CodexScanResult(livePaths: live, changed: changed)
    }

    // MARK: - Helpers

    private nonisolated func stampFor(source: PricingSource) -> PricingMeta {
        switch source {
        case .bundle(let commit):
            return PricingMeta(source: "bundle:\(commit)", fetchedAt: nil)
        case .fresh(let at):
            let f = ISO8601DateFormatter()
            return PricingMeta(source: "fresh:\(f.string(from: at))", fetchedAt: at)
        }
    }

    private static func localDateString(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: d)
    }
}

// MARK: - Per-file parser
//
// Reads one JSONL file and produces (a) deduped per-file cost entries and
// (b) per-date activity contributions. Pure: no actor state, no side effects.

private func parseFile(
    at path: String,
    relativePath: String,
    mtime: Double,
    fileSize: UInt64,
    startingAt offset: UInt64 = 0
) -> CachedFile? {
    guard FileManager.default.isReadableFile(atPath: path) else { return nil }

    let isoMain = ISO8601DateFormatter()
    isoMain.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let isoAlt = ISO8601DateFormatter()
    isoAlt.formatOptions = [.withInternetDateTime]

    let dateFmt = DateFormatter()
    dateFmt.dateFormat = "yyyy-MM-dd"
    dateFmt.locale = Locale(identifier: "en_US_POSIX")
    let hourFmt = DateFormatter()
    hourFmt.dateFormat = "H"
    hourFmt.locale = Locale(identifier: "en_US_POSIX")

    // File-level metadata (project, sessionId, isSidechain) is determined
    // by path shape; we infer it without scanning the JSON.
    let project: String = {
        let parts = relativePath.split(separator: "/")
        return parts.first.map(String.init) ?? "unknown"
    }()
    let isSidechain = relativePath.contains("/subagents/")
    var sessionId: String?
    var earliest: Date?

    // Per-file cost dedup state.
    var perFileBest: [String: Int] = [:]   // hash -> index of current max-output winner in costEntries
    var costEntries: [CachedEntry] = []

    // Per-date activity bookkeeping.
    var perDayTurns: [String: Int] = [:]
    var perDayTools: [String: [String: Int]] = [:]
    var perDayModels: [String: [String: Int]] = [:]
    var perDayLines: [String: Int] = [:]
    var perDayTimestamps: [String: [Date]] = [:]
    var perDayActivityRequestSeen: Set<String> = []

    // Strict schema regexes — originally lifted from ccusage 18.0.11's JS parser;
    // the row-acceptance schema is unchanged in 20.x (token columns still reconcile).
    // Bare patterns; ranges checked with `.regularExpression`.
    let timestampPattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{3})?Z$"#
    let versionPattern   = #"^\d+\.\d+\.\d+"#

    guard JSONLStreamReader.read(path: path, startingAt: offset, handleLine: { lineData in
        guard !lineData.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
        else { return }

        guard let timestampStr = obj["timestamp"] as? String,
              timestampStr.range(of: timestampPattern, options: .regularExpression) != nil,
              let timestamp = isoMain.date(from: timestampStr) ?? isoAlt.date(from: timestampStr)
        else { return }

        // `version`: if present, must match `^\d+\.\d+\.\d+`. Stale Claude
        // Code writes occasionally produce non-version strings here.
        if let v = obj["version"] {
            guard let vs = v as? String,
                  vs.range(of: versionPattern, options: .regularExpression) != nil else { return }
        }

        if earliest == nil || timestamp < earliest! { earliest = timestamp }
        if sessionId == nil, let s = obj["sessionId"] as? String, !s.isEmpty { sessionId = s }

        let dateStr = dateFmt.string(from: timestamp)
        let hour = Int(hourFmt.string(from: timestamp)) ?? 0
        let type = obj["type"] as? String ?? ""

        perDayTimestamps[dateStr, default: []].append(timestamp)

        switch type {
        case "user":
            let message = obj["message"] as? [String: Any]
            let rawContent = message?["content"]
            if let s = rawContent as? String, !s.isEmpty {
                perDayTurns[dateStr, default: 0] += 1
            } else if let arr = rawContent as? [[String: Any]] {
                let hasToolResult = arr.contains { $0["type"] as? String == "tool_result" }
                if !hasToolResult { perDayTurns[dateStr, default: 0] += 1 }
            }

        case "assistant":
            guard let message = obj["message"] as? [String: Any] else { return }

            // === Cost entry path (ccusage parity) ===
            // Match ccusage: any row with numeric input/output_tokens
            // gets its own entry. Schema is loose; rows with `<synthetic>` model
            // contribute zero-token entries, which is intentional — they're filtered
            // out from cost breakdowns at presentation time.
            if let usage = message["usage"] as? [String: Any],
               let input = usage["input_tokens"] as? Int,
               let output = usage["output_tokens"] as? Int {
                let cw = (usage["cache_creation_input_tokens"] as? Int) ?? 0
                // 1-hour-TTL portion of the cache write (billed higher than 5m).
                let cw1h = ((usage["cache_creation"] as? [String: Any])?["ephemeral_1h_input_tokens"] as? Int) ?? 0
                let cr = (usage["cache_read_input_tokens"] as? Int) ?? 0
                // `speed`: ccusage rejects values other than nil/"standard"/"fast".
                let rawSpeed = usage["speed"]
                let speed: String?
                if rawSpeed is NSNull || rawSpeed == nil {
                    speed = nil
                } else if let s = rawSpeed as? String, s == "standard" || s == "fast" {
                    speed = s
                } else {
                    return  // unsupported value -> reject row (matches reference)
                }
                // Non-empty-string requirements for id-like fields. An empty
                // string would collapse hash buckets like `":req_xxx"` → false dedup.
                let modelRaw = (message["model"] as? String) ?? ""
                guard !modelRaw.isEmpty else { return }
                let model = modelRaw

                let messageId: String? = {
                    guard let s = message["id"] as? String, !s.isEmpty else { return nil }
                    return s
                }()
                let requestId: String? = {
                    guard let s = obj["requestId"] as? String, !s.isEmpty else { return nil }
                    return s
                }()
                let costUSD = obj["costUSD"] as? Double
                let hash: String? = {
                    if let m = messageId, let r = requestId { return "\(m):\(r)" }
                    return nil
                }()

                // Tool counts + linesWritten for THIS row, attached at entry
                // level so we can slice cost-by-tool later if needed.
                var rowTools: [String: Int] = [:]
                var rowLines = 0
                if let arr = message["content"] as? [[String: Any]] {
                    for block in arr where (block["type"] as? String) == "tool_use" {
                        guard let toolName = block["name"] as? String else { continue }
                        rowTools[toolName, default: 0] += 1
                        if let input = block["input"] as? [String: Any] {
                            rowLines += estimateLines(tool: toolName, input: input)
                        }
                    }
                }
                let entry = CachedEntry(
                    hash: hash,
                    date: dateStr,
                    hour: hour,
                    model: model,
                    speed: speed,
                    input: input, output: output, cw: cw, cw1h: cw1h, cr: cr,
                    costUSDRow: costUSD,
                    tools: rowTools,
                    linesWritten: rowLines
                )
                // Per-file max-output-wins dedup. A message written more than once
                // (partial stream snapshot + final copy) shares a hash; input/cache
                // are identical across copies, only output_tokens grows, so keep the
                // largest-output copy. Global dedup happens later in costSummary.
                // nil-hash rows are never deduped — every occurrence is kept.
                if let h = hash {
                    if let idx = perFileBest[h] {
                        if output > costEntries[idx].output { costEntries[idx] = entry }
                    } else {
                        perFileBest[h] = costEntries.count
                        costEntries.append(entry)
                    }
                } else {
                    costEntries.append(entry)
                }
            }

            // === Activity-data path (file-level aggregation) ===
            // Model usage is deduped by requestId within each file,
            // tool counts and linesWritten summed across all assistant rows
            // (not just deduped winners).
            if let model = message["model"] as? String,
               let requestId = obj["requestId"] as? String,
               !perDayActivityRequestSeen.contains(requestId) {
                perDayActivityRequestSeen.insert(requestId)
                let short = CostParser.shortModelName(model)
                perDayModels[dateStr, default: [:]][short, default: 0] += 1
            }
            if let arr = message["content"] as? [[String: Any]] {
                for block in arr where (block["type"] as? String) == "tool_use" {
                    guard let toolName = block["name"] as? String else { continue }
                    perDayTools[dateStr, default: [:]][toolName, default: 0] += 1
                    if let input = block["input"] as? [String: Any] {
                        perDayLines[dateStr, default: 0] += estimateLines(tool: toolName, input: input)
                    }
                }
            }

        default: break
        }
    }) else { return nil }

    // Reduce activity per-day.
    var activityOut: [String: ActivityDayContribution] = [:]
    let allDates = Set(perDayTurns.keys)
        .union(perDayTools.keys)
        .union(perDayModels.keys)
        .union(perDayLines.keys)
        .union(perDayTimestamps.keys)
    for date in allDates {
        let active = calculateActiveMinutes(perDayTimestamps[date] ?? [])
        let c = ActivityDayContribution(
            turns: perDayTurns[date] ?? 0,
            activeMinutes: active,
            toolCounts: perDayTools[date] ?? [:],
            linesWritten: perDayLines[date] ?? 0,
            modelCounts: perDayModels[date] ?? [:]
        )
        if c.turns > 0 || c.activeMinutes > 0 || !c.toolCounts.isEmpty
            || c.linesWritten > 0 || !c.modelCounts.isEmpty {
            activityOut[date] = c
        }
    }

    return CachedFile(
        mtimeUnix: mtime,
        parsedByteCount: fileSize,
        // Must stay FINITE: JSONEncoder rejects non-finite floats by default, so a
        // single timestamp-less file with .infinity here made save() throw and the
        // whole cache silently never persisted (forcing a full re-parse every
        // cycle). .greatestFiniteMagnitude still sorts after every real timestamp.
        earliestTimestampUnix: earliest?.timeIntervalSince1970 ?? .greatestFiniteMagnitude,
        project: project,
        sessionId: sessionId,
        isSidechain: isSidechain,
        entries: costEntries,
        activityByDate: activityOut,
        firstTimestampByDate: perDayTimestamps.mapValues {
            $0.map(\.timeIntervalSince1970).min() ?? 0
        },
        lastTimestampByDate: perDayTimestamps.mapValues {
            $0.map(\.timeIntervalSince1970).max() ?? 0
        }
    )
}

/// Active coding minutes from a single date's timestamp set. Uses the same
/// algorithm (10-min idle gap splits sessions, 2-min tail padding).
private func calculateActiveMinutes(_ timestamps: [Date]) -> Int {
    let maxGap: TimeInterval = 10 * 60
    let tailPadding: TimeInterval = 2 * 60
    guard timestamps.count >= 2 else {
        return timestamps.isEmpty ? 0 : max(1, Int(tailPadding / 60))
    }
    let sorted = timestamps.sorted()
    var total: TimeInterval = 0
    var periodStart = sorted[0]
    var periodEnd = sorted[0]
    for i in 1..<sorted.count {
        let gap = sorted[i].timeIntervalSince(periodEnd)
        if gap <= maxGap {
            periodEnd = sorted[i]
        } else {
            total += periodEnd.timeIntervalSince(periodStart) + tailPadding
            periodStart = sorted[i]
            periodEnd = sorted[i]
        }
    }
    total += periodEnd.timeIntervalSince(periodStart) + tailPadding
    return total > 0 ? max(1, Int(total / 60)) : 0
}

private func estimateLines(tool: String, input: [String: Any]) -> Int {
    switch tool {
    case "Write":
        let content = input["content"] as? String ?? ""
        return content.components(separatedBy: "\n").count
    case "Edit":
        let newStr = input["new_string"] as? String ?? ""
        let oldStr = input["old_string"] as? String ?? ""
        return max(0, newStr.components(separatedBy: "\n").count - oldStr.components(separatedBy: "\n").count)
    default:
        return 0
    }
}
