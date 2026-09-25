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

@MainActor
final class AppSettings: ObservableObject {
    private enum Key {
        static let displayMode = "displayMode"
        static let claudeConnected = "claudeConnected"
        static let claudeAutoRefresh = "claudeAutoRefresh"
        static let codexPath = "codexPath"
        static let hasLaunchedBefore = "hasLaunchedBefore"
    }

    private let defaults: UserDefaults

    @Published var displayMode: DisplayMode {
        didSet { defaults.set(displayMode.rawValue, forKey: Key.displayMode) }
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
        claudeConnected = defaults.bool(forKey: Key.claudeConnected)
        claudeAutoRefresh = defaults.object(forKey: Key.claudeAutoRefresh) as? Bool ?? true
        codexPath = defaults.string(forKey: Key.codexPath)
    }

    /// True exactly once, on the very first launch.
    func consumeFirstLaunch() -> Bool {
        guard !defaults.bool(forKey: Key.hasLaunchedBefore) else { return false }
        defaults.set(true, forKey: Key.hasLaunchedBefore)
        return true
    }
}
