import Foundation
import Darwin

private let log = FileLog("ClaudeIdentity")

/// The `oauthAccount` entry of Claude Code's `~/.claude.json`, which names the
/// account of the live credential. `KeychainService` reads and writes the
/// identity through it.
///
/// Every running Claude Code session rewrites this file with its own state,
/// so an edit changes the text of that one entry and keeps every other byte,
/// and it replaces the file only when it is still the file that was read:
/// one changed meanwhile is read again and the edit retried, up to `attempts`
/// times.
struct ClaudeIdentityFile: Sendable {
    let url: URL
    var attempts = 5
    var retryDelay: TimeInterval = 0.05

    static let key = "oauthAccount"

    enum EditError: Error, Equatable {
        /// The file was replaced or rewritten after it was read.
        case changedSinceRead
        /// The file is not a JSON object.
        case unreadable
    }

    /// The file's bytes with what identifies that version of it: a rewrite
    /// changes the size or modification time, a replacement the inode.
    struct Snapshot {
        let data: Data
        let signature: Signature
    }

    struct Signature: Equatable {
        let device: Int64
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let mode: mode_t
    }

    /// The symlink's target when the file is one, so an edit replaces the
    /// target and keeps the link.
    var resolvedURL: URL { url.resolvingSymlinksInPath() }

    func readOAuthAccount() -> [String: AnyCodable]? {
        guard let data = FileManager.default.contents(atPath: resolvedURL.path),
              let json = try? JSONDecoder().decode([String: AnyCodable].self, from: data),
              let dict = json[Self.key]?.value as? [String: AnyCodable] else { return nil }
        return dict
    }

    /// Sets `oauthAccount` and keeps the rest of the file as it is.
    func writeOAuthAccount(_ oauthAccount: [String: AnyCodable]) throws {
        var lastError: Error = EditError.changedSinceRead
        for attempt in 1...max(1, attempts) {
            do {
                let snapshot = try read()
                guard let edited = Self.replacingTopLevelValue(
                    forKey: Self.key, in: snapshot.data, with: oauthAccount
                ) else { throw EditError.unreadable }
                try commit(edited, over: snapshot)
                return
            } catch EditError.changedSinceRead {
                lastError = EditError.changedSinceRead
                log.warning("[write] \(url.lastPathComponent) changed while it was edited (attempt \(attempt))")
                if attempt < attempts { Thread.sleep(forTimeInterval: retryDelay) }
            }
        }
        throw lastError
    }

    /// The file's current contents, read between two identical signatures so
    /// a write in progress is never taken for the file.
    func read() throws -> Snapshot {
        let path = resolvedURL.path
        for _ in 0..<max(1, attempts) {
            let before = try Self.signature(of: path)
            guard let data = FileManager.default.contents(atPath: path) else { throw EditError.unreadable }
            if try Self.signature(of: path) == before { return Snapshot(data: data, signature: before) }
        }
        throw EditError.changedSinceRead
    }

    /// Replaces the file with `data`, with the file's own permissions, if it
    /// is still the version `snapshot` read.
    func commit(_ data: Data, over snapshot: Snapshot) throws {
        let target = resolvedURL
        try PrivateFile.writeAtomically(data, to: target, mode: snapshot.signature.mode & 0o7777) {
            guard try Self.signature(of: target.path) == snapshot.signature else {
                throw EditError.changedSinceRead
            }
        }
    }

    static func signature(of path: String) throws -> Signature {
        var info = stat()
        guard stat(path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return Signature(
            device: Int64(info.st_dev),
            inode: UInt64(info.st_ino),
            size: Int64(info.st_size),
            modifiedSeconds: Int(info.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int(info.st_mtimespec.tv_nsec),
            mode: info.st_mode
        )
    }

    // MARK: - Editing one entry of a JSON object

    /// `data`, a JSON object, with the value of its top-level `key` replaced
    /// by `value`, or the entry added after the last one when absent. Every
    /// other byte is kept, so the other entries keep their values, order and
    /// layout. The new value is laid out like Claude Code lays out the file:
    /// indented by the unit the top-level entries use, or on one line in a
    /// file written on one line. Nil when `data` is not a JSON object.
    static func replacingTopLevelValue(forKey key: String, in data: Data, with value: [String: AnyCodable]) -> Data? {
        guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any],
              let object = TopLevelObject(Array(data)) else { return nil }
        let bytes = object.bytes
        let unit = object.indentUnit
        let rendered = Array(render(AnyCodable(value), unit: unit, depth: 1).utf8)
        var output = bytes
        let matches = object.members.filter { $0.key == key }
        if matches.isEmpty {
            let entry = Array((quoted(key) + (unit == nil ? ":" : ": ")).utf8) + rendered
            if let last = object.members.last {
                let separator = Array(("," + (unit.map { "\n" + $0 } ?? "")).utf8)
                output.insert(contentsOf: separator + entry, at: last.valueEnd)
            } else {
                let opening = Array((unit.map { "\n" + $0 } ?? "").utf8)
                let closing = Array((unit == nil ? "" : "\n").utf8)
                output.replaceSubrange(object.openIndex + 1..<object.closeIndex, with: opening + entry + closing)
            }
        } else {
            for member in matches.reversed() {
                output.replaceSubrange(member.valueStart..<member.valueEnd, with: rendered)
            }
        }
        let result = Data(output)
        guard (try? JSONSerialization.jsonObject(with: result)) is [String: Any] else { return nil }
        return result
    }

    private static func quoted(_ string: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return (try? encoder.encode(string)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
    }

    /// JSON text for `value`; with `unit`, one entry per line at `depth`.
    private static func render(_ value: AnyCodable, unit: String?, depth: Int) -> String {
        let colon = unit == nil ? ":" : ": "
        func lines(_ items: [String], open: String, close: String) -> String {
            guard !items.isEmpty else { return open + close }
            guard let unit else { return open + items.joined(separator: ",") + close }
            let inner = String(repeating: unit, count: depth + 1)
            let outer = String(repeating: unit, count: depth)
            return open + "\n" + items.map { inner + $0 }.joined(separator: ",\n") + "\n" + outer + close
        }
        switch value.value {
        case let object as [String: AnyCodable]:
            let items = object.keys.sorted().map { quoted($0) + colon + render(object[$0]!, unit: unit, depth: depth + 1) }
            return lines(items, open: "{", close: "}")
        case let array as [AnyCodable]:
            return lines(array.map { render($0, unit: unit, depth: depth + 1) }, open: "[", close: "]")
        default:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
        }
    }

    /// The spans of a JSON object's top-level entries, found by scanning its
    /// text: strings, nested objects and arrays are skipped whole.
    private struct TopLevelObject {
        struct Member {
            let key: String
            let valueStart: Int
            let valueEnd: Int
        }

        let bytes: [UInt8]
        let openIndex: Int
        let closeIndex: Int
        let members: [Member]
        /// The indentation of the first entry, nil for a one-line object.
        let indentUnit: String?

        init?(_ bytes: [UInt8]) {
            self.bytes = bytes
            var index = Self.skipSpace(bytes, 0)
            guard index < bytes.count, bytes[index] == UInt8(ascii: "{") else { return nil }
            openIndex = index
            index = Self.skipSpace(bytes, index + 1)
            var members: [Member] = []
            var indent: String?
            if index < bytes.count, bytes[index] != UInt8(ascii: "}") {
                let gap = bytes[(openIndex + 1)..<index]
                if let newline = gap.lastIndex(of: UInt8(ascii: "\n")) {
                    let spaces = String(decoding: bytes[(newline + 1)..<index], as: UTF8.self)
                    indent = spaces.isEmpty ? nil : spaces
                }
                while true {
                    guard let keyEnd = Self.stringEnd(bytes, index),
                          let key = try? JSONDecoder().decode(String.self, from: Data(bytes[index..<keyEnd])) else { return nil }
                    index = Self.skipSpace(bytes, keyEnd)
                    guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { return nil }
                    let valueStart = Self.skipSpace(bytes, index + 1)
                    guard let valueEnd = Self.valueEnd(bytes, valueStart) else { return nil }
                    members.append(Member(key: key, valueStart: valueStart, valueEnd: valueEnd))
                    index = Self.skipSpace(bytes, valueEnd)
                    guard index < bytes.count else { return nil }
                    if bytes[index] == UInt8(ascii: ",") {
                        index = Self.skipSpace(bytes, index + 1)
                        continue
                    }
                    guard bytes[index] == UInt8(ascii: "}") else { return nil }
                    break
                }
            }
            guard index < bytes.count, bytes[index] == UInt8(ascii: "}") else { return nil }
            closeIndex = index
            guard Self.skipSpace(bytes, index + 1) == bytes.count else { return nil }
            self.members = members
            indentUnit = indent
        }

        private static func skipSpace(_ bytes: [UInt8], _ start: Int) -> Int {
            var index = start
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
            return index
        }

        /// The index after the string starting at `start`.
        private static func stringEnd(_ bytes: [UInt8], _ start: Int) -> Int? {
            guard start < bytes.count, bytes[start] == UInt8(ascii: "\"") else { return nil }
            var index = start + 1
            while index < bytes.count {
                switch bytes[index] {
                case UInt8(ascii: "\\"): index += 2
                case UInt8(ascii: "\""): return index + 1
                default: index += 1
                }
            }
            return nil
        }

        /// The index after the value starting at `start`.
        private static func valueEnd(_ bytes: [UInt8], _ start: Int) -> Int? {
            guard start < bytes.count else { return nil }
            switch bytes[start] {
            case UInt8(ascii: "\""):
                return stringEnd(bytes, start)
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                var depth = 0
                var index = start
                while index < bytes.count {
                    switch bytes[index] {
                    case UInt8(ascii: "\""):
                        guard let end = stringEnd(bytes, index) else { return nil }
                        index = end
                        continue
                    case UInt8(ascii: "{"), UInt8(ascii: "["):
                        depth += 1
                    case UInt8(ascii: "}"), UInt8(ascii: "]"):
                        depth -= 1
                        if depth == 0 { return index + 1 }
                    default:
                        break
                    }
                    index += 1
                }
                return nil
            default:
                var index = start
                let ends: Set<UInt8> = [UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"), 0x20, 0x09, 0x0A, 0x0D]
                while index < bytes.count, !ends.contains(bytes[index]) { index += 1 }
                return index == start ? nil : index
            }
        }
    }
}
