import Foundation
import UsageCore

public enum AppPaths {
    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? BinaryLocator.home.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Howmuchusage", isDirectory: true)
    }

    public static var codexSessionsDirectory: URL {
        BinaryLocator.home.appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    public static var claudeSettingsFile: URL {
        BinaryLocator.home.appendingPathComponent(".claude/settings.json")
    }
}

/// Passive Codex fallback: `rate_limits` from local session logs. Only changes
/// while Codex runs on this Mac, so it is used when app-server is unavailable
/// or when it happens to be newer.
public struct CodexSessionLogSource: Sendable {
    public let root: URL
    public let daysBack: Int
    public let maxFiles: Int
    public let tailBytes: Int

    public init(root: URL = AppPaths.codexSessionsDirectory, daysBack: Int = 8, maxFiles: Int = 3, tailBytes: Int = 2_000_000) {
        self.root = root
        self.daysBack = daysBack
        self.maxFiles = maxFiles
        self.tailBytes = tailBytes
    }

    public func latestSnapshot(now: Date = Date()) -> UsageSnapshot? {
        let files = recentFiles(now: now).prefix(maxFiles)
        return UsageSnapshot.newest(files.map { file in
            readTail(of: file.url).flatMap(CodexSessionLogParser.latestSnapshot(inJSONLines:))
        })
    }

    /// Cheap activity signal: newest log modification time.
    public func newestModificationDate(now: Date = Date()) -> Date? {
        recentFiles(now: now, daysBack: 2).first?.modified
    }

    private func recentFiles(now: Date, daysBack: Int? = nil) -> [(url: URL, modified: Date)] {
        let fileManager = FileManager.default
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var files: [(URL, Date)] = []

        for offset in 0..<(daysBack ?? self.daysBack) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            guard let year = parts.year, let month = parts.month, let dayOfMonth = parts.day else { continue }
            let directory = root
                .appendingPathComponent(String(format: "%04d", year))
                .appendingPathComponent(String(format: "%02d", month))
                .appendingPathComponent(String(format: "%02d", dayOfMonth))
            guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { continue }
            for name in names where name.hasSuffix(".jsonl") {
                let url = directory.appendingPathComponent(name)
                let modified = (try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
                files.append((url, modified))
            }
        }
        return files.sorted { $0.1 > $1.1 }.map { (url: $0.0, modified: $0.1) }
    }

    private func readTail(of url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let offset = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        do {
            try handle.seek(toOffset: offset)
            guard var data = try handle.readToEnd() else { return nil }
            if offset > 0, let newline = data.firstIndex(of: 0x0A) {
                // Drop the partial first line.
                data = Data(data[data.index(after: newline)...])
            }
            return data
        } catch {
            return nil
        }
    }
}
