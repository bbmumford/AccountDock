import Foundation
import Darwin

/// Kimi Code's own lock around reading, renewing and writing its credential,
/// taken the way Kimi Code takes it, so a credential AccountDock writes never
/// lands in the middle of a renewal Kimi Code is making.
///
/// Kimi Code locks `<home>/oauth/<name>` with `proper-lockfile`
/// (`realpath: false`, `stale: 5000`): the lock is the directory
/// `<home>/oauth/<name>.lock`, created with one `mkdir`; its holder touches
/// it every half stale period, and a lock untouched for longer than the
/// stale period belongs to a process that died and is taken over. After
/// taking the lock Kimi Code reads the credential file again before it
/// decides to renew, so a file written by the previous holder is used as it
/// stands. `<name>` is the credential's storage name, the same name as its
/// file under `<home>/credentials/`.
///
/// Used by `KimiSessionIsolation.writeCredential` for a slot's credential,
/// and by `KimiService.renewLiveCredentialForSlots` for the credential in
/// Kimi Code's own home.
struct KimiCredentialLock: Sendable {
    /// `proper-lockfile`'s `stale` as Kimi Code sets it.
    static let staleAfter: TimeInterval = 5
    /// How often a holder touches the lock: half of `staleAfter`, as
    /// `proper-lockfile` does, so a held lock never looks stale.
    static let touchInterval: TimeInterval = staleAfter / 2
    /// Pause between attempts while another process holds the lock.
    static let retryInterval: TimeInterval = 0.1

    /// The file Kimi Code names as the lock's target, `<home>/oauth/<name>`;
    /// it creates it empty before locking, and so does `acquire`.
    let target: URL

    init(home: URL, name: String) {
        target = home.appendingPathComponent("oauth", isDirectory: true).appendingPathComponent(name)
    }

    /// The lock itself.
    var directory: URL { URL(fileURLWithPath: target.path + ".lock", isDirectory: true) }

    /// Takes the lock, waiting while a holder keeps it fresh, for at most
    /// `timeout` seconds; a stale lock is removed and taken. Blocks the
    /// calling thread between attempts. Returns whether the lock is held.
    func acquire(waitingUpTo timeout: TimeInterval) -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: target.path) { fm.createFile(atPath: target.path, contents: nil) }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if mkdir(directory.path, 0o777) == 0 { return true }
            guard errno == EEXIST else { return false }
            if let touched = lastTouched(), Date().timeIntervalSince(touched) > Self.staleAfter,
               rmdir(directory.path) == 0 {
                continue
            }
            guard Date() < deadline else { return false }
            usleep(useconds_t(Self.retryInterval * 1_000_000))
        }
    }

    /// Marks the held lock as alive, so a holder that keeps it longer than
    /// `staleAfter` is not taken over.
    func touch() {
        utimes(directory.path, nil)
    }

    func release() {
        rmdir(directory.path)
    }

    /// When the lock was last created or touched; nil when there is none.
    func lastTouched() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: directory.path))?[.modificationDate] as? Date
    }
}
