import Foundation

/// Parses `GET https://api.anthropic.com/api/oauth/usage`.
///
/// This endpoint is not publicly documented. The parser is deliberately
/// schema-tolerant: every top-level object carrying a `utilization` number is
/// treated as a quota window, so new per-model caps show up without code changes.
///
/// Known shape (2026):
/// `{"five_hour":{"utilization":33.0,"resets_at":"2026-04-11T07:00:00.528743+00:00"},
///   "seven_day":{...}, "seven_day_opus":null, "seven_day_sonnet":{...},
///   "extra_usage":{"is_enabled":false,"monthly_limit":null,"used_credits":null,"utilization":null}}`
public enum ClaudeOAuthUsageParser {
    public enum ParseError: Error, Equatable {
        case notJSONObject
        case noWindows
    }

    public static func snapshot(
        from data: Data,
        planName: String?,
        observedAt: Date
    ) throws -> UsageSnapshot {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError.notJSONObject
        }

        // 2026 shape: a `limits` array with explicit kinds and scopes (this is
        // where per-model caps such as Fable live). Older top-level windows
        // fill in only kinds the array does not cover.
        var windows = limitsArrayWindows(object["limits"])
        var legacy: [UsageWindow] = []
        collectWindows(in: object, path: [], depth: 0, into: &legacy)
        for window in legacy where !windows.contains(where: { $0.kind == window.kind }) {
            windows.append(window)
        }
        guard !windows.isEmpty else { throw ParseError.noWindows }
        windows.sort { order($0.kind) < order($1.kind) }

        var notes: [String] = []
        if let extra = object["extra_usage"] as? [String: Any], extra["is_enabled"] as? Bool == true {
            if let utilization = JSONValue.double(extra["utilization"]) {
                notes.append("Extra usage on · \(Int(utilization.rounded()))% of monthly limit used")
            } else {
                notes.append("Extra usage on")
            }
        }

        return UsageSnapshot(
            provider: .claude,
            windows: windows,
            planName: planName,
            source: .claudeOAuth,
            observedAt: observedAt,
            notes: notes
        )
    }

    /// Parses `limits: [{kind, percent, resets_at, scope: {model: {display_name}}}]`.
    static func limitsArrayWindows(_ value: Any?) -> [UsageWindow] {
        guard let items = value as? [[String: Any]] else { return [] }
        return items.compactMap { (item: [String: Any]) -> UsageWindow? in
            guard let percent = JSONValue.double(item["percent"] ?? item["utilization"]) else { return nil }
            let kindName = (item["kind"] as? String) ?? ""
            let kind: WindowKind
            switch kindName {
            case "session":
                kind = .session
            case "weekly_all", "weekly":
                kind = .weekly
            default:
                let scope = item["scope"] as? [String: Any]
                let label = scopeLabel(scope?["model"]) ?? scopeLabel(scope?["surface"])
                if kindName.hasPrefix("weekly") {
                    kind = .weeklyModel(prettyName(label ?? kindName))
                } else {
                    kind = .other(prettyName(label ?? kindName))
                }
            }
            let isWeekly = kindName.hasPrefix("weekly")
            return UsageWindow(
                kind: kind,
                usedPercent: percent,
                resetsAt: JSONValue.date(item["resets_at"]),
                durationMinutes: kindName == "session" ? 300 : (isWeekly ? 10_080 : nil)
            )
        }
    }

    static func scopeLabel(_ value: Any?) -> String? {
        if let string = value as? String, !string.isEmpty { return string }
        guard let object = value as? [String: Any] else { return nil }
        return labelValue(object) ?? (object["id"] as? String)
    }

    /// Keys that carry percentages but are not quota windows.
    static let ignoredKeys: Set<String> = ["extra_usage", "limits", "seven_day_breakdown", "spend"]

    static let utilizationKeys = ["utilization", "used_percentage", "used_percent", "percent_used"]
    static let labelKeys = ["display_name", "displayName", "name", "model", "label"]

    /// Walks the response: any object with a utilization number is a window.
    /// Nested objects and arrays (e.g. per-model limits) are searched too.
    static func collectWindows(in object: [String: Any], path: [String], depth: Int, into windows: inout [UsageWindow]) {
        guard depth <= 3 else { return }
        for key in object.keys.sorted() where !ignoredKeys.contains(key) {
            let childPath = path + [key]
            if let entry = object[key] as? [String: Any] {
                if let window = window(from: entry, path: childPath) {
                    windows.append(window)
                } else {
                    collectWindows(in: entry, path: childPath, depth: depth + 1, into: &windows)
                }
            } else if let items = object[key] as? [[String: Any]] {
                for (index, item) in items.enumerated() {
                    let itemPath = childPath + [labelValue(item) ?? String(index)]
                    if let window = window(from: item, path: itemPath) {
                        windows.append(window)
                    } else {
                        collectWindows(in: item, path: itemPath, depth: depth + 1, into: &windows)
                    }
                }
            }
        }
    }

    static func window(from entry: [String: Any], path: [String]) -> UsageWindow? {
        guard let utilization = utilizationKeys.lazy.compactMap({ JSONValue.double(entry[$0]) }).first else {
            return nil
        }
        return UsageWindow(
            kind: kind(forPath: path, label: labelValue(entry)),
            usedPercent: utilization,
            resetsAt: JSONValue.date(entry["resets_at"] ?? entry["resetsAt"]),
            durationMinutes: durationMinutes(forPath: path)
        )
    }

    static func labelValue(_ entry: [String: Any]) -> String? {
        labelKeys.lazy.compactMap { entry[$0] as? String }.first { !$0.isEmpty }
    }

    static func kind(forPath path: [String], label: String? = nil) -> WindowKind {
        let joined = path.joined(separator: "_")
        if path == ["five_hour"] { return .session }
        if path == ["seven_day"] { return .weekly }
        if joined.hasPrefix("seven_day") || joined.contains("weekly") {
            if let label { return .weeklyModel(prettyName(label)) }
            var model = path.last ?? joined
            if model.hasPrefix("seven_day_") { model = String(model.dropFirst("seven_day_".count)) }
            return .weeklyModel(prettyName(model))
        }
        return .other(prettyName(label ?? joined))
    }

    static func kind(forKey key: String) -> WindowKind {
        kind(forPath: [key])
    }

    static func durationMinutes(forPath path: [String]) -> Int? {
        let joined = path.joined(separator: "_")
        if joined.hasPrefix("five_hour") { return 300 }
        if joined.hasPrefix("seven_day") || joined.contains("weekly") { return 10_080 }
        return nil
    }

    static func prettyName(_ raw: String) -> String {
        raw.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == " " })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private static func order(_ kind: WindowKind) -> Int {
        switch kind {
        case .session: return 0
        case .weekly: return 1
        case .weeklyModel: return 2
        case .other: return 3
        }
    }
}

/// Claude Code's stored OAuth login (Keychain item `Claude Code-credentials`
/// or `~/.claude/.credentials.json`). Only the fields needed to read usage.
public struct ClaudeCredentials: Equatable, Sendable {
    public var accessToken: String
    public var expiresAt: Date?
    public var subscriptionType: String?
    public var scopes: [String]

    public init(accessToken: String, expiresAt: Date?, subscriptionType: String?, scopes: [String]) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.subscriptionType = subscriptionType
        self.scopes = scopes
    }

    public enum ParseError: Error, Equatable {
        case notJSON
        case missingAccessToken
    }

    public static func parse(_ data: Data) throws -> ClaudeCredentials {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError.notJSON
        }
        let oauth = root["claudeAiOauth"] as? [String: Any] ?? root
        guard let token = oauth["accessToken"] as? String, !token.isEmpty else {
            throw ParseError.missingAccessToken
        }
        // expiresAt is epoch milliseconds.
        let expiresAt = JSONValue.double(oauth["expiresAt"]).map { value in
            Date(timeIntervalSince1970: value > 10_000_000_000 ? value / 1_000 : value)
        }
        return ClaudeCredentials(
            accessToken: token,
            expiresAt: expiresAt,
            subscriptionType: oauth["subscriptionType"] as? String,
            scopes: oauth["scopes"] as? [String] ?? []
        )
    }

    /// Treat tokens as expired slightly early to avoid racing the server.
    public func isExpired(now: Date, margin: TimeInterval = 60) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.addingTimeInterval(-margin) <= now
    }
}

/// Claude Code statusline input (officially documented). Only `rate_limits`
/// is ever read or persisted; session fields such as paths are ignored.
public enum ClaudeStatuslineParser {
    /// Extracts the `rate_limits` object from raw statusline stdin JSON.
    public static func rateLimits(fromStatuslineInput data: Data) -> [String: Any]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = object["rate_limits"] as? [String: Any],
              !limits.isEmpty else {
            return nil
        }
        return limits
    }

    /// Bridge file written by Howmuchusage: `{"observed_at": <epoch>, "rate_limits": {...}}`.
    public static func bridgeFileData(rateLimits: [String: Any], observedAt: Date) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: ["observed_at": observedAt.timeIntervalSince1970, "rate_limits": rateLimits],
            options: [.sortedKeys]
        )
    }

    /// True when the stored bridge file already holds these exact values.
    public static func bridgeFile(_ data: Data?, hasSameRateLimitsAs limits: [String: Any]) -> Bool {
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stored = object["rate_limits"] as? [String: Any] else {
            return false
        }
        return NSDictionary(dictionary: stored).isEqual(to: limits)
    }

    public static func snapshot(fromBridgeFile data: Data) -> UsageSnapshot? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let observed = JSONValue.double(object["observed_at"]),
              let limits = object["rate_limits"] as? [String: Any] else {
            return nil
        }

        var windows: [UsageWindow] = []
        let mapping: [(String, WindowKind, Int)] = [("five_hour", .session, 300), ("seven_day", .weekly, 10_080)]
        for (key, kind, minutes) in mapping {
            guard let entry = limits[key] as? [String: Any],
                  let used = JSONValue.double(entry["used_percentage"]) else { continue }
            windows.append(
                UsageWindow(
                    kind: kind,
                    usedPercent: used,
                    resetsAt: JSONValue.double(entry["resets_at"]).map { Date(timeIntervalSince1970: $0) },
                    durationMinutes: minutes
                )
            )
        }
        guard !windows.isEmpty else { return nil }

        return UsageSnapshot(
            provider: .claude,
            windows: windows,
            source: .claudeStatusline,
            observedAt: Date(timeIntervalSince1970: observed)
        )
    }

    /// Default one-line status text used when the user had no statusline before.
    public static func defaultStatusText(rateLimits: [String: Any]?) -> String {
        guard let rateLimits else { return "" }
        var parts: [String] = []
        for (key, label) in [("five_hour", "5h"), ("seven_day", "7d")] {
            if let entry = rateLimits[key] as? [String: Any], let used = JSONValue.double(entry["used_percentage"]) {
                let remaining = Int(max(0, min(100, 100 - used.rounded())))
                parts.append("\(label) \(remaining)% left")
            }
        }
        return parts.joined(separator: " · ")
    }
}

public enum JSONValue {
    public static func double(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            // Booleans are NSNumbers too; they are never quota values.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
            return number.doubleValue
        case let double as Double:
            return double
        case let int as Int:
            return Double(int)
        case let string as String:
            return Double(string)
        default:
            return nil
        }
    }

    /// Accepts ISO-8601 strings (any fractional-second precision) or epoch seconds.
    public static func date(_ value: Any?) -> Date? {
        if let string = value as? String {
            return ISO8601.parse(string)
        }
        if let seconds = double(value) {
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }
}

public enum ISO8601 {
    /// Foundation's ISO8601DateFormatter rejects some fractional-second
    /// precisions (e.g. microseconds), so the fraction is split off first.
    public static func parse(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        var base = trimmed
        var fraction: Double = 0

        if let dot = trimmed.firstIndex(of: "."), let tIndex = trimmed.firstIndex(of: "T"), dot > tIndex {
            let afterDot = trimmed[trimmed.index(after: dot)...]
            let digits = afterDot.prefix { $0.isNumber }
            let zone = afterDot.dropFirst(digits.count)
            fraction = Double("0.\(digits)") ?? 0
            base = String(trimmed[..<dot]) + zone
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: base) else { return nil }
        return date.addingTimeInterval(fraction)
    }
}
