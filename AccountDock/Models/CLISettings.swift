import Foundation

/// What a provider's CLI settings tab (`CLISettingsTabView`) offers: which
/// executable AccountDock runs and how it is found, whether it was found,
/// and, where the provider has them, its versions, how its accounts are
/// kept apart and an action that recovers its sessions. Declared once per
/// provider as `ProviderCapabilities.cliSettings`; the texts are
/// localization keys.
struct CLISettings: Sendable {
    /// An executable found on this Mac, with what tells it apart (empty
    /// when only its path does).
    struct Found: Hashable, Identifiable, Sendable {
        var path: String
        var label: String
        var id: String { path }
    }

    /// An action that recovers the CLI's sessions, confirmed first.
    struct Recovery: Sendable {
        var title: String
        var explanation: String
        var confirmation: String
        var confirmationMessage: String
        var confirmButton: String
        var run: @MainActor @Sendable (AppState) async -> Void
    }

    /// The executable's name, in the custom path's placeholder.
    var executable: String
    /// The defaults key holding the chosen path; empty for automatic.
    var preferenceKey: String
    /// The executables found on this Mac. It may start a login shell, so
    /// the tab calls it off the main actor.
    var detect: @Sendable () -> [Found]
    /// The executable AccountDock runs now; nil when none is found.
    var current: @MainActor @Sendable () -> String?
    /// Whether the last refresh found the CLI.
    var available: @MainActor @Sendable (AppState) -> Bool
    /// Hands a choice (nil for automatic) to the provider's service.
    var apply: @MainActor @Sendable (String?) -> Void
    /// The version installed at a path, where the CLI reports it.
    var installedVersion: (@Sendable (String) async -> String?)? = nil
    /// The newest released version, where it can be looked up.
    var latestVersion: (@Sendable () async -> String?)? = nil
    /// How the provider keeps its accounts apart, when the tab explains it.
    var isolationNote: String? = nil
    var recovery: Recovery? = nil
}

extension CLISettings {
    /// Claude Code's: its executables with where each came from, and its
    /// installed and newest versions.
    static let claudeCode = CLISettings(
        executable: "claude",
        preferenceKey: kClaudeBinaryPathPreferenceKey,
        detect: { ClaudeService.detectedPaths().map { Found(path: $0.path, label: $0.label) } },
        current: { ClaudeService.shared.claudePath },
        available: { $0.claudeAvailable },
        apply: { ClaudeService.shared.setPath($0) },
        installedVersion: { await ClaudeService.readVersion(at: $0) },
        latestVersion: { await ClaudeService.fetchLatestVersion() }
    )

    /// Codex's: its executables, how its managed homes keep accounts apart,
    /// and restarting its Terminal sessions.
    static let codex = CLISettings(
        executable: "codex",
        preferenceKey: "codexBinaryPathPreference",
        detect: { CodexService.shared.detectedBinaryPaths().map { Found(path: $0, label: "") } },
        current: { CodexService.shared.binaryPath },
        available: { $0.codexAvailable },
        apply: { CodexService.shared.setBinaryPath($0) },
        isolationNote: "Each managed account has its own CODEX_HOME. Switching stages only auth.json into ~/.codex, preserving your system configuration and history.",
        recovery: Recovery(
            title: "Force Restart Codex Sessions",
            explanation: "Closes detected Codex Terminal sessions, then opens a new Terminal window for each recoverable session and runs codex resume with its session ID.",
            confirmation: "Force restart Codex sessions?",
            confirmationMessage: "AccountDock will close every detected Codex terminal process and its Terminal tab. Sessions without a detected session ID cannot be reopened automatically.",
            confirmButton: "Force Restart",
            run: { await $0.forceRestartCodexSessions() }
        )
    )
}
