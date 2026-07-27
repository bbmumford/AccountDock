import AppKit
import Foundation

@MainActor
final class UpdateChecker: ObservableObject {
    struct AvailableUpdate: Sendable {
        let version: String
        let releaseURL: URL
        let installCommand: String
    }

    @Published private(set) var isChecking = false
    @Published private(set) var availableUpdate: AvailableUpdate?
    @Published private(set) var statusMessage = "Check GitHub for a newer release."
    let updatesConfigured = true

    private let repository = "bbmumford/AccountDock"

    func checkForUpdates(manual: Bool = false) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        do {
            let release = try await fetchLatestRelease()
            let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
            guard Self.isVersion(release.version, newerThan: current) else {
                availableUpdate = nil
                statusMessage = manual ? "AccountDock is up to date." : statusMessage
                return
            }
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
        let payload = try JSONDecoder().decode(GitHubRelease.self, from: data)
        let version = payload.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        guard Self.isSafeVersion(version),
              let releaseURL = URL(string: payload.htmlURL),
              let package = payload.assets.first(where: { $0.name == "AccountDock.pkg" }),
              let checksum = payload.assets.first(where: { $0.name == "AccountDock.pkg.sha256" }),
              let packageURL = Self.validatedDownloadURL(package.browserDownloadURL),
              let checksumURL = Self.validatedDownloadURL(checksum.browserDownloadURL) else {
            throw UpdateError.malformedRelease
        }

        let (checksumData, checksumResponse) = try await URLSession.shared.data(from: checksumURL)
        guard let checksumHTTP = checksumResponse as? HTTPURLResponse,
              (200...299).contains(checksumHTTP.statusCode),
              let checksumText = String(data: checksumData, encoding: .utf8),
              let digest = checksumText.split(whereSeparator: \.isWhitespace).first.map(String.init),
              digest.range(of: #"^[0-9a-fA-F]{64}$"#, options: .regularExpression) != nil else {
            throw UpdateError.invalidChecksum
        }

        return AvailableUpdate(
            version: version,
            releaseURL: releaseURL,
            installCommand: Self.installCommand(packageURL: packageURL, checksum: digest.lowercased())
        )
    }

    private static func validatedDownloadURL(_ string: String) -> URL? {
        guard let url = URL(string: string),
              url.scheme == "https",
              url.host == "github.com" || url.host == "objects.githubusercontent.com" else { return nil }
        return url
    }

    private static func installCommand(packageURL: URL, checksum: String) -> String {
        """
        set -euo pipefail
        UPDATE_DIR="$(/usr/bin/mktemp -d)"
        trap 'rm -rf "$UPDATE_DIR"' EXIT
        /usr/bin/curl --proto '=https' --tlsv1.2 --fail --location \
          --output "$UPDATE_DIR/AccountDock.pkg" \
          '\(packageURL.absoluteString)'
        printf '%s  %s\\n' '\(checksum)' "$UPDATE_DIR/AccountDock.pkg" | /usr/bin/shasum -a 256 -c -
        /usr/bin/osascript -e 'tell application id "app.accountdock.mac" to quit' 2>/dev/null || true
        /usr/bin/sudo /usr/sbin/installer -pkg "$UPDATE_DIR/AccountDock.pkg" -target /
        /usr/bin/osascript -e 'tell application "System Events" to if not (exists login item "AccountDock") then make login item at end with properties {name:"AccountDock", path:"/Applications/AccountDock.app", hidden:false}'
        /usr/bin/open -a AccountDock
        """
    }

    private static func isSafeVersion(_ value: String) -> Bool {
        value.range(of: #"^[0-9]+(?:\.[0-9]+){1,3}(?:[-+][0-9A-Za-z.-]+)?$"#, options: .regularExpression) != nil
    }

    private static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        candidate.compare(current, options: .numeric) == .orderedDescending
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: String
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case assets
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

private enum UpdateError: LocalizedError {
    case releaseUnavailable
    case malformedRelease
    case invalidChecksum

    var errorDescription: String? {
        switch self {
        case .releaseUnavailable: "No published AccountDock release is available."
        case .malformedRelease: "The latest release is missing its installer assets."
        case .invalidChecksum: "The release checksum could not be verified."
        }
    }
}
