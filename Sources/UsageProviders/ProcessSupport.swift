import Foundation

public struct ProcessResult: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data
    public let timedOut: Bool

    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

/// Thread-safe byte accumulator for pipe readers.
final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func set(_ data: Data) {
        lock.lock(); storage = data; lock.unlock()
    }

    var value: Data {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    func set() {
        lock.lock(); storage = true; lock.unlock()
    }

    var value: Bool {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}

public enum ProcessRunner {
    /// Runs a short-lived command off the main thread with a hard timeout.
    public static func run(
        _ executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        stdin: Data? = nil,
        timeout: TimeInterval
    ) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    continuation.resume(returning: try runBlocking(
                        executable,
                        arguments: arguments,
                        environment: environment,
                        stdin: stdin,
                        timeout: timeout
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public static func runBlocking(
        _ executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        stdin: Data? = nil,
        timeout: TimeInterval
    ) throws -> ProcessResult {
        ignoreSIGPIPE()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }

        let outPipe = Pipe()
        let errPipe = Pipe()
        let inPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = stdin == nil ? FileHandle.nullDevice : inPipe

        try process.run()

        let out = LockedData()
        let err = LockedData()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            out.set(outPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            err.set(errPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }

        if let stdin {
            try? inPipe.fileHandleForWriting.write(contentsOf: stdin)
            try? inPipe.fileHandleForWriting.close()
        }

        let timedOut = LockedFlag()
        let killer = DispatchWorkItem {
            if process.isRunning {
                timedOut.set()
                process.terminate()
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: killer)
        process.waitUntilExit()
        killer.cancel()
        group.wait()

        return ProcessResult(
            status: process.terminationStatus,
            stdout: out.value,
            stderr: err.value,
            timedOut: timedOut.value
        )
    }

    /// Writing to a pipe whose reader died must not kill the app.
    public static func ignoreSIGPIPE() {
        signal(SIGPIPE, SIG_IGN)
    }
}

/// Finds command-line tools from a GUI app, which does not inherit the
/// user's shell PATH.
public enum BinaryLocator {
    public static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    public static func commonDirectories(home: URL = BinaryLocator.home) -> [String] {
        [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            home.appendingPathComponent(".local/bin").path,
            home.appendingPathComponent(".npm-global/bin").path,
            home.appendingPathComponent(".volta/bin").path,
            home.appendingPathComponent(".bun/bin").path,
            home.appendingPathComponent("bin").path,
            "/usr/bin",
            "/bin"
        ]
    }

    public static func candidates(for name: String, home: URL = BinaryLocator.home) -> [String] {
        var paths = commonDirectories(home: home).map { "\($0)/\(name)" }
        // nvm installs one bin directory per Node version; newest first.
        let nvm = home.appendingPathComponent(".nvm/versions/node")
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm.path) {
            for version in versions.sorted(by: >) {
                paths.append(nvm.appendingPathComponent(version).appendingPathComponent("bin/\(name)").path)
            }
        }
        return paths
    }

    public static func locate(_ name: String, override: String? = nil, extraCandidates: [String] = []) async -> URL? {
        let fileManager = FileManager.default
        if let override, !override.isEmpty {
            let expanded = (override as NSString).expandingTildeInPath
            return fileManager.isExecutableFile(atPath: expanded) ? URL(fileURLWithPath: expanded) : nil
        }

        for path in extraCandidates + candidates(for: name) where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return await loginShellLookup(name)
    }

    /// Last resort: ask the user's login shell, which loads their PATH setup.
    static func loginShellLookup(_ name: String) async -> URL? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard let result = try? await ProcessRunner.run(
            URL(fileURLWithPath: shell),
            arguments: ["-lc", "command -v \(name)"],
            timeout: 5
        ), result.status == 0 else {
            return nil
        }
        let path = result.stdoutText
            .split(whereSeparator: \.isNewline)
            .last
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces)
        guard let path, path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    /// Environment for child tools: npm-installed CLIs need `node` on PATH.
    public static func childEnvironment(prependingDirectoryOf executable: URL? = nil) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        var directories: [String] = []
        if let executable { directories.append(executable.deletingLastPathComponent().path) }
        directories += commonDirectories()
        if let existing = environment["PATH"] { directories += existing.split(separator: ":").map(String.init) }
        var seen = Set<String>()
        environment["PATH"] = directories.filter { seen.insert($0).inserted }.joined(separator: ":")
        return environment
    }
}
