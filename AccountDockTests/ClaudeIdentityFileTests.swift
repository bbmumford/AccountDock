import XCTest
@testable import AccountDock

final class ClaudeIdentityFileTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeIdentityFileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private let head = """
    {
      "zeta": "last \\"quoted\\" / slash",
      "numStartups": 412,
      "projects": {
        "/tmp/a": { "allowedTools": [], "history": [{"display": "}{ ]["}] }
      },
      "oauthAccount":
    """
    private let oldValue = """
     {
        "accountUuid": "old-uuid",
        "emailAddress": "old@example.com"
      }
    """
    private let tail = """
    ,
      "alpha": true,
      "cachedUsageUtilization": 0.25,
      "emptyThing": null
    }

    """

    private var newIdentity: [String: AnyCodable] {
        ["accountUuid": AnyCodable("new-uuid"), "emailAddress": AnyCodable("New@Example.com"),
         "organizationName": AnyCodable("Org \"A\""), "seats": AnyCodable(3)]
    }

    private func writeFile(_ text: String, mode: Int = 0o644) throws -> URL {
        let url = directory.appendingPathComponent(".claude.json")
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        return url
    }

    func testWritingTheIdentityKeepsEveryOtherEntryItsOrderAndItsText() throws {
        let url = try writeFile(head + oldValue + tail)
        try ClaudeIdentityFile(url: url).writeOAuthAccount(newIdentity)

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix(head), "the entries before oauthAccount are byte-for-byte unchanged")
        XCTAssertTrue(text.hasSuffix(tail), "the entries after oauthAccount are byte-for-byte unchanged")

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let identity = try XCTUnwrap(json["oauthAccount"] as? [String: Any])
        XCTAssertEqual(identity["emailAddress"] as? String, "New@Example.com")
        XCTAssertEqual(identity["organizationName"] as? String, "Org \"A\"")
        XCTAssertEqual(identity["seats"] as? Int, 3)
        XCTAssertEqual(json["numStartups"] as? Int, 412)
        XCTAssertEqual(json["zeta"] as? String, "last \"quoted\" / slash")
        XCTAssertEqual(json["alpha"] as? Bool, true)
        XCTAssertTrue(json["emptyThing"] is NSNull)
        XCTAssertEqual(ClaudeIdentityFile(url: url).readOAuthAccount()?["accountUuid"]?.value as? String, "new-uuid")
    }

    func testAMissingIdentityIsAddedAfterTheLastEntry() throws {
        let original = "{\n  \"b\": 1,\n  \"a\": [1, 2]\n}\n"
        let url = try writeFile(original)
        try ClaudeIdentityFile(url: url).writeOAuthAccount(["emailAddress": AnyCodable("x@example.com")])

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(text, "{\n  \"b\": 1,\n  \"a\": [1, 2],\n  \"oauthAccount\": {\n    \"emailAddress\": \"x@example.com\"\n  }\n}\n")
    }

    func testTheFileKeepsItsPermissions() throws {
        for mode in [0o600, 0o644] {
            let url = try writeFile(head + oldValue + tail, mode: mode)
            try ClaudeIdentityFile(url: url).writeOAuthAccount(newIdentity)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, mode)
        }
    }

    func testAFileChangedAfterItWasReadIsNotReplaced() throws {
        let url = try writeFile(head + oldValue + tail)
        let file = ClaudeIdentityFile(url: url)
        let snapshot = try file.read()
        let edited = try XCTUnwrap(ClaudeIdentityFile.replacingTopLevelValue(
            forKey: ClaudeIdentityFile.key, in: snapshot.data, with: newIdentity
        ))

        // A Claude Code session saves its own state in between.
        let sessionWrite = head + oldValue + ",\n  \"written\": \"by a session\"" + tail
        try Data(sessionWrite.utf8).write(to: url, options: .atomic)

        XCTAssertThrowsError(try file.commit(edited, over: snapshot)) { error in
            XCTAssertEqual(error as? ClaudeIdentityFile.EditError, .changedSinceRead)
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), sessionWrite)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(leftovers, [".claude.json"], "the refused edit leaves no temporary file")

        // The retrying write reads the session's version and keeps its entry.
        try file.writeOAuthAccount(newIdentity)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(json["written"] as? String, "by a session")
        XCTAssertEqual((json["oauthAccount"] as? [String: Any])?["accountUuid"] as? String, "new-uuid")
    }

    func testAFileThatIsNotAJSONObjectIsNotWritten() throws {
        let url = try writeFile("{\"a\": 1,")
        XCTAssertThrowsError(try ClaudeIdentityFile(url: url).writeOAuthAccount(newIdentity))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "{\"a\": 1,")
        XCTAssertNil(ClaudeIdentityFile.replacingTopLevelValue(forKey: "k", in: Data("[1]".utf8), with: [:]))
    }

    func testAOneLineFileGetsAOneLineValue() throws {
        let data = Data(#"{"a":{"b":[1,{"c":"}"}]},"oauthAccount":null,"z":2}"#.utf8)
        let edited = try XCTUnwrap(ClaudeIdentityFile.replacingTopLevelValue(
            forKey: "oauthAccount", in: data, with: ["e": AnyCodable("x")]
        ))
        XCTAssertEqual(String(decoding: edited, as: UTF8.self), #"{"a":{"b":[1,{"c":"}"}]},"oauthAccount":{"e":"x"},"z":2}"#)
    }
}
