import XCTest
@testable import AccountDock

final class UpdateCheckerTests: XCTestCase {
    private func release(_ assets: [String], tag: String = "v1.3.0") -> Data {
        let list = assets.map { #"{"name":"\#($0)","browser_download_url":"https://github.com/bbmumford/AccountDock/releases/download/\#(tag)/\#($0)"}"# }
        return Data(#"{"tag_name":"\#(tag)","html_url":"https://github.com/bbmumford/AccountDock/releases/tag/\#(tag)","body":"Notes","assets":[\#(list.joined(separator: ","))]}"#.utf8)
    }

    func testAReleaseIsInstalledFromItsArchiveAndOffersThePackageCommandToo() throws {
        let update = try UpdateChecker.update(from: release(["AccountDock.zip", "AccountDock.zip.sha256", "AccountDock.pkg", "AccountDock.pkg.sha256"]))
        XCTAssertEqual(update.version, "1.3.0")
        XCTAssertEqual(update.archiveURL.lastPathComponent, "AccountDock.zip")
        XCTAssertEqual(update.archiveChecksumURL.lastPathComponent, "AccountDock.zip.sha256")
        XCTAssertEqual(update.notes, "Notes")
        XCTAssertNotNil(update.installCommand)
        XCTAssertNil(try UpdateChecker.update(from: release(["AccountDock.zip", "AccountDock.zip.sha256"])).installCommand)
    }

    func testAReleaseWithoutItsArchiveOrWithAnOddTagIsRefused() {
        XCTAssertThrowsError(try UpdateChecker.update(from: release(["AccountDock.pkg", "AccountDock.pkg.sha256"])))
        XCTAssertThrowsError(try UpdateChecker.update(from: release(["AccountDock.zip", "AccountDock.zip.sha256"], tag: "v1.3.0;rm")))
    }

    func testVersionsCompareNumerically() {
        XCTAssertTrue(UpdateChecker.isVersion("1.10.0", newerThan: "1.9.3"))
        XCTAssertFalse(UpdateChecker.isVersion("1.2.0", newerThan: "1.2.0"))
        XCTAssertFalse(UpdateChecker.isVersion("1.1.9", newerThan: "1.2.0"))
    }

    func testTheDigestIsReadFromAShasumLineAndTheFileHashMatchesShasum() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("AccountDock".utf8).write(to: file)
        let digest = try UpdateChecker.sha256(of: file)
        XCTAssertEqual(digest.count, 64)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        process.arguments = ["-a", "256", file.path]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        let line = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(UpdateChecker.digest(in: line), digest)
        XCTAssertNil(UpdateChecker.digest(in: "not a digest  AccountDock.zip"))
    }

    func testTheHelperSwapsTheAppKeepsTheOldOneAndPutsItBackWhenTheSwapFails() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let helper = root.appendingPathComponent("install-update.sh")
        let installed = root.appendingPathComponent("Applications/Fake.app", isDirectory: true)
        let new = root.appendingPathComponent("new/Fake.app", isDirectory: true)
        let backup = root.appendingPathComponent("previous/Fake.app", isDirectory: true)
        try fm.createDirectory(at: installed, withIntermediateDirectories: true)
        try fm.createDirectory(at: new, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: installed.appendingPathComponent("marker"))
        try Data("new".utf8).write(to: new.appendingPathComponent("marker"))
        // `open` is replaced so the test never launches anything.
        let script = UpdateInstaller.helperScript.replacingOccurrences(of: "/usr/bin/open", with: "/usr/bin/true")
        try script.write(to: helper, atomically: true, encoding: .utf8)

        func run(_ pid: Int32) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [helper.path, String(pid), new.path, installed.path, backup.path]
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
        // A process ID no process has: the app has already quit.
        XCTAssertEqual(try run(99_999_999), 0)
        XCTAssertEqual(try String(contentsOf: installed.appendingPathComponent("marker"), encoding: .utf8), "new")
        XCTAssertEqual(try String(contentsOf: backup.appendingPathComponent("marker"), encoding: .utf8), "old")

        // Nothing at the new path: the swap fails and the installed app stays.
        XCTAssertEqual(try run(99_999_999), 1)
        XCTAssertEqual(try String(contentsOf: installed.appendingPathComponent("marker"), encoding: .utf8), "new")
    }

    func testAnAppSignedAdHocCannotVouchForAnUpdate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func app(_ name: String) throws -> URL {
            let app = root.appendingPathComponent("\(name).app", isDirectory: true)
            let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
            try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
            try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: macOS.appendingPathComponent(name).path)
            let plist: [String: Any] = ["CFBundleIdentifier": UpdateInstaller.bundleIdentifier, "CFBundleExecutable": name,
                                        "CFBundleShortVersionString": "1.3.0", "CFBundlePackageType": "APPL"]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: app.appendingPathComponent("Contents/Info.plist"))
            let sign = Process()
            sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            sign.arguments = ["--force", "--sign", "-", app.path]
            sign.standardError = FileHandle.nullDevice
            try sign.run()
            sign.waitUntilExit()
            return app
        }
        let installed = try app("Installed"), update = try app("Update")
        XCTAssertThrowsError(try UpdateInstaller.checkSigner(of: update, matches: installed)) { error in
            guard case UpdateError.unsignedInstall = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try UpdateInstaller.checkReplacement(update, version: "9.9.9", against: installed)) { error in
            guard case UpdateError.wrongVersion("1.3.0") = error else { return XCTFail("\(error)") }
        }
    }

    func testOnlyAnUpdateSignedByTheInstalledAppsCertificatePasses() throws {
        let find = Process()
        find.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        find.arguments = ["find-identity", "-p", "codesigning"]
        let found = Pipe()
        find.standardOutput = found
        try find.run()
        find.waitUntilExit()
        let identities = String(decoding: found.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard let line = identities.split(separator: "\n").first(where: { $0.contains("\"AccountDock Local\"") }),
              let identity = line.split(separator: " ").dropFirst().first.map(String.init) else {
            throw XCTSkip("The AccountDock Local signing identity is not in this keychain.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func app(_ name: String, signedBy signer: String) throws -> URL {
            let app = root.appendingPathComponent("\(name).app", isDirectory: true)
            let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
            try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
            try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: macOS.appendingPathComponent("AccountDock").path)
            let plist: [String: Any] = ["CFBundleIdentifier": UpdateInstaller.bundleIdentifier, "CFBundleExecutable": "AccountDock",
                                        "CFBundleShortVersionString": "1.3.0", "CFBundlePackageType": "APPL"]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: app.appendingPathComponent("Contents/Info.plist"))
            let sign = Process()
            sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            sign.arguments = ["--force", "--sign", signer, app.path]
            sign.standardError = FileHandle.nullDevice
            try sign.run()
            sign.waitUntilExit()
            XCTAssertEqual(sign.terminationStatus, 0, "codesign \(name)")
            return app
        }
        let installed = try app("Installed", signedBy: identity)
        XCTAssertNoThrow(try UpdateInstaller.checkReplacement(try app("Same", signedBy: identity), version: "1.3.0", against: installed))
        XCTAssertThrowsError(try UpdateInstaller.checkSigner(of: try app("AdHoc", signedBy: "-"), matches: installed)) { error in
            guard case UpdateError.signerMismatch = error else { return XCTFail("\(error)") }
        }
    }
}
