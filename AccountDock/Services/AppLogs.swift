import Foundation

/// The one directory every log, event history and audit trail the app keeps
/// is written to: `~/Library/Logs`, or a directory of this process's own
/// under the temporary directory while XCTest hosts the app, so a test run
/// never appends to the files a person reads.
///
/// Read by `FileLog`, `FailoverEventLog` and `CredentialAudit` for their
/// files, and `isTesting` by `AccountDockApp`, which skips its start-up work
/// under tests. A new sink takes its directory from here rather than naming
/// `~/Library/Logs`, which `AppLogsTests` checks across the sources.
enum AppLogs {
    /// True when XCTest hosts the app: Xcode sets the configuration path in
    /// the test host's environment and in no other launch.
    static let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// `~/Library/Logs`, where the files live outside tests.
    static var userDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs", isDirectory: true)
    }

    /// The test run's own directory, one per process so concurrent runs do
    /// not share files.
    static var testDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AccountDock-logs-tests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    }

    /// Where the sinks write in this process.
    static let directory: URL = isTesting ? testDirectory : userDirectory
}
