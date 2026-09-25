import Foundation
import UsageCore

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0.0-dev"
    }
}

enum DisplayMode: String, CaseIterable, Identifiable {
    case both
    case claude
    case codex

    var id: String { rawValue }

    var title: String {
        switch self {
        case .both: return "Both"
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }

    var providers: [Provider] {
        switch self {
        case .both: return [.claude, .codex]
        case .claude: return [.claude]
        case .codex: return [.codex]
        }
    }
}

/// How much of the menu bar the item may take.
enum MenuBarSize: String, CaseIterable, Identifiable {
    /// Full bars when they fit; numbers only when macOS would hide the item.
    case auto
    case full
    case compact

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Auto"
        case .full: return "Full"
        case .compact: return "Compact"
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    private enum Key {
        static let displayMode = "displayMode"
        static let menuBarSize = "menuBarSize"
        static let claudeConnected = "claudeConnected"
        // Renamed so everyone starts with renewal off: the first Keychain
        // write-back (via `security -i`) truncated logins longer than ~2 KB.
        static let claudeAutoRefresh = "claudeAutoRefreshV2"
        static let codexPath = "codexPath"
        static let hasLaunchedBefore = "hasLaunchedBefore"
    }

    private let defaults: UserDefaults

    @Published var displayMode: DisplayMode {
        didSet { defaults.set(displayMode.rawValue, forKey: Key.displayMode) }
    }

    @Published var menuBarSize: MenuBarSize {
        didSet { defaults.set(menuBarSize.rawValue, forKey: Key.menuBarSize) }
    }

    /// The user agreed to let the app read Claude Code's login from Keychain.
    @Published var claudeConnected: Bool {
        didSet { defaults.set(claudeConnected, forKey: Key.claudeConnected) }
    }

    /// Renew an expired Claude Code login here and save it back to Keychain.
    @Published var claudeAutoRefresh: Bool {
        didSet { defaults.set(claudeAutoRefresh, forKey: Key.claudeAutoRefresh) }
    }

    @Published var codexPath: String? {
        didSet { defaults.set(codexPath, forKey: Key.codexPath) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        displayMode = DisplayMode(rawValue: defaults.string(forKey: Key.displayMode) ?? "") ?? .both
        menuBarSize = MenuBarSize(rawValue: defaults.string(forKey: Key.menuBarSize) ?? "") ?? .auto
        claudeConnected = defaults.bool(forKey: Key.claudeConnected)
        claudeAutoRefresh = defaults.object(forKey: Key.claudeAutoRefresh) as? Bool ?? false
        codexPath = defaults.string(forKey: Key.codexPath)
    }

    /// True exactly once, on the very first launch.
    func consumeFirstLaunch() -> Bool {
        guard !defaults.bool(forKey: Key.hasLaunchedBefore) else { return false }
        defaults.set(true, forKey: Key.hasLaunchedBefore)
        return true
    }
}
