---
title: Menubar refresh must not block the main thread
date: 2026-05-22
category: docs/solutions/performance-issues
module: HowmuchusageMenuBar
problem_type: performance_issue
component: tooling
symptoms:
  - "Clicking Refresh felt unresponsive because local session log parsing ran on the main actor."
  - "The reader decoded many large JSONL lines that could never contain usage data."
  - "Users could compare the app with the official Usage panel without seeing that the app was reading a local log snapshot."
root_cause: thread_violation
resolution_type: code_fix
severity: medium
tags: [macos-menubar, refresh, main-thread, jsonl, codex-usage]
---

# Menubar refresh must not block the main thread

## Problem

Howmuchusage refreshes by reading local Codex JSONL session logs. The first implementation did that work synchronously from the SwiftUI popover button path, so manual refresh could make the menu bar app feel stuck even though the data eventually updated.

## Symptoms

- Pressing `Refresh` gave little immediate feedback.
- A probe against the current local session set took about 1.77 seconds in the already-built debug binary before the parsing optimization; after the fix it measured about 0.45 seconds in debug and about 0.35 seconds in release.
- The app's value could differ from the official Codex Usage panel, but the UI did not make the data source explicit enough.

## What Didn't Work

- Treating a 1-minute automatic refresh as sufficient. Manual refresh still needs immediate UI feedback.
- Reading local logs on the main actor. Even sub-second file parsing is noticeable in a menu bar popover.
- Decoding every JSONL line in the tail. Large encrypted or response payload lines are irrelevant when only `payload.rate_limits` is needed.

## Solution

Run refresh work off the main actor and publish state back to the UI when the read finishes:

```swift
refreshTask = Task { [weak self] in
    let result = await Task.detached(priority: .userInitiated) {
        Result {
            try reader.latestSnapshot()
        }
    }.value

    guard !Task.isCancelled else {
        return
    }

    switch result {
    case .success(let snapshot):
        self?.snapshot = snapshot
        self?.errorMessage = nil
    case .failure(let error):
        self?.errorMessage = error.localizedDescription
    }

    self?.lastRefresh = Date()
    self?.lastRefreshDuration = Date().timeIntervalSince(startedAt)
    self?.isRefreshing = false
}
```

Reduce parsing work by skipping JSON decode unless a line can contain usage data:

```swift
guard line.contains("\"rate_limits\"") else {
    continue
}
```

Stop scanning older files after a newer observed snapshot has already been found:

```swift
if let currentBest = best, file.modifiedAt <= currentBest.observedAt {
    break
}
```

Finally, make the source explicit in the popover with `Mode: local Codex session log`, and document that `Refresh` does not call the official server-side Usage endpoint.

## Why This Works

The expensive part of refresh is filesystem and JSON parsing work, not SwiftUI rendering. Moving it into a detached task keeps the menu bar UI responsive while preserving the same reader API. Filtering lines before decoding keeps huge non-usage payloads out of `JSONDecoder`, which was the main avoidable cost.

The early-stop condition is safe because files are sorted by modification time, and once a snapshot observed later than the next candidate file modification time is found, older files cannot contain a newer observed event.

## Prevention

- Never do filesystem scans or JSONL parsing directly on the main actor in a menu bar app.
- Add visible refresh state for manual refresh actions, even when the operation is expected to be fast.
- Filter semi-structured logs before decoding full JSON records.
- Label local snapshots clearly when official server-side usage values may differ.

## Related Issues

- `docs/solutions/ui-bugs/menubar-remaining-quota-display-2026-05-22.md`
