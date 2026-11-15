import SwiftUI

/// Shown under a provider heading while AccountDock holds sessions, each
/// because the account it runs on is at or near its usage limit, listing
/// each held session with that account and when it is expected to serve it
/// again (`AppState.pausedSessions`).
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
                let held = appState.pausedSessions(provider)
                ForEach(held.prefix(Self.listedSessions)) { session in
                    Text(line(session))
                        .font(.caption2)
                        .foregroundStyle(.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if held.count > Self.listedSessions {
                    Text("and \(held.count - Self.listedSessions) more")
                        .font(.caption2)
                        .foregroundStyle(.textSecondary)
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 4) {
                Button("Resume now") {
                    Task { await appState.resumePausedAgentsNow(provider) }
                }
                .controlSize(.small)
                .help("Let the paused sessions continue now. They may then reach the usage limit.")
                let paused = appState.pausedSessions(provider)
                if !paused.isEmpty {
                    Menu("Resume one") {
                        ForEach(paused) { session in
                            Button(session.isWaiting ? "\(session.label) (waiting)" : session.label) {
                                appState.resumeSession(session)
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .controlSize(.small)
                    .fixedSize()
                    .help("Let one session continue while the others stay paused, whether it is waiting now or would stop at its next tool call. \(SessionResumeShortcut.display) resumes the one in the front window.")
                }
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .sectionPadding()
    }

    /// Held sessions listed by name; the rest are counted.
    static let listedSessions = 8

    /// One held session: its name, the account it runs on, and when that
    /// account is expected to serve it again.
    private func line(_ session: WaitingSession) -> String {
        var parts = [session.isWaiting ? "\(session.label) (waiting)" : session.label]
        if let id = session.account, let account = appState.accounts.first(where: { $0.id == id }) {
            parts.append("on \(appState.messageName(account))")
        }
        if let resumeAt = session.resumeAt {
            parts.append("resumes about \(UsageFormat.clock(resumeAt))")
        }
        return parts.joined(separator: " · ")
    }

    private var title: String {
        let count = status.sessions + status.stoppedProcesses
        if status.manual { return count == 1 ? "1 session paused by you" : count == 0 ? "Sessions paused by you" : "\(count) sessions paused by you" }
        if count == 0 { return "Sessions paused" }
        return count == 1 ? "1 session paused" : "\(count) sessions paused"
    }

    private var detail: String {
        var parts: [String] = []
        if let resumeAt = status.resumeAt {
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
        parts.append("New turns wait until then. Paused since \(UsageFormat.clock(status.since)).")
        if status.waiting > 0 {
            parts.append("\(SessionResumeShortcut.display) resumes the session in the front window.")
        }
        return parts.joined(separator: " ")
    }
}
