import Foundation

/// Marks AccountDock's work on the providers' credentials as under way:
/// `AppState.refresh`, every switch, sign-in and re-authentication, and
/// `adoptRenewedCredentials` run inside it, and `runQuotaCycle` and
/// `adoptRenewedCredentials` do not start while it is busy, since either
/// would read or replace a credential the running work is changing.
///
/// A run nested inside another, as a switch `refresh` starts through
/// `evaluateFailover`, keeps the gate busy until the outermost run ends; the
/// gate counts runs and never waits, so nesting cannot deadlock.
@MainActor
final class CredentialOperationGate {
    private(set) var depth = 0

    /// Called with `true` when the first run starts and `false` when the
    /// last one ends; `AppState` shows it as `isLoading`.
    var onBusyChange: (@MainActor (Bool) -> Void)?

    var isBusy: Bool { depth > 0 }

    func run<T>(_ body: @MainActor () async -> T) async -> T {
        depth += 1
        if depth == 1 { onBusyChange?(true) }
        defer {
            depth -= 1
            if depth == 0 { onBusyChange?(false) }
        }
        return await body()
    }
}
