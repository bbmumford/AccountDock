import AppKit
import Carbon.HIToolbox

private let shortcutLog = FileLog("ResumeShortcut")

/// The system-wide shortcut that resumes one paused session: the session
/// waiting in the window the user is looking at, or one picked from a menu
/// (`AppState.resumeFrontmostSession`). A Carbon hot key needs no
/// Accessibility or Input Monitoring permission. The gate script names the
/// shortcut in a paused session's terminal title, and the pause banner in
/// its help text.
@MainActor
final class SessionResumeShortcut {
    static let shared = SessionResumeShortcut()

    /// Control-Option-Command-R.
    nonisolated static let keyCode = UInt32(kVK_ANSI_R)
    nonisolated static let modifiers = UInt32(controlKey | optionKey | cmdKey)
    nonisolated static let display = "⌃⌥⌘R"

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: (() -> Void)?

    /// Registers the shortcut once; `action` runs on the main actor each
    /// time it is pressed.
    func install(_ action: @escaping () -> Void) {
        self.action = action
        guard hotKey == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { SessionResumeShortcut.shared.action?() } }
            return noErr
        }, 1, &spec, nil, &handler)
        guard status == noErr else {
            shortcutLog.warning("Could not install the resume shortcut handler (\(status))")
            return
        }
        let id = EventHotKeyID(signature: OSType(0x4144_5253), id: 1) // "ADRS"
        let registered = RegisterEventHotKey(Self.keyCode, Self.modifiers, id, GetApplicationEventTarget(), 0, &hotKey)
        if registered != noErr {
            shortcutLog.warning("Could not register \(Self.display) for resuming a session (\(registered)); another app may use it")
        }
    }
}

/// Parent links between processes, read with `sysctl`, which needs no
/// permission.
enum ProcessAncestry {
    static func parent(of pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 0 ? parent : nil
    }

    /// When the process started.
    static func startTime(of pid: Int32) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        let started = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(started.tv_sec) + TimeInterval(started.tv_usec) / 1_000_000)
    }

    /// Whether `ancestor` is `pid` or one of its ancestors.
    static func isDescendant(_ pid: Int32, of ancestor: Int32) -> Bool {
        var current: Int32? = pid
        var steps = 0
        while let process = current, steps < 64 {
            if process == ancestor { return true }
            if process <= 1 { return false }
            current = parent(of: process)
            steps += 1
        }
        return false
    }
}

/// The menu the resume shortcut shows when it cannot tell which session the
/// user means, at the pointer. Focus returns to the app that was in front.
@MainActor
enum SessionResumeMenu {
    private final class Target: NSObject {
        let sessions: [WaitingSession]
        let choose: (WaitingSession) -> Void
        init(_ sessions: [WaitingSession], choose: @escaping (WaitingSession) -> Void) {
            self.sessions = sessions
            self.choose = choose
        }
        @objc func pick(_ item: NSMenuItem) { choose(sessions[item.tag]) }
    }

    static func show(_ sessions: [WaitingSession], returningTo app: NSRunningApplication?,
                     choose: @escaping (WaitingSession) -> Void) {
        let target = Target(sessions, choose: choose)
        let menu = NSMenu(title: "Resume a paused session")
        let heading = NSMenuItem(title: "Resume a paused session", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        for (index, session) in sessions.enumerated() {
            let item = NSMenuItem(title: session.label, action: #selector(Target.pick(_:)), keyEquivalent: "")
            item.target = target
            item.tag = index
            menu.addItem(item)
        }
        NSApp.activate(ignoringOtherApps: true)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        withExtendedLifetime(target) {}
        app?.activate()
    }
}
