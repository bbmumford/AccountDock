import Foundation

private let log = FileLog("SecurityTool")

/// Generic-password items in the login keychain, read and written only
/// through `/usr/bin/security`.
///
/// An item created by `security` is shared with every caller of that tool,
/// so reading it never asks for the login password, whatever the signature
/// of the app calling it. An item created by the app itself through
/// `SecItem` is tied to the app's code signature, and every rebuild asks
/// again. `KeychainService` keeps the saved accounts here for that reason,
/// and the per-session Claude credential slots are Claude Code's own
/// `security` items.
///
/// Values travel on the standard input of `security -i`, never as process
/// arguments, because arguments are visible to every process on the Mac.
/// `security -i` refuses lines over 4,096 bytes, so a write whose command
/// line would not fit is refused rather than sent another way.
struct SecurityToolKeychain: Sendable {
    let service: String

    /// Longest command line written to `security -i`, leaving room under its
    /// 4,096-byte limit.
    static let maxCommandBytes = 4_000

    /// The item's value, or nil when there is no such item.
    func read(account: String) -> String? {
        guard let output = Self.run(["find-generic-password", "-s", service, "-a", account, "-w"]) else { return nil }
        return Self.decodePassword(output)
    }

    /// Writes every value and deletes every listed account in one `security`
    /// process, then reads each written value back. Returns false when any
    /// command line is too long, or when any value does not read back as
    /// written; values written before the failure stay written.
    func apply(writes: [(account: String, value: String)], deletes: [String] = []) -> Bool {
        var lines: [String] = []
        for write in writes {
            guard let line = Self.addCommand(service: service, account: write.account, value: write.value) else {
                log.error("[apply] Value for \(service)/\(write.account) is too long for security -i; not written")
                return false
            }
            lines.append(line)
        }
        for account in deletes {
            lines.append("delete-generic-password -s \(Self.quoted(service)) -a \(Self.quoted(account))\n")
        }
        guard !lines.isEmpty else { return true }
        guard Self.runInteractive(lines.joined()) else { return false }
        for write in writes where read(account: write.account) != Self.asciiOnly(write.value) {
            log.error("[apply] \(service)/\(write.account) did not read back as written")
            return false
        }
        return true
    }

    // MARK: - Command text

    /// The `add-generic-password` line for `security -i`, or nil when it
    /// would exceed `maxCommandBytes`. `-U` replaces an existing item in
    /// place, so a reader never finds the item missing.
    static func addCommand(service: String, account: String, value: String) -> String? {
        let line = "add-generic-password -U -s \(quoted(service)) -a \(quoted(account)) -w \(quoted(asciiOnly(value)))\n"
        return line.utf8.count < maxCommandBytes ? line : nil
    }

    static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// The value with every non-ASCII character written as a JSON `\u`
    /// escape. `security -w` prints a value containing non-ASCII bytes as
    /// hexadecimal; the stored values are JSON, where the escape decodes to
    /// the same text.
    static func asciiOnly(_ value: String) -> String {
        guard !value.utf8.contains(where: { $0 >= 0x80 }) else {
            var out = ""
            for unit in value.utf16 {
                if unit < 0x80 { out.unicodeScalars.append(Unicode.Scalar(unit)!) }
                else { out += String(format: "\\u%04x", unit) }
            }
            return out
        }
        return value
    }

    /// `security -w` output as text: hexadecimal output is decoded, other
    /// output is returned unchanged.
    static func decodePassword(_ output: String) -> String {
        let hex = output.utf8
        guard hex.count.isMultiple(of: 2), !hex.isEmpty,
              hex.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }) else { return output }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index != hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(String(output[index..<next]), radix: 16) else { return output }
            bytes.append(byte)
            index = next
        }
        guard let text = String(bytes: bytes, encoding: .utf8), text.first == "{" || text.first == "[" else { return output }
        return text
    }

    // MARK: - Process

    private static func run(_ args: [String]) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return output?.isEmpty == false ? output : nil
        } catch {
            log.error("[run] Launch failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func runInteractive(_ commands: String) -> Bool {
        let process = Process()
        let input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["-i"]
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            input.fileHandleForWriting.write(Data(commands.utf8))
            try input.fileHandleForWriting.close()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            log.error("[runInteractive] Launch failed: \(error.localizedDescription)")
            return false
        }
    }
}
