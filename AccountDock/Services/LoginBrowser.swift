import AppKit

private let log = FileLog("Login")

/// Opens a provider's sign-in page in the browser the user used last, rather
/// than the default browser, which always opens the same app and profile: a
/// sign-in page signs in whichever account that browser window is signed in
/// to. `LoginProcessRunner` uses it for every provider's login.
enum LoginBrowser {
    /// The script a login CLI is told to open pages with, through the
    /// `BROWSER` environment variable. Its path has no spaces, since a CLI
    /// may pass the variable through a shell.
    static var openerURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".accountdock/bin/open-login-page")
    }

    /// The app owning the frontmost window that belongs to a browser, or nil
    /// when no browser has a window on screen.
    static func lastUsed() -> URL? {
        guard let page = URL(string: "https://example.com") else { return nil }
        let browsers = Set(NSWorkspace.shared.urlsForApplications(toOpen: page).map { $0.standardizedFileURL.path })
        // Front to back; layer 0 holds ordinary windows.
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let owners = windows.compactMap { window -> String? in
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t else { return nil }
            return NSRunningApplication(processIdentifier: pid)?.bundleURL?.standardizedFileURL.path
        }
        return frontmostBrowser(windowOwners: owners, browsers: browsers).map { URL(fileURLWithPath: $0) }
    }

    /// The first of `windowOwners`, front to back, that is one of `browsers`.
    static func frontmostBrowser(windowOwners: [String], browsers: Set<String>) -> String? {
        windowOwners.first(where: browsers.contains)
    }

    /// Opens `url` in the last-used browser, or in the default one when no
    /// browser has a window open.
    @discardableResult
    static func open(_ url: URL) -> Bool {
        guard let app = lastUsed() else { return NSWorkspace.shared.open(url) }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        log.info("Opened the sign-in page in \(app.deletingPathExtension().lastPathComponent)")
        return true
    }

    /// `environment` with `BROWSER` naming a script that opens pages in the
    /// last-used browser, for a CLI that opens its sign-in page itself. A CLI
    /// that ignores the variable opens the default browser as before.
    static func environment(_ environment: [String: String]) -> [String: String] {
        guard let app = lastUsed() else { return environment }
        do {
            try FileManager.default.createDirectory(at: openerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(openerScript(app: app.path).utf8).write(to: openerURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: openerURL.path)
        } catch {
            log.error("Sign-in page opener not written: \(error.localizedDescription)")
            return environment
        }
        var environment = environment
        environment["BROWSER"] = openerURL.path
        return environment
    }

    static func openerScript(app: String) -> String {
        "#!/bin/sh\nexec /usr/bin/open -a '" + app.replacingOccurrences(of: "'", with: "'\\''") + "' \"$@\"\n"
    }
}
