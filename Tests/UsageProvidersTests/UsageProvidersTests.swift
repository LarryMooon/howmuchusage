import XCTest
@testable import UsageCore
@testable import UsageProviders

final class CodexAppServerClientTests: XCTestCase {
    private var client: CodexAppServerClient!

    override func setUpWithError() throws {
        client = CodexAppServerClient(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["python3", try fakeServerPath()],
            requestTimeout: 2
        )
    }

    override func tearDown() {
        client.stop()
        client = nil
    }

    func testHandshakeAndRateLimitRead() async throws {
        try await client.start(clientVersion: "test")
        let data = try await client.request("account/rateLimits/read")
        let response = try JSONDecoder().decode(CodexRateLimitsResponseDTO.self, from: data)
        XCTAssertEqual(response.codexSnapshot?.primary?.usedPercent, 40)
    }

    func testDeliversNotifications() async throws {
        let received = expectation(description: "rate limit push")
        client.setHandlers(notification: { method, params in
            if method == "account/rateLimits/updated", params != nil { received.fulfill() }
        }, termination: nil)
        try await client.start(clientVersion: "test")
        _ = try await client.request("account/rateLimits/read")
        _ = try await client.request("account/read")
        await fulfillment(of: [received], timeout: 5)
    }

    func testServerErrorsAndTimeouts() async throws {
        try await client.start(clientVersion: "test")
        do {
            _ = try await client.request("does/not/exist")
            XCTFail("expected an error")
        } catch let error as CodexAppServerClient.ClientError {
            guard case .server(code: -32601, _) = error else { return XCTFail("unexpected \(error)") }
        }

        do {
            _ = try await client.request("test/silent")
            XCTFail("expected a timeout")
        } catch let error as CodexAppServerClient.ClientError {
            XCTAssertEqual(error, .timeout(method: "test/silent"))
        }
    }

    func testAnswersServerRequestsAndKeepsWorking() async throws {
        try await client.start(clientVersion: "test")
        _ = try await client.request("test/serverRequest")
        let data = try await client.request("account/read")
        let account = try JSONDecoder().decode(CodexAccountResponseDTO.self, from: data)
        XCTAssertEqual(account.account?.email, "me@example.com")
    }

    func testProcessExitFailsPendingRequestsAndAllowsRestart() async throws {
        try await client.start(clientVersion: "test")
        do {
            _ = try await client.request("test/exit")
            XCTFail("expected exit error")
        } catch let error as CodexAppServerClient.ClientError {
            guard case .processExited = error else { return XCTFail("unexpected \(error)") }
        }
        XCTAssertFalse(client.isRunning)

        try await client.start(clientVersion: "test")
        XCTAssertTrue(client.isRunning)
    }
}

final class CodexProviderTests: XCTestCase {
    func testReadsAccountAndMergesPushUpdates() async throws {
        let fakeCodex = try makeFakeCodexExecutable()
        let provider = CodexProvider(clientVersion: "test")
        provider.setExecutableOverride(fakeCodex.path)
        defer { provider.shutdown() }

        let pushed = expectation(description: "merged push")
        provider.setHandlers(push: { snapshot in
            if snapshot.session?.remainingPercent == 55, snapshot.weekly?.remainingPercent == 48 {
                pushed.fulfill()
            }
        }, accountChanged: nil, loginCompleted: nil)

        let snapshot = try await provider.read()
        XCTAssertEqual(snapshot.session?.remainingPercent, 60)
        XCTAssertEqual(snapshot.weekly?.remainingPercent, 48)
        XCTAssertEqual(snapshot.planName, "Pro")
        XCTAssertEqual(snapshot.accountLabel, "me@example.com")

        // The fake pushes a sparse update during the next account/read; it
        // must merge onto the full read instead of dropping the weekly window.
        _ = try await provider.read()
        await fulfillment(of: [pushed], timeout: 5)
    }

    func testLoginReturnsBrowserURLAndCompletes() async throws {
        let fakeCodex = try makeFakeCodexExecutable()
        let provider = CodexProvider(clientVersion: "test")
        provider.setExecutableOverride(fakeCodex.path)
        defer { provider.shutdown() }

        let completed = expectation(description: "login completed")
        provider.setHandlers(push: nil, accountChanged: nil, loginCompleted: { success, _ in
            if success { completed.fulfill() }
        })

        let url = try await provider.startChatGPTLogin()
        XCTAssertEqual(url.absoluteString, "https://auth.example.com/start")
        await fulfillment(of: [completed], timeout: 5)
    }

    func testMissingExecutableIsReportedAsNotInstalled() async {
        let provider = CodexProvider(clientVersion: "test")
        provider.setExecutableOverride("/nonexistent/codex")
        do {
            _ = try await provider.read()
            XCTFail("expected notInstalled")
        } catch {
            XCTAssertEqual(error as? CodexProviderError, .notInstalled)
        }
    }
}

final class ClaudeProviderTests: XCTestCase {
    func testCredentialFileFallbackWithoutKeychain() async throws {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent(".credentials.json")
        try Data(#"{"claudeAiOauth":{"accessToken":"tok","expiresAt":4102444800000,"subscriptionType":"pro"}}"#.utf8).write(to: file)

        let credentials = try await ClaudeCredentialStore(credentialsFile: file).read(allowKeychain: false)
        XCTAssertEqual(credentials.accessToken, "tok")
        XCTAssertEqual(credentials.subscriptionType, "pro")
    }

    func testMissingLoginWithoutConsentAsksToConnect() async {
        let store = ClaudeCredentialStore(credentialsFile: URL(fileURLWithPath: "/nonexistent/.credentials.json"))
        do {
            _ = try await store.read(allowKeychain: false)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ClaudeProviderError, .keychainNotAllowed)
        }
    }

    func testRetryAfterHeaderParsing() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(ClaudeUsageClient.retryAfter("120", now: now), 120)
        XCTAssertNil(ClaudeUsageClient.retryAfter(nil, now: now))
        XCTAssertNil(ClaudeUsageClient.retryAfter("soon", now: now))
        let date = ClaudeUsageClient.retryAfter("Fri, 15 Jan 2027 08:05:00 GMT", now: now)
        XCTAssertEqual(date ?? -1, 300, accuracy: 1)
        XCTAssertEqual(ClaudeProviderError.rateLimited(retryAfter: nil).retryAfter, 300)
    }
}

final class ClaudeTokenRenewalTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func tearDown() {
        StubURLProtocol.handler = nil
    }

    private func expiredLogin(in directory: URL) throws -> URL {
        let file = directory.appendingPathComponent(".credentials.json")
        try Data(#"{"claudeAiOauth":{"accessToken":"at-old","refreshToken":"rt-old","expiresAt":1700000000000,"subscriptionType":"pro"},"other":1}"#.utf8).write(to: file)
        return file
    }

    private func provider(file: URL, autoRefresh: Bool = true) -> ClaudeProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return ClaudeProvider(
            appVersion: "test",
            keychainAllowed: false,
            autoRefresh: autoRefresh,
            store: ClaudeCredentialStore(credentialsFile: file),
            session: URLSession(configuration: configuration)
        )
    }

    private static let usageBody = Data(#"{"five_hour":{"utilization":12,"resets_at":"2027-01-15T08:00:00+00:00"}}"#.utf8)

    func testRenewsExpiredLoginAndWritesItBack() async throws {
        let file = try expiredLogin(in: try temporaryDirectory())
        var refreshBody: [String: String]?
        StubURLProtocol.handler = { request in
            if request.url == ClaudeTokenRefreshClient.endpoint {
                refreshBody = (try? JSONSerialization.jsonObject(with: request.bodyData)) as? [String: String]
                return (200, Data(#"{"access_token":"at-new","refresh_token":"rt-new","expires_in":28800}"#.utf8))
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer at-new")
            return (200, Self.usageBody)
        }

        let snapshot = try await provider(file: file).read(now: now)
        XCTAssertEqual(snapshot.windows.first?.usedPercent, 12)
        XCTAssertEqual(refreshBody?["refresh_token"], "rt-old")

        let saved = try ClaudeCredentials.parse(Data(contentsOf: file))
        XCTAssertEqual(saved.accessToken, "at-new")
        XCTAssertEqual(saved.refreshToken, "rt-new")
        XCTAssertEqual(saved.subscriptionType, "pro")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(root["other"] as? Int, 1)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testClaudeCodeRenewalDuringRefreshWins() async throws {
        let file = try expiredLogin(in: try temporaryDirectory())
        let newer = Data(#"{"claudeAiOauth":{"accessToken":"at-claude","refreshToken":"rt-claude","expiresAt":4102444800000}}"#.utf8)
        StubURLProtocol.handler = { request in
            if request.url == ClaudeTokenRefreshClient.endpoint {
                // Claude Code saves its own renewal while ours is in flight.
                try? newer.write(to: file)
                return (200, Data(#"{"access_token":"at-mine","refresh_token":"rt-mine","expires_in":28800}"#.utf8))
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer at-claude")
            return (200, Self.usageBody)
        }

        _ = try await provider(file: file).read(now: now)
        XCTAssertEqual(try Data(contentsOf: file), newer, "Claude Code's login must not be overwritten")
    }

    func testRejectedRefreshReportsExpiredAndBacksOff() async throws {
        let file = try expiredLogin(in: try temporaryDirectory())
        var refreshCalls = 0
        StubURLProtocol.handler = { _ in
            refreshCalls += 1
            return (400, Data(#"{"error":"invalid_grant"}"#.utf8))
        }
        let provider = provider(file: file)

        for offset in [0.0, 60] {
            do {
                _ = try await provider.read(now: now.addingTimeInterval(offset))
                XCTFail("expected an error")
            } catch {
                XCTAssertEqual(error as? ClaudeProviderError, .refreshRejected, "a dead refresh token needs /login, not just opening Claude Code")
            }
        }
        XCTAssertEqual(refreshCalls, 1, "a rejected refresh is not retried on every poll")
        XCTAssertEqual(try ClaudeCredentials.parse(Data(contentsOf: file)).accessToken, "at-old")
    }

    func testFailedWriteBackIsReportedButLoginStillWorks() async throws {
        let directory = try temporaryDirectory()
        let file = try expiredLogin(in: directory)
        StubURLProtocol.handler = { request in
            if request.url == ClaudeTokenRefreshClient.endpoint {
                // Make the directory read-only so the atomic save fails.
                try? FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
                return (200, Data(#"{"access_token":"at-new","refresh_token":"rt-new","expires_in":28800}"#.utf8))
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer at-new")
            return (200, Self.usageBody)
        }
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }

        let provider = provider(file: file)
        let snapshot = try await provider.read(now: now)
        XCTAssertEqual(snapshot.windows.first?.usedPercent, 12, "the renewed login is still used by this app")
        XCTAssertNotNil(provider.writeBackProblem)
        XCTAssertEqual(try ClaudeCredentials.parse(Data(contentsOf: file)).accessToken, "at-old")
    }

    func testErrorDescriptionHidesLongSecrets() {
        let secretish = String(repeating: "7b22616363657373546f6b656e223a", count: 3)
        let text = ClaudeProvider.describe(ClaudeCredentialWriter.WriteError.keychain("security: add-generic-password -X \(secretish) failed"))
        XCTAssertFalse(text.contains(secretish))
        XCTAssertTrue(text.contains("failed"))
    }

    func testAutoRefreshOffNeverCallsServer() async throws {
        let file = try expiredLogin(in: try temporaryDirectory())
        StubURLProtocol.handler = { _ in
            XCTFail("no network expected")
            return (500, Data())
        }
        do {
            _ = try await provider(file: file, autoRefresh: false).read(now: now)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ClaudeProviderError, .tokenExpired)
        }
    }

    func testKeychainAccountParsingAndCommand() {
        let attributes = """
        keychain: "/Users/me/Library/Keychains/login.keychain-db"
        attributes:
            "acct"<blob>="larry"
            "svce"<blob>="Claude Code-credentials"
        """
        XCTAssertEqual(ClaudeCredentialWriter.account(fromAttributes: attributes), "larry")
        XCTAssertNil(ClaudeCredentialWriter.account(fromAttributes: "\"acct\"<blob>=<NULL>"))

        XCTAssertEqual(
            ClaudeCredentialWriter.keychainUpdateArguments(account: "larry", data: Data("{}".utf8)),
            ["add-generic-password", "-U", "-a", "larry", "-s", "Claude Code-credentials", "-X", "7b7d"]
        )
    }

    /// Real logins are ~2-6 KB; `security -i` used to cut them at ~4 KB of hex.
    func testLargeLoginSurvivesKeychainWriteExactly() async throws {
        let keychain = try temporaryDirectory().appendingPathComponent("test.keychain-db").path
        let security = URL(fileURLWithPath: "/usr/bin/security")
        for arguments in [["create-keychain", "-p", "test", keychain], ["unlock-keychain", "-p", "test", keychain]] {
            let result = try await ProcessRunner.run(security, arguments: arguments, timeout: 30)
            XCTAssertEqual(result.status, 0, result.stderrText)
        }
        defer { _ = try? ProcessRunner.runBlocking(security, arguments: ["delete-keychain", keychain], timeout: 30) }

        let writer = ClaudeCredentialWriter(keychain: keychain)
        let first = Data(#"{"claudeAiOauth":{"accessToken":"old"}}"#.utf8)
        try await writer.write(first, to: .keychain)
        let token = String(repeating: "a", count: 3_000)
        let large = try JSONSerialization.data(
            withJSONObject: ["claudeAiOauth": ["accessToken": token, "refreshToken": token + "r"], "mcpOAuth": ["x": token]],
            options: [.sortedKeys]
        )
        XCTAssertGreaterThan(large.count, 9_000)
        try await writer.write(large, to: .keychain)
        let stored = await writer.readKeychain()
        XCTAssertEqual(stored, large, "the whole login must be stored, byte for byte")
    }
}

/// Serves canned responses to a URLSession configured with it.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, body) = handler(request)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension URLRequest {
    /// URLSession moves POST bodies into a stream before protocols see them.
    var bodyData: Data {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

final class StatuslineBridgeTests: XCTestCase {
    func testInstallChainsPreviousCommandAndUninstallRestores() throws {
        let root = try temporaryDirectory()
        let settingsFile = root.appendingPathComponent("claude/settings.json")
        try FileManager.default.createDirectory(at: settingsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"model":"opus","statusLine":{"type":"command","command":"echo previous-line","padding":1}}"#.utf8)
            .write(to: settingsFile)

        let bridge = StatuslineBridge(supportDirectory: root.appendingPathComponent("support"), claudeSettingsFile: settingsFile)
        XCTAssertFalse(bridge.isInstalled)

        try bridge.install(appExecutable: URL(fileURLWithPath: "/Applications/Howmuchusage.app/Contents/MacOS/Howmuchusage"))
        XCTAssertTrue(bridge.isInstalled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: settingsFile.appendingPathExtension("howmuchusage-backup").path))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: bridge.scriptFile.path))

        let installed = try settings(settingsFile)
        XCTAssertEqual(installed["model"] as? String, "opus", "unrelated settings survive")
        let statusLine = try XCTUnwrap(installed["statusLine"] as? [String: Any])
        XCTAssertEqual(statusLine["padding"] as? Int, 1)

        // Installing twice must not overwrite the remembered original.
        try bridge.install(appExecutable: URL(fileURLWithPath: "/Applications/Howmuchusage.app/Contents/MacOS/Howmuchusage"))

        let input = try XCTUnwrap(#"{"cwd":"/private","rate_limits":{"five_hour":{"used_percentage":10,"resets_at":1790000000}}}"#.data(using: .utf8))
        let output = bridge.runBridge(input: input, now: Date(timeIntervalSince1970: 1_789_990_000))
        XCTAssertEqual(String(decoding: output, as: UTF8.self), "previous-line\n")
        let captured = try XCTUnwrap(bridge.latestSnapshot())
        XCTAssertEqual(captured.session?.remainingPercent, 90)
        XCTAssertEqual(captured.observedAt, Date(timeIntervalSince1970: 1_789_990_000))

        // Same values later keep the older observation time (never overclaim freshness).
        _ = bridge.runBridge(input: input, now: Date(timeIntervalSince1970: 1_789_999_000))
        XCTAssertEqual(bridge.latestSnapshot()?.observedAt, Date(timeIntervalSince1970: 1_789_990_000))

        try bridge.uninstall()
        XCTAssertFalse(bridge.isInstalled)
        let restored = try XCTUnwrap(try settings(settingsFile)["statusLine"] as? [String: Any])
        XCTAssertEqual(restored["command"] as? String, "echo previous-line")
    }

    func testBridgeWithoutPreviousCommandPrintsDefaultLine() throws {
        let root = try temporaryDirectory()
        let bridge = StatuslineBridge(supportDirectory: root.appendingPathComponent("support"), claudeSettingsFile: root.appendingPathComponent("settings.json"))
        try bridge.install(appExecutable: URL(fileURLWithPath: "/tmp/Howmuchusage"))

        let input = Data(#"{"rate_limits":{"five_hour":{"used_percentage":20,"resets_at":1},"seven_day":{"used_percentage":50,"resets_at":2}}}"#.utf8)
        XCTAssertEqual(String(decoding: bridge.runBridge(input: input), as: UTF8.self), "5h 80% left · 7d 50% left\n")

        try bridge.uninstall()
        XCTAssertNil(try settings(root.appendingPathComponent("settings.json"))["statusLine"])
    }

    func testRefusesToTouchInvalidSettings() throws {
        let root = try temporaryDirectory()
        let settingsFile = root.appendingPathComponent("settings.json")
        try Data("{ not json".utf8).write(to: settingsFile)
        let bridge = StatuslineBridge(supportDirectory: root.appendingPathComponent("support"), claudeSettingsFile: settingsFile)

        XCTAssertThrowsError(try bridge.install(appExecutable: URL(fileURLWithPath: "/tmp/Howmuchusage")))
        XCTAssertEqual(try String(contentsOf: settingsFile, encoding: .utf8), "{ not json")
    }

    func testScriptQuotesPaths() {
        XCTAssertEqual(StatuslineBridge.shellQuote("/a b/it's"), #"'/a b/it'\''s'"#)
    }

    private func settings(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
}

final class BinaryLocatorTests: XCTestCase {
    func testFindsCLIInsideDesktopAppBundle() throws {
        let root = try temporaryDirectory()
        let resources = root.appendingPathComponent("Codex.app/Contents/Resources/bin")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let cli = resources.appendingPathComponent("codex")
        try Data("#!/bin/sh\n".utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        // A non-executable file with the same name elsewhere must be ignored.
        let other = root.appendingPathComponent("ChatGPT.app/Contents/Resources")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data().write(to: other.appendingPathComponent("codex"))

        let found = BinaryLocator.searchAppBundles(for: "codex", appNameHints: ["codex", "chatgpt"], roots: [root])
        XCTAssertEqual(found?.resolvingSymlinksInPath().path, cli.resolvingSymlinksInPath().path)
        XCTAssertNil(BinaryLocator.searchAppBundles(for: "codex", appNameHints: ["other"], roots: [root]))
    }
}

final class LocalSourceTests: XCTestCase {
    func testSessionLogSourceReadsTodaysDirectory() throws {
        let root = try temporaryDirectory()
        let now = Date()
        let parts = Calendar(identifier: .gregorian).dateComponents(in: .current, from: now)
        let day = root
            .appendingPathComponent(String(format: "%04d", parts.year!))
            .appendingPathComponent(String(format: "%02d", parts.month!))
            .appendingPathComponent(String(format: "%02d", parts.day!))
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let line = #"{"timestamp":"2026-09-24T01:05:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":30.0,"window_minutes":300,"resets_at":1790000000},"secondary":null}}}"#
        try Data((line + "\n").utf8).write(to: day.appendingPathComponent("rollout-test.jsonl"))

        let source = CodexSessionLogSource(root: root)
        XCTAssertEqual(source.latestSnapshot(now: now)?.session?.remainingPercent, 70)
        XCTAssertNotNil(source.newestModificationDate(now: now))
        XCTAssertNil(CodexSessionLogSource(root: root.appendingPathComponent("missing")).latestSnapshot(now: now))
    }
}

// MARK: - Helpers

func fakeServerPath() throws -> String {
    try XCTUnwrap(Bundle.module.url(forResource: "fake_app_server", withExtension: "py", subdirectory: "Fixtures")).path
}

/// A stand-in `codex` executable that ignores `app-server` and runs the fake.
func makeFakeCodexExecutable() throws -> URL {
    let directory = try temporaryDirectory()
    let executable = directory.appendingPathComponent("codex")
    let script = "#!/bin/sh\nexec /usr/bin/env python3 \(StatuslineBridge.shellQuote(try fakeServerPath()))\n"
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    return executable
}

func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("howmuchusage-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
