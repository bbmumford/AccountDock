import Foundation
import SQLite3

private let usageDBLog = FileLog("UsageDatabase")
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct StoredFileMetadata: Sendable {
    let modificationTime: Double
    let byteCount: UInt64
}

/// The sole persistent usage index. It contains only numerical aggregates and
/// transcript offsets; prompts, responses, tool payloads and credentials are
/// never stored.
final class UsageDatabase: @unchecked Sendable {
    private var db: OpaquePointer?

    init(url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard sqlite3_open_v2(
            url.path,
            &db,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK else {
            usageDBLog.error("Unable to open usage database")
            return
        }
        execute("PRAGMA journal_mode=WAL")
        execute("PRAGMA synchronous=NORMAL")
        execute("PRAGMA temp_store=FILE")
        execute("PRAGMA cache_size=-8192")
        execute("PRAGMA foreign_keys=ON")
        createSchema()
    }

    deinit { close() }

    func close() {
        guard let db else { return }
        sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
        sqlite3_close(db)
        self.db = nil
    }

    func claudeFiles() -> [String: StoredFileMetadata] {
        var result: [String: StoredFileMetadata] = [:]
        query("SELECT path, mtime, byte_count FROM claude_files") { row in
            result[row.text(0)] = StoredFileMetadata(
                modificationTime: row.double(1),
                byteCount: UInt64(max(0, row.int64(2)))
            )
        }
        return result
    }

    func codexFiles() -> [String: StoredFileMetadata] {
        var result: [String: StoredFileMetadata] = [:]
        query("SELECT path, mtime, byte_count FROM codex_files") { row in
            result[row.text(0)] = StoredFileMetadata(
                modificationTime: row.double(1),
                byteCount: UInt64(max(0, row.int64(2)))
            )
        }
        return result
    }

    func replaceCodexFile(
        path: String,
        modificationTime: Double,
        byteCount: UInt64,
        aggregates: [CostParser.CodexAggregateKey: CostParser.CodexTokenAggregate]
    ) {
        transaction {
            run("DELETE FROM codex_files WHERE path=?", [.text(path)])
            run("INSERT INTO codex_files(path,mtime,byte_count) VALUES(?,?,?)", [
                .text(path), .double(modificationTime), .int64(Int64(byteCount))
            ])
            for (key, value) in aggregates {
                run("""
                    INSERT INTO codex_aggregates(file_path,date,model,reasoning,input,cached_input,output,events)
                    VALUES(?,?,?,?,?,?,?,?)
                    """, [
                        .text(path), .text(key.day), .text(key.model),
                        key.reasoningEffort.map(Binding.text) ?? .null,
                        .int64(Int64(value.input)), .int64(Int64(value.cachedInput)),
                        .int64(Int64(value.output)), .int64(Int64(value.events))
                    ])
            }
        }
    }

    func removeCodexFiles(notIn livePaths: Set<String>) -> Int {
        var removed = 0
        for path in codexFiles().keys where !livePaths.contains(path) {
            transaction { run("DELETE FROM codex_files WHERE path=?", [.text(path)]) }
            removed += 1
        }
        return removed
    }

    func codexAggregates() -> [CostParser.CodexAggregateKey: CostParser.CodexTokenAggregate] {
        var result: [CostParser.CodexAggregateKey: CostParser.CodexTokenAggregate] = [:]
        query("""
            SELECT date,model,reasoning,SUM(input),SUM(cached_input),SUM(output),SUM(events)
            FROM codex_aggregates GROUP BY date,model,reasoning
            """) { row in
            result[CostParser.CodexAggregateKey(
                day: row.text(0), model: row.text(1), reasoningEffort: row.optionalText(2)
            )] = CostParser.CodexTokenAggregate(
                input: Int(row.int64(3)), cachedInput: Int(row.int64(4)),
                output: Int(row.int64(5)), events: Int(row.int64(6))
            )
        }
        return result
    }

    func replaceClaudeFile(path: String, parsed: CachedFile) {
        transaction {
            deleteClaudeRows(path: path)
            upsertClaudeFile(path: path, parsed: parsed)
            insertEntries(path: path, entries: parsed.entries)
            insertActivities(path: path, parsed: parsed, additive: false)
        }
    }

    func appendClaudeFile(path: String, parsed: CachedFile) {
        transaction {
            upsertClaudeFile(path: path, parsed: parsed)
            insertEntries(path: path, entries: parsed.entries)
            insertActivities(path: path, parsed: parsed, additive: true)
        }
    }

    func removeClaudeFiles(notIn livePaths: Set<String>) -> Int {
        var removed = 0
        for path in claudeFiles().keys where !livePaths.contains(path) {
            transaction { deleteClaudeRows(path: path) }
            removed += 1
        }
        return removed
    }

    func distinctClaudeModels() -> [String] {
        var result: [String] = []
        query("SELECT DISTINCT model FROM claude_entries WHERE model != '<synthetic>'") {
            result.append($0.text(0))
        }
        return result
    }

    func forEachCostEntry(_ body: (CachedEntry, String) -> Void) {
        let sql = """
        WITH ranked AS (
          SELECT e.*, COALESCE(f.session_id, e.file_path) AS session_key,
                 CASE WHEN e.hash IS NULL THEN 1
                      ELSE ROW_NUMBER() OVER (PARTITION BY e.hash ORDER BY e.output DESC, e.id DESC)
                 END AS rank_number
          FROM claude_entries e JOIN claude_files f ON f.path = e.file_path
        )
        SELECT hash,date,hour,model,speed,input,output,cache_write,cache_write_hour,cache_read,
               cost_usd,tools_json,lines_written,session_key
        FROM ranked WHERE hash IS NULL OR rank_number = 1
        """
        query(sql) { row in
            let tools: [String: Int] = Self.decodeDictionary(row.text(11))
            body(CachedEntry(
                hash: row.optionalText(0), date: row.text(1), hour: Int(row.int64(2)),
                model: row.text(3), speed: row.optionalText(4),
                input: Int(row.int64(5)), output: Int(row.int64(6)),
                cw: Int(row.int64(7)), cw1h: Int(row.int64(8)), cr: Int(row.int64(9)),
                costUSDRow: row.isNull(10) ? nil : row.double(10),
                tools: tools, linesWritten: Int(row.int64(12))
            ), row.text(13))
        }
    }

    func activity(on date: String) -> ActivityStats {
        var stats = ActivityStats.empty
        query("""
            SELECT a.turns,a.active_minutes,a.tools_json,a.lines_written,a.models_json
            FROM claude_activity a JOIN claude_files f ON f.path=a.file_path
            WHERE a.date=? AND f.sidechain=0
            """
            , bindings: [.text(date)]) { row in
            stats.conversationTurns += Int(row.int64(0))
            stats.activeCodingMinutes += Int(row.int64(1))
            for (key, value) in Self.decodeDictionary(row.text(2)) { stats.toolUsage[key, default: 0] += value }
            stats.linesWritten += Int(row.int64(3))
            for (key, value) in Self.decodeDictionary(row.text(4)) { stats.modelUsage[key, default: 0] += value }
        }
        return stats
    }

    func databasePageBytes() -> Int64 {
        var pageCount: Int64 = 0, pageSize: Int64 = 0
        query("PRAGMA page_count") { pageCount = $0.int64(0) }
        query("PRAGMA page_size") { pageSize = $0.int64(0) }
        return pageCount * pageSize
    }

    private func createSchema() {
        execute("""
        CREATE TABLE IF NOT EXISTS claude_files(
          path TEXT PRIMARY KEY, mtime REAL NOT NULL, byte_count INTEGER NOT NULL,
          project TEXT NOT NULL, session_id TEXT, sidechain INTEGER NOT NULL,
          earliest REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS claude_entries(
          id INTEGER PRIMARY KEY, file_path TEXT NOT NULL REFERENCES claude_files(path) ON DELETE CASCADE,
          hash TEXT, date TEXT NOT NULL, hour INTEGER NOT NULL, model TEXT NOT NULL, speed TEXT,
          input INTEGER NOT NULL, output INTEGER NOT NULL, cache_write INTEGER NOT NULL,
          cache_write_hour INTEGER NOT NULL, cache_read INTEGER NOT NULL, cost_usd REAL,
          tools_json TEXT NOT NULL, lines_written INTEGER NOT NULL
        );
        CREATE UNIQUE INDEX IF NOT EXISTS claude_entry_hash ON claude_entries(file_path,hash) WHERE hash IS NOT NULL;
        CREATE INDEX IF NOT EXISTS claude_entry_date ON claude_entries(date);
        CREATE INDEX IF NOT EXISTS claude_entry_hash_global ON claude_entries(hash,output DESC);
        CREATE TABLE IF NOT EXISTS claude_activity(
          file_path TEXT NOT NULL REFERENCES claude_files(path) ON DELETE CASCADE,
          date TEXT NOT NULL, turns INTEGER NOT NULL, active_minutes INTEGER NOT NULL,
          tools_json TEXT NOT NULL, lines_written INTEGER NOT NULL, models_json TEXT NOT NULL,
          first_timestamp REAL, last_timestamp REAL, PRIMARY KEY(file_path,date)
        );
        CREATE TABLE IF NOT EXISTS codex_files(
          path TEXT PRIMARY KEY, mtime REAL NOT NULL, byte_count INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS codex_aggregates(
          file_path TEXT NOT NULL REFERENCES codex_files(path) ON DELETE CASCADE,
          date TEXT NOT NULL, model TEXT NOT NULL, reasoning TEXT,
          input INTEGER NOT NULL, cached_input INTEGER NOT NULL, output INTEGER NOT NULL,
          events INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS codex_aggregate_date ON codex_aggregates(date);
        """)
    }

    private func deleteClaudeRows(path: String) {
        run("DELETE FROM claude_files WHERE path=?", [.text(path)])
    }

    private func upsertClaudeFile(path: String, parsed: CachedFile) {
        run("""
            INSERT INTO claude_files(path,mtime,byte_count,project,session_id,sidechain,earliest)
            VALUES(?,?,?,?,?,?,?) ON CONFLICT(path) DO UPDATE SET
            mtime=excluded.mtime,byte_count=excluded.byte_count,project=excluded.project,
            session_id=COALESCE(excluded.session_id,claude_files.session_id),
            sidechain=excluded.sidechain,earliest=MIN(claude_files.earliest,excluded.earliest)
            """
            , [
                .text(path), .double(parsed.mtimeUnix), .int64(Int64(parsed.parsedByteCount)),
                .text(parsed.project), parsed.sessionId.map(Binding.text) ?? .null,
                .int64(parsed.isSidechain ? 1 : 0), .double(parsed.earliestTimestampUnix)
            ])
    }

    private func insertEntries(path: String, entries: [CachedEntry]) {
        let sql = """
            INSERT INTO claude_entries(file_path,hash,date,hour,model,speed,input,output,cache_write,
            cache_write_hour,cache_read,cost_usd,tools_json,lines_written) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(file_path,hash) WHERE hash IS NOT NULL DO UPDATE SET
            output=MAX(output,excluded.output), input=excluded.input, cache_write=excluded.cache_write,
            cache_write_hour=excluded.cache_write_hour, cache_read=excluded.cache_read,
            cost_usd=excluded.cost_usd, tools_json=excluded.tools_json, lines_written=excluded.lines_written
            """
        for entry in entries {
            run(sql, [
                .text(path), entry.hash.map(Binding.text) ?? .null, .text(entry.date), .int64(Int64(entry.hour)),
                .text(entry.model), entry.speed.map(Binding.text) ?? .null,
                .int64(Int64(entry.input)), .int64(Int64(entry.output)), .int64(Int64(entry.cw)),
                .int64(Int64(entry.cw1h)), .int64(Int64(entry.cr)),
                entry.costUSDRow.map(Binding.double) ?? .null,
                .text(Self.encodeDictionary(entry.tools)), .int64(Int64(entry.linesWritten))
            ])
        }
    }

    private func insertActivities(path: String, parsed: CachedFile, additive: Bool) {
        for (date, activity) in parsed.activityByDate {
            var value = activity
            var first = parsed.firstTimestampByDate[date]
            var last = parsed.lastTimestampByDate[date]
            if additive {
                var existing: (ActivityDayContribution, Double?, Double?)?
                query("""
                    SELECT turns,active_minutes,tools_json,lines_written,models_json,
                           first_timestamp,last_timestamp FROM claude_activity
                    WHERE file_path=? AND date=?
                    """
                    , bindings: [.text(path), .text(date)]) { row in
                    existing = (ActivityDayContribution(
                        turns: Int(row.int64(0)), activeMinutes: Int(row.int64(1)),
                        toolCounts: Self.decodeDictionary(row.text(2)),
                        linesWritten: Int(row.int64(3)),
                        modelCounts: Self.decodeDictionary(row.text(4))
                    ), row.isNull(5) ? nil : row.double(5), row.isNull(6) ? nil : row.double(6))
                }
                if let (old, oldFirst, oldLast) = existing {
                    var tools = old.toolCounts
                    for (key, count) in activity.toolCounts { tools[key, default: 0] += count }
                    var models = old.modelCounts
                    for (key, count) in activity.modelCounts { models[key, default: 0] += count }
                    var active = old.activeMinutes + activity.activeMinutes
                    if let oldLast, let first {
                        let gapMinutes = Int(max(0, first - oldLast) / 60)
                        if gapMinutes <= 10 { active += max(-2, gapMinutes - 2) }
                    }
                    value = ActivityDayContribution(
                        turns: old.turns + activity.turns, activeMinutes: max(0, active),
                        toolCounts: tools, linesWritten: old.linesWritten + activity.linesWritten,
                        modelCounts: models
                    )
                    if let oldFirst { first = min(first ?? oldFirst, oldFirst) }
                    if let oldLast { last = max(last ?? oldLast, oldLast) }
                }
            }
            run("""
                INSERT OR REPLACE INTO claude_activity(file_path,date,turns,active_minutes,tools_json,
                lines_written,models_json,first_timestamp,last_timestamp) VALUES(?,?,?,?,?,?,?,?,?)
                """
                , activityBindings(path: path, date: date, activity: value, first: first, last: last))
        }
    }

    private func activityBindings(path: String, date: String, activity: ActivityDayContribution, first: Double?, last: Double?) -> [Binding] {
        [.text(path), .text(date), .int64(Int64(activity.turns)), .int64(Int64(activity.activeMinutes)),
         .text(Self.encodeDictionary(activity.toolCounts)), .int64(Int64(activity.linesWritten)),
         .text(Self.encodeDictionary(activity.modelCounts)), first.map(Binding.double) ?? .null,
         last.map(Binding.double) ?? .null]
    }

    private static func encodeDictionary(_ value: [String: Int]) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func decodeDictionary(_ value: String) -> [String: Int] {
        guard let data = value.data(using: .utf8) else { return [:] }
        return (try? JSONDecoder().decode([String: Int].self, from: data)) ?? [:]
    }

    private enum Binding { case text(String), int64(Int64), double(Double), null }

    private func execute(_ sql: String) {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            usageDBLog.error("SQLite execution failed: \(String(cString: sqlite3_errmsg(db)))")
            return
        }
    }

    private func transaction(_ work: () -> Void) {
        execute("BEGIN IMMEDIATE")
        work()
        execute("COMMIT")
    }

    private func run(_ sql: String, _ bindings: [Binding]) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        bind(bindings, to: statement)
        if sqlite3_step(statement) != SQLITE_DONE {
            usageDBLog.error("SQLite write failed: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    private func query(_ sql: String, bindings: [Binding] = [], row: (SQLiteRow) -> Void) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        bind(bindings, to: statement)
        while sqlite3_step(statement) == SQLITE_ROW { row(SQLiteRow(statement: statement)) }
    }

    private func bind(_ bindings: [Binding], to statement: OpaquePointer?) {
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let text): sqlite3_bind_text(statement, index, text, -1, sqliteTransient)
            case .int64(let number): sqlite3_bind_int64(statement, index, number)
            case .double(let number): sqlite3_bind_double(statement, index, number)
            case .null: sqlite3_bind_null(statement, index)
            }
        }
    }
}

private struct SQLiteRow {
    let statement: OpaquePointer?
    func text(_ index: Int32) -> String { sqlite3_column_text(statement, index).map { String(cString: $0) } ?? "" }
    func optionalText(_ index: Int32) -> String? { isNull(index) ? nil : text(index) }
    func int64(_ index: Int32) -> Int64 { sqlite3_column_int64(statement, index) }
    func double(_ index: Int32) -> Double { sqlite3_column_double(statement, index) }
    func isNull(_ index: Int32) -> Bool { sqlite3_column_type(statement, index) == SQLITE_NULL }
}
