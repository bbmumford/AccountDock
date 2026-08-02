import SwiftUI

struct CodexCLITabView: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("codexBinaryPathPreference") private var selectedPath = ""
    @State private var customPath = ""
    @State private var showingForceRestartConfirmation = false

    private let service = CodexService.shared

    var body: some View {
        Form {
            Section("Codex CLI") {
                LabeledContent("Status") {
                    Label(
                        appState.codexAvailable ? "Available" : "Not found",
                        systemImage: appState.codexAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(appState.codexAvailable ? .green : .orange)
                }

                Picker("Executable", selection: $selectedPath) {
                    Text("Automatic").tag("")
                    ForEach(service.detectedBinaryPaths(), id: \.self) { path in
                        Text(path).tag(path)
                    }
                    if !customPath.isEmpty && !service.detectedBinaryPaths().contains(customPath) {
                        Text(customPath).tag(customPath)
                    }
                }
                .onChange(of: selectedPath) { _, value in
                    service.setBinaryPath(value)
                    Task { await appState.refresh() }
                }

                HStack {
                    TextField("Custom executable path", text: $customPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Use Path") {
                        selectedPath = customPath
                    }
                    .disabled(customPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            Section("Account isolation") {
                Text("Each managed account has its own CODEX_HOME. Switching stages only auth.json into ~/.codex, preserving your system configuration and history.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Session recovery") {
                Button("Force Restart Codex Sessions", role: .destructive) {
                    showingForceRestartConfirmation = true
                }
                Text("Closes detected Codex Terminal sessions, then opens a new Terminal window for each recoverable session and runs codex resume with its session ID.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            customPath = selectedPath
        }
        .alert("Force restart Codex sessions?", isPresented: $showingForceRestartConfirmation) {
            Button("Force Restart", role: .destructive) {
                Task { await appState.forceRestartCodexSessions() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("AccountDock will close every detected Codex terminal process and its Terminal tab. Sessions without a detected session ID cannot be reopened automatically.")
        }
    }
}
