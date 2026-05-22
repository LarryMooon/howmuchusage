import XCTest
@testable import CodexUsageCore

final class CodexUsageCoreTests: XCTestCase {
    func testReaderFindsLatestRateLimitByTimestamp() throws {
        let root = try XCTUnwrap(Bundle.module.resourceURL?.appendingPathComponent("Fixtures"))
        let reader = CodexUsageReader(sessionRoot: root, maxFiles: 10)

        let snapshot = try reader.latestSnapshot()

        XCTAssertEqual(Int(snapshot.primary.usedPercent), 49)
        XCTAssertEqual(snapshot.primary.windowMinutes, 300)
        XCTAssertEqual(Int(snapshot.secondary.usedPercent), 53)
        XCTAssertEqual(snapshot.secondary.windowMinutes, 10080)
        XCTAssertEqual(snapshot.sourceLine, 4)
    }

    func testFormatterBuildsCompactMenuTitle() {
        let snapshot = CodexUsageSnapshot(
            primary: UsageWindowSnapshot(
                usedPercent: 49,
                windowMinutes: 300,
                resetsAt: Date(timeIntervalSince1970: 1_000 + (3 * 3_600) + (25 * 60))
            ),
            secondary: UsageWindowSnapshot(
                usedPercent: 53,
                windowMinutes: 10080,
                resetsAt: Date(timeIntervalSince1970: 2_000)
            ),
            planType: "prolite",
            limitID: "codex",
            rateLimitReachedType: nil,
            observedAt: Date(timeIntervalSince1970: 1_000),
            sourceFile: "/tmp/sample.jsonl",
            sourceLine: 4
        )

        XCTAssertEqual(
            CodexUsageFormatter.menuTitle(snapshot: snapshot, now: Date(timeIntervalSince1970: 1_000)),
            "~5h 51% · ~1w 47%"
        )

        let lines = CodexUsageFormatter.menuLines(snapshot: snapshot, now: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(lines[0].title, "~5h 51% [|||||-----]")
        XCTAssertEqual(lines[0].colorName, "green")
    }

    func testFormatterBuildsLocalSnapshotAgeText() {
        XCTAssertEqual(
            CodexUsageFormatter.localSnapshotText(
                observedAt: Date(timeIntervalSince1970: 1_000),
                now: Date(timeIntervalSince1970: 1_000)
            ),
            "Local snapshot · just now"
        )
        XCTAssertEqual(
            CodexUsageFormatter.localSnapshotText(
                observedAt: Date(timeIntervalSince1970: 1_000),
                now: Date(timeIntervalSince1970: 1_305)
            ),
            "Local snapshot · 5m ago"
        )
        XCTAssertEqual(
            CodexUsageFormatter.localSnapshotText(
                observedAt: Date(timeIntervalSince1970: 1_000),
                now: Date(timeIntervalSince1970: 4_900)
            ),
            "Local snapshot · 1h 5m ago"
        )
    }

    func testBatteryThresholdsUseRemainingPercent() {
        XCTAssertEqual(CodexUsageFormatter.color(forRemainingPercent: 11), "green")
        XCTAssertEqual(CodexUsageFormatter.color(forRemainingPercent: 10), "yellow")
        XCTAssertEqual(CodexUsageFormatter.color(forRemainingPercent: 5), "red")
        XCTAssertEqual(CodexUsageFormatter.remainingPercent(forUsedPercent: 96), 4)
    }

    func testStaleDetection() {
        let snapshot = CodexUsageSnapshot(
            primary: UsageWindowSnapshot(usedPercent: 10, windowMinutes: 300, resetsAt: Date()),
            secondary: UsageWindowSnapshot(usedPercent: 20, windowMinutes: 10080, resetsAt: Date()),
            planType: nil,
            limitID: nil,
            rateLimitReachedType: nil,
            observedAt: Date(timeIntervalSince1970: 1_000),
            sourceFile: "/tmp/sample.jsonl",
            sourceLine: 1
        )

        XCTAssertFalse(snapshot.isStale(now: Date(timeIntervalSince1970: 1_599), threshold: 600))
        XCTAssertTrue(snapshot.isStale(now: Date(timeIntervalSince1970: 1_601), threshold: 600))
    }

    func testMalformedAndIrrelevantLinesAreIgnored() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HowmuchusageTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("events.jsonl")
        try """
        not json
        {"timestamp":"2026-05-22T10:00:00.000Z","type":"event_msg","payload":{"type":"token_count"}}
        {"timestamp":"2026-05-22T10:01:00.000Z","type":"event_msg","payload":{"rate_limits":{"limit_id":"codex","primary":{"used_percent":88.0,"window_minutes":300,"resets_at":1779457603},"secondary":{"used_percent":22.0,"window_minutes":10080,"resets_at":1779848664},"plan_type":"prolite","rate_limit_reached_type":null}}}
        """.write(to: file, atomically: true, encoding: .utf8)

        let snapshot = try CodexUsageReader(sessionRoot: root).latestSnapshot()

        XCTAssertEqual(Int(snapshot.primary.usedPercent), 88)
        XCTAssertEqual(snapshot.sourceLine, 3)
    }

    func testReaderFallsBackWhenNewestFileHasNoRateLimits() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HowmuchusageTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let usageFile = root.appendingPathComponent("older-usage.jsonl")
        try """
        {"timestamp":"2026-05-22T10:01:00.000Z","type":"event_msg","payload":{"rate_limits":{"limit_id":"codex","primary":{"used_percent":12.0,"window_minutes":300,"resets_at":1779457603},"secondary":{"used_percent":34.0,"window_minutes":10080,"resets_at":1779848664},"plan_type":"prolite"}}}
        """.write(to: usageFile, atomically: true, encoding: .utf8)

        let newerFile = root.appendingPathComponent("newer-without-usage.jsonl")
        try """
        {"timestamp":"2026-05-22T10:02:00.000Z","type":"event_msg","payload":{"type":"agent_message","message":"not usage"}}
        """.write(to: newerFile, atomically: true, encoding: .utf8)

        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000)],
            ofItemAtPath: usageFile.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000)],
            ofItemAtPath: newerFile.path
        )

        let snapshot = try CodexUsageReader(sessionRoot: root).latestSnapshot()

        XCTAssertEqual(Int(snapshot.primary.usedPercent), 12)
        XCTAssertEqual(Int(snapshot.secondary.usedPercent), 34)
        XCTAssertEqual(
            URL(fileURLWithPath: snapshot.sourceFile).standardizedFileURL,
            usageFile.standardizedFileURL
        )
    }
}
