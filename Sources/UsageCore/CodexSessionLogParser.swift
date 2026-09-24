import Foundation

/// Passive fallback: Codex writes `rate_limits` into
/// `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` while it runs on this Mac.
/// Only the `rate_limits` object is decoded; prompts and responses are skipped
/// before JSON parsing.
public enum CodexSessionLogParser {
    fileprivate struct Line: Decodable {
        struct Payload: Decodable {
            let rate_limits: CodexLogRateLimits?
        }

        let timestamp: String?
        let payload: Payload?
    }

    fileprivate struct CodexLogRateLimits: Decodable {
        struct Window: Decodable {
            let used_percent: Double
            let window_minutes: Int?
            let resets_at: Double?
            let resets_in_seconds: Double?
        }

        let primary: Window?
        let secondary: Window?
        let plan_type: String?
    }

    private static let marker = Data("\"rate_limits\"".utf8)

    /// Newest snapshot in one JSONL file, judged by each line's timestamp.
    public static func latestSnapshot(inJSONLines data: Data) -> UsageSnapshot? {
        var best: UsageSnapshot?
        let decoder = JSONDecoder()

        for rawLine in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard rawLine.range(of: marker) != nil,
                  let line = try? decoder.decode(Line.self, from: Data(rawLine)),
                  let limits = line.payload?.rate_limits,
                  let timestamp = line.timestamp.flatMap(ISO8601.parse) else {
                continue
            }

            var windows: [UsageWindow] = []
            if let primary = limits.primary {
                windows.append(window(primary, fallback: .session, observedAt: timestamp))
            }
            if let secondary = limits.secondary {
                windows.append(window(secondary, fallback: .weekly, observedAt: timestamp))
            }
            guard !windows.isEmpty else { continue }

            let snapshot = UsageSnapshot(
                provider: .codex,
                windows: windows,
                planName: PlanNames.display(limits.plan_type),
                source: .codexSessionLog,
                observedAt: timestamp
            )
            if best == nil || snapshot.observedAt >= best!.observedAt {
                best = snapshot
            }
        }
        return best
    }

    fileprivate static func window(_ window: CodexLogRateLimits.Window, fallback: WindowKind, observedAt: Date) -> UsageWindow {
        let resetsAt: Date?
        if let epoch = window.resets_at {
            resetsAt = Date(timeIntervalSince1970: epoch)
        } else if let seconds = window.resets_in_seconds {
            resetsAt = observedAt.addingTimeInterval(seconds)
        } else {
            resetsAt = nil
        }
        return UsageWindow(
            kind: UsageWindow.kind(forDurationMinutes: window.window_minutes, fallback: fallback),
            usedPercent: window.used_percent,
            resetsAt: resetsAt,
            durationMinutes: window.window_minutes
        )
    }
}
