---
title: Writing a login back through `security -i` truncated it
date: 2026-09-26
category: docs/solutions/logic-errors
module: UsageProviders
problem_type: data_corruption
component: keychain
severity: critical
applies_when:
  - "Writing a secret into another tool's Keychain item."
  - "Passing data through `security -i` (interactive mode, commands on stdin)."
tags: [keychain, claude-code, oauth, data-loss, security-cli]
---

# Writing a login back through `security -i` truncated it

## What happened

The Claude login auto-renewal (PR #4) wrote the renewed Claude Code login back with
`security -i` and one `add-generic-password -U ... -X <hex>` line on stdin. On a
real Mac the stored value was cut at 2,012 characters, so the JSON became invalid.
Both Howmuchusage and Claude Code then failed to read the login, and Claude Code
had to sign in again. Hex doubles the size, and the interactive line buffer is about 4 KB.

The earlier unit tests used a tiny `{}` payload and a file-based store. The manual check
used a throwaway keychain, also with a short value. Neither was close to the real size.

## Guidance

- Never pass secrets larger than a few hundred bytes through `security -i`.
- After writing, read back and require the *exact same bytes* (or a valid parse
  with the new token) before treating the write as done. If this check fails,
  report it clearly, because the old refresh token is already spent.
- Test writers with realistic payload sizes: at least 4 KB for OAuth JSON.
- Ship risky write-back behind a setting that is off by default until it is proven on a real machine.

## Status

Hotfix: renewal is off by default (`claudeAutoRefreshV2`, default false) until the
writer is rebuilt with a method that has no line-length limit and a full round-trip check.

## Fix

The writer now runs `security add-generic-password -U -a <account> -s
"Claude Code-credentials" -X <hex>` with the login as a command argument (no
line limit; this is also how Claude Code saves it). The argument is visible
only to the same user's processes for the moment the tool runs. After the
write it reads the item back and requires the exact same bytes, retries the
write once, and otherwise reports the failure. The provider also judges the
write-back by the whole stored login, not just the access token.
`testLargeLoginSurvivesKeychainWriteExactly` writes a 9 KB login into a
throwaway keychain with the real `security` tool. Renewal stays off by
default; users turn it on in Settings.

