import SwiftUI

/// "Rebalance sessions now": shows what `AppState.rebalancePreview` would
/// move and when the first account would run out, and makes the moves
/// (`AppState.applyRebalance`) once confirmed. Shown in Settings → Failover
/// and in the usage tab's provider menu for a provider whose sessions run in
/// slots of their own.
struct RebalanceButton: View {
    @EnvironmentObject private var appState: AppState
    let provider: AIProviderType
    @State private var preview: AppState.RebalancePreview?

    var body: some View {
        Button("Rebalance sessions now…") {
            preview = appState.rebalancePreview(provider)
        }
        .help("Places the running sessions on the accounts so that the first account to run out does so as late as possible, using each session's own rate and model. A move rewrites the session's prompt cache on its new account, so a session moves only when that pays for itself, and never mid-turn.")
        .alert(
            preview.map { $0.moves.isEmpty ? "Sessions are balanced" : "Rebalance \(provider.capabilities.displayName) sessions?" } ?? "",
            isPresented: Binding(get: { preview != nil }, set: { if !$0 { preview = nil } }),
            presenting: preview
        ) { plan in
            if plan.moves.isEmpty {
                Button("OK") { preview = nil }
            } else {
                Button(plan.moves.count == 1 ? "Move 1 session" : "Move \(plan.moves.count) sessions") {
                    Task { await appState.applyRebalance(provider) }
                    preview = nil
                }
                Button("Cancel", role: .cancel) { preview = nil }
            }
        } message: { plan in
            Text(([plan.outcome] + plan.lines).joined(separator: "\n"))
        }
    }
}
