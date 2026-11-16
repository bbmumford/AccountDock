import SwiftUI

extension Notification.Name {
    /// Asks the main window to show its Sessions tab, as the pause banner's
    /// link does.
    static let accountdockShowSessions = Notification.Name("accountdockShowSessions")
}

/// The main window's Sessions tab: every running session of each provider
/// with a pause gate or one-session slots (`AppState.sessionControlProviders`),
/// grouped by provider (`SessionsSection`, from `AppState.sessionsSection`),
/// one row each with the account serving it, its state and its controls
/// (`SessionControlButtons`). Each provider heading pauses or resumes all
/// its sessions and rebalances them. The rows are read again every few
/// seconds, since the gate changes the pause files on its own.
struct SessionsView: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage(ProviderVisibility.storageKey) private var hiddenProviders = ""
    /// What the last move chosen from a row's menu did, by provider.
    @State private var moveOutcomes: [AIProviderType: AppState.SessionMoveOutcome] = [:]
    #if DEBUG
    /// The screenshot renderer's sample sections, shown in place of the
    /// live ones; nil in every other launch.
    @Environment(\.sampleSessionsSections) private var sampleSections
    #endif

    var body: some View {
        ScrollView {
            TimelineView(.periodic(from: .now, by: 3)) { _ in
                let sections = self.sections
                VStack(alignment: .leading, spacing: 16) {
                    if sections.isEmpty {
                        Text("No provider here has sessions AccountDock can pause or move.")
                            .font(.caption)
                            .foregroundStyle(.textSecondary)
                            .sectionPadding()
                    }
                    ForEach(sections) { section in
                        providerSection(section)
                    }
                }
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                // The window's height follows this list, as it follows the
                // other tabs' content (MainMenuView.popoverHeight).
                .measureUsageContentHeight()
            }
        }
    }

    /// Each shown provider's section: the live ones, or the screenshot
    /// renderer's samples.
    private var sections: [SessionsSection] {
        #if DEBUG
        if let sampleSections { return sampleSections }
        #endif
        return providers.map { appState.sessionsSection($0) }
    }

    /// The Outlook is projected from the live sessions and accounts, so the
    /// screenshot renderer's sample sections show none.
    private var showsOutlook: Bool {
        #if DEBUG
        return sampleSections == nil
        #else
        return true
        #endif
    }

    private var providers: [AIProviderType] {
        let hidden = ProviderVisibility.hidden(in: hiddenProviders)
        return appState.sessionControlProviders.filter { provider in
            !hidden.contains(provider) && appState.accounts.contains { $0.provider == provider }
        }
    }

    @ViewBuilder
    private func providerSection(_ section: SessionsSection) -> some View {
        let provider = section.provider
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Label(provider.capabilities.displayName, systemImage: provider.iconName)
                    .font(.headline)
                    .foregroundStyle(.brand)
                Spacer()
                headerControls(section)
            }
            Text(section.pauseLine)
                .font(.caption)
                .foregroundStyle(.textSecondary)
            // The Outlook for the pool as a whole, then the pacer's notes on
            // single accounts: what an account with free room does with it
            // (`useByNotes`) and why a small plan's window with room takes
            // no running session.
            let outlook = showsOutlook && !section.entries.isEmpty ? appState.capacityOutlook(provider) : nil
            let notes = appState.laneNotes[provider] ?? []
            if outlook != nil || !notes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    if let outlook {
                        CapacityOutlookView(provider: provider, outlook: outlook)
                    }
                    ForEach(notes, id: \.self) { note in
                        Label(note, systemImage: "info.circle")
                            .font(.caption2)
                            .foregroundStyle(.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let outcome = moveOutcomes[provider] {
                Label(outcome.detail, systemImage: outcome.ok ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(outcome.ok ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(section.entries) { entry in
                sessionRow(entry)
                Divider()
            }
        }
        .sectionPadding()
    }

    @ViewBuilder
    private func headerControls(_ section: SessionsSection) -> some View {
        let provider = section.provider
        HStack(spacing: 10) {
            if provider.capabilities.pauseGate != nil {
                Button {
                    appState.pauseSessionsNow(provider)
                } label: {
                    Image(systemName: "pause.circle")
                }
                .disabled(!section.canPauseAll)
                .hoverExplanation("Pause all", "Every session waits at its next tool call and new turns wait at their start. Sessions continue when you resume them or when an account in the failover order has capacity; an active account that failover excludes does not resume them.")
                .accessibilityLabel("Pause all sessions")

                Button {
                    Task { await appState.resumePausedAgentsNow(provider) }
                } label: {
                    Image(systemName: "play.circle")
                }
                .disabled(!section.canResumeAll)
                .hoverExplanation("Resume all", "Every paused session continues now. Sessions may then reach the usage limit.")
                .accessibilityLabel("Resume all sessions")
            }
            ProviderFailoverSwitch(provider: provider, place: "the Sessions page")
            if section.canRebalance {
                RebalanceButton(provider: provider)
            }
        }
        .buttonStyle(.borderless)
        .font(.body)
    }

    private func sessionRow(_ entry: SessionsSection.Entry) -> some View {
        let row = entry.row
        return HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: row.label)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(row.label)
                HStack(spacing: 4) {
                    Text(verbatim: row.account)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(verbatim: "·")
                    Text(verbatim: row.state.label)
                        .foregroundStyle(stateColor(row.state))
                        .lineLimit(1)
                    if row.state.isPaused, let when = pauseNote(row) {
                        Text(verbatim: "· " + when)
                            .lineLimit(1)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.textSecondary)
            }
            Spacer(minLength: 4)
            SessionControlButtons(provider: row.provider, session: row.id, state: row.state, pinned: row.pinned,
                                  inSlot: row.inSlot, gated: row.gated, moveMenu: entry.moveMenu) { outcome in
                moveOutcomes[row.provider] = outcome
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// When a held session goes on: where and when its wait for a lane
    /// resumes it, else when its account is expected to serve it again, or,
    /// paused by the user, when the user plays it.
    private func pauseNote(_ row: SessionRow) -> String? {
        if row.pausedByYou { return "until you play it" }
        if let plan = row.waitPlan { return plan }
        return row.resumeAt.map { "resumes about \(UsageFormat.clock($0))" }
    }

    private func stateColor(_ state: SessionRowState) -> Color {
        switch state {
        case .waiting, .stopsAtNextStep: .orange
        case .refusedAtLimit: .red
        case .running, .resumedWhileOthersPaused, .notIsolated: .secondary
        }
    }
}
