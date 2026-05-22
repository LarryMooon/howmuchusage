---
title: Local snapshot limitations must be visible in the UI
date: 2026-05-22
category: docs/solutions/documentation-gaps
module: HowmuchusageMenuBar
problem_type: documentation_gap
component: tooling
severity: medium
applies_when:
  - "A local utility displays cached or observed usage data that may differ from an official server-side dashboard."
  - "A reload button re-reads local state but does not trigger the upstream service to refresh."
tags: [local-snapshot, usage-limits, product-semantics, macos-menubar, codex-usage]
---

# Local snapshot limitations must be visible in the UI

## Context

Howmuchusage reads `payload.rate_limits` from local Codex JSONL session logs. That makes it useful as a fast menu bar viewer, but it does not make the app an official Usage API client. If Codex has not written a newer local `rate_limits` entry, reloading Howmuchusage can only show the same old snapshot again.

## Guidance

Make cached/local state visible in the core UI, not only in README details:

- Prefix approximate menu bar values with `~`.
- Show `Local snapshot · Xm ago` in the popover.
- Use `Reload Snapshot` instead of `Refresh` when the action only re-reads local files.
- Fade old local snapshots to gray.
- Put the official dashboard/fallback rule in README and a short in-app note.

Example UI wording:

```text
~5h 36%
~1w 44%

Local snapshot · 5m ago
Reload only re-reads local logs. Official Usage may differ.
```

## Why This Matters

Without clear wording, users naturally assume a usage menu bar app is querying the official usage service. That creates false confidence and makes mismatches with the Codex Usage panel look like bugs. The product contract should say what the app actually knows: the latest local snapshot Codex wrote.

## When to Apply

- The app reads local logs, caches, browser storage, or snapshots.
- The displayed value can lag behind an official dashboard.
- The manual reload action does not call the upstream source of truth.
- Users may spend money or plan work based on the displayed remaining quota.

## Examples

Before:

```text
5h 36%
Refresh
```

After:

```text
~5h 36%
Local snapshot · 5m ago
Reload Snapshot
```

## Related

- `docs/solutions/performance-issues/menubar-refresh-must-not-block-main-thread-2026-05-22.md`
- `docs/solutions/ui-bugs/menubar-remaining-quota-display-2026-05-22.md`
