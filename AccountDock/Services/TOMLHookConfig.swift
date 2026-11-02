import Foundation

/// Adds and removes AccountDock's hooks in a CLI's TOML config, for
/// providers whose hooks use the `.tomlHooks` format (Kimi Code's
/// `config.toml`, the default file).
///
/// Each hook is one `[[hooks]]` table whose header line carries a marker
/// comment; removal deletes exactly those tables, from the marked header to
/// the next table header, so every other line of the file is kept as is.
enum TOMLHookConfig {
    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kimi-code/config.toml")
    }

    /// Whether exactly one marked table exists for every event and no other
    /// marked table does; with `command` and `timeout`, each must also run
    /// that command with that timeout. Copies make the CLI run a hook twice.
    static func hasHooks(at url: URL = configURL, events: [String], marker: String,
                         command: String? = nil, timeout: Int? = nil) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        let tables = markedTables(in: text, marker: marker)
        guard tables.count == events.count else { return false }
        return events.allSatisfy { event in
            tables.contains { table in
                let lines = Set(table.split(separator: "\n").map(String.init))
                return lines.contains("event = \"\(event)\"")
                    && command.map { lines.contains("command = \(quoted($0))") } ?? true
                    && timeout.map { lines.contains("timeout = \($0)") } ?? true
            }
        }
    }

    static func install(at url: URL = configURL, events: [String], command: String, timeout: Int, marker: String) throws {
        let original = try existingText(url)
        var text = removing(marker: marker, from: original)
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        for event in events {
            text += "\n[[hooks]] \(marker)\nevent = \"\(event)\"\ncommand = \(quoted(command))\ntimeout = \(timeout)\n"
        }
        try write(text, original: original, to: url)
    }

    static func uninstall(at url: URL = configURL, marker: String) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let original = try existingText(url)
        let text = removing(marker: marker, from: original)
        guard text != original else { return }
        try write(text, original: original, to: url)
    }

    // MARK: - One value in a table

    /// The string value of `key` in the table whose header is `[table]`.
    static func value(at url: URL, table: String, key: String) -> String? {
        guard let text = try? existingText(url) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let range = tableRange(lines, table: table),
              let line = lines[range].first(where: { keyOf($0) == key }) else { return nil }
        return stringValue(line)
    }

    /// Sets `key` in the table `[table]` to `value`, with `comment` after it;
    /// the rest of the file is kept as is. Throws when the table is missing,
    /// since the CLI writes it.
    static func setValue(at url: URL, table: String, key: String, value: String, comment: String?) throws {
        let original = try existingText(url)
        var lines = original.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let range = tableRange(lines, table: table) else {
            throw NSError(domain: "TOMLHookConfig", code: 2, userInfo: [NSLocalizedDescriptionKey: "[\(table)] not found in \(url.lastPathComponent)"])
        }
        let line = "\(key) = \(quoted(value))" + (comment.map { " \($0)" } ?? "")
        if let index = range.first(where: { keyOf(lines[$0]) == key }) {
            guard lines[index] != line else { return }
            lines[index] = line
        } else {
            lines.insert(line, at: range.lowerBound)
        }
        try write(lines.joined(separator: "\n"), original: original, to: url)
    }

    /// Lines after the header `[table]` up to the next table header.
    private static func tableRange(_ lines: [String], table: String) -> Range<Int>? {
        guard let header = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[\(table)]") }) else { return nil }
        let start = header + 1
        let end = lines[start...].firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") } ?? lines.count
        return start..<end
    }

    private static func keyOf(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { return nil }
        return trimmed[..<equals].trimmingCharacters(in: .whitespaces)
    }

    /// The basic string after `=`, without a trailing comment.
    private static func stringValue(_ line: String) -> String? {
        guard let equals = line.firstIndex(of: "=") else { return nil }
        let rest = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        guard rest.hasPrefix("\"") else { return nil }
        var value = ""
        var escaped = false
        for character in rest.dropFirst() {
            if escaped { value.append(character); escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "\"" { return value }
            value.append(character)
        }
        return nil
    }

    /// A TOML basic string.
    static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// The text as runs of lines, each starting at a table header; the
    /// first run holds the lines before any header.
    private static func runs(_ text: String) -> [[Substring]] {
        var runs: [[Substring]] = [[]]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("[") { runs.append([]) }
            runs[runs.count - 1].append(line)
        }
        return runs
    }

    /// Whether a run is a `[[hooks]]` table this marker installed: its header
    /// carries the marker, or its command does. Another program that rewrites
    /// the file with a TOML serializer drops the header comment but keeps the
    /// command string, which ends with the marker.
    private static func isMarked(_ run: [Substring], marker: String) -> Bool {
        guard let header = run.first?.trimmingCharacters(in: .whitespaces), header.hasPrefix("[[hooks]]") else { return false }
        if header.contains(marker) { return true }
        return run.dropFirst().contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return keyOf(trimmed) == "command" && stringValue(trimmed)?.hasSuffix(marker) == true
        }
    }

    static func removing(marker: String, from text: String) -> String {
        var kept: [Substring] = []
        for run in runs(text) {
            if isMarked(run, marker: marker) {
                while kept.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { kept.removeLast() }
            } else {
                kept += run
            }
        }
        return kept.joined(separator: "\n")
    }

    private static func markedTables(in text: String, marker: String) -> [String] {
        runs(text).filter { isMarked($0, marker: marker) }.map { run in
            run.dropFirst().map { $0.trimmingCharacters(in: .whitespaces) + "\n" }.joined()
        }
    }

    private static func existingText(_ url: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        return try String(contentsOf: url.resolvingSymlinksInPath(), encoding: .utf8)
    }

    private static func write(_ text: String, original: String, to url: URL) throws {
        let target = url.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let backup = target.appendingPathExtension("accountdock-hooks-backup")
        if !original.isEmpty, !FileManager.default.fileExists(atPath: backup.path) {
            try original.write(to: backup, atomically: true, encoding: .utf8)
        }
        // Kimi may have rewritten its config meanwhile; its write wins.
        if (try? existingText(url)) != original {
            throw NSError(domain: "TOMLHookConfig", code: 1, userInfo: [NSLocalizedDescriptionKey: "config.toml changed during update"])
        }
        try text.write(to: target, atomically: true, encoding: .utf8)
    }
}
