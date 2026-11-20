import SwiftUI

/// The icon controls of one running session, on the Sessions page and in an
/// account card's session list: a lock pinning it to its subscription (for
/// a session on the shared sign-in, its restart into a slot of its own
/// instead), pause or play, and a menu moving it to another account.
struct SessionControlButtons: View {
    @EnvironmentObject private var appState: AppState
    let provider: AIProviderType
    let session: String
    let state: SessionRowState
    let pinned: Bool
    /// It reads a one-session slot of its own.
    let inSlot: Bool
    /// A pause can hold it (`SessionRow.gated`).
    let gated: Bool
    /// Its move menu (`AppState.sessionMoveMenu`, through
    /// `SessionsSection.Entry` on the Sessions page); nil while the
    /// provider's sessions run in no slots, which dims the move control.
    let moveMenu: SessionMoveMenu?
    /// Told what a move chosen from the menu did.
    var onMove: (AppState.SessionMoveOutcome) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 8) {
            pinControl
            pauseControl
            moveControl
        }
        .buttonStyle(.borderless)
    }

    private func iconButton(_ symbol: String, label: String, help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 16)
        }
        .help(help)
        .accessibilityLabel(label)
    }

    /// The lock, or for a session on the shared sign-in, which cannot be
    /// pinned, its restart into a slot of its own.
    @ViewBuilder
    private var pinControl: some View {
        if !pinned, !inSlot, let live = appState.unisolatedSessions[provider]?.first(where: { $0.sessionID == session }) {
            let blocker = AppState.restartBlocker(live, terminal: appState.unisolatedTerminals[session],
                                                  background: appState.backgroundSessionStates[session],
                                                  refused: appState.sessionRefusals[session] != nil)
            iconButton("arrow.clockwise.circle", label: "Restart in its own slot",
                       help: blocker.map { "It runs on the shared sign-in, so it cannot be pinned until it restarts in a slot of its own. \($0)" }
                           ?? "It runs on the shared sign-in, so it cannot be pinned. Restart it in a slot of its own first; it can then be pinned.") {
                Task { await appState.restartInOwnSlot(session) }
            }
            .disabled(blocker != nil)
        } else {
            iconButton(pinned ? "lock.fill" : "lock.open", label: pinned ? "Unpin session" : "Pin session",
                       help: pinned
                           ? "Pinned: failover, pacing, rebalancing and the model fallback leave it on this subscription. Click to unpin."
                           : inSlot ? "Pin this session to its subscription, so nothing automatic moves it."
                           : "It runs on the shared sign-in and moves with the active account, so it cannot be pinned.") {
                if pinned { appState.unpinSession(session) } else { appState.pinSession(session) }
            }
            .foregroundStyle(pinned ? Color.accentColor : Color.secondary)
            .disabled(!pinned && !inSlot)
        }
    }

    @ViewBuilder
    private var pauseControl: some View {
        if state.isPaused, let note = appState.playNotes[session] {
            // A first press found no account with room: the control says
            // why until the note clears, and pressing it again runs the
            // session anyway (`AppState.pressPlay`).
            Button {
                appState.playSession(provider, session: session)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: "play.fill")
                    Text(note.text)
                        .font(.caption)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 280, alignment: .leading)
            }
            .help(note.text)
            .accessibilityLabel("Run session anyway")
            .foregroundStyle(.orange)
        } else if state.isPaused {
            iconButton("play.fill", label: "Play session",
                       help: (state == .waiting
                           ? "It is waiting at the pause. Let it continue while the others stay paused."
                           : "The pause stops it at its next tool call or turn. Let it keep running while the others stay paused.")
                           + " With no account having room, the first press says why and a second runs it anyway.") {
                appState.playSession(provider, session: session)
            }
            .foregroundStyle(.orange)
        } else {
            iconButton("pause.fill", label: "Pause session",
                       help: gated
                           ? "Hold this session at its next tool call, and its new turns at their start, while other sessions keep running."
                           : provider.capabilities.pauseGate == nil
                           ? "\(provider.capabilities.displayName) sessions cannot be paused."
                           : "It started before the pause hook was installed, so no pause can hold it; restart it so one can.") {
                appState.pauseSession(provider, session: session)
            }
            .disabled(!gated)
        }
    }

    @ViewBuilder
    private var moveControl: some View {
        if let menu = moveMenu {
            let restartBlocker = menu.kind == .restartInSlot
                ? appState.unisolatedSessions[provider]?.first(where: { $0.sessionID == session }).flatMap { live in
                    AppState.restartBlocker(live, terminal: appState.unisolatedTerminals[session],
                                            background: appState.backgroundSessionStates[session],
                                            refused: appState.sessionRefusals[session] != nil)
                }
                : nil
            Menu {
                if let pinnedTo = menu.pinnedTo {
                    Text("Pinned to \(pinnedTo); a move unpins it first.")
                }
                if menu.kind == .restartInSlot {
                    Text("On the shared sign-in: it restarts in a slot of its own on the account chosen.")
                }
                ForEach(menu.options) { option in
                    let detail = menu.detail(option, sessionWindow: provider.capabilities.sessionQuotaLabel,
                                             longWindow: provider.capabilities.weeklyQuotaLabel)
                    // A destination the user may choose but should know
                    // about (excluded, or at or near its limit) carries a
                    // warning sign; one that cannot serve is disabled.
                    Button {
                        Task { onMove(await appState.moveSessionByHand(session, to: option.account)) }
                    } label: {
                        if option.warning != nil {
                            Label(menu.title(option) + " — " + detail, systemImage: "exclamationmark.triangle")
                        } else {
                            Text(menu.title(option) + " — " + detail)
                        }
                    }
                    .disabled(option.blocker != nil)
                }
            } label: {
                Image(systemName: "arrow.left.arrow.right")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(restartBlocker != nil)
            .help(restartBlocker.map { "It moves by restarting in a slot of its own. \($0)" }
                  ?? "Move this session to another account. It is pinned there, so failover and balancing leave it, unless balancing would place it there itself.")
            .accessibilityLabel("Move session")
        } else {
            Image(systemName: "arrow.left.arrow.right")
                .frame(width: 16)
                .foregroundStyle(.tertiary)
                .help("\(provider.capabilities.displayName) sessions do not run in slots of their own here, so one moves only with the active account.")
                .accessibilityLabel("Move session, unavailable")
        }
    }
}
