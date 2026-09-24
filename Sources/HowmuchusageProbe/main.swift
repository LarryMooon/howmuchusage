import Foundation
import UsageCore
import UsageProviders

// Debug CLI: checks each connection exactly the way the menu bar app does.
//
//   howmuchusage-probe [all|codex|claude|local] [--json]

let arguments = Array(CommandLine.arguments.dropFirst())
let wantsJSON = arguments.contains("--json")
let target = arguments.first { !$0.hasPrefix("--") } ?? "all"
let version = "2.0.0-probe"

guard ["all", "codex", "claude", "local"].contains(target) else {
    print("usage: howmuchusage-probe [all|codex|claude|local] [--json]")
    exit(2)
}

ProcessRunner.ignoreSIGPIPE()

struct ProbeResult: Encodable {
    let source: String
    let ok: Bool
    let error: String?
    let snapshot: UsageSnapshot?
    let elapsedSeconds: Double
}

func measure(_ source: String, _ body: () async throws -> UsageSnapshot?) async -> ProbeResult {
    let started = Date()
    do {
        let snapshot = try await body()
        return ProbeResult(
            source: source,
            ok: snapshot != nil,
            error: snapshot == nil ? "no data" : nil,
            snapshot: snapshot,
            elapsedSeconds: Date().timeIntervalSince(started)
        )
    } catch {
        return ProbeResult(
            source: source,
            ok: false,
            error: (error as? LocalizedError)?.errorDescription ?? String(describing: error),
            snapshot: nil,
            elapsedSeconds: Date().timeIntervalSince(started)
        )
    }
}

var results: [ProbeResult] = []

if target == "all" || target == "codex" {
    let provider = CodexProvider(clientVersion: version)
    results.append(await measure("codex app-server") { try await provider.read() })
    provider.shutdown()
}

if target == "all" || target == "claude" {
    let provider = ClaudeProvider(appVersion: version, keychainAllowed: true)
    results.append(await measure("claude account usage API") { try await provider.read() })
}

if target == "all" || target == "local" {
    results.append(await measure("codex local session log") { CodexSessionLogSource().latestSnapshot() })
    results.append(await measure("claude statusline bridge") { StatuslineBridge().latestSnapshot() })
}

if wantsJSON {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(results)
    print(String(decoding: data, as: UTF8.self))
} else {
    let now = Date()
    for result in results {
        let timing = String(format: "%.2fs", result.elapsedSeconds)
        guard let snapshot = result.snapshot else {
            print("✗ \(result.source) (\(timing)): \(result.error ?? "unknown error")")
            continue
        }
        let plan = snapshot.planName.map { " · \($0)" } ?? ""
        let account = snapshot.accountLabel.map { " · \($0)" } ?? ""
        print("✓ \(result.source) (\(timing))\(plan)\(account) · observed \(UsageFormat.age(since: snapshot.observedAt, now: now))")
        for window in snapshot.windows {
            let reset = window.resetsAt.map { "resets in \(UsageFormat.timeUntil($0, now: now)) (\(UsageFormat.resetTime($0)))" } ?? ""
            print("    \(window.title.padding(toLength: 18, withPad: " ", startingAt: 0)) \(window.remainingPercent)% left  \(reset)")
        }
        snapshot.notes.forEach { print("    \($0)") }
    }
}

exit(results.contains { $0.ok } ? 0 : 1)
