import SwiftUI

/// Shown under a provider heading while AccountDock holds sessions: each
/// because the account it runs on is at or near its usage limit, or because
/// the user paused all of them or some one at a time. One line says how many
/// are held and when they are expected to continue; the Sessions tab lists
/// each one (`AppState.pausedSessions`), and the icons resume every session
/// or open that tab. Under it, for a few seconds, the reason a play found no
/// account with room (`AppState.playNotes`).
struct AgentPauseBanner: View {
    @EnvironmentObject private var appState: AppState
    let provider: AIProviderType
    let status: AppState.AgentPauseStatus

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "pause.circle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary)
                    .font(.caption)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                // A play pressed while no account had room, until its note
                // clears (`AppState.playNotes`).
                ForEach(notes, id: \.session) { note in
                    Text("\(note.label): \(note.text)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
                Button {
                    NotificationCenter.default.post(name: .accountdockShowSessions, object: nil)
                } label: {
                    Image(systemName: "rectangle.stack")
                }
                .help("Open the Sessions page to see each paused session and pause, play, pin or move it. \(SessionResumeShortcut.display) resumes the session in the front window.")
                .accessibilityLabel("Show sessions")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .sectionPadding()
    }

    /// The provider's notes of first presses that found no room.
    private var notes: [AppState.PlayNote] {
        appState.playNotes.values.filter { $0.provider == provider }.sorted { $0.label < $1.label }
    }

    /// "9 sessions paused · resumes about 8:40 pm", or "held until you play
    /// them" for a pause that holds only sessions the user chose.
    private var summary: String {
        let when: String
        if chosenOnly {
            when = "held until you play them"
        } else if let resumeAt = status.resumeAt {
            when = "resumes about \(UsageFormat.clock(resumeAt))"
        } else {
            when = "resumes when an account has room"
        }
        return "\(title) · \(when)"
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
}
