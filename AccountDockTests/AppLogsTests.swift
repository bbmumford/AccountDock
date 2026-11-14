import XCTest
@testable import AccountDock

/// Checks that a test run writes its logs, event history and audit trail
/// under the temporary directory and leaves the files in `~/Library/Logs`
/// alone.
final class AppLogsTests: XCTestCase {
    func testEverySinkWritesTheTestRunsOwnDirectory() async {
        XCTAssertTrue(AppLogs.isTesting)
        XCTAssertEqual(AppLogs.directory, AppLogs.testDirectory)
        XCTAssertNotEqual(AppLogs.directory.standardizedFileURL, AppLogs.userDirectory.standardizedFileURL)
        XCTAssertTrue(AppLogs.directory.standardizedFileURL.path
            .hasPrefix(FileManager.default.temporaryDirectory.standardizedFileURL.path))

        XCTAssertEqual(FileLog.fileURL.deletingLastPathComponent().standardizedFileURL, AppLogs.directory.standardizedFileURL)
        XCTAssertEqual(CredentialAudit.shared.fileURL.deletingLastPathComponent().standardizedFileURL,
                       AppLogs.directory.standardizedFileURL)
        XCTAssertEqual(CredentialAudit.shared.ownersURL.deletingLastPathComponent().standardizedFileURL,
                       AppLogs.directory.standardizedFileURL)
        let events = await MainActor.run { FailoverEventLog.shared.fileURL }
        XCTAssertEqual(events.deletingLastPathComponent().standardizedFileURL, AppLogs.directory.standardizedFileURL)
    }

    func testALoggedLineLandsInTheTestDirectoryAndNotInTheRealLog() throws {
        let marker = "AppLogsTests-\(UUID().uuidString)"
        FileLog("AppLogsTests").info(marker)
        FileLog.flush()

        let written = try String(contentsOf: FileLog.fileURL, encoding: .utf8)
        XCTAssertTrue(written.contains(marker))

        let real = AppLogs.userDirectory.appendingPathComponent("AccountDock-app.log")
        if let data = FileManager.default.contents(atPath: real.path) {
            XCTAssertNil(data.range(of: Data(marker.utf8)), "the line reached the real app log")
        }
    }

    /// No source names `~/Library/Logs` itself: every sink takes its
    /// directory from `AppLogs`, which is what keeps it out of tests.
    func testNoSourceNamesTheLogsDirectoryOutsideAppLogs() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("AccountDock", isDirectory: true)
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertGreaterThan(files.count, 50, "the app's sources were found")
        var offenders: [String] = []
        for file in files where file.lastPathComponent != "AppLogs.swift" {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                if line.contains("Library/Logs") { offenders.append("\(file.lastPathComponent):\(index + 1)") }
            }
        }
        XCTAssertEqual(offenders, [], "log paths that bypass AppLogs")
    }
}
