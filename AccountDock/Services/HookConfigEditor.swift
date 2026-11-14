import Foundation

/// The one editor of the files a CLI reads its hooks from, for every
/// provider: Claude Code's `settings.json` and Codex's `hooks.json`
/// (`PauseGateSupport.ConfigFormat.jsonHooks`, `JSONHookFile`) and Kimi
/// Code's `config.toml` (`.tomlHooks`, `TOMLHookConfig`). Each hook carries
/// `marker` in its command or header, which is how it is found again; every
/// other byte of the file is kept as it was. `AgentHookInstaller` writes the
/// lifecycle hooks through it and `AgentPauseGate` the pause gate.
enum HookConfigEditor {
    /// Whether every event in `events` has a marked hook; with `command` and
    /// `timeout`, each must also run that command with that timeout.
    static func hasHooks(_ format: PauseGateSupport.ConfigFormat, at url: URL, events: [String], marker: String,
                         command: String? = nil, timeout: Int? = nil) -> Bool {
        switch format {
        case .jsonHooks: JSONHookFile.hasHooks(at: url, events: events, marker: marker, command: command, timeout: timeout)
        case .tomlHooks: TOMLHookConfig.hasHooks(at: url, events: events, marker: marker, command: command, timeout: timeout)
        }
    }

    /// Replaces the marked hooks of `events` with one hook each that runs
    /// `command`, limited to `timeout` seconds when it is above zero.
    static func install(_ format: PauseGateSupport.ConfigFormat, at url: URL, events: [String], command: String,
                        timeout: Int, marker: String) throws {
        switch format {
        case .jsonHooks:
            try JSONHookFile.edit(url) { try JSONHookFile.installing(events: events, command: command, timeout: timeout,
                                                                     marker: marker, in: $0) }
        case .tomlHooks:
            try TOMLHookConfig.install(at: url, events: events, command: command, timeout: timeout, marker: marker)
        }
    }

    /// Removes the marked hooks: those of `events` in a JSON hooks file,
    /// every marked table in a TOML one.
    static func uninstall(_ format: PauseGateSupport.ConfigFormat, at url: URL, events: [String], marker: String) throws {
        switch format {
        case .jsonHooks:
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            try JSONHookFile.edit(url) { try JSONHookFile.uninstalling(events: events, marker: marker, in: $0) }
        case .tomlHooks:
            try TOMLHookConfig.uninstall(at: url, marker: marker)
        }
    }
}

/// A JSON hooks file, `{"hooks": {"<event>": [{"matcher": "", "hooks":
/// [{"type": "command", "command": …, "timeout": …}]}]}}`, edited in place:
/// a hook group is added after the event's last group and removed with the
/// separator before it, so the bytes of every other setting, group and
/// space are kept. A new group is written in the file's own indentation.
enum JSONHookFile {
    enum Failure: LocalizedError, Equatable {
        case empty
        case notAnObject
        case unreadable
        case changedDuringUpdate

        var errorDescription: String? {
            switch self {
            case .empty: "file is empty"
            case .notAnObject: "file is not a JSON object"
            case .unreadable: "file is not valid JSON"
            case .changedDuringUpdate: "file changed during update"
            }
        }
    }

    // MARK: - Reading

    /// `HookConfigEditor.hasHooks` for a JSON hooks file. A hook whose
    /// command's first quoted path no longer exists counts as missing, so
    /// one left pointing at a moved or deleted app is reinstalled.
    static func hasHooks(at url: URL, events: [String], marker: String,
                         command expected: String? = nil, timeout: Int? = nil) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else { return false }
        return events.allSatisfy { event in
            let groups = hooks[event] as? [[String: Any]] ?? []
            return groups.contains { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains { hook in
                    guard let command = hook["command"] as? String, command.contains(marker) else { return false }
                    if let expected, command != expected { return false }
                    if let timeout, (hook["timeout"] as? Int) != timeout { return false }
                    return scriptExists(in: command)
                }
            }
        }
    }

    /// The first quoted path in a hook command must exist.
    private static func scriptExists(in command: String) -> Bool {
        for quote in ["\"", "'"] {
            let parts = command.components(separatedBy: quote)
            if parts.count >= 3, parts[1].hasPrefix("/") {
                return FileManager.default.fileExists(atPath: parts[1])
            }
        }
        return true
    }

    // MARK: - Editing text

    /// `text` with the marked groups of `events` replaced by one group each
    /// running `command`. Empty text is a new file.
    static func installing(events: [String], command: String, timeout: Int, marker: String, in text: String) throws -> String {
        try editing(text, events: events, marker: marker, adding: { indent, unit in
            group(command: command, timeout: timeout, indent: indent, unit: unit)
        })
    }

    /// `text` without the marked groups of `events`; an event left with no
    /// group is removed. Unchanged when it holds none.
    static func uninstalling(events: [String], marker: String, in text: String) throws -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }
        return try editing(text, events: events, marker: marker, adding: nil)
    }

    private static func editing(_ text: String, events: [String], marker: String,
                                adding: ((_ indent: String, _ unit: String) -> String)?) throws -> String {
        let isNew = text.isEmpty
        var bytes = Array((isNew ? "{}\n" : text).utf8)
        for event in events {
            var parser = Parser(bytes: bytes)
            let root = try parser.document()
            guard case .object(let rootMembers) = root.kind else { throw Failure.notAnObject }
            let unit = indentUnit(bytes, root: root)
            let hooksMember = rootMembers.last { $0.key == "hooks" }
            guard let hooksMember, case .object(let eventMembers) = hooksMember.value.kind else {
                guard let adding else { continue }
                // No hooks object: one holding this event, as the last setting
                // or in place of a hooks value that is no object.
                let hooksIndent = hooksMember.map { lineIndent(bytes, at: $0.range.lowerBound) }
                    ?? memberIndent(bytes, members: rootMembers, container: root, unit: unit)
                let eventIndent = hooksIndent + unit
                let hooksText = "{\n" + eventIndent + "\"\(escaped(event))\": "
                    + arrayText(adding, indent: eventIndent, unit: unit) + "\n" + hooksIndent + "}"
                if let hooksMember {
                    bytes.replaceSubrange(hooksMember.value.range, with: Array(hooksText.utf8))
                } else {
                    bytes = appendingMember("\"hooks\": " + hooksText, to: root, members: rootMembers, in: bytes, unit: unit)
                }
                continue
            }
            let hooksObject = hooksMember.value
            let eventMember = eventMembers.last { $0.key == event }
            guard let eventMember, case .array(let groups) = eventMember.value.kind else {
                // A marked hook lives only in an array of groups.
                guard let adding else { continue }
                if let eventMember {
                    let indent = lineIndent(bytes, at: eventMember.range.lowerBound)
                    bytes.replaceSubrange(eventMember.value.range, with: Array(arrayText(adding, indent: indent, unit: unit).utf8))
                } else {
                    let indent = memberIndent(bytes, members: eventMembers, container: hooksObject, unit: unit)
                    bytes = appendingMember("\"\(escaped(event))\": " + arrayText(adding, indent: indent, unit: unit),
                                            to: hooksObject, members: eventMembers, in: bytes, unit: unit)
                }
                continue
            }
            let marked = Set(groups.indices.filter { groupIsMarked(bytes, groups[$0].range, marker: marker) })
            let kept = groups.indices.filter { !marked.contains($0) }
            if adding == nil, marked.isEmpty { continue }
            if adding == nil, kept.isEmpty {
                bytes = removingMember(eventMember, from: hooksObject, members: eventMembers, in: bytes)
                continue
            }
            let arrayIndent = lineIndent(bytes, at: eventMember.range.lowerBound)
            let groupIndent = groups.first.map { lineIndent(bytes, at: $0.range.lowerBound) } ?? arrayIndent + unit
            bytes.replaceSubrange(eventMember.value.range, with: rebuilt(
                eventMember.value, children: groups.map(\.range), kept: kept, adding: adding.map { $0(groupIndent, unit) },
                childIndent: groupIndent, closingIndent: arrayIndent, in: bytes))
        }
        guard (try? JSONSerialization.jsonObject(with: Data(bytes))) != nil else { throw Failure.unreadable }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// A new array of one group, its closing bracket at `indent`.
    private static func arrayText(_ adding: (String, String) -> String, indent: String, unit: String) -> String {
        let groupIndent = indent + unit
        return "[\n" + groupIndent + adding(groupIndent, unit) + "\n" + indent + "]"
    }

    /// Whether a group's `hooks` run a command carrying `marker`.
    private static func groupIsMarked(_ bytes: [UInt8], _ range: Range<Int>, marker: String) -> Bool {
        guard let group = try? JSONSerialization.jsonObject(with: Data(bytes[range])) as? [String: Any],
              let hooks = group["hooks"] as? [Any] else { return false }
        return hooks.contains { hook in
            ((hook as? [String: Any])?["command"] as? String)?.contains(marker) ?? false
        }
    }

    /// An array's text with only its `kept` children, in order, and
    /// `adding` after them. The first kept child follows the space after
    /// the opening bracket, each later one keeps the separator and space
    /// before it, and the space before the closing bracket stays; an added
    /// child follows a comma and the space the last kept child had after
    /// its own comma.
    private static func rebuilt(_ container: Parser.Node, children: [Range<Int>], kept: [Int], adding: String?,
                                childIndent: String, closingIndent: String, in bytes: [UInt8]) -> [UInt8] {
        let open = container.range.lowerBound + 1, close = container.range.upperBound - 1
        func leading(_ index: Int) -> [UInt8] {
            Array(bytes[(index == 0 ? open : children[index - 1].upperBound)..<children[index].lowerBound])
        }
        let trailing = children.last.map { Array(bytes[$0.upperBound..<close]) } ?? []
        var out: [UInt8] = [UInt8(ascii: "[")]
        if let first = kept.first {
            out += leading(0) + bytes[children[first]]
            for index in kept.dropFirst() { out += leading(index) + bytes[children[index]] }
            if let adding {
                let last = kept[kept.count - 1]
                let space = last == 0 ? leading(0) : Array(leading(last).drop { $0 != UInt8(ascii: ",") }.dropFirst())
                out += [UInt8(ascii: ",")] + (space.contains(UInt8(ascii: "\n")) ? space : Array("\n\(childIndent)".utf8))
                out += Array(adding.utf8)
            }
            out += trailing
        } else if let adding {
            out += children.isEmpty ? Array("\n\(childIndent)\(adding)\n\(closingIndent)".utf8)
                                    : leading(0) + Array(adding.utf8) + trailing
        }
        out.append(UInt8(ascii: "]"))
        return out
    }

    /// `members` of `object` less `member`, with the separator before it, or
    /// after it when it is the first.
    private static func removingMember(_ member: Parser.Member, from object: Parser.Node, members: [Parser.Member],
                                       in bytes: [UInt8]) -> [UInt8] {
        guard let index = members.firstIndex(where: { $0.range == member.range }) else { return bytes }
        var out = bytes
        if index > 0 {
            out.removeSubrange(members[index - 1].range.upperBound..<member.range.upperBound)
        } else if members.count > 1 {
            out.removeSubrange(member.range.lowerBound..<members[1].range.lowerBound)
        } else {
            out.replaceSubrange(object.range, with: Array("{}".utf8))
        }
        return out
    }

    /// `bytes` with `text` added as `object`'s last member.
    private static func appendingMember(_ text: String, to object: Parser.Node, members: [Parser.Member],
                                        in bytes: [UInt8], unit: String) -> [UInt8] {
        var out = bytes
        if let last = members.last {
            let indent = lineIndent(bytes, at: last.range.lowerBound)
            out.insert(contentsOf: Array(",\n\(indent)\(text)".utf8), at: last.range.upperBound)
        } else {
            let indent = lineIndent(bytes, at: object.range.lowerBound)
            out.replaceSubrange(object.range, with: Array("{\n\(indent)\(unit)\(text)\n\(indent)}".utf8))
        }
        return out
    }

    /// The indentation of `container`'s members: that of its first member,
    /// or one `unit` deeper than the container's own line.
    private static func memberIndent(_ bytes: [UInt8], members: [Parser.Member], container: Parser.Node,
                                     unit: String) -> String {
        if let first = members.first { return lineIndent(bytes, at: first.range.lowerBound) }
        return lineIndent(bytes, at: container.range.lowerBound) + unit
    }

    /// The spaces and tabs that start the line `offset` is on.
    static func lineIndent(_ bytes: [UInt8], at offset: Int) -> String {
        var start = offset
        while start > 0, bytes[start - 1] != UInt8(ascii: "\n") { start -= 1 }
        let indent = bytes[start..<offset].prefix { $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") }
        return String(decoding: indent, as: UTF8.self)
    }

    /// The file's indentation step: the indent of the root's first member,
    /// two spaces when it has none on a line of its own.
    private static func indentUnit(_ bytes: [UInt8], root: Parser.Node) -> String {
        guard case .object(let members) = root.kind, let first = members.first else { return "  " }
        let indent = lineIndent(bytes, at: first.range.lowerBound)
        return indent.isEmpty ? "  " : indent
    }

    /// One hook group as `JSON.stringify(…, null, 2)` writes it, its lines
    /// after the first indented from `indent` by `unit`.
    static func group(command: String, timeout: Int, indent: String, unit: String) -> String {
        let one = indent + unit, two = one + unit, three = two + unit
        var hook = "\(three)\"type\": \"command\",\n\(three)\"command\": \"\(escaped(command))\""
        if timeout > 0 { hook += ",\n\(three)\"timeout\": \(timeout)" }
        return "{\n\(one)\"matcher\": \"\",\n\(one)\"hooks\": [\n\(two){\n\(hook)\n\(two)}\n\(one)]\n\(indent)}"
    }

    /// `value` as the inside of a JSON string, as `JSON.stringify` writes it.
    static func escaped(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8), text.count >= 4 else { return value }
        return String(text.dropFirst(2).dropLast(2))
    }

    // MARK: - The file

    /// Applies `change` to the file at `url`: a symlink is followed, an
    /// empty or non-object file is never replaced, the first edit keeps a
    /// copy beside it (`.accountdock-hooks-backup`), and a file that changed
    /// while being edited is left alone. A missing file is created.
    static func edit(_ url: URL, _ change: (String) throws -> String) throws {
        let target = url.resolvingSymlinksInPath()
        let manager = FileManager.default
        let exists = manager.fileExists(atPath: target.path)
        let before = exists ? modified(target) : nil
        let original = exists ? try String(contentsOf: target, encoding: .utf8) : ""
        if exists, original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw Failure.empty }
        let text = try change(original)
        guard text != original else { return }
        try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if exists {
            let backup = URL(fileURLWithPath: target.path + ".accountdock-hooks-backup")
            if !manager.fileExists(atPath: backup.path) { try? manager.copyItem(at: target, to: backup) }
            if modified(target) != before { throw Failure.changedDuringUpdate }
        }
        try Data(text.utf8).write(to: target, options: .atomic)
    }

    private static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    // MARK: - Parsing

    /// Reads JSON text into nodes that keep their byte ranges.
    struct Parser {
        struct Member {
            var key: String
            /// From the key's opening quote to the end of the value.
            var range: Range<Int>
            var value: Node
        }

        struct Node {
            indirect enum Kind {
                case object([Member])
                case array([Node])
                case scalar
            }

            var kind: Kind
            var range: Range<Int>
        }

        let bytes: [UInt8]
        var index = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func document() throws -> Node {
            skipSpace()
            let node = try value()
            skipSpace()
            guard index == bytes.count else { throw Failure.unreadable }
            return node
        }

        private mutating func skipSpace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        private mutating func value() throws -> Node {
            guard index < bytes.count else { throw Failure.unreadable }
            let start = index
            switch bytes[index] {
            case UInt8(ascii: "{"):
                index += 1
                var members: [Member] = []
                skipSpace()
                if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
                    index += 1
                    return Node(kind: .object([]), range: start..<index)
                }
                while true {
                    skipSpace()
                    let keyStart = index
                    let key = try string()
                    skipSpace()
                    guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw Failure.unreadable }
                    index += 1
                    skipSpace()
                    let member = try value()
                    members.append(Member(key: key, range: keyStart..<member.range.upperBound, value: member))
                    skipSpace()
                    guard index < bytes.count else { throw Failure.unreadable }
                    if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                    guard bytes[index] == UInt8(ascii: "}") else { throw Failure.unreadable }
                    index += 1
                    return Node(kind: .object(members), range: start..<index)
                }
            case UInt8(ascii: "["):
                index += 1
                var elements: [Node] = []
                skipSpace()
                if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
                    index += 1
                    return Node(kind: .array([]), range: start..<index)
                }
                while true {
                    skipSpace()
                    elements.append(try value())
                    skipSpace()
                    guard index < bytes.count else { throw Failure.unreadable }
                    if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                    guard bytes[index] == UInt8(ascii: "]") else { throw Failure.unreadable }
                    index += 1
                    return Node(kind: .array(elements), range: start..<index)
                }
            case UInt8(ascii: "\""):
                _ = try string()
                return Node(kind: .scalar, range: start..<index)
            default:
                while index < bytes.count, !",]} \t\r\n".utf8.contains(bytes[index]) { index += 1 }
                guard index > start else { throw Failure.unreadable }
                return Node(kind: .scalar, range: start..<index)
            }
        }

        private mutating func string() throws -> String {
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw Failure.unreadable }
            let start = index
            index += 1
            while index < bytes.count, bytes[index] != UInt8(ascii: "\"") {
                index += bytes[index] == UInt8(ascii: "\\") ? 2 : 1
            }
            guard index < bytes.count else { throw Failure.unreadable }
            index += 1
            let literal = Data(bytes[start..<index])
            guard let decoded = try? JSONSerialization.jsonObject(with: literal, options: .fragmentsAllowed) as? String else {
                throw Failure.unreadable
            }
            return decoded
        }
    }
}
