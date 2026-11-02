import XCTest
@testable import AccountDock

final class RouterPacingTests: XCTestCase {
    let members = [RouterPoolMember(accountID: "a", tokenFile: "a", weight: 1),
                   RouterPoolMember(accountID: "b", tokenFile: "b", weight: 1)]

    func testAMoveTakesEffectAtTheNextTurnOnly() {
        XCTAssertEqual(RouterLogic.poolAccount(current: "a", startsTurn: true, members: members, unavailable: [], load: [:], move: "b"), "b")
        XCTAssertEqual(RouterLogic.poolAccount(current: "a", startsTurn: false, members: members, unavailable: [], load: [:], move: "b"), "a",
                       "a turn in progress finishes on its account")
        XCTAssertEqual(RouterLogic.poolAccount(current: "a", startsTurn: true, members: members, unavailable: ["b"], load: [:], move: "b"), "a",
                       "a move to an unavailable account is ignored")
        XCTAssertEqual(RouterLogic.poolAccount(current: "a", startsTurn: false, members: members, unavailable: ["a"], load: ["b": 0, "c": 0], move: "b"), "b",
                       "a session whose own account cannot serve goes where it was placed, mid-turn too")
    }

    func testASessionWithAnExpiredCacheIsPlacedAgain() {
        let load = ["a": 3, "b": 0]
        XCTAssertEqual(RouterLogic.poolAccount(current: "a", startsTurn: true, members: members, unavailable: [], load: load), "a")
        XCTAssertEqual(RouterLogic.poolAccount(current: "a", startsTurn: true, members: members, unavailable: [], load: load, cacheExpired: true), "b")
        XCTAssertEqual(RouterLogic.poolAccount(current: "a", startsTurn: false, members: members, unavailable: [], load: load, cacheExpired: true), "a")
    }

    func testCacheLifetimeIsTheLongestMark() {
        XCTAssertNil(RouterLogic.cacheLifetime(["messages": [["role": "user", "content": "hi"]]]))
        let body: [String: Any] = [
            "system": [["type": "text", "text": "s", "cache_control": ["type": "ephemeral"]]],
            "messages": [["role": "user", "content": [["type": "text", "text": "x", "cache_control": ["type": "ephemeral", "ttl": "1h"]]]]],
        ]
        XCTAssertEqual(RouterLogic.cacheLifetime(body), 3600)
        XCTAssertEqual(RouterLogic.cacheLifetime(["tools": [["name": "t", "cache_control": ["type": "ephemeral"]]]]), 300)
    }

    func testARefusedRequestWaitsOnlyForAResetBeforeTheCacheExpires() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func headers(resetIn seconds: Double) -> [String: String] {
            ["anthropic-ratelimit-unified-reset": String(Int(now.timeIntervalSince1970 + seconds))]
        }
        let served = now.addingTimeInterval(-10 * 60)
        XCTAssertNotNil(RouterLogic.holdUntil(headers(resetIn: 4 * 60), lastServed: served, cacheLifetime: 3600, now: now))
        XCTAssertNil(RouterLogic.holdUntil(headers(resetIn: 20 * 60), lastServed: served, cacheLifetime: 3600, now: now),
                     "Claude Code abandons a request held this long")
        XCTAssertNil(RouterLogic.holdUntil(headers(resetIn: 4 * 60), lastServed: now.addingTimeInterval(-58 * 60), cacheLifetime: 3600, now: now),
                     "the cache would expire first")
        XCTAssertNil(RouterLogic.holdUntil(headers(resetIn: 2 * 60), lastServed: served, cacheLifetime: 300, now: now),
                     "a five-minute cache has already expired")
        XCTAssertNil(RouterLogic.holdUntil([:], lastServed: served, cacheLifetime: 3600, now: now), "no reset named")
        XCTAssertNil(RouterLogic.holdUntil(headers(resetIn: 60), lastServed: nil, cacheLifetime: 3600, now: now))
    }

    func testErrorsAfterAHeldHeadAreStreamEvents() {
        let upstream = RouterLogic.errorBody(type: "rate_limit_error", message: "limit")
        let event = String(decoding: RouterLogic.streamedError(upstream, status: 429), as: UTF8.self)
        XCTAssertTrue(event.hasPrefix("event: error\ndata: {"))
        XCTAssertTrue(event.hasSuffix("\n\n"))
        XCTAssertTrue(event.contains("rate_limit_error"))
        let plain = String(decoding: RouterLogic.streamedError(Data("bad gateway".utf8), status: 502), as: UTF8.self)
        XCTAssertTrue(plain.contains("api_error") && plain.contains("bad gateway"))
    }

    func testStateCarriesMovesAndCacheAwareness() throws {
        var state = RouterState()
        state.moves = ["s": "b"]
        state.cacheAwareSessions = true
        let decoded = try RouterConfig.decoder().decode(RouterState.self, from: RouterConfig.encoder().encode(state))
        XCTAssertEqual(decoded.moves, ["s": "b"])
        XCTAssertTrue(decoded.cacheAwareSessions)
        let old = try RouterConfig.decoder().decode(RouterState.self, from: Data("{}".utf8))
        XCTAssertTrue(old.moves.isEmpty)
        XCTAssertFalse(old.cacheAwareSessions)
    }

    func testHooksAreRecognisedAfterAnotherProgramDropsTheirHeaderComment() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hooks-\(UUID().uuidString).toml")
        defer { try? FileManager.default.removeItem(at: url) }
        let gate = "/bin/sh '/x/accountdock-gate.sh' kimi 480 # accountdock-gate"
        // As a TOML serializer writes it: header comments gone, tables moved.
        let rewritten = """
        default_model = "k3"

        [[hooks]]
        event = "Stop"
        command = "/bin/sh '/other/hook.sh'"
        timeout = 10

        [[hooks]]
        event = "PreToolUse"
        command = "\(gate)"
        timeout = 600

        [providers.p]
        base_url = "https://example.invalid"
        """
        try rewritten.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertTrue(TOMLHookConfig.hasHooks(at: url, events: ["PreToolUse"], marker: "# accountdock-gate", command: gate, timeout: 600))
        let copy = "\n[[hooks]]\nevent = \"PreToolUse\"\ncommand = \"\(gate)\"\ntimeout = 600\n"
        try (rewritten + copy).write(to: url, atomically: true, encoding: .utf8)
        XCTAssertFalse(TOMLHookConfig.hasHooks(at: url, events: ["PreToolUse"], marker: "# accountdock-gate", command: gate, timeout: 600),
                       "a copy beside the hook needs a repair")
        try TOMLHookConfig.install(at: url, events: ["PreToolUse"], command: gate, timeout: 600, marker: "# accountdock-gate")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "accountdock-gate.sh").count - 1, 1, "the unmarked copies are replaced, not kept beside the new one")
        XCTAssertTrue(text.contains("/other/hook.sh"))
        XCTAssertTrue(text.contains("[providers.p]\nbase_url"))
    }
}
