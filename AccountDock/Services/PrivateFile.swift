import Foundation
import Darwin

/// Replaces a file so that no reader sees it partly written or with wider
/// permissions than `mode`: the bytes go to a new file in the destination's
/// directory, created and set to `mode` before anything is written to it,
/// which then replaces the destination with one `rename(2)`.
///
/// Used for the credential files `CodexService` and `KimiService` keep, the
/// identity `ClaudeIdentityFile` edits in `~/.claude.json`, and the
/// `.command` files `SessionTerminal` hands to Terminal.
enum PrivateFile {
    /// `beforeReplacing` runs once the new contents are on disk and before
    /// the rename; an error it throws leaves the destination untouched.
    /// `ClaudeIdentityFile` uses it to refuse a file another process changed
    /// after it was read.
    static func writeAtomically(
        _ data: Data,
        to url: URL,
        mode: mode_t,
        beforeReplacing: () throws -> Void = {}
    ) throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode)
        guard descriptor >= 0 else { throw posixError() }
        do {
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            // The umask can narrow the mode `open` applied; set it exactly.
            guard fchmod(descriptor, mode) == 0 else {
                let error = posixError()
                try? handle.close()
                throw error
            }
            do {
                try handle.write(contentsOf: data)
                try handle.synchronize()
            } catch {
                try? handle.close()
                throw error
            }
            try handle.close()
            try beforeReplacing()
            guard rename(temporary.path, url.path) == 0 else { throw posixError() }
        } catch {
            unlink(temporary.path)
            throw error
        }
    }

    private static func posixError() -> Error {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
