import Foundation

/// How much the displayed value can be trusted right now.
public enum Freshness: String, Equatable, Sendable {
    /// Polling is healthy; the value is as current as the server allows.
    case live
    /// A few minutes old (missed polls, passive source). Shown with `~`.
    case recent
    /// Too old to trust. Shown gray with `~`.
    case stale

    public static let staleAfter: TimeInterval = 900

    public static func evaluate(
        observedAt: Date,
        now: Date,
        liveWindow: TimeInterval,
        staleAfter: TimeInterval = Freshness.staleAfter
    ) -> Freshness {
        let age = now.timeIntervalSince(observedAt)
        if age <= liveWindow { return .live }
        if age <= staleAfter { return .recent }
        return .stale
    }

    public var label: String {
        switch self {
        case .live: return "Live"
        case .recent: return "Recent"
        case .stale: return "Old"
        }
    }
}

public enum UsageLevel: String, Equatable, Sendable {
    case good
    case warning
    case critical
    case stale

    /// Remaining-quota thresholds kept from v0.1: ≤5% red, ≤10% yellow.
    public static func forRemaining(_ remaining: Int) -> UsageLevel {
        switch remaining {
        case ...5: return .critical
        case ...10: return .warning
        default: return .good
        }
    }
}

/// One rendered row: `5h [bar] 64%`.
public struct DisplayLine: Equatable, Sendable {
    public let label: String
    /// `nil` when the current value is unknown (the window reset after the
    /// last observation and no fresh read has arrived yet).
    public let remainingPercent: Int?
    /// Shown with a `~` prefix: not a live value.
    public let isApproximate: Bool
    /// The window reset after the last observation.
    public let isResetPassed: Bool
    public let level: UsageLevel
    public let resetsAt: Date?

    public var displayLabel: String {
        isApproximate ? "~\(label)" : label
    }

    public var percentText: String {
        remainingPercent.map { "\($0)%" } ?? "--"
    }
}

public enum UsageDisplay {
    /// A reset this recent, seen from a non-stale value, is assumed to have
    /// restored the full quota until the next read confirms it. Older resets
    /// say nothing about current usage, so the value becomes unknown.
    public static let resetInferenceGrace: TimeInterval = 300

    public static func line(
        for window: UsageWindow,
        freshness: Freshness,
        now: Date
    ) -> DisplayLine {
        let resetPassed = window.isResetPassed(now: now)
        let remaining: Int?
        if resetPassed {
            let sinceReset = window.resetsAt.map { now.timeIntervalSince($0) } ?? .infinity
            remaining = (freshness != .stale && sinceReset <= resetInferenceGrace) ? 100 : nil
        } else {
            remaining = window.remainingPercent
        }

        let level: UsageLevel
        if freshness == .stale || remaining == nil {
            level = .stale
        } else {
            level = .forRemaining(remaining ?? 0)
        }

        return DisplayLine(
            label: window.shortLabel,
            remainingPercent: remaining,
            isApproximate: resetPassed || freshness != .live,
            isResetPassed: resetPassed,
            level: level,
            resetsAt: window.resetsAt
        )
    }

    /// The two headline rows (session, weekly). Missing windows are skipped.
    public static func headlineLines(
        for snapshot: UsageSnapshot,
        freshness: Freshness,
        now: Date
    ) -> [DisplayLine] {
        [snapshot.session, snapshot.weekly]
            .compactMap { $0 }
            .map { line(for: $0, freshness: freshness, now: now) }
    }
}

public enum UsageFormat {
    public static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "<1m"
    }

    public static func timeUntil(_ date: Date?, now: Date) -> String {
        guard let date else { return "unknown" }
        if date <= now { return "now" }
        return duration(date.timeIntervalSince(now))
    }

    public static func age(since date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 10 { return "just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3_600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3_600)h ago" }
        return "\(seconds / 86_400)d ago"
    }

    public static func resetTime(_ date: Date?, calendar: Calendar = .current) -> String {
        guard let date else { return "unknown" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = calendar.isDateInToday(date) ? "HH:mm" : "EEE HH:mm"
        return formatter.string(from: date)
    }
}
