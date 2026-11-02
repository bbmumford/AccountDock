import XCTest
@testable import AccountDock

final class SecurityToolKeychainTests: XCTestCase {
    func testQuotedEscapesBackslashesAndQuotes() {
        XCTAssertEqual(SecurityToolKeychain.quoted(#"a"b\c"#), #""a\"b\\c""#)
    }

    func testAsciiOnlyEscapesNonAsciiAsJSON() throws {
        let value = #"{"name":"Zoë 😀"}"#
        let escaped = SecurityToolKeychain.asciiOnly(value)
        XCTAssertFalse(escaped.utf8.contains { $0 >= 0x80 })
        let decoded = try JSONSerialization.jsonObject(with: Data(escaped.utf8)) as? [String: String]
        XCTAssertEqual(decoded?["name"], "Zoë 😀")
    }

    func testDecodePasswordDecodesHexJSONAndLeavesTextAlone() {
        let hex = Data(#"{"a":1}"#.utf8).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(SecurityToolKeychain.decodePassword(hex), #"{"a":1}"#)
        XCTAssertEqual(SecurityToolKeychain.decodePassword(#"{"a":1}"#), #"{"a":1}"#)
        XCTAssertEqual(SecurityToolKeychain.decodePassword("abcd"), "abcd")
    }

    func testAddCommandRefusesLinesOverTheLimit() {
        XCTAssertNotNil(SecurityToolKeychain.addCommand(service: "s", account: "a", value: String(repeating: "x", count: 3_000)))
        XCTAssertNil(SecurityToolKeychain.addCommand(service: "s", account: "a", value: String(repeating: "x", count: 4_000)))
    }

    /// Round trip through the login keychain with a throwaway service name.
    func testWriteReadReplaceDelete() {
        let store = SecurityToolKeychain(service: "app.accountdock.tests.\(UUID().uuidString)")
        defer { _ = store.apply(writes: [], deletes: ["one", "two"]) }
        let first = #"{"token":"{\"claudeAiOauth\":{\"accessToken\":\"x\"}}","who":"Zoë"}"#
        XCTAssertTrue(store.apply(writes: [("one", first), ("two", "[\"a\"]")]))
        XCTAssertEqual(store.read(account: "one"), SecurityToolKeychain.asciiOnly(first))
        XCTAssertEqual(store.read(account: "two"), "[\"a\"]")
        XCTAssertTrue(store.apply(writes: [("one", "{}")], deletes: ["two"]))
        XCTAssertEqual(store.read(account: "one"), "{}")
        XCTAssertNil(store.read(account: "two"))
        XCTAssertFalse(store.apply(writes: [("one", String(repeating: "x", count: 5_000))]))
        XCTAssertEqual(store.read(account: "one"), "{}")
    }
}
