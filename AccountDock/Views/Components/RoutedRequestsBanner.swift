import SwiftUI

/// Shown under a provider heading while its requests are served by the
/// router's route target because every account is exhausted.
struct RoutedRequestsBanner: View {
    @EnvironmentObject private var appState: AppState
    let provider: AIProviderType
    let status: AppState.RoutedStatus

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .font(.title3)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Requests are served by \(status.target)")
                    .font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button("Return now") { appState.returnToPrimaryNow(provider) }
                .controlSize(.small)
                .help("Send new turns to \(provider.capabilities.displayName) again. They may then reach the usage limit.")
        }
        .padding(10)
        .background(Color.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .sectionPadding()
    }

    private var detail: String {
        var parts = ["\(status.model) on \(status.backingAccount) since \(status.since.formatted(date: .omitted, time: .shortened)); sessions keep running."]
        if status.turns > 0 { parts.append("\(status.turns) turn(s) served.") }
        if let resumeAt = status.resumeAt {
            parts.append("Back when capacity returns, expected \(resumeAt.formatted(date: .omitted, time: .shortened)).")
        } else {
            parts.append("Back when an account has capacity again.")
        }
        return parts.joined(separator: " ")
    }
}
