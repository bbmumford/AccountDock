import Foundation
import Security

/// Puts a downloaded release in place of the running app for
/// `UpdateChecker.installUpdate`. The release must be AccountDock at the
/// release's version, signed by the identity that signed the running app;
/// a helper swaps it in once the app has quit, keeps the replaced copy, puts
/// it back if the swap fails, and opens the result.
enum UpdateInstaller {
    static let bundleIdentifier = "app.accountdock.mac"

    /// Where the replaced app is kept, and the helper written.
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AccountDock/Updates", isDirectory: true)
    }

    static func checkReplacement(_ newApp: URL, version: String, against installed: URL) throws {
        guard let bundle = Bundle(url: newApp), bundle.bundleIdentifier == bundleIdentifier else {
            throw UpdateError.notAnAccountDockApp
        }
        let found = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        guard found == version else { throw UpdateError.wrongVersion(found) }
        try checkSigner(of: newApp, matches: installed)
    }

    /// The installed app's designated requirement names its signing
    /// certificate; the update must satisfy it. A copy signed ad hoc names
    /// only its own code hash, which no other build satisfies, so nothing can
    /// be checked and the update is refused.
    static func checkSigner(of newApp: URL, matches installed: URL) throws {
        var installedCode: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(installed as CFURL, [], &installedCode) == errSecSuccess,
              let installedCode,
              SecCodeCopyDesignatedRequirement(installedCode, [], &requirement) == errSecSuccess,
              let requirement else { throw UpdateError.unsignedInstall }
        var text: CFString?
        SecRequirementCopyString(requirement, [], &text)
        guard let text = text as String?, text.contains("certificate") else { throw UpdateError.unsignedInstall }

        var newCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(newApp as CFURL, [], &newCode) == errSecSuccess, let newCode else {
            throw UpdateError.signerMismatch
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(newCode, flags, requirement) == errSecSuccess else {
            throw UpdateError.signerMismatch
        }
    }

    /// Starts the helper that replaces `installed` with `newApp` once the
    /// process `pid` has exited. The caller quits straight after.
    static func replace(_ installed: URL, with newApp: URL, afterProcess pid: Int32) throws {
        let parent = installed.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw UpdateError.cannotReplace("\(parent.path) is not writable by this user; install from the release page.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let helper = directory.appendingPathComponent("install-update.sh")
        try helperScript.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let backup = directory.appendingPathComponent("previous/AccountDock.app", isDirectory: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [helper.path, String(pid), newApp.path, installed.path, backup.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw UpdateError.cannotReplace(error.localizedDescription)
        }
    }

    /// Waits up to a minute for the app to quit and leaves everything as it
    /// was when it does not. The replaced copy is kept until the next update,
    /// so a release that fails to start can be put back by hand.
    static let helperScript = """
    #!/bin/sh
    pid="$1"; new="$2"; dest="$3"; backup="$4"
    i=0
    while /bin/kill -0 "$pid" 2>/dev/null && [ "$i" -lt 600 ]; do /bin/sleep 0.1; i=$((i + 1)); done
    /bin/kill -0 "$pid" 2>/dev/null && exit 1
    /bin/rm -rf "$backup"
    /bin/mkdir -p "$(/usr/bin/dirname "$backup")"
    if /bin/mv "$dest" "$backup"; then
        if /bin/mv "$new" "$dest"; then
            /usr/bin/open "$dest"
            exit 0
        fi
        /bin/mv "$backup" "$dest"
    fi
    /usr/bin/open "$dest"
    exit 1
    """
}
