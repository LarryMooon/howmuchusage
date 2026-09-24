import Foundation
import UsageCore

/// Optional Claude Code statusline integration (officially documented input).
///
/// Installing points Claude Code's `statusLine.command` at a tiny script that
/// runs this app's binary in `--statusline-bridge` mode. The bridge saves only
/// `rate_limits` to a file the menu bar app watches, then runs the user's
/// previous statusline command so their terminal looks exactly the same.
public struct StatuslineBridge: Sendable {
    public enum BridgeError: Error, LocalizedError, Equatable {
        case unreadableSettings
        case notInstalled

        public var errorDescription: String? {
            switch self {
            case .unreadableSettings:
                return "~/.claude/settings.json is not valid JSON; left untouched."
            case .notInstalled:
                return "The statusline bridge is not installed."
            }
        }
    }

    public static let launchArgument = "--statusline-bridge"

    public let supportDirectory: URL
    public let claudeSettingsFile: URL

    public init(supportDirectory: URL = AppPaths.supportDirectory, claudeSettingsFile: URL = AppPaths.claudeSettingsFile) {
        self.supportDirectory = supportDirectory
        self.claudeSettingsFile = claudeSettingsFile
    }

    public var bridgeFile: URL { supportDirectory.appendingPathComponent("claude-statusline.json") }
    public var scriptFile: URL { supportDirectory.appendingPathComponent("claude-statusline-bridge.sh") }
    /// Previous `statusLine` object, restored on uninstall.
    public var previousSettingFile: URL { supportDirectory.appendingPathComponent("statusline-previous.json") }
    /// Previous command as plain text, chained by the bridge.
    public var previousCommandFile: URL { supportDirectory.appendingPathComponent("statusline-previous-command.txt") }

    var bridgeCommand: String { "\"\(scriptFile.path)\"" }

    // MARK: - Install state

    public var isInstalled: Bool {
        guard let settings = try? readSettings(),
              let statusLine = settings["statusLine"] as? [String: Any],
              let command = statusLine["command"] as? String else {
            return false
        }
        return command == bridgeCommand
    }

    public func install(appExecutable: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)

        var settings = try readSettings() ?? [:]
        if fileManager.fileExists(atPath: claudeSettingsFile.path) {
            let backup = claudeSettingsFile.appendingPathExtension("howmuchusage-backup")
            try? fileManager.removeItem(at: backup)
            try fileManager.copyItem(at: claudeSettingsFile, to: backup)
        } else {
            try fileManager.createDirectory(at: claudeSettingsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        }

        let previous = settings["statusLine"] as? [String: Any]
        let previousCommand = previous?["command"] as? String
        if previousCommand != bridgeCommand {
            // Remember what the user had so it keeps rendering and can be restored.
            let record: [String: Any] = previous.map { ["statusLine": $0] } ?? [:]
            try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
                .write(to: previousSettingFile, options: .atomic)
            try Data((previousCommand ?? "").utf8).write(to: previousCommandFile, options: .atomic)
        }

        try Data(Self.script(appExecutable: appExecutable, previousCommandFile: previousCommandFile).utf8)
            .write(to: scriptFile, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptFile.path)

        var statusLine: [String: Any] = ["type": "command", "command": bridgeCommand]
        statusLine["padding"] = previous?["padding"] ?? 0
        if let refresh = previous?["refreshInterval"] { statusLine["refreshInterval"] = refresh }
        settings["statusLine"] = statusLine
        try writeSettings(settings)
    }

    public func uninstall() throws {
        guard var settings = try readSettings(), isInstalled else { throw BridgeError.notInstalled }
        if let data = try? Data(contentsOf: previousSettingFile),
           let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let previous = record["statusLine"] {
            settings["statusLine"] = previous
        } else {
            settings.removeValue(forKey: "statusLine")
        }
        try writeSettings(settings)
        try? FileManager.default.removeItem(at: previousSettingFile)
        try? FileManager.default.removeItem(at: previousCommandFile)
    }

    // MARK: - Reading captured values

    public func latestSnapshot() -> UsageSnapshot? {
        guard let data = try? Data(contentsOf: bridgeFile) else { return nil }
        return ClaudeStatuslineParser.snapshot(fromBridgeFile: data)
    }

    public func bridgeFileModificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: bridgeFile.path))?[.modificationDate] as? Date
    }

    // MARK: - Bridge mode (runs inside Claude Code's statusline call)

    /// Captures `rate_limits`, then returns what the statusline should print.
    public func runBridge(input: Data, now: Date = Date()) -> Data {
        let limits = ClaudeStatuslineParser.rateLimits(fromStatuslineInput: input)
        if let limits {
            let existing = try? Data(contentsOf: bridgeFile)
            // Unchanged values keep their older timestamp: never overclaim freshness.
            if !ClaudeStatuslineParser.bridgeFile(existing, hasSameRateLimitsAs: limits),
               let data = try? ClaudeStatuslineParser.bridgeFileData(rateLimits: limits, observedAt: now) {
                try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
                try? data.write(to: bridgeFile, options: .atomic)
            }
        }

        let previousCommand = (try? String(contentsOf: previousCommandFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !previousCommand.isEmpty,
           let result = try? ProcessRunner.runBlocking(
               URL(fileURLWithPath: "/bin/sh"),
               arguments: ["-c", previousCommand],
               stdin: input,
               timeout: 10
           ) {
            return result.stdout
        }
        return Data((ClaudeStatuslineParser.defaultStatusText(rateLimits: limits) + "\n").utf8)
    }

    // MARK: - Helpers

    static func script(appExecutable: URL, previousCommandFile: URL) -> String {
        """
        #!/bin/sh
        # Installed by Howmuchusage. Saves Claude Code rate_limits for the menu bar
        # app, then runs your previous statusline command. Remove it from the app.
        APP=\(shellQuote(appExecutable.path))
        if [ -x "$APP" ]; then
          exec "$APP" \(launchArgument)
        fi
        PREVIOUS=\(shellQuote(previousCommandFile.path))
        if [ -s "$PREVIOUS" ]; then
          exec /bin/sh -c "$(cat "$PREVIOUS")"
        fi
        cat >/dev/null

        """
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func readSettings() throws -> [String: Any]? {
        guard let data = try? Data(contentsOf: claudeSettingsFile) else { return nil }
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BridgeError.unreadableSettings
        }
        return object
    }

    private func writeSettings(_ settings: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        try data.write(to: claudeSettingsFile, options: .atomic)
    }
}
