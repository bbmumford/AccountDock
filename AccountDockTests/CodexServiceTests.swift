import XCTest
@testable import AccountDock

final class CodexServiceTests: XCTestCase {
    func testUsageLimitDetectionRequiresLatestTurnError() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jsonl")
        defer { try? FileManager.default.removeItem(at: file) }

        let error = #"{"type":"event_msg","payload":{"type":"error","message":"You've hit your usage limit. Try again later."}}"#
        try Data(error.utf8).write(to: file)
        XCTAssertTrue(CodexService.rolloutEndsWithUsageLimit(file.path))

        let newerPrompt = #"{"type":"event_msg","payload":{"type":"user_message","message":"retry"}}"#
        try Data("\(error)\n\(newerPrompt)\n".utf8).write(to: file)
        XCTAssertFalse(CodexService.rolloutEndsWithUsageLimit(file.path))
    }

    func testBundledPricingSeparatesCodexAndClaudeProviders() async {
        await PricingService.shared.ensureLoaded()
        let codex = await PricingService.shared.pricing(
            for: "gpt-5.6-sol",
            provider: .codex,
            reasoningEffort: "xhigh"
        )
        let claude = await PricingService.shared.pricing(
            for: "claude-sonnet-4-6",
            provider: .claudeCode
        )

        XCTAssertNotNil(codex)
        XCTAssertNotNil(claude)
        if let codex {
            XCTAssertEqual(codex.inputPerToken, 0.000005, accuracy: 0.000000001)
            XCTAssertEqual(codex.outputPerToken, 0.00003, accuracy: 0.000000001)
        }
    }

    func testIdentityReadsEmailNameAndAccountIDFromJWT() throws {
        let payload: [String: Any] = [
            "email": "dev@example.com",
            "name": "Example Developer",
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "account-123",
                "chatgpt_plan_type": "plus"
            ]
        ]
        let auth = try self.authData(payload: payload)

        let identity = try CodexService.identity(fromAuthData: auth)

        XCTAssertEqual(identity.email, "dev@example.com")
        XCTAssertEqual(identity.displayName, "Example Developer")
        XCTAssertEqual(identity.accountID, "account-123")
        XCTAssertEqual(identity.planType, "plus")
    }

    func testIdentityFallsBackToAccountIDSuffix() throws {
        let payload: [String: Any] = [
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "account-abcdefgh"
            ]
        ]
        let auth = try self.authData(payload: payload)

        let identity = try CodexService.identity(fromAuthData: auth)

        XCTAssertEqual(identity.email, "Codex abcdefgh")
        XCTAssertEqual(identity.displayName, "Codex abcdefgh")
    }

    func testIdentityRejectsCredentialsWithoutIdentity() throws {
        let auth = try self.authData(payload: ["sub": "anonymous"])
        XCTAssertThrowsError(try CodexService.identity(fromAuthData: auth))
    }

    func testCredentialRefreshUsesAccessTokenExpiryDespiteFractionalTimestamp() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let auth: [String: Any] = [
            "last_refresh": "2026-08-11T08:35:14.267692Z",
            "tokens": [
                "access_token": try jwt(payload: [
                    "exp": now.addingTimeInterval(24 * 60 * 60).timeIntervalSince1970
                ])
            ]
        ]

        XCTAssertFalse(CodexService.credentialsNeedRefresh(auth, now: now))
    }

    func testCredentialRefreshStartsFiveMinutesBeforeAccessTokenExpiry() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let auth: [String: Any] = [
            "tokens": [
                "access_token": try jwt(payload: [
                    "exp": now.addingTimeInterval(4 * 60).timeIntervalSince1970
                ])
            ]
        ]

        XCTAssertTrue(CodexService.credentialsNeedRefresh(auth, now: now))
    }

    func testFreePlanPrimaryQuotaFallsBackToLongWindow() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "rate_limit": [
                "primary_window": [
                    "used_percent": 12,
                    "reset_at": 1_790_000_000,
                    "limit_window_seconds": 30 * 24 * 60 * 60,
                ],
                "secondary_window": NSNull(),
            ],
        ])

        let usage = try CodexService.decodeUsage(data)

        XCTAssertEqual(usage.sevenDay?.utilization, 12)
        XCTAssertEqual(usage.sevenDay?.windowSeconds, 30 * 24 * 60 * 60)
        XCTAssertNil(usage.fiveHour)
    }

    func testLiveUsageSnapshotCarriesCurrentPlanType() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "plan_type": "business",
            "rate_limit": [
                "primary_window": [
                    "used_percent": 25,
                    "reset_at": 1_790_000_000,
                    "limit_window_seconds": 7 * 24 * 60 * 60,
                ],
            ],
        ])

        let snapshot = try CodexService.decodeUsageSnapshot(data)

        XCTAssertEqual(snapshot.planType, "business")
        XCTAssertEqual(snapshot.usage.sevenDay?.utilization, 25)
    }

    func testMovingZeroPercentCodexPlaceholderIsTreatedAsUnstarted() throws {
        let window = 7 * 24 * 60 * 60
        let data = try JSONSerialization.data(withJSONObject: [
            "rate_limit": [
                "primary_window": [
                    "used_percent": 0,
                    "reset_at": 1_790_000_000,
                    "reset_after_seconds": window,
                    "limit_window_seconds": window,
                ],
            ],
        ])

        let usage = try CodexService.decodeUsage(data)

        XCTAssertEqual(usage.sevenDay?.utilization, 0)
        XCTAssertNil(usage.sevenDay?.resetsAt)
        XCTAssertTrue(usage.sevenDay?.isUnusedUnstartedWindow == true)
    }

    func testEstablishedZeroPercentCodexCountdownKeepsFixedReset() throws {
        let window = 7 * 24 * 60 * 60
        let data = try JSONSerialization.data(withJSONObject: [
            "rate_limit": [
                "primary_window": [
                    "used_percent": 0,
                    "reset_at": 1_790_000_000,
                    "reset_after_seconds": window - 10,
                    "limit_window_seconds": window,
                ],
            ],
        ])

        let usage = try CodexService.decodeUsage(data)

        XCTAssertNotNil(usage.sevenDay?.resetsAt)
        XCTAssertFalse(usage.sevenDay?.isUnusedUnstartedWindow == true)
    }

    func testDetectsRestartableCodexCLICommands() {
        XCTAssertTrue(CodexService.isRestartableCodexCommand("codex"))
        XCTAssertTrue(CodexService.isRestartableCodexCommand("/Users/me/.local/bin/codex resume session-123"))
        XCTAssertFalse(CodexService.isRestartableCodexCommand("/Users/me/.local/bin/codex-code-mode-host"))
        XCTAssertFalse(CodexService.isRestartableCodexCommand("/Users/me/.local/bin/codex app-server"))
    }

    func testExtractsResumeSessionID() {
        XCTAssertEqual(
            CodexService.extractResumeSessionID(from: "codex resume 019fb3dc-ea07-7413-95e3-aeec2e1616cf"),
            "019fb3dc-ea07-7413-95e3-aeec2e1616cf"
        )
        XCTAssertEqual(
            CodexService.extractResumeSessionID(from: "/opt/bin/codex resume=session_123 -C /tmp"),
            "session_123"
        )
        XCTAssertNil(CodexService.extractResumeSessionID(from: "codex"))
    }

    func testExtractsSessionIDFromOpenRolloutPath() {
        XCTAssertEqual(
            CodexService.sessionID(
                fromRolloutPath: "/Users/me/.codex/sessions/2026/07/31/rollout-2026-07-31T02-30-27-019fb3dc-ea07-7413-95e3-aeec2e1616cf.jsonl"
            ),
            "019fb3dc-ea07-7413-95e3-aeec2e1616cf"
        )
        XCTAssertNil(CodexService.sessionID(fromRolloutPath: "/tmp/not-a-rollout.jsonl"))
    }

    private func authData(payload: [String: Any]) throws -> Data {
        let token = try jwt(payload: payload)
        return try JSONSerialization.data(withJSONObject: [
            "tokens": [
                "id_token": token
            ]
        ])
    }

    private func jwt(payload: [String: Any]) throws -> String {
        let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let payloadPart = payloadData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(payloadPart).signature"
    }
}
