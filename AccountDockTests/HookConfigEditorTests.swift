import XCTest
@testable import AccountDock

/// Golden tests of the one hook-config editor: the exact text each edit
/// leaves, so every byte outside AccountDock's own hooks is shown to stay.
final class HookConfigEditorTests: XCTestCase {
    private let marker = "# accountdock-hook"
    private let command = "/bin/sh '/Apps/AccountDock.app/hook.sh' session # accountdock-hook"

    /// A settings file in the style a person or another tool left it: four
    /// spaces, keys in their own order, another tool's hook, an inline
    /// array, escapes and text outside ASCII.
    private let settings = """
    {
        "model": "opus",
        "permissions": { "allow": ["Bash(ls:*)"], "deny": [] },
        "hooks": {
            "Stop": [
                {
                    "matcher": "",
                    "hooks": [{ "type": "command", "command": "say done \\u00e9 ✓" }]
                }
            ]
        },
        "statusLine": {"type": "command", "command": "~/bin/line"}
    }

    """

    func testInstallingAddsOneGroupPerEventAndKeepsEveryOtherByte() throws {
        let installed = try JSONHookFile.installing(events: ["Stop", "SessionStart"], command: command, timeout: 10,
                                                    marker: marker, in: settings)
        let expected = """
        {
            "model": "opus",
            "permissions": { "allow": ["Bash(ls:*)"], "deny": [] },
            "hooks": {
                "Stop": [
                    {
                        "matcher": "",
                        "hooks": [{ "type": "command", "command": "say done \\u00e9 ✓" }]
                    },
                    {
                        "matcher": "",
                        "hooks": [
                            {
                                "type": "command",
                                "command": "/bin/sh '/Apps/AccountDock.app/hook.sh' session # accountdock-hook",
                                "timeout": 10
                            }
                        ]
                    }
                ],
                "SessionStart": [
                    {
                        "matcher": "",
                        "hooks": [
                            {
                                "type": "command",
                                "command": "/bin/sh '/Apps/AccountDock.app/hook.sh' session # accountdock-hook",
                                "timeout": 10
                            }
                        ]
                    }
                ]
            },
            "statusLine": {"type": "command", "command": "~/bin/line"}
        }

        """
        XCTAssertEqual(installed, expected)

        // Installing again replaces AccountDock's group with the same text.
        XCTAssertEqual(try JSONHookFile.installing(events: ["Stop", "SessionStart"], command: command, timeout: 10,
                                                   marker: marker, in: installed), expected)
        // Removing it gives back the file as it was, byte for byte.
        XCTAssertEqual(try JSONHookFile.uninstalling(events: ["Stop", "SessionStart"], marker: marker, in: installed), settings)
    }

    func testANewFileIsWrittenAsTheCLIWritesItsSettings() throws {
        let text = try JSONHookFile.installing(events: ["Stop"], command: "run \"x\" # accountdock-hook", timeout: 0,
                                               marker: marker, in: "")
        XCTAssertEqual(text, """
        {
          "hooks": {
            "Stop": [
              {
                "matcher": "",
                "hooks": [
                  {
                    "type": "command",
                    "command": "run \\"x\\" # accountdock-hook"
                  }
                ]
              }
            ]
          }
        }

        """)
    }

    func testAFileWithoutHooksGetsAHooksSettingAfterItsLastOne() throws {
        let plain = "{\n\t\"model\": \"opus\"\n}"
        let installed = try JSONHookFile.installing(events: ["Stop"], command: command, timeout: 5, marker: marker, in: plain)
        XCTAssertTrue(installed.hasPrefix("{\n\t\"model\": \"opus\",\n\t\"hooks\": {\n\t\t\"Stop\": [\n\t\t\t{\n"), installed)
        XCTAssertTrue(installed.hasSuffix("\n\t\t]\n\t}\n}"), installed)
        XCTAssertEqual(try JSONHookFile.uninstalling(events: ["Stop"], marker: marker, in: installed),
                       "{\n\t\"model\": \"opus\",\n\t\"hooks\": {}\n}", "an emptied hooks setting stays, as the CLI leaves it")
        XCTAssertEqual(try JSONHookFile.uninstalling(events: ["Stop"], marker: marker, in: plain), plain,
                       "a file without AccountDock's hooks is left alone")
    }

    func testRemovingTheFirstOfSeveralGroupsKeepsTheRestAsTheyWere() throws {
        let text = """
        {"hooks": {"Stop": [{"hooks": [{"command": "a # accountdock-hook"}]}, {"hooks": [{"command": "b"}]}], "Other": []}}
        """
        XCTAssertEqual(try JSONHookFile.uninstalling(events: ["Stop"], marker: marker, in: text),
                       #"{"hooks": {"Stop": [{"hooks": [{"command": "b"}]}], "Other": []}}"#)
        let only = #"{"hooks": {"Stop": [{"hooks": [{"command": "a # accountdock-hook"}]}], "Other": []}}"#
        XCTAssertEqual(try JSONHookFile.uninstalling(events: ["Stop"], marker: marker, in: only), #"{"hooks": {"Other": []}}"#)
    }

    func testAFileThatIsNoObjectIsRefused() {
        XCTAssertThrowsError(try JSONHookFile.installing(events: ["Stop"], command: command, timeout: 1, marker: marker,
                                                         in: "[1, 2]")) { error in
            XCTAssertEqual(error as? JSONHookFile.Failure, .notAnObject)
        }
        XCTAssertThrowsError(try JSONHookFile.installing(events: ["Stop"], command: command, timeout: 1, marker: marker,
                                                         in: #"{"hooks": "#))
    }

    /// The editor keeps a copy of the first version it edits, refuses an
    /// empty file and creates a missing one.
    func testTheFileIsEditedInPlaceWithABackup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HookConfigEditor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let real = directory.appendingPathComponent("settings.json")
        let link = real
        // An unquoted command: a quoted script path must exist to count.
        let command = "/bin/echo session # accountdock-hook"
        try Data(settings.utf8).write(to: real)

        try HookConfigEditor.install(.jsonHooks, at: link, events: ["Stop"], command: command, timeout: 10, marker: marker)
        XCTAssertTrue(JSONHookFile.hasHooks(at: link, events: ["Stop"], marker: marker, command: command, timeout: 10))
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: real.path + ".accountdock-hooks-backup"), encoding: .utf8),
                       settings)
        try HookConfigEditor.uninstall(.jsonHooks, at: link, events: ["Stop"], marker: marker)
        XCTAssertEqual(try String(contentsOf: real, encoding: .utf8), settings)
        XCTAssertFalse(HookConfigEditor.hasHooks(.jsonHooks, at: link, events: ["Stop"], marker: marker))

        let empty = directory.appendingPathComponent("empty.json")
        try Data(" \n".utf8).write(to: empty)
        XCTAssertThrowsError(try HookConfigEditor.install(.jsonHooks, at: empty, events: ["Stop"], command: command,
                                                          timeout: 1, marker: marker))
        let missing = directory.appendingPathComponent("new/hooks.json")
        try HookConfigEditor.install(.jsonHooks, at: missing, events: ["Stop"], command: command, timeout: 1, marker: marker)
        XCTAssertTrue(HookConfigEditor.hasHooks(.jsonHooks, at: missing, events: ["Stop"], marker: marker))
    }

    /// The TOML adapter: marked tables are added after the file's last line
    /// and removed whole, every other line kept.
    func testTheTOMLAdapterKeepsEveryOtherLine() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HookConfigEditor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.toml")
        let original = "default_model = \"k2\"  # mine\n\n[[hooks]]\nevent = \"Stop\"\ncommand = \"say hi\"\n"
        try Data(original.utf8).write(to: url)
        try HookConfigEditor.install(.tomlHooks, at: url, events: ["Stop"], command: "run # accountdock-hook", timeout: 5,
                                     marker: marker)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original
            + "\n[[hooks]] # accountdock-hook\nevent = \"Stop\"\ncommand = \"run # accountdock-hook\"\ntimeout = 5\n")
        XCTAssertTrue(HookConfigEditor.hasHooks(.tomlHooks, at: url, events: ["Stop"], marker: marker, timeout: 5))
        try HookConfigEditor.uninstall(.tomlHooks, at: url, events: ["Stop"], marker: marker)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original)
    }
}
