import AppKit
import ServiceManagement
import SwiftUI
import UsageCore
import UsageProviders

struct UsagePopover: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Howmuchusage")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                Spacer()
                Button {
                    store.refreshNow()
                } label: {
                    HStack(spacing: 4) {
                        if store.isAnyRefreshing {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text("Refresh")
                    }
                    .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut("r", modifiers: .command)
                .help("Check all services now (⌘R). Services checked moments ago wait out their minimum interval.")
            }

            if let note = store.refreshNote {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }

            ForEach(settings.displayMode.providers, id: \.self) { provider in
                ProviderSection(store: store, provider: provider)
                Divider()
            }

            SettingsSection(store: store, settings: settings)

            HStack {
                Menu("Official usage") {
                    ForEach(Provider.allCases, id: \.self) { provider in
                        Button(provider.displayName) { NSWorkspace.shared.open(provider.usageURL) }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .font(.caption)
        }
        .padding(14)
        .frame(width: 320)
    }
}

struct ProviderSection: View {
    @ObservedObject var store: UsageStore
    let provider: Provider

    var body: some View {
        let state = store.state(for: provider)
        VStack(alignment: .leading, spacing: 8) {
            header(state)

            if let snapshot = state.snapshot, let freshness = store.freshness(for: provider) {
                ForEach([snapshot.session, snapshot.weekly].compactMap { $0 }, id: \.self) { window in
                    BatteryUsageRow(line: UsageDisplay.line(for: window, freshness: freshness, now: store.now), now: store.now)
                }
                // Unlabeled internal limits (API codenames) are left to the probe CLI.
                ForEach(snapshot.extraWindows.filter(\.isNamedModelLimit), id: \.self) { window in
                    CompactUsageRow(window: window, line: UsageDisplay.line(for: window, freshness: freshness, now: store.now), now: store.now)
                }
                ForEach(snapshot.credits, id: \.self) { credit in
                    CreditRow(credit: credit, now: store.now)
                }
                ForEach(snapshot.notes, id: \.self) { note in
                    Text(note).font(.caption2).foregroundStyle(.secondary)
                }
                SourceLine(snapshot: snapshot, state: state, now: store.now)
            }

            if let warning = state.warning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ConnectionView(store: store, provider: provider, state: state)
        }
    }

    @ViewBuilder
    private func header(_ state: ProviderState) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(provider.displayName)
                .font(.system(size: 12, weight: .bold, design: .rounded))
            if let plan = state.snapshot?.planName {
                Text(plan)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }
            Spacer()
            FreshnessBadge(freshness: store.freshness(for: provider), snapshot: state.snapshot, isRefreshing: state.isRefreshing, now: store.now)
        }
    }
}

struct FreshnessBadge: View {
    let freshness: Freshness?
    let snapshot: UsageSnapshot?
    let isRefreshing: Bool
    let now: Date

    var body: some View {
        HStack(spacing: 4) {
            if isRefreshing {
                ProgressView().controlSize(.mini)
            } else {
                Circle().fill(color).frame(width: 6, height: 6)
            }
            Text(text)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private var text: String {
        guard let freshness, let snapshot else { return "No data" }
        let prefix = freshness == .live ? "Live" : "~ \(freshness.label)"
        return "\(prefix) · \(UsageFormat.age(since: snapshot.observedAt, now: now))"
    }

    private var color: Color {
        switch freshness {
        case .live?: return .green
        case .recent?: return .yellow
        case .stale?, nil: return .gray
        }
    }
}

struct BatteryUsageRow: View {
    let line: DisplayLine
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(line.displayLabel)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .frame(width: 26, alignment: .leading)
                Text(line.remainingPercent.map { "\($0)% left" } ?? "unknown")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(UsageColors.swiftUI(line.level))
                Spacer(minLength: 8)
                Text(resetSummary)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            BatteryBar(remaining: line.remainingPercent ?? 0, level: line.level, height: 5)
        }
    }

    private var resetSummary: String {
        if line.isResetPassed {
            return line.remainingPercent == nil ? "reset passed · waiting for a fresh read" : "just reset · confirming"
        }
        guard let resetsAt = line.resetsAt else { return "" }
        return "resets in \(UsageFormat.timeUntil(resetsAt, now: now)) · \(UsageFormat.resetTime(resetsAt))"
    }
}

struct CompactUsageRow: View {
    let window: UsageWindow
    let line: DisplayLine
    let now: Date

    var body: some View {
        HStack(spacing: 6) {
            Text(window.title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            BatteryBar(remaining: line.remainingPercent ?? 0, level: line.level, height: 3)
            Text(line.percentText)
                .font(.caption2)
                .monospacedDigit()
                .frame(width: 32, alignment: .trailing)
        }
    }
}

struct BatteryBar: View {
    let remaining: Int
    let level: UsageLevel
    let height: CGFloat

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height / 2).fill(Color.secondary.opacity(0.16))
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(UsageColors.swiftUI(level))
                    .frame(width: remaining > 0 ? max(height, proxy.size.width * CGFloat(min(100, remaining)) / 100) : 0)
            }
        }
        .frame(height: height)
    }
}

struct SourceLine: View {
    let snapshot: UsageSnapshot
    let state: ProviderState
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(sourceText)
            if let next = state.nextRefreshAt, next > now {
                Text("Next check in \(UsageFormat.duration(next.timeIntervalSince(now)))")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
    }

    private var sourceText: String {
        var parts = ["Source: \(snapshot.source.displayName)"]
        if !snapshot.source.isActiveAccountQuery { parts.append("this Mac only") }
        if let account = snapshot.accountLabel { parts.append(account) }
        return parts.joined(separator: " · ")
    }
}

struct ConnectionView: View {
    @ObservedObject var store: UsageStore
    let provider: Provider
    let state: ProviderState

    var body: some View {
        switch state.connection {
        case .idle, .connected:
            EmptyView()
        case .connecting(let message):
            Label(message, systemImage: "hourglass")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failing(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .needsSetup(let need):
            VStack(alignment: .leading, spacing: 6) {
                Text(need.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    actions(for: need)
                }
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func actions(for need: SetupNeed) -> some View {
        switch need {
        case .codexNotInstalled:
            Button("Copy install command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("brew install codex", forType: .string)
            }
            Button("Locate codex…") { locateCodex() }
        case .codexSignedOut:
            Button("Sign in with ChatGPT") { store.connectCodex() }
                .buttonStyle(.borderedProminent)
        case .codexAPIKey:
            Button("Sign in with ChatGPT") { store.connectCodex() }
        case .claudeNotConnected:
            Button("Connect Claude") { store.connectClaude() }
                .buttonStyle(.borderedProminent)
                .help("Reads the login Claude Code keeps in Keychain. Choose \"Always Allow\" once.")
        case .claudeNotSignedIn, .claudeRelogin:
            Button("Sign in via Claude Code") { store.openClaudeSignIn() }
            Button("Retry") { store.connectClaude() }
        case .claudeExpired:
            Button("Open Claude Code") { store.openClaudeSignIn() }
            Button("Retry") { store.kick(.claude) }
        }
    }

    private func locateCodex() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = "Choose the codex executable"
        if panel.runModal() == .OK, let url = panel.url {
            store.setCodexPath(url.path)
        }
    }
}

struct SettingsSection: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: AppSettings
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var bridgeInstalled = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Menu bar", selection: $settings.displayMode) {
                ForEach(DisplayMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Picker("Size", selection: $settings.menuBarSize) {
                ForEach(MenuBarSize.allCases) { size in
                    Text(size.title).tag(size)
                }
            }
            .pickerStyle(.segmented)
            .help("Auto shows full bars when they fit and switches to numbers only when macOS would hide the item.")

            Toggle("Launch at Login", isOn: Binding(
                get: { launchAtLogin },
                set: { setLaunchAtLogin($0) }
            ))
            .toggleStyle(.switch)

            Toggle(isOn: Binding(
                get: { bridgeInstalled },
                set: { setBridge($0) }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Claude Code statusline hint")
                    Text("Instant updates while Claude Code runs on this Mac")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            if settings.claudeConnected {
                Toggle(isOn: Binding(
                    get: { settings.claudeAutoRefresh },
                    set: { store.setClaudeAutoRefresh($0) }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Renew Claude login automatically")
                        Text("Saves the renewed login back for Claude Code")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                Button("Disconnect Claude") { store.disconnectClaude() }
                    .buttonStyle(.link)
                    .font(.caption2)
            }

            if let message {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.caption)
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            bridgeInstalled = store.bridge.isInstalled
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            message = SMAppService.mainApp.status == .requiresApproval
                ? "Allow Howmuchusage in System Settings › General › Login Items."
                : nil
        } catch {
            message = "Launch at Login: \(error.localizedDescription) (install the app in /Applications first)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func setBridge(_ enabled: Bool) {
        do {
            try store.setStatuslineBridge(enabled: enabled)
            message = nil
        } catch {
            message = error.localizedDescription
        }
        bridgeInstalled = store.bridge.isInstalled
    }
}

enum UsageColors {
    static func swiftUI(_ level: UsageLevel) -> Color {
        switch level {
        case .good: return .green
        case .warning: return .yellow
        case .critical: return .red
        case .stale: return .secondary
        }
    }
}

struct CreditRow: View {
    let credit: CreditBalance
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(credit.name)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 96, alignment: .leading)
                BatteryBar(remaining: credit.remainingPercent, level: .forRemaining(credit.remainingPercent), height: 3)
                Text("\(credit.remainingPercent)%")
                    .font(.caption2)
                    .monospacedDigit()
                    .frame(width: 32, alignment: .trailing)
            }
            Text(detail)
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private var detail: String {
        guard let expiresAt = credit.expiresAt else { return credit.amountText }
        return "\(credit.amountText) · expires in \(UsageFormat.timeUntil(expiresAt, now: now))"
    }
}
