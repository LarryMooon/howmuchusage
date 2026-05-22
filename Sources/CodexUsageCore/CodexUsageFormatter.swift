import Foundation

public enum CodexUsageFormatter {
    public static let usageURL = URL(string: "https://chatgpt.com/codex/settings/usage")!
    public static let refreshIntervalSeconds: TimeInterval = 60
    public static let staleSnapshotThresholdSeconds: TimeInterval = 600

    public struct UsageLine: Equatable, Sendable {
        public let label: String
        public let usedPercent: Int
        public let remainingPercent: Int
        public let remainingText: String
        public let resetText: String
        public let barText: String
        public let colorName: String

        public var displayLabel: String {
            "~\(label)"
        }

        public var title: String {
            "\(displayLabel) \(remainingPercent)% \(barText)"
        }
    }

    public static func menuTitle(snapshot: CodexUsageSnapshot, now: Date = Date()) -> String {
        let primary = usageLine(label: "5h", window: snapshot.primary, now: now)
        let secondary = usageLine(label: "1w", window: snapshot.secondary, now: now)
        return "\(primary.displayLabel) \(primary.remainingPercent)% · \(secondary.displayLabel) \(secondary.remainingPercent)%"
    }

    public static func menuLines(snapshot: CodexUsageSnapshot, now: Date = Date()) -> [UsageLine] {
        [
            usageLine(label: "5h", window: snapshot.primary, now: now),
            usageLine(label: "1w", window: snapshot.secondary, now: now)
        ]
    }

    public static func swiftBarOutput(snapshot: CodexUsageSnapshot, now: Date = Date()) -> String {
        let output = ProbeOutput(snapshot: snapshot, now: now)
        let lines = menuLines(snapshot: snapshot, now: now)
        let observed = timeFormatter.string(from: output.observedAt)
        let staleLabel = output.stale ? "old local snapshot" : "recent local snapshot"
        let primaryDisplayColor = output.stale ? "gray" : lines[0].colorName
        let secondaryDisplayColor = output.stale ? "gray" : lines[1].colorName

        return """
        \(lines[0].title) | color=\(primaryDisplayColor)
        \(lines[1].title) | color=\(secondaryDisplayColor)
        ---
        5h left: \(lines[0].remainingPercent)%, reset in \(output.primaryRemaining) | color=\(lines[0].colorName)
        5h reset: \(lines[0].resetText)
        Weekly left: \(lines[1].remainingPercent)%, reset in \(output.secondaryRemaining) | color=\(lines[1].colorName)
        Weekly reset: \(lines[1].resetText)
        \(localSnapshotText(observedAt: output.observedAt, now: now)) (\(staleLabel))
        Observed at: \(observed)
        Source: \(URL(fileURLWithPath: output.sourceFile).lastPathComponent):\(output.sourceLine)
        ---
        Open Codex Usage | href=\(usageURL.absoluteString)
        """
    }

    public static func textOutput(snapshot: CodexUsageSnapshot, now: Date = Date()) -> String {
        let output = ProbeOutput(snapshot: snapshot, now: now)
        return """
        Codex remaining
        ~5h left: \(remainingPercent(forUsedPercent: output.primaryUsedPercent))%, reset in \(output.primaryRemaining)
        ~1w left: \(remainingPercent(forUsedPercent: output.secondaryUsedPercent))%, reset in \(output.secondaryRemaining)
        \(localSnapshotText(observedAt: output.observedAt, now: now))
        Observed at: \(dateTimeFormatter.string(from: output.observedAt))
        Source: \(output.sourceFile):\(output.sourceLine)
        """
    }

    public static func remainingText(until target: Date, now: Date = Date()) -> String {
        let remaining = max(0, Int(target.timeIntervalSince(now).rounded()))
        let days = remaining / 86_400
        let hours = (remaining % 86_400) / 3_600
        let minutes = (remaining % 3_600) / 60

        if days > 0 {
            return "\(days)d \(hours)h"
        }

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }

        return "\(minutes)m"
    }

    public static func compactRemainingText(until target: Date, now: Date = Date()) -> String {
        let remaining = max(0, Int(target.timeIntervalSince(now).rounded()))
        let days = remaining / 86_400
        let hours = (remaining % 86_400) / 3_600
        let minutes = (remaining % 3_600) / 60

        if days > 0 {
            return "\(days)d"
        }

        return "\(hours):" + String(format: "%02d", minutes)
    }

    public static func localSnapshotText(observedAt: Date, now: Date = Date()) -> String {
        "Local snapshot · \(ageText(since: observedAt, now: now))"
    }

    public static func ageText(since date: Date, now: Date = Date()) -> String {
        let elapsed = max(0, Int(now.timeIntervalSince(date).rounded()))
        let days = elapsed / 86_400
        let hours = (elapsed % 86_400) / 3_600
        let minutes = (elapsed % 3_600) / 60

        if days > 0 {
            return "\(days)d \(hours)h ago"
        }

        if hours > 0 {
            return "\(hours)h \(minutes)m ago"
        }

        if minutes > 0 {
            return "\(minutes)m ago"
        }

        return "just now"
    }

    public static func usageLine(label: String, window: UsageWindowSnapshot, now: Date = Date()) -> UsageLine {
        let usedPercent = Int(window.usedPercent.rounded())
        let remainingPercent = remainingPercent(forUsedPercent: usedPercent)

        return UsageLine(
            label: label,
            usedPercent: usedPercent,
            remainingPercent: remainingPercent,
            remainingText: remainingText(until: window.resetsAt, now: now),
            resetText: label == "5h" ? timeFormatter.string(from: window.resetsAt) : weekdayFormatter.string(from: window.resetsAt),
            barText: batteryBarText(remainingPercent: remainingPercent),
            colorName: color(forRemainingPercent: remainingPercent)
        )
    }

    public static func remainingPercent(forUsedPercent usedPercent: Int) -> Int {
        max(0, min(100, 100 - usedPercent))
    }

    public static func batteryBarText(remainingPercent: Int, width: Int = 10) -> String {
        let clamped = max(0, min(100, remainingPercent))
        let filled = max(0, min(width, Int((Double(clamped) / 100.0 * Double(width)).rounded())))
        return "[" + String(repeating: "|", count: filled) + String(repeating: "-", count: width - filled) + "]"
    }

    public static func color(forRemainingPercent remainingPercent: Int) -> String {
        switch remainingPercent {
        case ...5:
            return "red"
        case ...10:
            return "yellow"
        default:
            return "green"
        }
    }

    public static var timeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }

    public static var weekdayFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE HH:mm"
        return formatter
    }

    public static var dateTimeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
        return formatter
    }
}
