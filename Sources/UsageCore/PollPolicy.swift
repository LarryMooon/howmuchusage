import Foundation

/// How often each provider is asked for fresh usage, and how failures back off.
public struct PollPolicy: Equatable, Sendable {
    /// Interval while usage is changing (someone is actively using the tool).
    public var active: TimeInterval
    /// Normal interval.
    public var base: TimeInterval
    /// Interval after usage has been flat for `idleAfter`.
    public var idle: TimeInterval
    /// Lower bound between any two requests, manual refreshes included.
    public var minimumSpacing: TimeInterval
    public var backoffStart: TimeInterval
    public var backoffMax: TimeInterval
    /// Lower bound for a server "slow down" (HTTP 429) without Retry-After.
    public var rateLimitedMinimum: TimeInterval
    public var activeWindow: TimeInterval
    public var idleAfter: TimeInterval

    public init(
        active: TimeInterval,
        base: TimeInterval,
        idle: TimeInterval,
        minimumSpacing: TimeInterval,
        backoffStart: TimeInterval = 30,
        backoffMax: TimeInterval = 900,
        rateLimitedMinimum: TimeInterval = 300,
        activeWindow: TimeInterval = 600,
        idleAfter: TimeInterval = 1_800
    ) {
        self.active = active
        self.base = base
        self.idle = idle
        self.minimumSpacing = minimumSpacing
        self.backoffStart = backoffStart
        self.backoffMax = backoffMax
        self.rateLimitedMinimum = rateLimitedMinimum
        self.activeWindow = activeWindow
        self.idleAfter = idleAfter
    }

    /// app-server reads are cheap and do not consume quota.
    public static let codex = PollPolicy(active: 30, base: 60, idle: 120, minimumSpacing: 10)

    /// The Claude usage endpoint is unofficial and rate limits aggressive
    /// clients, so it is polled more conservatively.
    public static let claude = PollPolicy(active: 60, base: 120, idle: 300, minimumSpacing: 45)

    public static func `for`(_ provider: Provider) -> PollPolicy {
        switch provider {
        case .claude: return .claude
        case .codex: return .codex
        }
    }

    /// A value observed within this age counts as live: polling is healthy.
    public var liveWindow: TimeInterval { idle + 60 }

    public func nextDelay(for state: PollState, now: Date) -> TimeInterval {
        var delay: TimeInterval
        if state.consecutiveFailures > 0 {
            let exponent = Double(min(state.consecutiveFailures - 1, 10))
            delay = min(backoffMax, backoffStart * pow(2, exponent))
        } else if let changed = state.lastChangeAt, now.timeIntervalSince(changed) <= activeWindow {
            delay = active
        } else if let reference = state.lastChangeAt ?? state.firstSuccessAt,
                  now.timeIntervalSince(reference) >= idleAfter {
            delay = idle
        } else {
            delay = base
        }

        if let until = state.retryAfterUntil {
            delay = max(delay, until.timeIntervalSince(now))
        }
        return max(delay, minimumSpacing)
    }

    /// Seconds to wait before an out-of-schedule request is allowed.
    public func waitBeforeManualRequest(state: PollState, now: Date) -> TimeInterval {
        var wait: TimeInterval = 0
        if let last = state.lastAttemptAt {
            wait = max(wait, minimumSpacing - now.timeIntervalSince(last))
        }
        if let until = state.retryAfterUntil {
            wait = max(wait, until.timeIntervalSince(now))
        }
        return max(0, wait)
    }

    /// Spreads requests by ±fraction so wake-ups do not line up. `unit` is 0...1.
    public static func jitter(_ delay: TimeInterval, fraction: Double = 0.1, unit: Double) -> TimeInterval {
        let clamped = max(0, min(1, unit))
        return delay * (1 + fraction * (2 * clamped - 1))
    }
}

/// Mutable bookkeeping the scheduler keeps per provider.
public struct PollState: Equatable, Sendable {
    public var lastAttemptAt: Date?
    public var lastSuccessAt: Date?
    public var firstSuccessAt: Date?
    public var lastChangeAt: Date?
    public var consecutiveFailures: Int
    public var retryAfterUntil: Date?

    public init() {
        consecutiveFailures = 0
    }

    public mutating func recordAttempt(at date: Date) {
        lastAttemptAt = date
    }

    public mutating func recordSuccess(at date: Date, usageChanged: Bool) {
        lastSuccessAt = date
        if firstSuccessAt == nil { firstSuccessAt = date }
        if usageChanged { lastChangeAt = date }
        consecutiveFailures = 0
        retryAfterUntil = nil
    }

    public mutating func recordFailure(at date: Date, retryAfter: TimeInterval? = nil) {
        consecutiveFailures += 1
        if let retryAfter {
            retryAfterUntil = date.addingTimeInterval(retryAfter)
        }
    }
}
