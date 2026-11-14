import SwiftUI

/// A provider's CLI settings tab, the same for every provider and driven by
/// its `ProviderCapabilities.cliSettings`: which executable AccountDock
/// runs (found ones, automatic, or a custom path), whether it was found,
/// and, where the provider declares them, its installed and newest
/// versions, how its accounts are kept apart, and an action that recovers
/// its sessions. A provider without CLI settings says where its accounts
/// are managed. Shown by `SettingsView` for each visible provider.
struct CLISettingsTabView: View {
    let provider: AIProviderType

    var body: some View {
        if let settings = provider.capabilities.cliSettings {
            CLISettingsForm(settings: settings, cli: provider.capabilities.displayName)
        } else {
            VStack(spacing: 12) {
                Image(systemName: provider.iconName)
                    .font(.largeTitle)
                Text("\(provider.capabilities.displayName) accounts are managed from the Accounts tab.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct CLISettingsForm: View {
    @EnvironmentObject private var appState: AppState
    let settings: CLISettings
    let cli: String
    @AppStorage private var preference: String

    private static let autoTag = ""
    private static let customSentinel = "__custom__"

    @State private var detected: [CLISettings.Found] = []
    @State private var selection: String = ""
    @State private var customInput: String = ""
    @State private var customError: String? = nil
    @State private var installedVersion: String? = nil
    @State private var latestVersion: String? = nil
    @State private var isLoading: Bool = false
    @State private var confirmingRecovery = false
    /// When non-nil, the next onChange callback receiving this exact value
    /// is a programmatic write and is skipped. Tying it to a value rather
    /// than a flag keeps a real click that SwiftUI coalesces with it.
    @State private var suppressNextSelection: String? = nil
    /// The version fetch under way, which a later one supersedes.
    @State private var versionLoadTask: Task<Void, Never>? = nil

    init(settings: CLISettings, cli: String) {
        self.settings = settings
        self.cli = cli
        _preference = AppStorage(wrappedValue: "", settings.preferenceKey)
    }

    private var hasVersions: Bool { settings.installedVersion != nil || settings.latestVersion != nil }

    var body: some View {
        Form {
            Section("\(cli) CLI") {
                LabeledContent("Status") {
                    let available = settings.available(appState)
                    Label(available ? "Available" : "Not found",
                          systemImage: available ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(available ? .green : .orange)
                }

                Picker("Executable", selection: $selection) {
                    Text("Auto-detect").tag(Self.autoTag)
                    Divider()
                    ForEach(detected) { item in
                        Text(item.label.isEmpty ? item.path : "\(item.label) — \(item.path)").tag(item.path)
                    }
                    Divider()
                    Text("Custom path…").tag(Self.customSentinel)
                }
                .onChange(of: selection) { _, newValue in
                    handleSelectionChange(newValue)
                }

                if selection == Self.customSentinel {
                    TextField("/absolute/path/to/\(settings.executable)", text: $customInput)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { commitCustomPath() }

                    if let customError {
                        Label(customError, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else if !customInput.isEmpty {
                        Text("Press Return to apply.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let current = settings.current() {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Currently using: \(current)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            if hasVersions {
                Section("Version") {
                    versionRow("Installed", installedVersion)
                    HStack {
                        versionRow("Latest", latestVersion)
                        if let installed = installedVersion, let latest = latestVersion, installed != latest {
                            Text("Update available")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.orange.opacity(0.2), in: Capsule())
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }

            if let note = settings.isolationNote {
                Section("Account isolation") {
                    Text(LocalizedStringKey(note))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let recovery = settings.recovery {
                Section("Session recovery") {
                    Button(LocalizedStringKey(recovery.title), role: .destructive) {
                        confirmingRecovery = true
                    }
                    Text(LocalizedStringKey(recovery.explanation))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button {
                    Task { await refreshAll() }
                } label: {
                    Label(isLoading ? "Refreshing…" : (hasVersions ? "Refresh detected paths & versions" : "Refresh detected paths"),
                          systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
        }
        .formStyle(.grouped)
        .padding()
        .task {
            await refreshAll()
        }
        .alert(LocalizedStringKey(settings.recovery?.confirmation ?? ""), isPresented: $confirmingRecovery) {
            if let recovery = settings.recovery {
                Button(LocalizedStringKey(recovery.confirmButton), role: .destructive) {
                    Task { await recovery.run(appState) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(LocalizedStringKey(settings.recovery?.confirmationMessage ?? ""))
        }
    }

    private func versionRow(_ title: LocalizedStringKey, _ version: String?) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(version ?? (isLoading ? "Checking…" : "—"))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    // MARK: - Loaders

    private func refreshAll() async {
        isLoading = true
        defer { isLoading = false }
        // Detection can fall back to an interactive shell that blocks for
        // seconds, so it runs off the main actor and the picker fills in
        // when it returns.
        let detect = settings.detect
        detected = await Task.detached(priority: .userInitiated) { detect() }.value
        syncSelectionToPreference()
        await reloadVersions()
    }

    /// Cancels any earlier version fetch, then reads the installed and the
    /// newest version afresh.
    private func reloadVersions() async {
        versionLoadTask?.cancel()
        guard hasVersions else { return }
        let path = settings.current()
        let installedReader = settings.installedVersion, latestReader = settings.latestVersion
        let task = Task { @MainActor in
            async let installed = Self.version(at: path, installedReader)
            async let latest = Self.newest(latestReader)
            let i = await installed
            let l = await latest
            guard !Task.isCancelled else { return }
            installedVersion = i
            latestVersion = l
        }
        versionLoadTask = task
        await task.value
    }

    private static func version(at path: String?, _ reader: (@Sendable (String) async -> String?)?) async -> String? {
        guard let path, let reader else { return nil }
        return await reader(path)
    }

    private static func newest(_ reader: (@Sendable () async -> String?)?) async -> String? {
        guard let reader else { return nil }
        return await reader()
    }

    /// Sets the picker's selection from the preference, recording the
    /// value in `suppressNextSelection` so the onChange it causes is skipped.
    private func syncSelectionToPreference() {
        let target: String
        if preference.isEmpty {
            target = Self.autoTag
            customInput = ""
        } else if detected.contains(where: { $0.path == preference }) {
            target = preference
            customInput = ""
        } else {
            // A preferred path not among those found is a custom one.
            target = Self.customSentinel
            customInput = preference
        }
        guard target != selection else { return }
        suppressNextSelection = target
        selection = target
    }

    // MARK: - Selection handling

    private func handleSelectionChange(_ newValue: String) {
        // Only the exact programmatic write is skipped; another value is the
        // user's choice.
        if let expected = suppressNextSelection, expected == newValue {
            suppressNextSelection = nil
            return
        }
        suppressNextSelection = nil
        customError = nil
        if newValue == Self.autoTag {
            applyPreference("")
            return
        }
        if newValue == Self.customSentinel {
            if customInput.isEmpty, !preference.isEmpty,
               !detected.contains(where: { $0.path == preference }) {
                customInput = preference
            }
            return
        }
        applyPreference(newValue)
    }

    private func commitCustomPath() {
        let trimmed = customInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            customError = "Path is empty."
            return
        }
        guard trimmed.hasPrefix("/") else {
            customError = "Path must be absolute (start with /)."
            return
        }
        guard FileManager.default.isExecutableFile(atPath: trimmed) else {
            customError = "Not found or not executable."
            return
        }
        customError = nil
        customInput = trimmed
        applyPreference(trimmed)
        // A typed path that was found selects that entry, so the picker
        // shows it; the onChange consumes the suppress token.
        if detected.contains(where: { $0.path == trimmed }), selection != trimmed {
            suppressNextSelection = trimmed
            selection = trimmed
        }
    }

    /// Writes the preference ("" for automatic), hands it to the provider's
    /// service, and reads the versions and every account again.
    private func applyPreference(_ newValue: String) {
        preference = newValue
        settings.apply(newValue.isEmpty ? nil : newValue)
        Task {
            await reloadVersions()
            await appState.refresh(forceUnavailablePlanCheck: true)
        }
    }
}
