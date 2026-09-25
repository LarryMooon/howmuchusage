import AppKit
import Network
import UsageCore
import UsageProviders

enum ConnectionState: Equatable {
    /// Nothing tried yet.
    case idle
    case connecting(String)
    case connected
    /// The user has to do something (install, sign in, allow access).
    case needsSetup(SetupNeed)
    /// Temporary trouble; the last value stays on screen and ages visibly.
    case failing(String)
}

enum SetupNeed: Equatable {
    case codexNotInstalled
    case codexSignedOut
    case codexAPIKey
    case claudeNotConnected
    case claudeNotSignedIn
    case claudeExpired
    case claudeRelogin(String)

    var message: String {
        switch self {
        case .codexNotInstalled: return CodexProviderError.notInstalled.errorDescription ?? ""
        case .codexSignedOut: return "Sign in with ChatGPT to show Codex usage."
        case .codexAPIKey: return CodexProviderError.apiKeyAccount.errorDescription ?? ""
        case .claudeNotConnected: return "Connect to read your Claude plan usage (all devices)."
        case .claudeNotSignedIn: return ClaudeProviderError.notSignedIn.errorDescription ?? ""
        case .claudeExpired: return ClaudeProviderError.tokenExpired.errorDescription ?? ""
        case .claudeRelogin(let detail): return detail
        }
    }
}

struct ProviderState {
    var snapshot: UsageSnapshot?
    var connection: ConnectionState = .idle
    var isRefreshing = false
    var poll = PollState()
    var nextRefreshAt: Date?

    var needsSetup: Bool {
        if case .needsSetup = connection { return true }
        return false
    }
}

/// Owns provider state and keeps it fresh: one adaptive polling loop per
/// provider, plus wake-ups from sleep/wake, network changes, popover opens,
/// local activity and Codex push notifications.
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var states: [Provider: ProviderState] = [.claude: ProviderState(), .codex: ProviderState()]
    /// Ticks so relative times, freshness and passed resets re-render.
    @Published private(set) var now = Date()

    let settings: AppSettings
    private let codex: CodexProvider
    private let claude: ClaudeProvider
    private let codexLog = CodexSessionLogSource()
    let bridge = StatuslineBridge()

    private var loops: [Provider: Task<Void, Never>] = [:]
    private var wakers: [Provider: Waker] = [.claude: Waker(), .codex: Waker()]
    private var clock: Timer?
    private var activityTimer: Timer?
    private var lastCodexLogChange: Date?
    private var lastBridgeChange: Date?
    private let pathMonitor = NWPathMonitor()
    private var networkWasDown = false
    private var activity: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    init(settings: AppSettings) {
        self.settings = settings
        codex = CodexProvider(clientVersion: AppInfo.version)
        claude = ClaudeProvider(appVersion: AppInfo.version, keychainAllowed: settings.claudeConnected)
        codex.setExecutableOverride(settings.codexPath)

        codex.setHandlers(
            push: { [weak self] snapshot in
                Task { @MainActor in self?.apply(snapshot, to: .codex, countsAsPoll: false) }
            },
            accountChanged: { [weak self] in
                Task { @MainActor in self?.kick(.codex) }
            },
            loginCompleted: { [weak self] success, error in
                Task { @MainActor in self?.codexLoginFinished(success: success, error: error) }
            }
        )
    }

    func start() {
        // Keep timers on schedule without preventing idle system sleep.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Keep Claude and Codex usage current"
        )

        loadLocalSources()
        for provider in Provider.allCases {
            loops[provider] = Task { [weak self] in await self?.runLoop(provider) }
        }

        clock = repeatingTimer(interval: 15) { [weak self] in self?.now = Date() }
        activityTimer = repeatingTimer(interval: 10) { [weak self] in self?.checkLocalActivity() }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                // Give Wi-Fi a moment to come back after wake.
                self?.kickAll(after: 4)
            }
        }

        pathMonitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(satisfied: satisfied) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.larrymoon.howmuchusage.network"))
    }

    func shutdown() {
        loops.values.forEach { $0.cancel() }
        wakers.values.forEach { $0.cancel() }
        pathMonitor.cancel()
        codex.shutdown()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
    }

    // MARK: - Reading state

    func state(for provider: Provider) -> ProviderState {
        states[provider] ?? ProviderState()
    }

    func freshness(for provider: Provider) -> Freshness? {
        guard let snapshot = state(for: provider).snapshot else { return nil }
        return Freshness.evaluate(
            observedAt: snapshot.observedAt,
            now: now,
            liveWindow: PollPolicy.for(provider).liveWindow
        )
    }

    /// Providers drawn in the menu bar: selected ones that are set up or have data.
    var visibleProviders: [Provider] {
        let selected = settings.displayMode.providers
        let ready = selected.filter { state(for: $0).snapshot != nil || !state(for: $0).needsSetup }
        return ready.isEmpty ? selected : ready
    }

    // MARK: - Triggers

    /// Requests an early refresh, never closer than the provider's minimum spacing.
    func kick(_ provider: Provider, after delay: TimeInterval = 0) {
        let wait = PollPolicy.for(provider).waitBeforeManualRequest(state: state(for: provider).poll, now: Date())
        wakers[provider]?.wake(after: max(delay, wait))
    }

    func kickAll(after delay: TimeInterval = 0) {
        Provider.allCases.forEach { kick($0, after: delay) }
    }

    /// Short feedback shown under the popover header after a manual refresh.
    @Published private(set) var refreshNote: String?
    private var refreshNoteTask: Task<Void, Never>?

    var isAnyRefreshing: Bool {
        states.values.contains { $0.isRefreshing }
    }

    /// Manual refresh with visible feedback. Services polled too recently
    /// wait out their minimum interval; the note says how long.
    func refreshNow() {
        let now = Date()
        var waiting: [String] = []
        for provider in settings.displayMode.providers {
            let wait = PollPolicy.for(provider).waitBeforeManualRequest(state: state(for: provider).poll, now: now)
            if wait >= 1 {
                waiting.append("\(provider.displayName) in \(UsageFormat.duration(wait))")
            }
        }
        kickAll()
        refreshNote = waiting.isEmpty
            ? "Checking now…"
            : "Checking now · \(waiting.joined(separator: ", ")) (rate limit)"
        refreshNoteTask?.cancel()
        refreshNoteTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            self?.refreshNote = nil
        }
    }

    func popoverOpened() {
        now = Date()
        kickAll()
    }

    // MARK: - Account actions

    func connectClaude() {
        settings.claudeConnected = true
        claude.setKeychainAllowed(true)
        update(.claude) { $0.connection = .connecting("Reading Claude Code login…") ; $0.poll = PollState() }
        kick(.claude)
    }

    func disconnectClaude() {
        settings.claudeConnected = false
        claude.setKeychainAllowed(false)
        update(.claude) { $0.connection = .needsSetup(.claudeNotConnected) }
    }

    /// Opens Terminal running `claude`, which starts its own sign-in when needed.
    func openClaudeSignIn() {
        let script = AppPaths.supportDirectory.appendingPathComponent("claude-sign-in.command")
        let contents = """
        #!/bin/zsh -l
        echo "Howmuchusage: signing in to Claude Code. If you are already signed in, type /login to switch accounts."
        exec claude

        """
        do {
            try FileManager.default.createDirectory(at: AppPaths.supportDirectory, withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: script, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            NSWorkspace.shared.open(script)
        } catch {
            update(.claude) { $0.connection = .failing(error.localizedDescription) }
        }
    }

    func connectCodex() {
        update(.codex) { $0.connection = .connecting("Starting ChatGPT sign-in…") }
        Task {
            do {
                let url = try await codex.startChatGPTLogin()
                NSWorkspace.shared.open(url)
                update(.codex) { $0.connection = .connecting("Finish signing in in your browser…") }
            } catch {
                update(.codex) { $0.connection = .failing(error.localizedDescription) }
            }
        }
    }

    func setCodexPath(_ path: String?) {
        settings.codexPath = path
        codex.setExecutableOverride(path)
        update(.codex) { $0.poll = PollState() }
        kick(.codex)
    }

    func setStatuslineBridge(enabled: Bool) throws {
        if enabled {
            let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
            try bridge.install(appExecutable: executable)
        } else {
            try bridge.uninstall()
        }
        objectWillChange.send()
    }

    // MARK: - Loop

    private func runLoop(_ provider: Provider) async {
        while !Task.isCancelled {
            await refresh(provider)
            let policy = PollPolicy.for(provider)
            var delay = policy.nextDelay(for: state(for: provider).poll, now: Date())
            if case .needsSetup(.claudeExpired) = state(for: provider).connection {
                // Re-checking the login is cheap; recover quickly once Claude Code renews it.
                delay = min(delay, 120)
            }
            if case .needsSetup(.claudeNotConnected) = state(for: provider).connection {
                delay = policy.idle
            }
            delay = PollPolicy.jitter(delay, unit: Double.random(in: 0...1))
            update(provider) { $0.nextRefreshAt = Date().addingTimeInterval(delay) }
            await wakers[provider]?.sleep(delay)
        }
    }

    private func refresh(_ provider: Provider) async {
        guard !state(for: provider).isRefreshing else { return }
        let started = Date()
        update(provider) {
            $0.isRefreshing = true
            $0.poll.recordAttempt(at: started)
        }
        defer { update(provider) { $0.isRefreshing = false } }

        switch provider {
        case .codex: await refreshCodex(started: started)
        case .claude: await refreshClaude(started: started)
        }
    }

    private func refreshCodex(started: Date) async {
        do {
            let snapshot = try await codex.read(now: Date())
            apply(snapshot, to: .codex, countsAsPoll: true)
            update(.codex) { $0.connection = .connected }
        } catch {
            update(.codex) { $0.poll.recordFailure(at: Date()) }
            loadCodexLog()
            let connection: ConnectionState
            switch error as? CodexProviderError {
            case .notInstalled?: connection = .needsSetup(.codexNotInstalled)
            case .signedOut?: connection = .needsSetup(.codexSignedOut)
            case .apiKeyAccount?: connection = .needsSetup(.codexAPIKey)
            default: connection = .failing(error.localizedDescription)
            }
            update(.codex) { state in
                // Keep "finish sign-in" visible while the browser flow is open.
                if case .connecting = state.connection, connection == .needsSetup(.codexSignedOut) { return }
                state.connection = connection
            }
        }
    }

    private func refreshClaude(started: Date) async {
        loadBridge()
        guard settings.claudeConnected else {
            update(.claude) { $0.connection = .needsSetup(.claudeNotConnected) }
            return
        }

        do {
            let snapshot = try await claude.read(now: Date())
            apply(snapshot, to: .claude, countsAsPoll: true)
            update(.claude) { $0.connection = .connected }
        } catch {
            let providerError = error as? ClaudeProviderError
            update(.claude) { $0.poll.recordFailure(at: Date(), retryAfter: providerError?.retryAfter) }
            let connection: ConnectionState
            switch providerError {
            case .keychainNotAllowed?: connection = .needsSetup(.claudeNotConnected)
            case .notSignedIn?: connection = .needsSetup(.claudeNotSignedIn)
            case .tokenExpired?: connection = .needsSetup(.claudeExpired)
            case .unauthorized?, .keychainDenied?, .http(status: 403)?:
                connection = .needsSetup(.claudeRelogin(error.localizedDescription))
            default:
                connection = .failing(error.localizedDescription)
            }
            update(.claude) { $0.connection = connection }
        }
    }

    /// Newest observation wins; every source reports server-side values.
    private func apply(_ incoming: UsageSnapshot, to provider: Provider, countsAsPoll: Bool) {
        update(provider) { state in
            let previous = state.snapshot
            let chosen = UsageSnapshot.newest([previous, incoming]) ?? incoming
            // Metadata (plan, email) from a live query survives a newer passive value.
            var merged = chosen
            if merged.planName == nil { merged.planName = incoming.planName ?? previous?.planName }
            if merged.accountLabel == nil { merged.accountLabel = incoming.accountLabel ?? previous?.accountLabel }
            if merged.credits.isEmpty { merged.credits = incoming.credits.isEmpty ? (previous?.credits ?? []) : incoming.credits }
            let changed = merged.hasDifferentUsage(than: previous)
            state.snapshot = merged
            if countsAsPoll {
                state.poll.recordSuccess(at: Date(), usageChanged: changed)
            } else if changed {
                state.poll.lastChangeAt = Date()
            }
        }
        now = Date()
    }

    // MARK: - Local sources

    private func loadLocalSources() {
        loadCodexLog()
        loadBridge()
        lastCodexLogChange = codexLog.newestModificationDate()
        lastBridgeChange = bridge.bridgeFileModificationDate()
    }

    private func loadCodexLog() {
        let source = codexLog
        Task {
            let snapshot = await Task.detached(priority: .utility) { source.latestSnapshot() }.value
            if let snapshot { apply(snapshot, to: .codex, countsAsPoll: false) }
        }
    }

    private func loadBridge() {
        if let snapshot = bridge.latestSnapshot() {
            apply(snapshot, to: .claude, countsAsPoll: false)
        }
    }

    /// Cheap file-time checks: local use of Codex / Claude Code means usage
    /// is moving, so ask the servers soon.
    private func checkLocalActivity() {
        let source = codexLog
        let bridge = self.bridge
        Task {
            let (codexChange, bridgeChange) = await Task.detached(priority: .utility) {
                (source.newestModificationDate(), bridge.bridgeFileModificationDate())
            }.value

            if let codexChange, codexChange != lastCodexLogChange {
                lastCodexLogChange = codexChange
                loadCodexLog()
                kick(.codex)
            }
            if let bridgeChange, bridgeChange != lastBridgeChange {
                lastBridgeChange = bridgeChange
                loadBridge()
                kick(.claude)
            }
        }
    }

    private func networkChanged(satisfied: Bool) {
        if satisfied, networkWasDown {
            kickAll(after: 2)
        }
        networkWasDown = !satisfied
    }

    private func codexLoginFinished(success: Bool, error: String?) {
        if success {
            update(.codex) { $0.connection = .connecting("Signed in. Loading usage…"); $0.poll = PollState() }
            kick(.codex)
        } else {
            update(.codex) { $0.connection = .failing(error ?? "Sign-in did not complete.") }
        }
    }

    // MARK: - Helpers

    private func update(_ provider: Provider, _ body: (inout ProviderState) -> Void) {
        var state = states[provider] ?? ProviderState()
        body(&state)
        states[provider] = state
    }

    private func repeatingTimer(interval: TimeInterval, _ action: @escaping @MainActor () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            Task { @MainActor in action() }
        }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}

/// An interruptible sleep: `wake(after:)` can only bring the wake-up closer.
@MainActor
final class Waker {
    private var continuation: CheckedContinuation<Void, Never>?
    private var timer: Timer?

    func sleep(_ seconds: TimeInterval) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.continuation = continuation
            schedule(after: seconds)
        }
    }

    func wake(after seconds: TimeInterval) {
        guard continuation != nil else { return }
        let target = Date().addingTimeInterval(max(0, seconds))
        if let fireDate = timer?.fireDate, fireDate <= target { return }
        schedule(after: seconds)
    }

    func cancel() {
        fire()
    }

    private func schedule(after seconds: TimeInterval) {
        timer?.invalidate()
        let timer = Timer(timeInterval: max(0, seconds), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.fire() }
        }
        timer.tolerance = min(5, max(0, seconds) * 0.05)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func fire() {
        timer?.invalidate()
        timer = nil
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume()
    }
}
