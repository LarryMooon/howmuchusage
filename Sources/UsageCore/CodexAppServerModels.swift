import Foundation

// Wire types for `codex app-server` (protocol v2), trimmed to the fields this
// app reads. Every field is optional so schema additions never break decoding.
// Reference: openai/codex codex-rs/app-server-protocol/schema/typescript/v2.

public struct CodexRateLimitWindowDTO: Codable, Equatable, Sendable {
    public var usedPercent: Double
    public var windowDurationMins: Int?
    /// Unix epoch seconds.
    public var resetsAt: Double?

    public init(usedPercent: Double, windowDurationMins: Int?, resetsAt: Double?) {
        self.usedPercent = usedPercent
        self.windowDurationMins = windowDurationMins
        self.resetsAt = resetsAt
    }
}

public struct CodexCreditsDTO: Codable, Equatable, Sendable {
    public var hasCredits: Bool?
    public var unlimited: Bool?
    public var balance: String?
}

public struct CodexRateLimitSnapshotDTO: Codable, Equatable, Sendable {
    public var limitId: String?
    public var limitName: String?
    public var primary: CodexRateLimitWindowDTO?
    public var secondary: CodexRateLimitWindowDTO?
    public var credits: CodexCreditsDTO?
    public var planType: String?
    public var rateLimitReachedType: String?

    public init(
        limitId: String? = nil,
        limitName: String? = nil,
        primary: CodexRateLimitWindowDTO? = nil,
        secondary: CodexRateLimitWindowDTO? = nil,
        credits: CodexCreditsDTO? = nil,
        planType: String? = nil,
        rateLimitReachedType: String? = nil
    ) {
        self.limitId = limitId
        self.limitName = limitName
        self.primary = primary
        self.secondary = secondary
        self.credits = credits
        self.planType = planType
        self.rateLimitReachedType = rateLimitReachedType
    }

    /// `account/rateLimits/updated` is sparse: available values override,
    /// missing values keep what the last full read returned.
    public func merging(_ update: CodexRateLimitSnapshotDTO) -> CodexRateLimitSnapshotDTO {
        CodexRateLimitSnapshotDTO(
            limitId: update.limitId ?? limitId,
            limitName: update.limitName ?? limitName,
            primary: update.primary ?? primary,
            secondary: update.secondary ?? secondary,
            credits: update.credits ?? credits,
            planType: update.planType ?? planType,
            rateLimitReachedType: update.rateLimitReachedType ?? rateLimitReachedType
        )
    }
}

/// Result of `account/rateLimits/read`.
public struct CodexRateLimitsResponseDTO: Codable, Equatable, Sendable {
    public var rateLimits: CodexRateLimitSnapshotDTO?
    public var rateLimitsByLimitId: [String: CodexRateLimitSnapshotDTO?]?
    public var ordinaryUsageAllowed: Bool?
    public var accountId: String?

    public static let codexLimitId = "codex"

    /// Prefers the metered `codex` bucket, falling back to the single view.
    public var codexSnapshot: CodexRateLimitSnapshotDTO? {
        if let bucket = rateLimitsByLimitId?[Self.codexLimitId], let bucket {
            return bucket
        }
        return rateLimits
    }
}

/// Params of the `account/rateLimits/updated` notification.
public struct CodexRateLimitsUpdatedDTO: Codable, Equatable, Sendable {
    public var rateLimits: CodexRateLimitSnapshotDTO
}

/// Result of `account/read`.
public struct CodexAccountResponseDTO: Codable, Equatable, Sendable {
    public struct Account: Codable, Equatable, Sendable {
        public var type: String
        public var email: String?
        public var planType: String?
    }

    public var account: Account?
    public var requiresOpenaiAuth: Bool?
}

/// Result of `account/login/start`.
public struct CodexLoginStartDTO: Codable, Equatable, Sendable {
    public var type: String
    public var loginId: String?
    public var authUrl: String?
    public var verificationUrl: String?
    public var userCode: String?
}

/// Params of `account/login/completed`.
public struct CodexLoginCompletedDTO: Codable, Equatable, Sendable {
    public var loginId: String?
    public var success: Bool
    public var error: String?
}

public enum CodexUsageMapper {
    public static func snapshot(
        from dto: CodexRateLimitSnapshotDTO,
        account: CodexAccountResponseDTO.Account?,
        source: SourceKind = .codexAppServer,
        observedAt: Date
    ) -> UsageSnapshot {
        var windows: [UsageWindow] = []
        if let primary = dto.primary {
            windows.append(window(from: primary, fallback: .session))
        }
        if let secondary = dto.secondary {
            windows.append(window(from: secondary, fallback: .weekly))
        }

        var notes: [String] = []
        if let credits = dto.credits {
            if credits.unlimited == true {
                notes.append("Unlimited credits")
            } else if credits.hasCredits == true, let balance = credits.balance {
                notes.append("Credits: \(balance)")
            }
        }
        if let reached = dto.rateLimitReachedType, !reached.isEmpty {
            notes.append("Limit reached: \(reached)")
        }

        return UsageSnapshot(
            provider: .codex,
            windows: windows,
            planName: PlanNames.display(dto.planType ?? account?.planType),
            accountLabel: account?.email,
            source: source,
            observedAt: observedAt,
            notes: notes
        )
    }

    static func window(from dto: CodexRateLimitWindowDTO, fallback: WindowKind) -> UsageWindow {
        UsageWindow(
            kind: UsageWindow.kind(forDurationMinutes: dto.windowDurationMins, fallback: fallback),
            usedPercent: dto.usedPercent,
            resetsAt: dto.resetsAt.map { Date(timeIntervalSince1970: $0) },
            durationMinutes: dto.windowDurationMins
        )
    }
}
