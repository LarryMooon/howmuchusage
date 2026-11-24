---
title: One catch-all error message hid a signed-out login for 9 days
date: 2026-11-25
category: docs/solutions/logic-errors
module: UsageProviders
problem_type: misleading_error
component: claude-provider
severity: high
applies_when:
  - "Several different failures (stored data, network answer, renewal answer) are mapped to one error case."
  - "An error message names a cause (\"response was not understood\") that only one of the failures really has."
tags: [error-handling, claude-code, oauth, diagnostics]
---

# One catch-all error message hid a signed-out login for 9 days

## What happened

The Claude row showed "Old · 9d ago" with "Claude usage response was not understood".
That text came from `ClaudeProviderError.badResponse`, which was thrown in six places:
the stored Keychain login failing to parse, the usage JSON failing to parse, a
non-HTTP response, and three spots in token renewal.

The real cause was none of the "response" cases. Claude Code ends a login at its
maximum lifetime and then blanks `accessToken`/`refreshToken` in the Keychain
(`loginEnded: time_limit`). `ClaudeCredentials.parse` threw `missingAccessToken`, the
store mapped it to `badResponse`, and the app told the user the *server* answer was
the problem. The answer that would have fixed it, `/login`, was never shown. Because
the Keychain had been corrupted by an app bug in September, the message also pointed
diagnosis at the wrong suspect.

A second, smaller gap: the fast 60 s login re-check applied only to "expired", not
"signed out", so after `/login` the app still waited up to 15 min of error backoff (#17).

## Guidance

- Give each failure stage its own error case, and let the message name the action:
  blank tokens → `notSignedIn` ("run /login"); unreadable stored JSON →
  `storedLoginUnreadable`; usage 200 in an unknown shape → `usageFormatChanged`;
  unreadable token answer → `renewalResponseUnreadable` (#16, #18).
- Distinguish "no data" from "broken data": an empty token is a normal signed-out
  state, not corruption.
- When a server answer can't be parsed, log the top-level **key names** at notice level
  (never values) so the next format change is diagnosable from `log show`.
- Every "needs the user to act" state must skip error backoff and re-check quickly.

## Check

- `testBlankStoredLoginMeansSignedOutNotDamaged`, `testEndedLoginInFileAsksToSignIn`,
  `testChangedUsageFormatIsReportedAsSuch`.
- `grep -rn "badResponse" Sources` should only show transport-level, non-HTTP cases.
