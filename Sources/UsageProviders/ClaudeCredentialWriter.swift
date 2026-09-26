import Foundation
import UsageCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Where Claude Code keeps its login on this Mac.
public enum ClaudeLoginLocation: Equatable, Sendable {
    case keychain
    case file(URL)
}

/// The stored login as Claude Code wrote it, plus where it came from, so a
/// renewal can be written back to the same place without losing fields.
public struct ClaudeStoredLogin: Sendable {
    public let credentials: ClaudeCredentials
    public let data: Data
    public let location: ClaudeLoginLocation
}

/// Exchanges Claude Code's refresh token for a new access token.
public struct ClaudeTokenRefreshClient: Sendable {
    public static let endpoint = URL(string: "https://platform.claude.com/v1/oauth/token")!

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

    public func refresh(refreshToken: String, now: Date = Date()) async throws -> ClaudeTokenRefresh.Response {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.httpBody = try ClaudeTokenRefresh.requestBody(refreshToken: refreshToken)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
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
            do {
                return try ClaudeTokenRefresh.parseResponse(data, now: now)
            } catch {
                throw ClaudeProviderError.badResponse
            }
        case 400, 401, 403:
            // The refresh token was used up or revoked; only a new sign-in helps.
            throw ClaudeProviderError.refreshRejected
        case 429:
            throw ClaudeProviderError.rateLimited(
                retryAfter: ClaudeUsageClient.retryAfter(http.value(forHTTPHeaderField: "Retry-After"), now: now)
            )
        default:
            throw ClaudeProviderError.http(status: http.statusCode)
        }
    }
}

/// Writes a renewed login back where Claude Code reads it, so both apps keep
/// sharing one valid login.
public struct ClaudeCredentialWriter: Sendable {
    public enum WriteError: Error, Equatable {
        case keychain(String)
        case file(String)
    }

    private let securityTool: URL
    /// A specific keychain file; nil means the user's default keychain.
    private let keychain: String?

    public init(securityTool: URL = URL(fileURLWithPath: "/usr/bin/security"), keychain: String? = nil) {
        self.securityTool = securityTool
        self.keychain = keychain
    }

    public func write(_ data: Data, to location: ClaudeLoginLocation) async throws {
        switch location {
        case .keychain:
            try await writeKeychain(data)
        case .file(let url):
            try writeFile(data, to: url)
        }
    }

    /// Goes through Apple's `security` tool, like the read path, so the
    /// item's existing access list keeps working. The login is passed as a
    /// hex argument, the same way Claude Code saves it: `security -i` cuts
    /// lines at ~4 KB, which truncated real logins. The write is then read
    /// back and must match byte for byte.
    private func writeKeychain(_ data: Data) async throws {
        let account = await keychainAccount() ?? NSUserName()
        var lastProblem = "saved login did not match"
        for _ in 0..<2 {
            let result = try await ProcessRunner.run(
                securityTool,
                arguments: Self.keychainUpdateArguments(account: account, data: data) + keychainArgument,
                timeout: 120
            )
            if result.status != 0 || result.timedOut {
                let stderr = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
                lastProblem = stderr.isEmpty ? "security exited \(result.status)" : stderr
                continue
            }
            if await readKeychain() == data { return }
        }
        throw WriteError.keychain(lastProblem)
    }

    private var keychainArgument: [String] { keychain.map { [$0] } ?? [] }

    /// The stored login exactly as saved, for verifying a write.
    func readKeychain() async -> Data? {
        guard let result = try? await ProcessRunner.run(
            securityTool,
            arguments: ["find-generic-password", "-s", ClaudeCredentialStore.keychainService, "-w"] + keychainArgument,
            timeout: 120
        ), result.status == 0 else {
            return nil
        }
        return Data(result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
    }

    /// The existing item's account, so the update replaces it instead of
    /// adding a second item. Reading attributes does not reveal the secret.
    private func keychainAccount() async -> String? {
        guard let result = try? await ProcessRunner.run(
            securityTool,
            arguments: ["find-generic-password", "-s", ClaudeCredentialStore.keychainService] + keychainArgument,
            timeout: 30
        ), result.status == 0 else {
            return nil
        }
        return Self.account(fromAttributes: result.stdoutText)
    }

    /// Parses `"acct"<blob>="name"` from `security find-generic-password` output.
    static func account(fromAttributes text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let prefix = "\"acct\"<blob>=\""
            guard trimmed.hasPrefix(prefix), trimmed.hasSuffix("\"") else { continue }
            let value = String(trimmed.dropFirst(prefix.count).dropLast())
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// `add-generic-password -U` updates the existing item in place. The
    /// login is hex-encoded (`-X`) so its JSON needs no quoting.
    static func keychainUpdateArguments(account: String, data: Data) -> [String] {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        return ["add-generic-password", "-U", "-a", account, "-s", ClaudeCredentialStore.keychainService, "-X", hex]
    }

    private func writeFile(_ data: Data, to url: URL) throws {
        do {
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw WriteError.file(error.localizedDescription)
        }
    }
}
