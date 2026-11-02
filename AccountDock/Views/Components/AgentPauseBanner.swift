import SwiftUI

/// Shown under a provider heading while AccountDock holds sessions because
/// every account of that provider reached its usage limit.
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
            VStack(alignment: .trailing, spacing: 4) {
                Button("Resume now") {
                    Task { await appState.resumePausedAgentsNow(provider) }
                }
                .controlSize(.small)
                .help("Let the paused sessions continue now. They may then reach the usage limit.")
                let waiting = appState.waitingSessions(provider)
                if !waiting.isEmpty {
                    Menu("Resume one") {
                        ForEach(waiting) { session in
                            Button(session.label) { appState.resumeSession(session) }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .controlSize(.small)
                    .fixedSize()
                    .help("Let one waiting session continue while the others stay paused. \(SessionResumeShortcut.display) resumes the one in the front window.")
                }
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .sectionPadding()
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
            parts.append("Resumes when capacity returns, expected \(resumeAt.formatted(date: .omitted, time: .shortened)).")
        } else {
            parts.append("Resumes when an account has capacity again.")
        }
        if status.sessions > 0 {
            let waiting = status.waiting
            parts.append(waiting == status.sessions
                ? "All are waiting before their next request."
                : "\(waiting) waiting now; the others pause at their next tool call.")
        }
        parts.append("New turns wait until then. Paused since \(status.since.formatted(date: .omitted, time: .shortened)).")
        if status.waiting > 0 {
            parts.append("\(SessionResumeShortcut.display) resumes the session in the front window.")
        }
        return parts.joined(separator: " ")
    }
}
