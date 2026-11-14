import Foundation

/// What a slot holds for the account it serves: the provider's credential
/// with no refresh token, as the CLI reads it from the slot. AccountDock
/// renews every account it stores and writes the renewed access token to
/// the slots; a CLI holding the refresh token would renew it under
/// AccountDock and revoke the copy AccountDock keeps.
struct SlotCredential: Equatable, Sendable {
    let contents: String
}

/// A provider's part in running each CLI session in a location of its own,
/// a slot, whose credential AccountDock writes and can change one session at
/// a time. Everything else is the same for every provider and lives in
/// `SessionSlots` and `AppState+SessionSlots`: the launcher on the user's
/// `PATH`, the pool and resume files, spare and claimed one-session slots,
/// which process reads which slot, and moving a session by rewriting its
/// slot. A provider offers one through `ProviderCapabilities.sessionIsolation`;
/// without one its sessions keep the CLI's own credential.
protocol ProviderSessionIsolation: Sendable {
    /// The CLI's executable name: the launcher's name, the prefix of the
    /// slot root (`~/.accountdock/<executable>-slots`), and the name its
    /// processes are found by.
    var executable: String { get }
    /// The environment variable naming the slot directory the CLI then
    /// reads its credential from. The launcher exports it, and
    /// `SessionSlots.directoriesByProcess` finds each process's slot by it
    /// in `ps -E` output.
    var directoryVariable: String { get }
    /// Variables that already decide the CLI's credential; a launch that
    /// sets any of them runs the CLI unchanged.
    var passThroughVariables: [String] { get }
    /// First arguments of the CLI's sign-in and sign-out commands, which run
    /// unchanged so they act on the CLI's own credential.
    var passThroughCommands: [String] { get }
    /// The CLI's background-session service, whose sessions run in workers
    /// that never pass through the launcher; nil when it has none.
    var background: BackgroundSessionSupport? { get }
    /// Directories under the home where the CLI's own installer puts it,
    /// searched by `SessionSlots.realExecutable` after the usual install
    /// paths.
    var installDirectories: [String] { get }
    /// The CLI path chosen in AccountDock's settings, tried first by
    /// `SessionSlots.realExecutable`; nil when there is no such setting.
    var preferredExecutable: String? { get }
    /// Launcher lines that set `resumed` to the ID of the session a launch
    /// resumes, read from `"$@"`, with `previous` starting empty;
    /// `SessionSlots.resumeArgumentScript` writes them for options that
    /// take the ID as their value.
    var resumeArgumentScript: String { get }
    /// The command line that resumes the session `sessionID` through the
    /// launcher, typed by `SessionTerminalActions`.
    func resumeCommand(sessionID: String) -> String
    /// What a slot holds for `credential` as AccountDock stores it; nil
    /// when it is not one.
    func slotCredential(from credential: String) -> SlotCredential?
    /// What a slot serving `account` holds now: its credential valid for at
    /// least `minimumLifetime`, renewed through `state` when needed; nil
    /// when there is none.
    @MainActor func currentSlotCredential(for account: Account, minimumLifetime: TimeInterval,
                                           from state: AppState) async -> SlotCredential?
    /// Creates the slot directory, and whatever the CLI needs in it, before
    /// a credential is written; it may exist already.
    func prepareSlot(_ directory: URL) throws
    /// Writes `credential` where the CLI reads it for `directory`. Returns
    /// whether it reads back as written.
    func writeCredential(_ credential: SlotCredential, to directory: URL) -> Bool
    /// The credential the CLI reads for `directory`; nil when there is none.
    func readCredential(in directory: URL) -> SlotCredential?
    /// Deletes what the CLI keeps for `directory` outside the directory;
    /// `SessionSlots.remove` deletes the directory after.
    func removeSlot(_ directory: URL)
    /// Tells a CLI reading `directory` that its credential was rewritten,
    /// for a CLI that does not read it again before each request on its
    /// own. Called by `SessionSlots.serve` after each write.
    func signalReread(_ directory: URL)
}
