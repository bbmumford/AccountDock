import XCTest

/// Reads the app's sources so that no path writing, removing, renewing,
/// serving or reading a credential for use can skip `CredentialAudit`:
/// every call of such an operation passes the audit a `reason:`, or sits in
/// a function that records an audit entry itself.
final class CredentialAuditCoverageTests: XCTestCase {
    /// Operations on a credential, as they appear at a call.
    private static let operations = [
        "apply(writes:", "SecItemAdd(", "SecItemUpdate(", "SecItemDelete(",
        "readClaudeToken(", "writeClaudeToken(", "saveAccountBackup(", "getAccountBackup(", "removeAccountBackup(",
        "writeCredential(", "removeSlot(", "writePrivateAuth(", "promoteToSystem(", "removeManagedAccount(",
        "syncSystemCredentials(", "renewCredential(", "renewSavedCopy(", "renewSavedCredential(",
        "renewLiveCredentialForSlots(", "freshAccessToken(", "captureOwnCredential(", "install(savedCopyOf:",
        "signalRunningSessions(", "makeSlot(", "makeSpare(", "makeRequestedSlot(", "removeSpare(",
        "slots.serve(", "slots.assign(", "slots.remove(", ".savedCopy(",
    ]

    /// File operations that move a credential in the files where they do.
    private static let credentialFileOperations: [String: [String]] = [
        "CodexService.swift": ["copyItem(", "replaceItemAt(", "PrivateFile.writeAtomically(", "copyAuth("],
        "KimiService.swift": ["PrivateFile.writeAtomically("],
    ]

    /// Functions that perform an operation for a caller that records it,
    /// whose own calls are checked here: the isolations' slot primitives,
    /// called by `SessionSlots.serve` and `remove`, and Codex's `copyAuth`,
    /// called by `captureSystemAccount`.
    private static let delegates: Set<String> = [
        "ClaudeSessionIsolation.swift:writeCredential", "ClaudeSessionIsolation.swift:removeSlot",
        "KimiSessionIsolation.swift:writeCredential", "KimiSessionIsolation.swift:removeSlot",
        "CodexService.swift:copyAuth",
    ]

    /// Operations whose own body records the entry for the `reason` they take.
    private static let recordingDefinitions = [
        "KeychainService.swift": ["readClaudeToken", "writeClaudeToken", "saveAccountBackup", "getAccountBackup",
                                  "removeAccountBackup"],
        "CodexService.swift": ["writePrivateAuth", "promoteToSystem", "removeManagedAccount", "syncSystemCredentials"],
        "KimiService.swift": ["writeCredential", "removeManagedAccount", "identity"],
        "SessionSlots.swift": ["serve", "assign", "remove"],
        "ClaudeCredentialModule.swift": ["renewSavedCopy", "owner", "signalRunningSessions", "save"],
    ]

    private static let recordsAudit = try! NSRegularExpression(pattern: #"[aA]udit\.record\w*\(|\.noteProcessCredential\(|recordServed\(|recordTranscriptRequest\("#)

    private struct Source {
        let name: String
        let lines: [String]
    }

    private func sources() throws -> [Source] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("AccountDock", isDirectory: true)
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertGreaterThan(files.count, 50, "the app's sources were found")
        return try files.map { Source(name: $0.lastPathComponent, lines: try String(contentsOf: $0, encoding: .utf8)
            .components(separatedBy: "\n")) }
    }

    private static func isComment(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*")
    }

    private static func isDefinition(_ line: String) -> Bool {
        line.range(of: #"\bfunc\s"#, options: .regularExpression) != nil
    }

    private static func indentation(_ line: String) -> Int {
        line.prefix { $0 == " " }.count
    }

    /// The function a line is in: from the nearest `func` line above it to
    /// the next `func` line indented no deeper, so a function's nested
    /// functions count as its own, and that function's name.
    private static func enclosingFunction(of index: Int, in lines: [String]) -> (name: String, body: String) {
        var start = index
        while start > 0, !isDefinition(lines[start]) { start -= 1 }
        let depth = indentation(lines[start])
        var end = start + 1
        while end < lines.count, !(isDefinition(lines[end]) && indentation(lines[end]) <= depth) { end += 1 }
        end = max(end, index + 1)
        let name = lines[start].range(of: #"func\s+(\w+)"#, options: .regularExpression)
            .map { String(lines[start][$0].split(separator: " ").last ?? "") } ?? ""
        return (name, lines[start..<end].joined(separator: "\n"))
    }

    /// The call starting on `index`, through the line its parentheses close.
    private static func call(at index: Int, from operation: String, in lines: [String]) -> String {
        var text = ""
        var depth = 0
        var started = false
        for line in lines[index..<min(lines.count, index + 8)] {
            let segment = started ? line : String(line[line.range(of: operation)!.lowerBound...])
            text += segment + "\n"
            for character in segment {
                if character == "(" { depth += 1; started = true }
                if character == ")" { depth -= 1 }
            }
            if started, depth <= 0 { break }
        }
        return text
    }

    func testEveryCredentialOperationPassesAReasonOrIsRecordedWhereItIsCalled() throws {
        var unrecorded: [String] = []
        for source in try sources() {
            let operations = Self.operations + (Self.credentialFileOperations[source.name] ?? [])
            for (index, line) in source.lines.enumerated() where !Self.isComment(line) && !Self.isDefinition(line) {
                for operation in operations where line.contains(operation) {
                    let function = Self.enclosingFunction(of: index, in: source.lines)
                    if Self.delegates.contains("\(source.name):\(function.name)") { continue }
                    let callText = Self.call(at: index, from: operation, in: source.lines)
                    if callText.contains("reason:") { continue }
                    let body = function.body
                    if Self.recordsAudit.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)) != nil { continue }
                    unrecorded.append("\(source.name):\(index + 1) \(operation) in \(function.name)")
                }
            }
        }
        XCTAssertEqual(unrecorded, [], "credential operations that skip the audit trail")
    }

    func testEveryOperationTakingAReasonRecordsTheEntryItself() throws {
        let sources = try sources()
        for (file, names) in Self.recordingDefinitions {
            let source = try XCTUnwrap(sources.first { $0.name == file }, file)
            for name in names {
                let starts = source.lines.indices.filter {
                    source.lines[$0].range(of: #"func\s+\#(name)\("#, options: .regularExpression) != nil
                }
                XCTAssertFalse(starts.isEmpty, "\(file): \(name) not found")
                for start in starts {
                    let body = Self.enclosingFunction(of: start, in: source.lines).body
                    XCTAssertNotNil(Self.recordsAudit.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
                                    "\(file): \(name) records no audit entry")
                }
            }
        }
    }

    func testTheScanFindsAnUnrecordedWrite() {
        let lines = ["    func sneaky() {", "        _ = keychain.writeClaudeToken(token)", "    }"]
        let function = Self.enclosingFunction(of: 1, in: lines)
        XCTAssertEqual(function.name, "sneaky")
        XCTAssertFalse(Self.call(at: 1, from: "writeClaudeToken(", in: lines).contains("reason:"))
        XCTAssertNil(Self.recordsAudit.firstMatch(in: function.body, range: NSRange(function.body.startIndex..., in: function.body)))
    }
}
