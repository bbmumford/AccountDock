import Foundation
import Darwin

/// Whether a provider's CLI has a process running, from a fresh
/// `ProcessTable`, matched by the CLI's executable name
/// (`ProviderCapabilities.cliExecutableName`) the way
/// `AgentSuspensionService.matchesCommand` matches it.
///
/// `CodexService` and `KimiService` ask it before renewing the credential the
/// CLI's sessions share: a running CLI renews that credential itself, from
/// the file, and AccountDock rotating its refresh token under it can leave
/// the CLI renewing with a token already used.
enum CLIProcessScan {
    /// Fails closed: when the processes cannot be read, the CLI counts as
    /// running, so the shared credential is left to it.
    static func isRunning(_ provider: AIProviderType) async -> Bool {
        guard let table = await ProcessTable.readInBackground() else { return true }
        return isRunning(provider, in: table, excluding: getpid())
    }

    /// Whether `table` holds a process of `provider`'s CLI other than
    /// `excluding`.
    static func isRunning(_ provider: AIProviderType, in table: ProcessTable, excluding: Int32) -> Bool {
        table.entries.contains { entry in
            entry.pid != excluding && AgentSuspensionService.matchesCommand(entry.command, provider: provider)
        }
    }
}
