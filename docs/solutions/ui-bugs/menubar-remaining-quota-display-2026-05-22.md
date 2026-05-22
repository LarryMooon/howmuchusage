---
title: Menubar quota display must show remaining percent
date: 2026-05-22
category: docs/solutions/ui-bugs
module: HowmuchusageMenuBar
problem_type: ui_bug
component: tooling
symptoms:
  - "Menu bar label showed `used_percent` even though the product requirement was remaining quota."
  - "Battery bar fill used remaining percent, but the adjacent text showed usage percent."
  - "Open Usage action pointed at a ChatGPT route that returned 404 for the user."
root_cause: logic_error
resolution_type: code_fix
severity: medium
tags: [macos-menubar, quota-display, swiftui, appkit, codex-usage]
---

# Menubar quota display must show remaining percent

## Problem

Howmuchusage is meant to answer "how much Codex quota is left" from the menu bar. The parser correctly reads Codex's local `used_percent` values, but the visible UI initially displayed those values directly, so the number next to the remaining-style battery bar communicated the opposite meaning.

## Symptoms

- The menu bar showed values like `5h 61%` and `1w 55%`, which looked like remaining capacity but were actually usage.
- The thin battery bar was filled from `100 - used_percent`, so the bar and number disagreed.
- The popover and SwiftBar output also used "used" wording in user-visible rows.
- The `Open Usage` button opened `https://chatgpt.com/codex/usage`, which returned 404 for the user.

## What Didn't Work

- Treating Codex's `used_percent` field as the display value. That field is a source metric, not the product-facing quota number.
- Only changing the battery fill. The adjacent text, CLI text, SwiftBar rows, tests, and docs must use the same display semantic.
- Using a guessed direct Usage URL. The official guidance points users to Codex settings > Usage panel, so hardcoded shortcuts need verification.

## Solution

Keep `used_percent` as the parser input, but convert it at the formatting boundary:

```swift
public static func remainingPercent(forUsedPercent usedPercent: Int) -> Int {
    max(0, min(100, 100 - usedPercent))
}
```

Use `remainingPercent` for every visible compact label:

```swift
public var title: String {
    "\(label) \(remainingPercent)% \(barText)"
}
```

For the native app, draw the same value in the AppKit status item and keep the columns fixed so both rows align:

```swift
drawText(
    "\(line.remainingPercent)%",
    rect: NSRect(x: 54, y: textY, width: 23, height: 8.5),
    fontSize: 7.2,
    color: textColor,
    alignment: .right
)
```

Update the official action to the settings usage route:

```swift
public static let usageURL = URL(string: "https://chatgpt.com/codex/settings/usage")!
```

## Why This Works

The data source still matches the local Codex schema, where `used_percent` is the stable field observed in `rate_limits`. The UI now converts that source metric once and passes the remaining value through the formatter, SwiftBar output, native menu bar drawing, popover, and tests. This prevents the bar and number from drifting into different meanings.

The AppKit `NSStatusItem` custom view also avoids the earlier SwiftUI `MenuBarExtra` label clipping issue and gives exact control over the `label / bar / percent` grid.

## Prevention

- Name product-facing values as `remainingPercent` and avoid rendering `usedPercent` in compact UI.
- Add or update formatter tests whenever a source field has the opposite meaning from the visible product requirement.
- Verify external product links against official docs or authenticated UI routes before hardcoding them.
- For menu bar UI, prefer a custom `NSStatusItem` view when the label needs multi-row alignment or custom drawing.

## Related Issues

- No prior `docs/solutions/` entries existed in this project.
