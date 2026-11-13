import XCTest
@testable import AccountDock

/// Credential files on disk: written private from the first byte, deleted
/// only inside AccountDock's storage, and found through Kimi Code's config.
final class CredentialFileTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CredentialFileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func mode(of url: URL) throws -> Int? {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
    }

    private func directory(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private let credentialJSON = #"{"access_token":"a","refresh_token":"r","expires_at":4102444800}"#

    // MARK: PrivateFile

    func testAPrivateFileReplacesAWiderFileWithItsOwnModeAndLeavesNoTemporaryFile() throws {
        let url = root.appendingPathComponent("auth.json")
        try Data("old".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)

        try PrivateFile.writeAtomically(Data("new".utf8), to: url, mode: 0o600)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "new")
        XCTAssertEqual(try mode(of: url), 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["auth.json"])
    }

    func testAPrivateFileRefusedBeforeReplacingLeavesTheDestinationAsItWas() throws {
        let url = root.appendingPathComponent("auth.json")
        try Data("old".utf8).write(to: url)
        struct Refused: Error {}
        XCTAssertThrowsError(try PrivateFile.writeAtomically(Data("new".utf8), to: url, mode: 0o600) { throw Refused() })
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "old")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["auth.json"])
    }

    func testCodexAuthIsWrittenOwnerOnly() throws {
        let url = root.appendingPathComponent("auth.json")
        try Data("{}".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)

        try CodexService.writePrivateAuth(["tokens": ["refresh_token": "r"]], to: url)

        XCTAssertEqual(try mode(of: url), 0o600)
        let auth = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual((auth?["tokens"] as? [String: Any])?["refresh_token"] as? String, "r")
    }

    // MARK: Kimi

    private func kimiHome(config: String) throws -> URL {
        let home = try directory("kimi-home")
        try Data(config.utf8).write(to: home.appendingPathComponent("config.toml"))
        return home
    }

    func testKimisActiveCredentialIsNamedByTheManagedProvidersOAuthTable() throws {
        let home = try kimiHome(config: """
        default_model = "kimi-for-coding"

        [providers.other.oauth]
        storage = "file"
        key = "oauth/other-provider"

        [models."kimi-for-coding"]
        provider = "managed:kimi-code"
        reasoning_key = "effort"

        [providers."managed:kimi-code"]
        type = "kimi"
        api_key = ""

        [providers."managed:kimi-code".oauth]
        storage = "file"
        key = "oauth/kimi-code-env-0e4f99c6"

        [services.moonshot_search.oauth]
        key = "oauth/kimi-code"
        """)
        let service = KimiService(home: home, managedRoot: try directory("managed"))
        XCTAssertEqual(
            try service.activeCredentialURL(in: home).standardizedFileURL,
            home.appendingPathComponent("credentials/kimi-code-env-0e4f99c6.json").standardizedFileURL
        )
    }

    func testKimiConfigWithoutTheManagedProvidersOAuthTableNamesNoCredential() throws {
        let home = try kimiHome(config: "[providers.other.oauth]\nkey = \"oauth/other-provider\"\n")
        let service = KimiService(home: home, managedRoot: try directory("managed"))
        XCTAssertThrowsError(try service.activeCredentialURL(in: home))
    }

    func testPromotingAKimiAccountWritesTheSlotOwnerOnly() throws {
        let home = try kimiHome(config: "[providers.\"managed:kimi-code\".oauth]\nkey = \"oauth/kimi-code\"\n")
        let managed = try directory("managed/account")
        let location = managed.appendingPathComponent("credentials.json")
        try Data(credentialJSON.utf8).write(to: location)
        let slot = try directory("kimi-home/credentials").appendingPathComponent("kimi-code.json")
        try Data("{}".utf8).write(to: slot)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: slot.path)

        try KimiService(home: home, managedRoot: try directory("managed")).promoteToSystem(location: location.path)

        XCTAssertEqual(try mode(of: slot), 0o600)
        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: slot)) as? [String: Any]
        XCTAssertEqual(written?["refresh_token"] as? String, "r")
    }

    func testRemovingAKimiAccountDeletesOnlyADirectoryInsideItsManagedRoot() throws {
        let managedRoot = try directory("managed")
        let service = KimiService(home: try directory("kimi-home"), managedRoot: managedRoot)
        let outside = try directory("elsewhere")
        try Data("keep".utf8).write(to: outside.appendingPathComponent("credentials.json"))

        for location in [
            outside.appendingPathComponent("credentials.json").path,
            managedRoot.appendingPathComponent("credentials.json").path,
            managedRoot.appendingPathComponent("account/../../elsewhere/credentials.json").path,
        ] {
            XCTAssertThrowsError(try service.removeManagedAccount(location: location), location) { error in
                guard case KimiServiceError.unsafeCredentialLocation = error else {
                    return XCTFail("unexpected error \(error)")
                }
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appendingPathComponent("credentials.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: managedRoot.path))

        let account = try directory("managed/\(UUID().uuidString)")
        try Data(credentialJSON.utf8).write(to: account.appendingPathComponent("credentials.json"))
        try service.removeManagedAccount(location: account.appendingPathComponent("credentials.json").path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: account.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: managedRoot.path))
    }
}
