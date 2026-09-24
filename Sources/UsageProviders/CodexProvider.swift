import Foundation
import UsageCore

public enum CodexProviderError: Error, LocalizedError, Equatable {
    case notInstalled
    case signedOut
    case apiKeyAccount
    case noUsageData

    public var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Codex CLI not found in the usual places or inside Codex/ChatGPT apps. Install it (brew install codex) or locate it."
        case .signedOut:
            return "Not signed in to Codex."
        case .apiKeyAccount:
            return "Codex is signed in with an API key; plan limits need a ChatGPT sign-in."
        case .noUsageData:
            return "Codex returned no usage windows yet."
        }
    }
}

/// Codex usage from the official `codex app-server` protocol. Values are
/// account-wide, so usage from ChatGPT web/iOS/cloud shows up here too.
public final class CodexProvider: @unchecked Sendable {
    public typealias SnapshotHandler = @Sendable (UsageSnapshot) -> Void
    public typealias EventHandler = @Sendable () -> Void
    public typealias LoginHandler = @Sendable (_ success: Bool, _ error: String?) -> Void

    private let lock = NSLock()
    private var client: CodexAppServerClient?
    private var lastLimits: CodexRateLimitSnapshotDTO?
    private var trackedLimitID: String?
    private var account: CodexAccountResponseDTO.Account?
    private var executableOverride: String?
    /// Last discovered `codex`, so bundle searches are not repeated each poll.
    private var resolvedExecutable: URL?

    private let clientVersion: String
    private var onPush: SnapshotHandler?
    private var onAccountChanged: EventHandler?
    private var onLoginCompleted: LoginHandler?

    public init(clientVersion: String) {
        self.clientVersion = clientVersion
    }

    public func setHandlers(push: SnapshotHandler?, accountChanged: EventHandler?, loginCompleted: LoginHandler?) {
        locked {
            onPush = push
            onAccountChanged = accountChanged
            onLoginCompleted = loginCompleted
        }
    }

    public func setExecutableOverride(_ path: String?) {
        let old: CodexAppServerClient? = locked {
            guard executableOverride != path else { return nil }
            executableOverride = path
            resolvedExecutable = nil
            defer { client = nil }
            return client
        }
        old?.stop()
    }

    /// Path of the `codex` executable in use, if one was found.
    public var executablePath: String? {
        locked { resolvedExecutable?.path }
    }

    public var signedInEmail: String? {
        locked { account?.email }
    }

    /// Full read: account, then rate limits.
    public func read(now: Date = Date()) async throws -> UsageSnapshot {
        let client = try await ensureClient()

        let accountData = try await client.request("account/read", params: ["refreshToken": false])
        let accountResponse = try JSONDecoder().decode(CodexAccountResponseDTO.self, from: accountData)
        guard let account = accountResponse.account else {
            throw CodexProviderError.signedOut
        }
        guard account.type == "chatgpt" else {
            throw CodexProviderError.apiKeyAccount
        }

        let limitsData = try await client.request("account/rateLimits/read")
        let limits = try JSONDecoder().decode(CodexRateLimitsResponseDTO.self, from: limitsData)
        guard let codexLimits = limits.codexSnapshot else {
            throw CodexProviderError.noUsageData
        }

        locked {
            self.account = account
            lastLimits = codexLimits
            trackedLimitID = codexLimits.limitId
        }

        let snapshot = CodexUsageMapper.snapshot(from: codexLimits, account: account, observedAt: now)
        guard !snapshot.windows.isEmpty else { throw CodexProviderError.noUsageData }
        return snapshot
    }

    /// Raw `account/rateLimits/read` result, for diagnostics.
    public func readRaw() async throws -> Data {
        let client = try await ensureClient()
        return try await client.request("account/rateLimits/read")
    }

    /// Starts ChatGPT sign-in through app-server and returns the browser URL.
    /// Completion arrives via the `loginCompleted` handler.
    public func startChatGPTLogin() async throws -> URL {
        let client = try await ensureClient()
        let data = try await client.request("account/login/start", params: ["type": "chatgpt"])
        let response = try JSONDecoder().decode(CodexLoginStartDTO.self, from: data)
        guard let raw = response.authUrl, let url = URL(string: raw) else {
            throw CodexAppServerClient.ClientError.server(code: -1, message: "No sign-in URL returned")
        }
        return url
    }

    public func shutdown() {
        let old: CodexAppServerClient? = locked {
            defer { client = nil }
            return client
        }
        old?.stop()
    }

    // MARK: - Internals

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func ensureClient() async throws -> CodexAppServerClient {
        let (existing, override) = locked { (client, executableOverride) }

        if let existing, existing.isRunning { return existing }

        let executable: URL
        if override == nil, let cached = locked({ resolvedExecutable }),
           FileManager.default.isExecutableFile(atPath: cached.path) {
            executable = cached
        } else if let found = await BinaryLocator.locate("codex", override: override) {
            executable = found
            locked { resolvedExecutable = found }
        } else {
            throw CodexProviderError.notInstalled
        }

        let fresh = CodexAppServerClient(
            executableURL: executable,
            environment: BinaryLocator.childEnvironment(prependingDirectoryOf: executable)
        )
        fresh.setHandlers(
            notification: { [weak self] method, params in
                self?.handleNotification(method: method, params: params)
            },
            termination: nil
        )
        try await fresh.start(clientVersion: clientVersion)

        let replaced: CodexAppServerClient? = locked {
            defer { client = fresh }
            return client
        }
        if replaced !== fresh { replaced?.stop() }
        return fresh
    }

    private func handleNotification(method: String, params: Data?) {
        switch method {
        case "account/rateLimits/updated":
            guard let params,
                  let update = try? JSONDecoder().decode(CodexRateLimitsUpdatedDTO.self, from: params) else {
                return
            }
            let merge: (CodexRateLimitSnapshotDTO, CodexAccountResponseDTO.Account?, SnapshotHandler?)? = locked {
                // Without a full read to merge onto, a sparse update would show
                // partial data; the next scheduled read picks it up instead.
                guard let base = lastLimits else { return nil }
                let incoming = update.rateLimits.limitId
                guard incoming == nil || trackedLimitID == nil || incoming == trackedLimitID else {
                    return nil
                }
                let merged = base.merging(update.rateLimits)
                lastLimits = merged
                return (merged, self.account, self.onPush)
            }
            guard let merge else { return }
            let (merged, accountInfo, handler) = merge

            let snapshot = CodexUsageMapper.snapshot(from: merged, account: accountInfo, observedAt: Date())
            if !snapshot.windows.isEmpty { handler?(snapshot) }

        case "account/updated":
            let handler = locked { onAccountChanged }
            handler?()

        case "account/login/completed":
            guard let params,
                  let completed = try? JSONDecoder().decode(CodexLoginCompletedDTO.self, from: params) else {
                return
            }
            let handler = locked { onLoginCompleted }
            handler?(completed.success, completed.error)

        default:
            break
        }
    }
}
