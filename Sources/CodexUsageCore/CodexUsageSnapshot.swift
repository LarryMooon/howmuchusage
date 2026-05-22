import Foundation

public struct UsageWindowSnapshot: Codable, Equatable, Sendable {
    public let usedPercent: Double
    public let windowMinutes: Int
    public let resetsAt: Date

    public init(usedPercent: Double, windowMinutes: Int, resetsAt: Date) {
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
    }
}

public struct CodexUsageSnapshot: Codable, Equatable, Sendable {
    public let primary: UsageWindowSnapshot
    public let secondary: UsageWindowSnapshot
    public let planType: String?
    public let limitID: String?
    public let rateLimitReachedType: String?
    public let observedAt: Date
    public let sourceFile: String
    public let sourceLine: Int

    public init(
        primary: UsageWindowSnapshot,
        secondary: UsageWindowSnapshot,
        planType: String?,
        limitID: String?,
        rateLimitReachedType: String?,
        observedAt: Date,
        sourceFile: String,
        sourceLine: Int
    ) {
        self.primary = primary
        self.secondary = secondary
        self.planType = planType
        self.limitID = limitID
        self.rateLimitReachedType = rateLimitReachedType
        self.observedAt = observedAt
        self.sourceFile = sourceFile
        self.sourceLine = sourceLine
    }

    public func isStale(now: Date = Date(), threshold: TimeInterval = 600) -> Bool {
        now.timeIntervalSince(observedAt) > threshold
    }
}

public struct ProbeOutput: Codable, Equatable, Sendable {
    public let primaryUsedPercent: Int
    public let primaryWindowMinutes: Int
    public let primaryResetAt: Date
    public let primaryRemaining: String
    public let secondaryUsedPercent: Int
    public let secondaryWindowMinutes: Int
    public let secondaryResetAt: Date
    public let secondaryRemaining: String
    public let planType: String?
    public let stale: Bool
    public let observedAt: Date
    public let sourceFile: String
    public let sourceLine: Int

    public init(snapshot: CodexUsageSnapshot, now: Date = Date()) {
        self.primaryUsedPercent = Int(snapshot.primary.usedPercent.rounded())
        self.primaryWindowMinutes = snapshot.primary.windowMinutes
        self.primaryResetAt = snapshot.primary.resetsAt
        self.primaryRemaining = CodexUsageFormatter.remainingText(until: snapshot.primary.resetsAt, now: now)
        self.secondaryUsedPercent = Int(snapshot.secondary.usedPercent.rounded())
        self.secondaryWindowMinutes = snapshot.secondary.windowMinutes
        self.secondaryResetAt = snapshot.secondary.resetsAt
        self.secondaryRemaining = CodexUsageFormatter.remainingText(until: snapshot.secondary.resetsAt, now: now)
        self.planType = snapshot.planType
        self.stale = snapshot.isStale(now: now)
        self.observedAt = snapshot.observedAt
        self.sourceFile = snapshot.sourceFile
        self.sourceLine = snapshot.sourceLine
    }
}

