import Foundation

public enum Provider: String, Codable, CaseIterable, Hashable, Sendable {
    case claude
    case codex

    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }

    /// Two-letter tag drawn next to each menu bar block.
    public var shortTag: String {
        switch self {
        case .claude: return "CL"
        case .codex: return "CX"
        }
    }

    /// Official usage page, the fallback source of truth.
    public var usageURL: URL {
        switch self {
        case .claude: return URL(string: "https://claude.ai/settings/usage")!
        case .codex: return URL(string: "https://chatgpt.com/codex/settings/usage")!
        }
    }
}

public enum WindowKind: Codable, Hashable, Sendable {
    /// Rolling short window (5 hours for both providers today).
    case session
    /// Rolling weekly window.
    case weekly
    /// Model-specific weekly cap, e.g. Claude "Opus" or "Sonnet".
    case weeklyModel(String)
    case other(String)
}

public struct UsageWindow: Codable, Hashable, Sendable {
    public var kind: WindowKind
    /// 0–100 as reported by the server. Can exceed 100 for spend-style limits.
    public var usedPercent: Double
    public var resetsAt: Date?
    public var durationMinutes: Int?

    public init(kind: WindowKind, usedPercent: Double, resetsAt: Date?, durationMinutes: Int? = nil) {
        self.kind = kind
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.durationMinutes = durationMinutes
    }

    /// Visible numbers are always remaining quota, never used quota.
    public var remainingPercent: Int {
        let remaining = 100 - usedPercent.rounded()
        return Int(max(0, min(100, remaining)))
    }

    public func isResetPassed(now: Date) -> Bool {
        guard let resetsAt else { return false }
        return resetsAt <= now
    }

    public var shortLabel: String {
        switch kind {
        case .session:
            return durationMinutes.map(Self.durationLabel(minutes:)) ?? "5h"
        case .weekly:
            return "1w"
        case .weeklyModel(let name):
            return name
        case .other(let name):
            return durationMinutes.map(Self.durationLabel(minutes:)) ?? name
        }
    }

    /// Per-model weekly caps are shown in the app; other API-specific
    /// windows (often internal codenames) are only listed by the probe.
    public var isNamedModelLimit: Bool {
        if case .weeklyModel = kind { return true }
        return false
    }

    public var title: String {
        switch kind {
        case .session: return "\(shortLabel) session"
        case .weekly: return "Weekly"
        case .weeklyModel(let name): return "Weekly · \(name)"
        case .other(let name): return name
        }
    }

    public static func durationLabel(minutes: Int) -> String {
        if minutes >= 10_080, minutes % 10_080 == 0 { return "\(minutes / 10_080)w" }
        if minutes >= 1_440, minutes % 1_440 == 0 { return "\(minutes / 1_440)d" }
        if minutes >= 60, minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }

    /// Classifies a window from its duration when the source does not name it.
    public static func kind(forDurationMinutes minutes: Int?, fallback: WindowKind) -> WindowKind {
        guard let minutes else { return fallback }
        if minutes <= 24 * 60 { return .session }
        if minutes >= 6 * 24 * 60, minutes <= 8 * 24 * 60 { return .weekly }
        return .other(durationLabel(minutes: minutes))
    }
}

public enum SourceKind: String, Codable, Hashable, Sendable {
    case codexAppServer
    case codexSessionLog
    case claudeOAuth
    case claudeStatusline

    public var displayName: String {
        switch self {
        case .codexAppServer: return "app-server"
        case .codexSessionLog: return "local Codex log"
        case .claudeOAuth: return "account usage API"
        case .claudeStatusline: return "Claude Code statusline"
        }
    }

    /// True when the source asks the server for the whole account right now.
    /// Passive sources only change when a tool runs on this Mac.
    public var isActiveAccountQuery: Bool {
        switch self {
        case .codexAppServer, .claudeOAuth: return true
        case .codexSessionLog, .claudeStatusline: return false
        }
    }
}

public struct UsageSnapshot: Codable, Equatable, Sendable {
    public var provider: Provider
    public var windows: [UsageWindow]
    public var planName: String?
    public var accountLabel: String?
    public var source: SourceKind
    /// When the server-reported values were observed (fetch time for live
    /// queries, log time for passive sources).
    public var observedAt: Date
    /// Short extra facts such as credit balance or extra-usage state.
    public var notes: [String]
    /// Dollar-denominated balances (e.g. Claude cloud session credits).
    public var credits: [CreditBalance]

    public init(
        provider: Provider,
        windows: [UsageWindow],
        planName: String? = nil,
        accountLabel: String? = nil,
        source: SourceKind,
        observedAt: Date,
        notes: [String] = [],
        credits: [CreditBalance] = []
    ) {
        self.provider = provider
        self.windows = windows
        self.planName = planName
        self.accountLabel = accountLabel
        self.source = source
        self.observedAt = observedAt
        self.notes = notes
        self.credits = credits
    }

    public func window(_ kind: WindowKind) -> UsageWindow? {
        windows.first { $0.kind == kind }
    }

    public var session: UsageWindow? { window(.session) }
    public var weekly: UsageWindow? { window(.weekly) }

    /// Windows other than the two headline rows.
    public var extraWindows: [UsageWindow] {
        windows.filter { $0.kind != .session && $0.kind != .weekly }
    }

    /// True when the quota numbers (not metadata) differ.
    public func hasDifferentUsage(than other: UsageSnapshot?) -> Bool {
        guard let other else { return true }
        let lhs = windows.map { [$0.usedPercent, $0.resetsAt?.timeIntervalSince1970 ?? 0] }
        let rhs = other.windows.map { [$0.usedPercent, $0.resetsAt?.timeIntervalSince1970 ?? 0] }
        return lhs != rhs
    }

    /// All sources report server-side values, so the most recently observed
    /// one wins. Ties go to active account queries.
    public static func newest(_ candidates: [UsageSnapshot?]) -> UsageSnapshot? {
        candidates.compactMap { $0 }.max { lhs, rhs in
            if lhs.observedAt != rhs.observedAt {
                return lhs.observedAt < rhs.observedAt
            }
            return !lhs.source.isActiveAccountQuery && rhs.source.isActiveAccountQuery
        }
    }
}

public enum PlanNames {
    public static func display(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, raw != "unknown" else { return nil }
        switch raw.lowercased() {
        case "prolite": return "Pro Lite"
        case "max": return "Max"
        case "pro": return "Pro"
        case "plus": return "Plus"
        case "free": return "Free"
        default:
            return raw
                .replacingOccurrences(of: "_", with: " ")
                .split(separator: " ")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }
}

/// A prepaid or included dollar balance with an expiry.
public struct CreditBalance: Codable, Hashable, Sendable {
    public var name: String
    public var limitDollars: Double
    public var remainingDollars: Double
    public var expiresAt: Date?

    public init(name: String, limitDollars: Double, remainingDollars: Double, expiresAt: Date?) {
        self.name = name
        self.limitDollars = limitDollars
        self.remainingDollars = remainingDollars
        self.expiresAt = expiresAt
    }

    public var remainingPercent: Int {
        guard limitDollars > 0 else { return 0 }
        return Int(max(0, min(100, (remainingDollars / limitDollars * 100).rounded())))
    }

    public var amountText: String {
        String(format: "$%.2f of $%.0f left", remainingDollars, limitDollars)
    }
}
