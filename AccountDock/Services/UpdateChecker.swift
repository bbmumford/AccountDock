import AppKit
import CryptoKit
import Foundation

private let log = FileLog("Updates")

/// Finds newer AccountDock releases on GitHub and installs one when the user
/// asks: Settings → About, and the menu's footer once one is found. Releases
/// come from `scripts/publish-release.sh`, which signs every one with the
/// same identity, so an update keeps the app's Keychain access and login
/// item. Shared by the Settings window and the menu popover.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    struct AvailableUpdate: Sendable, Equatable {
        let version: String
        let releaseURL: URL
        let notes: String
        let archiveURL: URL
        let archiveChecksumURL: URL
        let installCommand: String?
    }

    enum InstallState: Equatable {
        case idle
        case working(String)
        case failed(String)
    }

    @Published private(set) var isChecking = false
    @Published private(set) var availableUpdate: AvailableUpdate?
    @Published private(set) var statusMessage = "Check GitHub for a newer release."
    @Published private(set) var installState: InstallState = .idle
    let updatesConfigured = true

    private let repository = "bbmumford/AccountDock"
    /// How often the app looks for a release while it runs.
    static let checkInterval: TimeInterval = 6 * 60 * 60
    private var timer: Timer?

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Checks now and then every `checkInterval`.
    func startPeriodicChecks() {
        guard timer == nil else { return }
        Task { await checkForUpdates() }
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkForUpdates() }
        }
    }

    func checkForUpdates(manual: Bool = false) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        do {
            let release = try await fetchLatestRelease()
            guard Self.isVersion(release.version, newerThan: currentVersion) else {
                availableUpdate = nil
                statusMessage = manual ? "AccountDock is up to date." : statusMessage
                return
            }
            if availableUpdate != release { log.info("AccountDock \(release.version) is available") }
            availableUpdate = release
            statusMessage = "AccountDock \(release.version) is available."
        } catch {
            if manual {
                statusMessage = "Update check failed: \(error.localizedDescription)"
            }
        }
    }

    func copyInstallCommand() {
        guard let command = availableUpdate?.installCommand else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        statusMessage = "Safe install command copied."
    }

    /// Downloads the release, checks it against its published SHA-256 and
    /// against the running app's signer, and hands it to `UpdateInstaller`,
    /// which swaps it in once this app has quit and opens it.
    func installUpdate() async {
        guard let update = availableUpdate, installState == .idle || isFailed else { return }
        do {
            installState = .working("Downloading \(update.version)…")
            let work = FileManager.default.temporaryDirectory
                .appendingPathComponent("AccountDock-update-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let archive = try await download(update.archiveURL, to: work.appendingPathComponent("AccountDock.zip"))
            let expected = try await Self.publishedDigest(at: update.archiveChecksumURL)

            installState = .working("Checking \(update.version)…")
            guard try Self.sha256(of: archive) == expected else { throw UpdateError.invalidChecksum }
            let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
            try Self.unzip(archive, into: unpacked)
            let newApp = unpacked.appendingPathComponent("AccountDock.app", isDirectory: true)
            try UpdateInstaller.checkReplacement(newApp, version: update.version, against: Bundle.main.bundleURL)

            installState = .working("Installing \(update.version)…")
            try UpdateInstaller.replace(Bundle.main.bundleURL, with: newApp,
                                        afterProcess: ProcessInfo.processInfo.processIdentifier)
            log.info("Installing \(update.version); AccountDock quits and reopens")
            NSApplication.shared.terminate(nil)
        } catch {
            log.error("Update not installed: \(error.localizedDescription)")
            installState = .failed(error.localizedDescription)
        }
    }

    private var isFailed: Bool {
        if case .failed = installState { return true }
        return false
    }

    private func fetchLatestRelease() async throws -> AvailableUpdate {
        let endpoint = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("AccountDock", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw UpdateError.releaseUnavailable
        }
        return try Self.update(from: data)
    }

    /// The update a release describes: its version, notes and the archive
    /// the app installs from, plus the installer package for the manual
    /// command when the release has one. Throws for a release without a
    /// usable archive.
    nonisolated static func update(from data: Data) throws -> AvailableUpdate {
        let payload = try JSONDecoder().decode(GitHubRelease.self, from: data)
        let version = payload.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        func asset(_ name: String) -> URL? {
            payload.assets.first(where: { $0.name == name }).flatMap { validatedDownloadURL($0.browserDownloadURL) }
        }
        guard isSafeVersion(version), let releaseURL = URL(string: payload.htmlURL),
              let archive = asset("AccountDock.zip"), let archiveChecksum = asset("AccountDock.zip.sha256") else {
            throw UpdateError.malformedRelease
        }
        let command = asset("AccountDock.pkg").map { installCommand(packageURL: $0) }
        return AvailableUpdate(version: version, releaseURL: releaseURL, notes: payload.body ?? "",
                               archiveURL: archive, archiveChecksumURL: archiveChecksum, installCommand: command)
    }

    private func download(_ url: URL, to destination: URL) async throws -> URL {
        let (location, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw UpdateError.downloadFailed
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: location, to: destination)
        return destination
    }

    private static func publishedDigest(at url: URL) async throws -> String {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let text = String(data: data, encoding: .utf8),
              let digest = digest(in: text) else {
            throw UpdateError.invalidChecksum
        }
        return digest
    }

    /// The first word of a `shasum -a 256` line, when it is a SHA-256.
    nonisolated static func digest(in text: String) -> String? {
        guard let word = text.split(whereSeparator: \.isWhitespace).first.map(String.init),
              word.range(of: #"^[0-9a-fA-F]{64}$"#, options: .regularExpression) != nil else { return nil }
        return word.lowercased()
    }

    nonisolated static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func unzip(_ archive: URL, into directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, directory.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError.unreadableArchive }
    }

    nonisolated private static func validatedDownloadURL(_ string: String) -> URL? {
        guard let url = URL(string: string),
              url.scheme == "https",
              url.host == "github.com" || url.host == "objects.githubusercontent.com" else { return nil }
        return url
    }

    nonisolated private static func installCommand(packageURL: URL) -> String {
        """
        set -euo pipefail
        UPDATE_DIR="$(/usr/bin/mktemp -d)"
        trap 'rm -rf "$UPDATE_DIR"' EXIT
        /usr/bin/curl --proto '=https' --tlsv1.2 --fail --location \
          --output "$UPDATE_DIR/AccountDock.pkg" '\(packageURL.absoluteString)'
        /usr/bin/curl --proto '=https' --tlsv1.2 --fail --location \
          --output "$UPDATE_DIR/AccountDock.pkg.sha256" '\(packageURL.absoluteString).sha256'
        (cd "$UPDATE_DIR" && /usr/bin/shasum -a 256 -c AccountDock.pkg.sha256)
        /usr/bin/osascript -e 'tell application id "app.accountdock.mac" to quit' 2>/dev/null || true
        /usr/bin/sudo /usr/sbin/installer -pkg "$UPDATE_DIR/AccountDock.pkg" -target /
        /usr/bin/open -a AccountDock
        """
    }

    nonisolated static func isSafeVersion(_ value: String) -> Bool {
        value.range(of: #"^[0-9]+(?:\.[0-9]+){1,3}(?:[-+][0-9A-Za-z.-]+)?$"#, options: .regularExpression) != nil
    }

    nonisolated static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        candidate.compare(current, options: .numeric) == .orderedDescending
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: String
    let body: String?
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case body, assets
    }

    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: String

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }
}

enum UpdateError: LocalizedError {
    case releaseUnavailable
    case malformedRelease
    case invalidChecksum
    case downloadFailed
    case unreadableArchive
    case notAnAccountDockApp
    case wrongVersion(String)
    case signerMismatch
    case unsignedInstall
    case cannotReplace(String)

    var errorDescription: String? {
        switch self {
        case .releaseUnavailable: "No published AccountDock release is available."
        case .malformedRelease: "The latest release is missing its update archive."
        case .invalidChecksum: "The download does not match the release's SHA-256, so it was not installed."
        case .downloadFailed: "The update could not be downloaded."
        case .unreadableArchive: "The update archive could not be opened."
        case .notAnAccountDockApp: "The update archive does not hold AccountDock."
        case .wrongVersion(let version): "The update archive holds version \(version), not the release's."
        case .signerMismatch: "The update is not signed by the same identity as this copy of AccountDock, so it was not installed."
        case .unsignedInstall: "This copy of AccountDock is not signed with a certificate, so an update's signer cannot be checked. Install it from the release page instead."
        case .cannotReplace(let reason): "AccountDock could not be replaced: \(reason)"
        }
    }
}
