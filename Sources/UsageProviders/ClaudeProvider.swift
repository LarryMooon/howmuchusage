import Foundation
import UsageCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ClaudeProviderError: Error, LocalizedError, Equatable {
    case keychainNotAllowed
    case notSignedIn
    case keychainDenied(String)
    case tokenExpired
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case http(status: Int)
    case network(String)
    case badResponse

    public var errorDescription: String? {
        switch self {
        case .keychainNotAllowed:
            return "Connect Claude to allow reading the Claude Code login."
        case .notSignedIn:
            return "No Claude Code login found. Run `claude` and /login once."
        case .keychainDenied(let detail):
            return "Keychain access was denied\(detail.isEmpty ? "" : ": \(detail)")."
        case .tokenExpired:
            return "Claude Code login expired. Open Claude Code once to renew it; this app picks it up automatically."
        case .unauthorized:
            return "Claude rejected the stored login. Run `claude` and /login again."
        case .rateLimited:
            return "Claude usage server asked to slow down. Retrying later."
        case .http(let status):
            return status == 403
                ? "This Claude login cannot read usage (403). Use a normal `claude` /login, not a setup token."
                : "Claude usage request failed (HTTP \(status))."
        case .network(let detail):
            return "Network error: \(detail)"
        case .badResponse:
            return "Claude usage response was not understood."
        }
    }

    /// Server-requested wait before the next attempt, if any.
    public var retryAfter: TimeInterval? {
        if case .rateLimited(let retryAfter) = self { return retryAfter ?? 300 }
        return nil
    }
}

/// Reads the OAuth login Claude Code already stores on this Mac. Renewals
/// are written back by `ClaudeCredentialWriter`, so Claude Code keeps working.
public final class ClaudeCredentialStore: @unchecked Sendable {
    public static let keychainService = "Claude Code-credentials"

    private let credentialsFile: URL

    public init(credentialsFile: URL = BinaryLocator.home.appendingPathComponent(".claude/.credentials.json")) {
        self.credentialsFile = credentialsFile
    }

    public func read(allowKeychain: Bool) async throws -> ClaudeCredentials {
        try await readStored(allowKeychain: allowKeychain).credentials
    }

    public func readStored(allowKeychain: Bool) async throws -> ClaudeStoredLogin {
        var keychainError: ClaudeProviderError?

        if allowKeychain {
            // Going through Apple's signed `security` tool keeps the user's
            // "Always Allow" choice valid across app updates.
            let result = try await ProcessRunner.run(
                URL(fileURLWithPath: "/usr/bin/security"),
                arguments: ["find-generic-password", "-s", Self.keychainService, "-w"],
                timeout: 120
            )
            if result.status == 0 {
                let data = Data(result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
                if let credentials = try? ClaudeCredentials.parse(data) {
                    return ClaudeStoredLogin(credentials: credentials, data: data, location: .keychain)
                }
                keychainError = .badResponse
            } else if result.status != 44 {
                // 44 = item not found; anything else is a denial or cancel.
                keychainError = .keychainDenied(result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        if let data = try? Data(contentsOf: credentialsFile),
           let credentials = try? ClaudeCredentials.parse(data) {
            return ClaudeStoredLogin(credentials: credentials, data: data, location: .file(credentialsFile))
        }

        if let keychainError { throw keychainError }
        throw allowKeychain ? ClaudeProviderError.notSignedIn : ClaudeProviderError.keychainNotAllowed
    }
}

public struct ClaudeUsageClient: Sendable {
    public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    private let session: URLSession
    private let userAgent: String

    public init(appVersion: String, session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 30
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
        userAgent = "Howmuchusage/\(appVersion) (macOS menu bar usage viewer)"
    }

    public func fetch(token: String, planName: String?, now: Date = Date()) async throws -> UsageSnapshot {
        let data = try await fetchRaw(token: token, now: now)
        do {
            return try ClaudeOAuthUsageParser.snapshot(from: data, planName: planName, observedAt: now)
        } catch {
            throw ClaudeProviderError.badResponse
        }
    }

    /// The unparsed response body (contains usage numbers only, no tokens).
    public func fetchRaw(token: String, now: Date = Date()) async throws -> Data {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request)
        } catch {
            throw ClaudeProviderError.network(error.localizedDescription)
        }
        let (data, response) = result

        guard let http = response as? HTTPURLResponse else {
            throw ClaudeProviderError.badResponse
        }

        switch http.statusCode {
        case 200:
            return data
        case 401:
            throw ClaudeProviderError.unauthorized
        case 429:
            throw ClaudeProviderError.rateLimited(
                retryAfter: Self.retryAfter(http.value(forHTTPHeaderField: "Retry-After"), now: now)
            )
        default:
            throw ClaudeProviderError.http(status: http.statusCode)
        }
    }

    static func retryAfter(_ header: String?, now: Date) -> TimeInterval? {
        guard let header = header?.trimmingCharacters(in: .whitespaces), !header.isEmpty else { return nil }
        if let seconds = TimeInterval(header) { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: header).map { max(0, $0.timeIntervalSince(now)) }
    }
}

/// Claude usage from the account usage endpoint (all devices), authenticated
/// with Claude Code's stored login.
public final class ClaudeProvider: @unchecked Sendable {
    /// Minimum wait between renewal attempts, so a dead refresh token is not
    /// retried on every poll.
    public static let refreshRetryInterval: TimeInterval = 10 * 60

    private let store: ClaudeCredentialStore
    private let client: ClaudeUsageClient
    private let refresher: ClaudeTokenRefreshClient
    private let writer: ClaudeCredentialWriter
    private let lock = NSLock()
    private var cached: ClaudeCredentials?
    private var keychainAllowed: Bool
    private var autoRefresh: Bool
    private var lastRefreshAttempt: Date?

    public init(
        appVersion: String,
        keychainAllowed: Bool,
        autoRefresh: Bool = false,
        store: ClaudeCredentialStore = ClaudeCredentialStore(),
        writer: ClaudeCredentialWriter = ClaudeCredentialWriter(),
        session: URLSession? = nil
    ) {
        self.store = store
        self.client = ClaudeUsageClient(appVersion: appVersion, session: session)
        self.refresher = ClaudeTokenRefreshClient(appVersion: appVersion, session: session)
        self.writer = writer
        self.keychainAllowed = keychainAllowed
        self.autoRefresh = autoRefresh
    }

    public func setKeychainAllowed(_ allowed: Bool) {
        locked {
            keychainAllowed = allowed
            if !allowed { cached = nil }
        }
    }

    /// When on, an expired login is renewed here and written back for Claude Code.
    public func setAutoRefresh(_ enabled: Bool) {
        locked {
            autoRefresh = enabled
            if enabled { lastRefreshAttempt = nil }
        }
    }

    public var planName: String? {
        locked { PlanNames.display(cached?.subscriptionType) }
    }

    public func read(now: Date = Date()) async throws -> UsageSnapshot {
        var credentials = try await self.credentials(reload: false)
        if credentials.isExpired(now: now) {
            // Claude Code may have renewed the login since the last read.
            credentials = try await self.credentials(reload: true)
            if credentials.isExpired(now: now) {
                credentials = try await renew(now: now)
            }
        }

        do {
            return try await fetch(with: credentials, now: now)
        } catch ClaudeProviderError.unauthorized {
            let reloaded = try await self.credentials(reload: true)
            guard reloaded.accessToken != credentials.accessToken else {
                throw reloaded.isExpired(now: now) ? ClaudeProviderError.tokenExpired : ClaudeProviderError.unauthorized
            }
            return try await fetch(with: reloaded, now: now)
        }
    }

    /// Raw usage response, for diagnostics (`howmuchusage-probe claude --raw`).
    public func readRaw(now: Date = Date()) async throws -> Data {
        let credentials = try await self.credentials(reload: true)
        if credentials.isExpired(now: now) { throw ClaudeProviderError.tokenExpired }
        return try await client.fetchRaw(token: credentials.accessToken, now: now)
    }

    /// Renews an expired login and stores it where Claude Code reads it.
    /// If Claude Code renewed it in the meantime, its login wins.
    private func renew(now: Date) async throws -> ClaudeCredentials {
        // Claiming the attempt under the lock also keeps overlapping reads
        // from spending the refresh token twice.
        let (claimed, allowed) = locked { () -> (Bool, Bool) in
            guard autoRefresh else { return (false, keychainAllowed) }
            if let lastRefreshAttempt, now.timeIntervalSince(lastRefreshAttempt) < Self.refreshRetryInterval {
                return (false, keychainAllowed)
            }
            lastRefreshAttempt = now
            return (true, keychainAllowed)
        }
        guard claimed else { throw ClaudeProviderError.tokenExpired }

        let stored = try await store.readStored(allowKeychain: allowed)
        if !stored.credentials.isExpired(now: now) {
            locked {
                cached = stored.credentials
                lastRefreshAttempt = nil
            }
            return stored.credentials
        }
        guard let refreshToken = stored.credentials.refreshToken else {
            throw ClaudeProviderError.tokenExpired
        }

        let response = try await refresher.refresh(refreshToken: refreshToken, now: now)

        // Re-read right before writing: never overwrite a newer login.
        let latest = try await store.readStored(allowKeychain: allowed)
        if latest.credentials.accessToken != stored.credentials.accessToken
            || latest.credentials.refreshToken != stored.credentials.refreshToken {
            locked { cached = latest.credentials }
            if latest.credentials.isExpired(now: now) { throw ClaudeProviderError.tokenExpired }
            return latest.credentials
        }

        let updated: Data
        let renewed: ClaudeCredentials
        do {
            updated = try ClaudeTokenRefresh.updatedCredentialsData(latest.data, with: response)
            renewed = try ClaudeCredentials.parse(updated)
        } catch {
            throw ClaudeProviderError.badResponse
        }

        // The old refresh token is likely spent now, so a failed write-back
        // must not hide the new login from this app.
        try? await writer.write(updated, to: latest.location)
        locked {
            cached = renewed
            lastRefreshAttempt = nil
        }
        return renewed
    }

    private func fetch(with credentials: ClaudeCredentials, now: Date) async throws -> UsageSnapshot {
        try await client.fetch(
            token: credentials.accessToken,
            planName: PlanNames.display(credentials.subscriptionType),
            now: now
        )
    }

    private func credentials(reload: Bool) async throws -> ClaudeCredentials {
        let (existing, allowed) = locked { (cached, keychainAllowed) }
        if !reload, let existing { return existing }
        let fresh = try await store.read(allowKeychain: allowed)
        locked { cached = fresh }
        return fresh
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
