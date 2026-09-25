---
title: Quota usage must come from the account, not from local logs
date: 2026-09-24
category: docs/solutions/architecture
module: UsageProviders
problem_type: architecture_decision
component: data-source
severity: high
applies_when:
  - "An app displays a subscription or rate-limit quota that is shared across devices."
  - "A local log or cache happens to contain the same numbers the server reports."
  - "A push/streaming channel delivers sparse updates on top of a full read."
tags: [usage-limits, cross-device, codex-app-server, claude-usage, freshness, macos-menubar]
---

# Quota usage must come from the account, not from local logs

## Context

Howmuchusage v0.1 read `rate_limits` from `~/.codex/sessions` JSONL files. The
numbers were real server values, but they only changed when Codex ran on that
Mac. Usage from ChatGPT web, the iPhone app or Codex cloud never appeared, and
"Reload" could only re-read the same stale snapshot. v0.1.2 papered over this
with `~` labels; v2 fixed the cause.

## Guidance

- Ask the account, not the device: Codex via `codex app-server`
  `account/rateLimits/read`, Claude via the account usage endpoint. Local logs
  and statusline captures stay as passive signals and fallbacks.
- Treat every source as "a server value observed at time T" and let the newest
  observation win. Never let an older passive value replace a newer live one.
- Show freshness from the observation age (live / `~` recent / gray stale),
  and infer 100% only once a window's `resetsAt` has passed, marked with `~`.
- Merge sparse push updates only onto a full read. With no base yet, drop the
  update and let the next scheduled read pick it up; otherwise a missing
  weekly window silently disappears from the display.
- A GUI app does not inherit the shell PATH: look up CLIs in known install
  directories, then ask the login shell, and pass a PATH that includes `node`
  for npm-installed tools.
- Treat another tool's OAuth login (Claude Code's Keychain item) as theirs:
  re-read it first, renew only when it is still expired, write the renewal
  back to the same place with every other field kept, and re-read right
  before writing so a renewal made by that tool always wins. Refresh tokens
  rotate, so a renewal that is not written back would sign that tool out.

## Verification

- `Tests/UsageProvidersTests`: fake app-server (`Fixtures/fake_app_server.py`)
  covers handshake, push merge, server requests, timeouts and process restart.
- `Tests/UsageCoreTests`: newest-wins merge, freshness thresholds, inferred
  resets, poll policy backoff and Retry-After.
