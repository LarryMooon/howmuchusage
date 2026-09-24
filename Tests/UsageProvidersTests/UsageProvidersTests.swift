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
