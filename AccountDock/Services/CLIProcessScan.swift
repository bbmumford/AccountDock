import Foundation
import Darwin

/// Whether a provider's CLI has a process running, from one `ps` listing,
/// matched by the CLI's executable name (`ProviderCapabilities.cliExecutableName`)
/// the way `AgentSuspensionService.matchesCommand` matches it.
///
/// `CodexService` and `KimiService` ask it before renewing the credential the
/// CLI's sessions share: a running CLI renews that credential itself, from
/// the file, and AccountDock rotating its refresh token under it can leave
/// the CLI renewing with a token already used.
enum CLIProcessScan {
    /// Fails closed: when the listing cannot be read, the CLI counts as
    /// running, so the shared credential is left to it.
    static func isRunning(_ provider: AIProviderType) async -> Bool {
        guard let result = try? await BoundedProcess.run(
            executable: URL(fileURLWithPath: "/bin/ps"), arguments: ["-axo", "pid=,command="], timeout: 5
        ), result.status == 0 else { return true }
        return isRunning(provider, inListing: String(decoding: result.output, as: UTF8.self), excluding: getpid())
    }

    /// Whether `listing`, `ps -o pid=,command=` output, holds a process of
    /// `provider`'s CLI other than `excluding`.
    static func isRunning(_ provider: AIProviderType, inListing listing: String, excluding: Int32) -> Bool {
        listing.split(whereSeparator: \.isNewline).contains { line in
            let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard fields.count == 2, let pid = Int32(fields[0]), pid != excluding else { return false }
            return AgentSuspensionService.matchesCommand(String(fields[1]), provider: provider)
        }
    }
}
