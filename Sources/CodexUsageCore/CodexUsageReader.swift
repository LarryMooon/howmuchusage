import Foundation

public enum CodexUsageReaderError: Error, LocalizedError, Equatable {
    case sessionsRootMissing(String)
    case noUsageSnapshot(String)

    public var errorDescription: String? {
        switch self {
        case .sessionsRootMissing(let path):
            return "Codex sessions folder not found: \(path)"
        case .noUsageSnapshot(let path):
            return "No Codex rate_limits snapshot found under: \(path)"
        }
    }
}

public final class CodexUsageReader: @unchecked Sendable {
    private let sessionRoot: URL
    private let fileManager: FileManager
    private let maxFiles: Int
    private let maxBytesPerFile: UInt64

    public init(
        sessionRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
            .appendingPathComponent("sessions"),
        fileManager: FileManager = .default,
        maxFiles: Int = 80,
        maxBytesPerFile: UInt64 = 4 * 1_024 * 1_024
    ) {
        self.sessionRoot = sessionRoot
        self.fileManager = fileManager
        self.maxFiles = maxFiles
        self.maxBytesPerFile = maxBytesPerFile
    }

    public func latestSnapshot() throws -> CodexUsageSnapshot {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sessionRoot.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CodexUsageReaderError.sessionsRootMissing(sessionRoot.path)
        }

        let files = jsonlFiles()
        var best: CodexUsageSnapshot?

        for file in files.prefix(maxFiles) {
            if let currentBest = best, file.modifiedAt <= currentBest.observedAt {
                break
            }

            if let snapshot = latestSnapshot(in: file.url) {
                if let currentBest = best {
                    if snapshot.observedAt > currentBest.observedAt {
                        best = snapshot
                    }
                } else {
                    best = snapshot
                }
            }
        }

        guard let best else {
            throw CodexUsageReaderError.noUsageSnapshot(sessionRoot.path)
        }

        return best
    }

    private func jsonlFiles() -> [CandidateFile] {
        let datedFiles = recentDateDirectories().flatMap { directory in
            collectJSONLFiles(in: directory, recursive: false)
        }

        if !datedFiles.isEmpty {
            return sortedByModifiedDate(datedFiles)
        }

        return sortedByModifiedDate(collectJSONLFiles(in: sessionRoot, recursive: true))
    }

    private func recentDateDirectories(now: Date = Date()) -> [URL] {
        let calendar = Calendar.current

        return (0..<3).compactMap { dayOffset in
            guard let date = calendar.date(byAdding: .day, value: -dayOffset, to: now) else {
                return nil
            }

            let components = calendar.dateComponents([.year, .month, .day], from: date)
            guard let year = components.year,
                  let month = components.month,
                  let day = components.day
            else {
                return nil
            }

            return sessionRoot
                .appendingPathComponent(String(format: "%04d", year))
                .appendingPathComponent(String(format: "%02d", month))
                .appendingPathComponent(String(format: "%02d", day))
        }
    }

    private func collectJSONLFiles(in directory: URL, recursive: Bool) -> [URL] {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return []
        }

        if recursive {
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                return []
            }

            return enumerator.compactMap { item in
                guard let file = item as? URL, file.pathExtension == "jsonl" else { return nil }
                let values = try? file.resourceValues(forKeys: [.isRegularFileKey])
                return values?.isRegularFile == true ? file : nil
            }
        }

        guard let children = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return children.filter { file in
            guard file.pathExtension == "jsonl" else { return false }
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey])
            return values?.isRegularFile == true
        }
    }

    private func sortedByModifiedDate(_ urls: [URL]) -> [CandidateFile] {
        var files: [CandidateFile] = []

        for file in urls {
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }

            files.append(CandidateFile(url: file, modifiedAt: values?.contentModificationDate ?? .distantPast))
        }

        return files
            .sorted { lhs, rhs in
                if lhs.modifiedAt == rhs.modifiedAt {
                    return lhs.url.path > rhs.url.path
                }
                return lhs.modifiedAt > rhs.modifiedAt
            }
    }

    private func latestSnapshot(in file: URL) -> CodexUsageSnapshot? {
        guard let contents = tailString(from: file) else {
            return nil
        }

        var latest: CodexUsageSnapshot?
        let decoder = JSONDecoder()

        for (offset, line) in contents.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            guard line.contains("\"rate_limits\"") else {
                continue
            }

            guard let data = line.data(using: .utf8),
                  let event = try? decoder.decode(CodexLogEvent.self, from: data),
                  event.type == "event_msg",
                  let rateLimits = event.payload?.rateLimits,
                  let primary = rateLimits.primary?.windowSnapshot,
                  let secondary = rateLimits.secondary?.windowSnapshot
            else {
                continue
            }

            let observedAt = event.parsedTimestamp ?? fileModifiedDate(file) ?? .distantPast
            let snapshot = CodexUsageSnapshot(
                primary: primary,
                secondary: secondary,
                planType: rateLimits.planType,
                limitID: rateLimits.limitID,
                rateLimitReachedType: rateLimits.rateLimitReachedType,
                observedAt: observedAt,
                sourceFile: file.path,
                sourceLine: offset + 1
            )

            if let currentLatest = latest {
                if snapshot.observedAt > currentLatest.observedAt {
                    latest = snapshot
                }
            } else {
                latest = snapshot
            }
        }

        return latest
    }

    private func tailString(from file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else {
            return nil
        }

        defer {
            try? handle.close()
        }

        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0
        let startOffset = size > maxBytesPerFile ? size - maxBytesPerFile : 0

        do {
            try handle.seek(toOffset: startOffset)
            let data = try handle.readToEnd() ?? Data()
            guard var text = String(data: data, encoding: .utf8) else {
                return nil
            }

            if startOffset > 0, let firstNewline = text.firstIndex(of: "\n") {
                text.removeSubrange(text.startIndex...firstNewline)
            }

            return text
        } catch {
            return nil
        }
    }

    private func fileModifiedDate(_ file: URL) -> Date? {
        try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}

private struct CandidateFile {
    let url: URL
    let modifiedAt: Date
}

private struct CodexLogEvent: Decodable {
    let timestamp: String?
    let type: String?
    let payload: CodexLogPayload?

    var parsedTimestamp: Date? {
        timestamp.flatMap(Self.parseTimestamp)
    }

    private static func parseTimestamp(_ rawValue: String) -> Date? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        if let date = fractionalFormatter.date(from: rawValue) {
            return date
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: rawValue)
    }
}

private struct CodexLogPayload: Decodable {
    let rateLimits: CodexRateLimits?

    private enum CodingKeys: String, CodingKey {
        case rateLimits = "rate_limits"
    }
}

private struct CodexRateLimits: Decodable {
    let limitID: String?
    let primary: RawUsageWindow?
    let secondary: RawUsageWindow?
    let planType: String?
    let rateLimitReachedType: String?

    private enum CodingKeys: String, CodingKey {
        case limitID = "limit_id"
        case primary
        case secondary
        case planType = "plan_type"
        case rateLimitReachedType = "rate_limit_reached_type"
    }
}

private struct RawUsageWindow: Decodable {
    let usedPercent: Double
    let windowMinutes: Int
    let resetsAt: TimeInterval

    var windowSnapshot: UsageWindowSnapshot {
        UsageWindowSnapshot(
            usedPercent: usedPercent,
            windowMinutes: windowMinutes,
            resetsAt: Date(timeIntervalSince1970: resetsAt)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case windowMinutes = "window_minutes"
        case resetsAt = "resets_at"
    }
}
