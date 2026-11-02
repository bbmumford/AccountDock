import SwiftUI

/// Settings section listing each part AccountDock adds to the agents'
/// configuration, with its state and a reinstall action.
struct AgentHooksSettingsSection: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage(AgentHookInstaller.promptSuppressedKey) private var promptSuppressed = false
    @State private var statuses: [AgentHookInstaller.Status] = []
    @State private var working = false
    @State private var result: String?

    var body: some View {
        Section {
            ForEach(statuses) { status in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: icon(status))
                        .foregroundStyle(color(status))
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(status.component.title)
                        Text(status.required ? status.component.purpose : "Not needed with the current settings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(label(status))
                        .font(.caption)
                        .foregroundStyle(color(status))
                }
            }
            HStack {
                Button(working ? "Installing…" : "Reinstall hooks") { reinstall() }
                    .disabled(working)
                if let result {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Toggle("Ask on launch when hooks are missing", isOn: Binding(
                get: { !promptSuppressed },
                set: { promptSuppressed = !$0 }
            ))
        } header: {
            Text("Agent hooks")
        } footer: {
            Text("AccountDock adds these to \(hookFiles.joined(separator: ", ")). Other settings in those files are kept, and the first change keeps a backup next to each file.")
        }
        .onAppear(perform: refresh)
    }

    /// The configuration files the providers' hooks and router go in.
    private var hookFiles: [String] {
        var files: [String] = []
        for provider in AIProviderType.implementedProviders {
            let capabilities = provider.capabilities
            for file in [capabilities.lifecycleHooks?.hookFile, capabilities.pauseGate?.hookFile,
                         capabilities.requestRouter?.settingsFile].compactMap({ $0 })
            where !files.contains("~/" + file) {
                files.append("~/" + file)
            }
        }
        return files
    }

    private func refresh() {
        statuses = AgentHookInstaller.statuses(pausingProviders: appState.pausingProviders)
    }

    private func reinstall() {
        working = true
        result = nil
        let providers = appState.pausingProviders
        Task {
            let failures = await Task.detached(priority: .userInitiated) {
                AgentHookInstaller.install(pausingProviders: providers, reinstall: true)
            }.value
            working = false
            result = failures.isEmpty
                ? "Hooks reinstalled."
                : failures.map { "\($0.key.title): \($0.value)" }.joined(separator: "\n")
            refresh()
        }
    }

    private func icon(_ status: AgentHookInstaller.Status) -> String {
        guard status.required else { return "minus.circle" }
        return status.installed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private func color(_ status: AgentHookInstaller.Status) -> Color {
        guard status.required else { return .secondary }
        return status.installed ? .green : .orange
    }

    private func label(_ status: AgentHookInstaller.Status) -> String {
        guard status.required else { return status.installed ? "Installed" : "Off" }
        return status.installed ? "Installed" : "Missing"
    }
}
