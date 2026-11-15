import SwiftUI

/// Shown under a provider heading while AccountDock holds sessions: because
/// every account of that provider reached its usage limit, or because the
/// user paused all of them or some one at a time. Its icons resume every
/// session, resume one from a menu, and open the Sessions tab.
struct AgentPauseBanner: View {
    @EnvironmentObject private var appState: AppState
    let provider: AIProviderType
    let status: AppState.AgentPauseStatus

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "pause.circle.fill")
                .font(.title3)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            HStack(spacing: 8) {
                Button {
                    Task { await appState.resumePausedAgentsNow(provider) }
                } label: {
                    Image(systemName: "play.circle")
                }
                .help("Resume all: let the paused sessions continue now. They may then reach the usage limit.")
                .accessibilityLabel("Resume all sessions")
                let paused = appState.pausedSessions(provider)
                if !paused.isEmpty {
                    Menu {
                        ForEach(paused) { session in
                            Button("Play " + (session.isWaiting ? "\(session.label) (waiting)" : session.label)) {
                                appState.resumeSession(session)
                            }
                        }
                    } label: {
                        Image(systemName: "play.square.stack")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Play one session while the others stay paused, whether it is waiting now or would stop at its next tool call. \(SessionResumeShortcut.display) resumes the one in the front window.")
                    .accessibilityLabel("Play one session")
                }
                Button {
                    NotificationCenter.default.post(name: .accountdockShowSessions, object: nil)
                } label: {
                    Image(systemName: "rectangle.stack")
                }
                .help("Open the Sessions page to pause, play, pin or move each session.")
                .accessibilityLabel("Show sessions")
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .sectionPadding()
    }

    /// Whether the pause holds only sessions the user paused one at a time,
    /// which only the user ends and which lets new turns of other sessions
    /// go on (`AgentPauseGate.PauseFile.holdsOnlyChosenSessions`).
    private var chosenOnly: Bool {
        AgentPauseGate.read(provider)?.holdsOnlyChosenSessions == true
    }

    private var title: String {
        let count = status.sessions + status.stoppedProcesses
        if status.manual { return count == 1 ? "1 session paused by you" : count == 0 ? "Sessions paused by you" : "\(count) sessions paused by you" }
        if count == 0 { return "Sessions paused" }
        return count == 1 ? "1 session paused" : "\(count) sessions paused"
    }

    private var detail: String {
        var parts: [String] = []
        if chosenOnly {
            parts.append("Held until you play them; other sessions keep running.")
        } else if let resumeAt = status.resumeAt {
            parts.append("Resumes when capacity returns, expected \(UsageFormat.clock(resumeAt)).")
        } else {
            parts.append("Resumes when an account has capacity again.")
        }
        if status.sessions > 0 {
            let waiting = status.waiting
            parts.append(waiting == status.sessions
                ? "All are waiting before their next request."
                : "\(waiting) waiting now; the others pause at their next tool call.")
        }
        parts.append((chosenOnly ? "" : "New turns wait until then. ") + "Paused since \(UsageFormat.clock(status.since)).")
        if status.waiting > 0 {
            parts.append("\(SessionResumeShortcut.display) resumes the session in the front window.")
        }
        return parts.joined(separator: " ")
    }
}
