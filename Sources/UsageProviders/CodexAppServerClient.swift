import Foundation
import UsageCore

/// Long-lived `codex app-server` child process speaking newline-delimited
/// JSON-RPC over stdio. One process is reused for every read; if it exits,
/// pending requests fail and the next `start()` launches a fresh one.
public final class CodexAppServerClient: @unchecked Sendable {
    public enum ClientError: Error, LocalizedError, Equatable {
        case notRunning
        case timeout(method: String)
        case server(code: Int, message: String)
        case processExited(status: Int32, detail: String)

        public var errorDescription: String? {
            switch self {
            case .notRunning:
                return "codex app-server is not running."
            case .timeout(let method):
                return "codex app-server did not answer \(method) in time."
            case .server(_, let message):
                return "codex app-server: \(message)"
            case .processExited(let status, let detail):
                let suffix = detail.isEmpty ? "" : " — \(detail)"
                return "codex app-server exited (\(status))\(suffix)"
            }
        }
    }

    public typealias NotificationHandler = @Sendable (_ method: String, _ params: Data?) -> Void
    public typealias TerminationHandler = @Sendable (_ status: Int32) -> Void

    private let executableURL: URL
    private let arguments: [String]
    private let environment: [String: String]?
    private let requestTimeout: TimeInterval
    private let queue = DispatchQueue(label: "com.larrymoon.howmuchusage.codex-app-server")

    // Everything below is only touched on `queue`.
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var buffer = LineBuffer()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var stderrTail = ""
    private var notificationHandler: NotificationHandler?
    private var terminationHandler: TerminationHandler?

    public init(
        executableURL: URL,
        arguments: [String] = ["app-server"],
        environment: [String: String]? = nil,
        requestTimeout: TimeInterval = 20
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.requestTimeout = requestTimeout
        ProcessRunner.ignoreSIGPIPE()
    }

    deinit {
        process?.terminate()
    }

    public func setHandlers(notification: NotificationHandler?, termination: TerminationHandler?) {
        queue.sync {
            notificationHandler = notification
            terminationHandler = termination
        }
    }

    public var isRunning: Bool {
        queue.sync { process?.isRunning == true }
    }

    /// Launches the process and performs the `initialize` handshake.
    public func start(clientName: String = "howmuchusage", clientTitle: String = "Howmuchusage", clientVersion: String) async throws {
        try queue.sync { try launchLocked() }
        let params: [String: Any] = [
            "clientInfo": ["name": clientName, "title": clientTitle, "version": clientVersion],
            "capabilities": ["experimentalApi": false, "requestAttestation": false]
        ]
        do {
            _ = try await request("initialize", params: params)
            try sendLine(RPCMessage.encodeNotification(method: "initialized"))
        } catch {
            stop()
            throw error
        }
    }

    public func stop() {
        queue.sync {
            if process?.isRunning == true { process?.terminate() }
        }
    }

    /// Sends a request and returns the raw JSON `result`.
    public func request(_ method: String, params: [String: Any]? = nil) async throws -> Data {
        let timeout = requestTimeout
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard let handle = self.stdinHandle, self.process?.isRunning == true else {
                    continuation.resume(throwing: ClientError.notRunning)
                    return
                }
                let id = self.nextID
                self.nextID += 1
                do {
                    let line = try RPCMessage.encodeRequest(id: id, method: method, params: params)
                    self.pending[id] = continuation
                    try handle.write(contentsOf: line)
                } catch {
                    self.pending.removeValue(forKey: id)
                    continuation.resume(throwing: error)
                    return
                }
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    self.pending.removeValue(forKey: id)?.resume(throwing: ClientError.timeout(method: method))
                }
            }
        }
    }

    private func sendLine(_ line: Data) throws {
        try queue.sync {
            guard let handle = stdinHandle else { throw ClientError.notRunning }
            try handle.write(contentsOf: line)
        }
    }

    // MARK: - Queue-confined internals

    private func launchLocked() throws {
        if process?.isRunning == true { return }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        if let environment { process.environment = environment }

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.queue.async { self?.receiveLocked(data) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.queue.async { self?.appendStderrLocked(data) }
        }
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            self?.queue.async { self?.handleTerminationLocked(finished, status: status) }
        }

        buffer = LineBuffer()
        stderrTail = ""
        try process.run()
        self.process = process
        stdinHandle = inPipe.fileHandleForWriting
    }

    private func receiveLocked(_ data: Data) {
        for line in buffer.append(data) {
            switch RPCMessage.parse(line) {
            case .response(let id, let result):
                pending.removeValue(forKey: id)?.resume(returning: result)
            case .error(let id, let code, let message):
                pending.removeValue(forKey: id)?.resume(throwing: ClientError.server(code: code, message: message))
            case .notification(let method, let params):
                if let handler = notificationHandler {
                    DispatchQueue.global(qos: .utility).async { handler(method, params) }
                }
            case .request(let id, _):
                // No threads are ever started, so approvals etc. are unexpected.
                if let reply = try? RPCMessage.encodeErrorResponse(id: id, code: -32601, message: "Not supported by Howmuchusage") {
                    try? stdinHandle?.write(contentsOf: reply)
                }
            case .invalid:
                continue
            }
        }
    }

    private func appendStderrLocked(_ data: Data) {
        stderrTail += String(decoding: data, as: UTF8.self)
        if stderrTail.count > 2_000 {
            stderrTail = String(stderrTail.suffix(2_000))
        }
    }

    private func handleTerminationLocked(_ finished: Process, status: Int32) {
        // A stale termination from an older process must not tear down a new one.
        guard finished === process else { return }
        let detail = stderrTail
            .split(whereSeparator: \.isNewline)
            .last
            .map(String.init) ?? ""
        let error = ClientError.processExited(status: status, detail: detail)
        let waiting = pending
        pending.removeAll()
        waiting.values.forEach { $0.resume(throwing: error) }
        process = nil
        stdinHandle = nil
        if let handler = terminationHandler {
            DispatchQueue.global(qos: .utility).async { handler(status) }
        }
    }
}
