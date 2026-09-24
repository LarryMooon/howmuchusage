---
title: A passed reset time does not mean the quota is full
date: 2026-09-24
category: docs/solutions/logic-errors
module: UsageCore
problem_type: logic_error
component: display
severity: high
applies_when:
  - "A cached quota value carries a reset time that is now in the past."
  - "The display is tempted to infer the post-reset value instead of waiting for a fresh read."
tags: [usage-limits, freshness, inference, codex, trust]
---

# A passed reset time does not mean the quota is full

## Context

On the first real-Mac run, Codex had no app-server connection and fell back to
a 2-day-old local log (5h window 97% used). Its reset time had passed, and the
display inferred "reset → 100% left". The official Codex page showed **3% left**:
the user had been using Codex on other devices since the reset.

## Guidance

- After a reset passes, the old value says nothing about current usage. Show it
  as unknown (`--`, gray) until a fresh read arrives.
- Infer "full" only in the narrow case where it is nearly certain: the value is
  not stale and the reset happened within a few minutes (`resetInferenceGrace`,
  300 s). Live polling replaces it within one interval anyway.
- Any inference must be visibly marked (`~` prefix, popover wording).

## Verification

`UsageCoreTests.DisplayTests.testOldResetMakesValueUnknownInsteadOfFull`
reproduces the real-Mac case.
