import CodexUsageCore
import Foundation

enum ProbeFormat: String {
    case json
    case swiftbar
    case text
}

struct ProbeArguments {
    var sessionsRoot: URL?
    var format: ProbeFormat = .json

    init(arguments: [String]) throws {
        var iterator = arguments.dropFirst().makeIterator()

        while let argument = iterator.next() {
            switch argument {
            case "probe":
                continue
            case "--sessions-root":
                guard let value = iterator.next() else {
                    throw ArgumentError.missingValue("--sessions-root")
                }
                sessionsRoot = URL(fileURLWithPath: NSString(string: value).expandingTildeInPath)
            case "--format":
                guard let value = iterator.next() else {
                    throw ArgumentError.missingValue("--format")
                }
                guard let parsed = ProbeFormat(rawValue: value) else {
                    throw ArgumentError.invalidValue("--format", value)
                }
                format = parsed
            case "--help", "-h":
                print(Self.help)
                Foundation.exit(0)
            default:
                throw ArgumentError.unknown(argument)
            }
        }
    }

    static let help = """
    howmuchusage-probe [probe] [--format json|swiftbar|text] [--sessions-root PATH]

    Reads local Codex session JSONL files and prints the latest rate_limits snapshot.
    """
}

enum ArgumentError: Error, LocalizedError {
    case missingValue(String)
    case invalidValue(String, String)
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .missingValue(let option):
            return "Missing value for \(option)"
        case .invalidValue(let option, let value):
            return "Invalid value for \(option): \(value)"
        case .unknown(let argument):
            return "Unknown argument: \(argument)"
        }
    }
}

do {
    let arguments = try ProbeArguments(arguments: CommandLine.arguments)
    let reader = CodexUsageReader(
        sessionRoot: arguments.sessionsRoot ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
            .appendingPathComponent("sessions")
    )
    let snapshot = try reader.latestSnapshot()

    switch arguments.format {
    case .json:
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(ProbeOutput(snapshot: snapshot))
        print(String(decoding: data, as: UTF8.self))
    case .swiftbar:
        print(CodexUsageFormatter.swiftBarOutput(snapshot: snapshot))
    case .text:
        print(CodexUsageFormatter.textOutput(snapshot: snapshot))
    }
} catch {
    fputs("howmuchusage-probe: \(error.localizedDescription)\n", stderr)
    Foundation.exit(2)
}

