import XCTest
@testable import UsageCore

final class CodexParsingTests: XCTestCase {
    func testRateLimitsPreferCodexBucketAndShowRemaining() throws {
        let response = try JSONDecoder().decode(CodexRateLimitsResponseDTO.self, from: fixture("codex-rate-limits.json"))
        let dto = try XCTUnwrap(response.codexSnapshot)
        let account = try JSONDecoder().decode(CodexAccountResponseDTO.self, from: fixture("codex-account.json")).account
        let observed = Date(timeIntervalSince1970: 1_789_990_000)

        let snapshot = CodexUsageMapper.snapshot(from: dto, account: account, observedAt: observed)

        XCTAssertEqual(snapshot.provider, .codex)
        XCTAssertEqual(snapshot.source, .codexAppServer)
        XCTAssertEqual(snapshot.session?.remainingPercent, 60, "bucket `codex` (40% used) wins over the legacy single view")
        XCTAssertEqual(snapshot.weekly?.remainingPercent, 48)
        XCTAssertEqual(snapshot.session?.shortLabel, "5h")
        XCTAssertEqual(snapshot.weekly?.shortLabel, "1w")
        XCTAssertEqual(snapshot.session?.resetsAt, Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertEqual(snapshot.planName, "Pro")
        XCTAssertEqual(snapshot.accountLabel, "me@example.com")
        XCTAssertEqual(snapshot.notes, ["Credits: 12.50"])
    }

    func testSparseUpdateKeepsMissingWindows() throws {
        let response = try JSONDecoder().decode(CodexRateLimitsResponseDTO.self, from: fixture("codex-rate-limits.json"))
        let base = try XCTUnwrap(response.codexSnapshot)
        let update = try JSONDecoder().decode(CodexRateLimitsUpdatedDTO.self, from: fixture("codex-rate-limits-update.json"))

        let merged = base.merging(update.rateLimits)

        XCTAssertEqual(merged.primary?.usedPercent, 45)
        XCTAssertEqual(merged.secondary?.usedPercent, 52, "null in a rolling update must not clear the weekly window")
        XCTAssertEqual(merged.planType, "pro")
        XCTAssertEqual(merged.credits?.balance, "12.50")
    }

    func testFallsBackToSingleViewWithoutBuckets() throws {
        var response = try JSONDecoder().decode(CodexRateLimitsResponseDTO.self, from: fixture("codex-rate-limits.json"))
        response.rateLimitsByLimitId = nil
        XCTAssertEqual(response.codexSnapshot?.primary?.usedPercent, 10)
    }

    func testSessionLogPicksNewestTimestampAndSkipsOtherLines() throws {
        let snapshot = try XCTUnwrap(CodexSessionLogParser.latestSnapshot(inJSONLines: fixture("codex-session.jsonl")))

        XCTAssertEqual(snapshot.source, .codexSessionLog)
        XCTAssertEqual(snapshot.observedAt, ISO8601.parse("2026-09-24T01:05:00.000Z"))
        XCTAssertEqual(snapshot.session?.remainingPercent, 51)
        XCTAssertEqual(snapshot.weekly?.remainingPercent, 47)
        XCTAssertEqual(snapshot.planName, "Pro Lite")
    }
}

final class ClaudeParsingTests: XCTestCase {
    func testOAuthUsageParsesAllWindowsInOrder() throws {
        let observed = Date(timeIntervalSince1970: 1_775_000_000)
        let snapshot = try ClaudeOAuthUsageParser.snapshot(from: fixture("claude-oauth-usage.json"), planName: "Max", observedAt: observed)

        XCTAssertEqual(snapshot.windows.map(\.kind), [.session, .weekly, .weeklyModel("Sonnet")], "null windows are skipped")
        XCTAssertEqual(snapshot.session?.remainingPercent, 67)
        XCTAssertEqual(snapshot.weekly?.remainingPercent, 87)
        XCTAssertEqual(snapshot.extraWindows.first?.shortLabel, "Sonnet")
        XCTAssertEqual(snapshot.planName, "Max")
        XCTAssertEqual(snapshot.source, .claudeOAuth)
        XCTAssertTrue(snapshot.notes.isEmpty, "disabled extra usage adds no note")

        let reset = try XCTUnwrap(snapshot.session?.resetsAt)
        XCTAssertEqual(reset.timeIntervalSince1970, 1_775_890_800.528743, accuracy: 0.001)
    }

    func testOAuthUsageWithoutWindowsFails() {
        XCTAssertThrowsError(try ClaudeOAuthUsageParser.snapshot(from: Data("{\"extra_usage\":null}".utf8), planName: nil, observedAt: Date()))
    }

    func testISO8601AcceptsAnyFractionPrecision() throws {
        let micro = try XCTUnwrap(ISO8601.parse("2026-04-11T07:00:00.528743+00:00"))
        let none = try XCTUnwrap(ISO8601.parse("2026-04-11T07:00:00Z"))
        let milli = try XCTUnwrap(ISO8601.parse("2026-04-11T16:00:00.250+09:00"))
        XCTAssertEqual(micro.timeIntervalSince(none), 0.528743, accuracy: 0.000_01)
        XCTAssertEqual(milli.timeIntervalSince(none), 0.25, accuracy: 0.000_01)
        XCTAssertNil(ISO8601.parse("yesterday"))
    }

    func testCredentialsParseMillisecondExpiry() throws {
        let credentials = try ClaudeCredentials.parse(fixture("claude-credentials.json"))
        XCTAssertEqual(credentials.accessToken, "sk-ant-oat01-test")
        XCTAssertEqual(credentials.expiresAt, Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertEqual(credentials.subscriptionType, "max")
        XCTAssertTrue(credentials.scopes.contains("user:profile"))
        XCTAssertFalse(credentials.isExpired(now: Date(timeIntervalSince1970: 1_789_000_000)))
        XCTAssertTrue(credentials.isExpired(now: Date(timeIntervalSince1970: 1_789_999_990)), "expires early by the safety margin")
        XCTAssertThrowsError(try ClaudeCredentials.parse(Data("{\"claudeAiOauth\":{}}".utf8)))
    }

    func testStatuslineBridgeKeepsOnlyRateLimits() throws {
        let input = try fixture("statusline-input.json")
        let limits = try XCTUnwrap(ClaudeStatuslineParser.rateLimits(fromStatuslineInput: input))
        let observed = Date(timeIntervalSince1970: 1_738_400_000)
        let file = try ClaudeStatuslineParser.bridgeFileData(rateLimits: limits, observedAt: observed)

        let text = String(decoding: file, as: UTF8.self)
        XCTAssertFalse(text.contains("secret-project"), "session paths must never be persisted")
        XCTAssertTrue(ClaudeStatuslineParser.bridgeFile(file, hasSameRateLimitsAs: limits))

        let snapshot = try XCTUnwrap(ClaudeStatuslineParser.snapshot(fromBridgeFile: file))
        XCTAssertEqual(snapshot.source, .claudeStatusline)
        XCTAssertEqual(snapshot.observedAt, observed)
        XCTAssertEqual(snapshot.session?.remainingPercent, 76, "23.5% used rounds to 24")
        XCTAssertEqual(snapshot.weekly?.remainingPercent, 59)
        XCTAssertEqual(snapshot.weekly?.resetsAt, Date(timeIntervalSince1970: 1_738_857_600))
        XCTAssertEqual(ClaudeStatuslineParser.defaultStatusText(rateLimits: limits), "5h 76% left · 7d 59% left")
        XCTAssertNil(ClaudeStatuslineParser.rateLimits(fromStatuslineInput: Data("{\"model\":{}}".utf8)))
    }
}

final class DisplayTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testFreshnessThresholds() {
        let live = PollPolicy.claude.liveWindow
        XCTAssertEqual(Freshness.evaluate(observedAt: now.addingTimeInterval(-live), now: now, liveWindow: live), .live)
        XCTAssertEqual(Freshness.evaluate(observedAt: now.addingTimeInterval(-live - 1), now: now, liveWindow: live), .recent)
        XCTAssertEqual(Freshness.evaluate(observedAt: now.addingTimeInterval(-901), now: now, liveWindow: live), .stale)
    }

    func testLiveLineShowsPlainLabelAndLevel() {
        let window = UsageWindow(kind: .session, usedPercent: 92, resetsAt: now.addingTimeInterval(600), durationMinutes: 300)
        let line = UsageDisplay.line(for: window, freshness: .live, now: now)
        XCTAssertEqual(line.displayLabel, "5h")
        XCTAssertEqual(line.remainingPercent, 8)
        XCTAssertEqual(line.level, .warning)
        XCTAssertEqual(UsageDisplay.line(for: UsageWindow(kind: .weekly, usedPercent: 96, resetsAt: nil), freshness: .live, now: now).level, .critical)
    }

    func testRecentAndStaleLinesAreMarked() {
        let window = UsageWindow(kind: .weekly, usedPercent: 30, resetsAt: now.addingTimeInterval(86_400))
        let recent = UsageDisplay.line(for: window, freshness: .recent, now: now)
        XCTAssertEqual(recent.displayLabel, "~1w")
        XCTAssertEqual(recent.level, .good)
        let stale = UsageDisplay.line(for: window, freshness: .stale, now: now)
        XCTAssertEqual(stale.level, .stale)
    }

    func testPassedResetIsInferredAsFullButApproximate() {
        let window = UsageWindow(kind: .session, usedPercent: 99, resetsAt: now.addingTimeInterval(-1), durationMinutes: 300)
        let line = UsageDisplay.line(for: window, freshness: .live, now: now)
        XCTAssertEqual(line.remainingPercent, 100)
        XCTAssertTrue(line.isInferredReset)
        XCTAssertEqual(line.displayLabel, "~5h")
    }

    func testRemainingIsClamped() {
        XCTAssertEqual(UsageWindow(kind: .other("Spend"), usedPercent: 130, resetsAt: nil).remainingPercent, 0)
        XCTAssertEqual(UsageWindow(kind: .session, usedPercent: -3, resetsAt: nil).remainingPercent, 100)
    }

    func testWindowClassificationAndLabels() {
        XCTAssertEqual(UsageWindow.kind(forDurationMinutes: 300, fallback: .weekly), .session)
        XCTAssertEqual(UsageWindow.kind(forDurationMinutes: 10_080, fallback: .session), .weekly)
        XCTAssertEqual(UsageWindow.kind(forDurationMinutes: 43_200, fallback: .session), .other("30d"))
        XCTAssertEqual(UsageWindow.kind(forDurationMinutes: nil, fallback: .weekly), .weekly)
        XCTAssertEqual(UsageWindow.durationLabel(minutes: 90), "90m")
    }

    func testFormatting() {
        XCTAssertEqual(UsageFormat.duration(3 * 86_400 + 4 * 3_600 + 59), "3d 4h")
        XCTAssertEqual(UsageFormat.duration(2 * 3_600 + 13 * 60), "2h 13m")
        XCTAssertEqual(UsageFormat.duration(30), "<1m")
        XCTAssertEqual(UsageFormat.age(since: now.addingTimeInterval(-5), now: now), "just now")
        XCTAssertEqual(UsageFormat.age(since: now.addingTimeInterval(-42), now: now), "42s ago")
        XCTAssertEqual(UsageFormat.age(since: now.addingTimeInterval(-7_300), now: now), "2h ago")
        XCTAssertEqual(UsageFormat.timeUntil(now.addingTimeInterval(-1), now: now), "now")
    }

    func testNewestSnapshotWinsAndActiveQueryWinsTies() {
        let time = now
        let live = UsageSnapshot(provider: .claude, windows: [], source: .claudeOAuth, observedAt: time)
        let passive = UsageSnapshot(provider: .claude, windows: [], source: .claudeStatusline, observedAt: time)
        let newerPassive = UsageSnapshot(provider: .claude, windows: [], source: .claudeStatusline, observedAt: time.addingTimeInterval(1))
        XCTAssertEqual(UsageSnapshot.newest([passive, live])?.source, .claudeOAuth)
        XCTAssertEqual(UsageSnapshot.newest([live, passive])?.source, .claudeOAuth)
        XCTAssertEqual(UsageSnapshot.newest([live, nil, newerPassive])?.observedAt, time.addingTimeInterval(1))
        XCTAssertNil(UsageSnapshot.newest([nil]))
    }

    func testUsageChangeDetectionIgnoresMetadata() {
        let windows = [UsageWindow(kind: .session, usedPercent: 10, resetsAt: now)]
        let a = UsageSnapshot(provider: .codex, windows: windows, planName: "Pro", source: .codexAppServer, observedAt: now)
        var b = a
        b.observedAt = now.addingTimeInterval(60)
        b.planName = nil
        XCTAssertFalse(b.hasDifferentUsage(than: a))
        b.windows[0].usedPercent = 11
        XCTAssertTrue(b.hasDifferentUsage(than: a))
        XCTAssertTrue(a.hasDifferentUsage(than: nil))
    }
}

final class PollPolicyTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testBaseActiveAndIdleIntervals() {
        let policy = PollPolicy.codex
        var state = PollState()
        state.recordSuccess(at: now, usageChanged: false)
        state.lastChangeAt = nil
        XCTAssertEqual(policy.nextDelay(for: state, now: now), policy.base)

        state.lastChangeAt = now.addingTimeInterval(-60)
        XCTAssertEqual(policy.nextDelay(for: state, now: now), policy.active)

        state.lastChangeAt = now.addingTimeInterval(-policy.idleAfter)
        XCTAssertEqual(policy.nextDelay(for: state, now: now), policy.idle)
    }

    func testExponentialBackoffIsCapped() {
        let policy = PollPolicy.claude
        var state = PollState()
        state.recordFailure(at: now)
        XCTAssertEqual(policy.nextDelay(for: state, now: now), policy.minimumSpacing, "30s backoff is lifted to the 45s minimum")
        state.recordFailure(at: now)
        XCTAssertEqual(policy.nextDelay(for: state, now: now), 60)
        for _ in 0..<20 { state.recordFailure(at: now) }
        XCTAssertEqual(policy.nextDelay(for: state, now: now), policy.backoffMax)

        state.recordSuccess(at: now, usageChanged: true)
        XCTAssertEqual(state.consecutiveFailures, 0)
        XCTAssertEqual(policy.nextDelay(for: state, now: now), policy.active)
    }

    func testRetryAfterIsRespected() {
        let policy = PollPolicy.claude
        var state = PollState()
        state.recordFailure(at: now, retryAfter: 600)
        XCTAssertEqual(policy.nextDelay(for: state, now: now), 600)
        XCTAssertEqual(policy.waitBeforeManualRequest(state: state, now: now), 600)
    }

    func testManualRequestsHonorMinimumSpacing() {
        let policy = PollPolicy.claude
        var state = PollState()
        XCTAssertEqual(policy.waitBeforeManualRequest(state: state, now: now), 0)
        state.recordAttempt(at: now.addingTimeInterval(-10))
        XCTAssertEqual(policy.waitBeforeManualRequest(state: state, now: now), 35)
    }

    func testJitterStaysWithinBounds() {
        XCTAssertEqual(PollPolicy.jitter(100, unit: 0), 90, accuracy: 0.0001)
        XCTAssertEqual(PollPolicy.jitter(100, unit: 1), 110, accuracy: 0.0001)
        XCTAssertEqual(PollPolicy.jitter(100, unit: 0.5), 100, accuracy: 0.0001)
        XCTAssertEqual(PollPolicy.jitter(100, unit: 7), 110, accuracy: 0.0001, "unit is clamped")
    }
}

final class JSONRPCTests: XCTestCase {
    func testLineBufferSplitsAcrossChunks() {
        var buffer = LineBuffer()
        XCTAssertEqual(buffer.append(Data("{\"id\":1,".utf8)), [])
        let lines = buffer.append(Data("\"result\":{}}\r\n\n{\"method\":\"x\"}\n{\"par".utf8))
        XCTAssertEqual(lines.map { String(decoding: $0, as: UTF8.self) }, ["{\"id\":1,\"result\":{}}", "{\"method\":\"x\"}"])
        XCTAssertEqual(buffer.pendingByteCount, 5)
    }

    func testParsesEachMessageKind() throws {
        guard case .response(let id, let result) = RPCMessage.parse(Data("{\"id\":7,\"result\":{\"a\":1}}".utf8)) else {
            return XCTFail("expected response")
        }
        XCTAssertEqual(id, 7)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: result) as? [String: Int], ["a": 1])

        guard case .error(8, -32601, "nope") = RPCMessage.parse(Data("{\"id\":8,\"error\":{\"code\":-32601,\"message\":\"nope\"}}".utf8)) else {
            return XCTFail("expected error")
        }
        guard case .notification("account/updated", nil) = RPCMessage.parse(Data("{\"method\":\"account/updated\"}".utf8)) else {
            return XCTFail("expected notification")
        }
        guard case .request(.string("s1"), "item/tool/call") = RPCMessage.parse(Data("{\"id\":\"s1\",\"method\":\"item/tool/call\",\"params\":{}}".utf8)) else {
            return XCTFail("expected server request")
        }
        guard case .invalid = RPCMessage.parse(Data("[1,2]".utf8)) else {
            return XCTFail("expected invalid")
        }
    }

    func testEncodesWithoutJSONRPCField() throws {
        let data = try RPCMessage.encodeRequest(id: 3, method: "account/rateLimits/read", params: nil)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "{\"id\":3,\"method\":\"account/rateLimits/read\"}\n")
    }
}

func fixture(_ name: String) throws -> Data {
    let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}
