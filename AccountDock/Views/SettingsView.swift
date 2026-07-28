import SwiftUI
import ServiceManagement

/// Settings window for configuring the app.
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var updateChecker: UpdateChecker
    @AppStorage("refreshInterval") private var refreshInterval: Double = 300
    @AppStorage("showFullEmail") private var showFullEmail = false
    @AppStorage("showInDock") private var showInDock = false
    @AppStorage("appLanguage") private var appLanguage = "auto"
    @AppStorage("accentPalette") private var accentPalette = "softWhite"
    @AppStorage("interfaceDensity") private var interfaceDensity = "comfortable"
    @AppStorage("cardCornerRadius") private var cardCornerRadius = 7.0
    @AppStorage("disableCardShadows") private var disableCardShadows = false
    @AppStorage("showClaudeProvider") private var showClaudeProvider = true
    @AppStorage("showCodexProvider") private var showCodexProvider = true
    @State private var launchAtLogin = false

    var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            menuBarTab
                .tabItem {
                    Label("Menu Bar", systemImage: "menubar.rectangle")
                }

            AppearanceSettingsView()
                .tabItem {
                    Label("Appearance", systemImage: "paintpalette")
                }

            FailoverSettingsView()
                .tabItem {
                    Label("Failover", systemImage: "arrow.triangle.branch")
                }

            FailoverLogView()
                .tabItem {
                    Label("Log", systemImage: "list.bullet.rectangle")
                }

            if showClaudeProvider {
                ClaudeCLITabView()
                    .tabItem {
                        Label("Claude CLI", systemImage: "terminal")
                    }
            }

            if showCodexProvider {
                CodexCLITabView()
                    .tabItem {
                        Label("Codex CLI", systemImage: AIProviderType.codex.iconName)
                    }
            }

            aboutTab
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 660, height: 560)
        .tint(Color.brand)
        .id("\(accentPalette)|\(interfaceDensity)|\(cardCornerRadius)|\(disableCardShadows)")
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            Section("Refresh") {
                Picker("Auto-refresh interval", selection: $refreshInterval) {
                    Text("15 seconds").tag(15.0)
                    Text("30 seconds").tag(30.0)
                    Text("1 minute").tag(60.0)
                    Text("5 minutes").tag(300.0)
                    Text("10 minutes").tag(600.0)
                }
                .onChange(of: refreshInterval) { _, newValue in
                    appState.startAutoRefresh(interval: newValue)
                }
            }

            Section("Account display") {
                Toggle("Show full email address", isOn: $showFullEmail)
            }

            Section("Providers") {
                Toggle("Show Claude", isOn: $showClaudeProvider)
                    .disabled(showClaudeProvider && !showCodexProvider)
                Toggle("Show Codex", isOn: $showCodexProvider)
                    .disabled(showCodexProvider && !showClaudeProvider)
                Text("Visible providers appear together in AccountDock. At least one provider must remain enabled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Appearance") {
                Picker("Language", selection: $appLanguage) {
                    Text("Automatic").tag("auto")
                    Divider()
                    Text("English").tag("en")
                    Text("中文（简体）").tag("zh-Hans")
                    Text("日本語").tag("ja")
                    Text("Deutsch").tag("de")
                    Text("Français").tag("fr")
                }
                .onChange(of: appLanguage) { _, newValue in
                    applyLanguage(newValue)
                }
            }

            Section("System") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        toggleLaunchAtLogin(newValue)
                    }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Menu Bar Tab

    private var menuBarTab: some View {
        Form {
            Section {
                MenuBarModulesSettingsView()
                    .environmentObject(appState)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - About Tab

    private var aboutTab: some View {
        VStack(spacing: 12) {
            AccountDockMark(size: 72)

            Text("AccountDock")
                .font(.system(.title2, design: .rounded, weight: .bold))

            Text("ONE DOCK. EVERY IDENTITY.")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1.8)
                .foregroundStyle(.brand)

            Text("Claude Code & Codex Account Switcher")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")")
                .font(.caption)
                .foregroundStyle(.tertiary)

            VStack(spacing: 8) {
                Text(updateChecker.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                HStack {
                    Button {
                        Task { await updateChecker.checkForUpdates(manual: true) }
                    } label: {
                        if updateChecker.isChecking {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Check for Updates")
                        }
                    }
                    .disabled(updateChecker.isChecking)

                    if let update = updateChecker.availableUpdate {
                        Button("Copy Safe Install Command") {
                            updateChecker.copyInstallCommand()
                        }
                        Link("View Release", destination: update.releaseURL)
                    }
                }
            }
            .padding(.top, 4)

            Spacer()

            Text("Switch Claude Code and Codex accounts, monitor usage, and shape the interface around your workflow.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Text("Unified local account control for Claude Code and Codex.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            .padding(.top, 8)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private func applyLanguage(_ lang: String) {
        // Set AppleLanguages for next launch; .environment(\.locale) handles live update
        if lang == "auto" {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([lang], forKey: "AppleLanguages")
        }
    }

    private func toggleLaunchAtLogin(_ enable: Bool) {
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLogin = !enable // revert on failure
        }
    }
}

private struct FailoverLogView: View {
    @ObservedObject private var eventLog = FailoverEventLog.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Failover activity")
                        .font(.headline)
                    Text("Account identities are obfuscated and credentials are never recorded.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Clear", role: .destructive) {
                    eventLog.clear()
                }
                .disabled(eventLog.events.isEmpty)
            }
            .padding()

            Divider()

            if eventLog.events.isEmpty {
                ContentUnavailableView(
                    "No Failover Activity",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Threshold decisions, switches, reset waits, and recovery attempts will appear here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(Array(eventLog.events.reversed())) { event in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: event.provider == AIProviderType.codex.rawValue
                              ? AIProviderType.codex.iconName
                              : AIProviderType.claudeCode.iconName)
                            .foregroundStyle(.brand)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(event.provider)
                                    .font(.caption.weight(.medium))
                                Spacer()
                                Text(event.date, format: .dateTime.month(.abbreviated).day().hour().minute().second())
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                            Text(event.message)
                                .font(.caption)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 3)
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
