# Howmuchusage

A tiny macOS menu bar app that shows how much **Claude** and **Codex** usage
you have left — updated automatically, no matter where you use them (Mac,
web, iPhone, iPad).

```text
CL  5h [=======   ] 64%    CX  5h [====      ] 41%
    1w [========= ] 88%        1w [======    ] 57%
```

Numbers are always **remaining** quota. Green by default, yellow at 10% left,
red at 5% left, gray when the value is too old to trust.

> v2 is a from-scratch rebuild. v0.1.x only read local Codex log files, so it
> never saw usage from other devices. v2 asks each service for your
> **account-level** usage instead. The old 0.1.x downloads stay in `Downloads/`.

## Install

Paste into Terminal on your Mac (macOS 13+, Apple Silicon or Intel):

```sh
curl -fsSL https://raw.githubusercontent.com/LarryMooon/howmuchusage/refs/heads/main/Scripts/install.sh | bash
```

It downloads the CI-built zip from `Downloads/`, checks its SHA-256, quits any
running copy (0.1.x included), replaces `/Applications/Howmuchusage.app`, and
opens it. Run the same command again to update. The build is not notarized
yet, so the script clears the download flag that would otherwise block the
first launch.

Manual download:
[Howmuchusage-2.0.0-universal-macos.zip](https://github.com/LarryMooon/howmuchusage/raw/main/Downloads/Howmuchusage-2.0.0-universal-macos.zip)
([SHA-256](https://github.com/LarryMooon/howmuchusage/raw/main/Downloads/Howmuchusage-2.0.0-universal-macos.zip.sha256)).

## What it shows

- **Menu bar**: two rows per service, `5h` session and `1w` weekly, with the
  percent left and a thin battery bar. `CL` = Claude, `CX` = Codex.
- **Popover**, per service: plan, freshness and source, reset times, and
  - Claude per-model weekly caps (for example *Weekly · Fable*),
  - Claude cloud session credits (`$235.28 of $250 left · expires in …`),
  - Codex credits when the account has them.
- Display mode (Both / Claude / Codex), Launch at Login, and links to the
  official usage pages.

## How it stays current on every device

Usage limits are counted per account on the server. Howmuchusage asks the
server directly, so usage from the web or mobile apps shows up while your Mac
is on and the app is running.

| Service | Where the numbers come from | Status |
|---|---|---|
| Codex | `codex app-server` → `account/rateLimits/read` (plus live push updates) | Official Codex protocol |
| Codex (fallback) | `~/.codex/sessions` logs | Only changes when Codex runs on this Mac |
| Claude | `api.anthropic.com/api/oauth/usage` using Claude Code's login | **Unofficial** endpoint used by Claude Code itself; may change |
| Claude (optional) | Claude Code statusline `rate_limits` | Officially documented; only while Claude Code runs on this Mac |

Refresh schedule adapts automatically:

- Codex: every 30 s while usage moves, 60 s normally, 120 s when idle.
- Claude: every 60 s while usage moves, 120 s normally, 300 s when idle.
- Immediate re-check after wake from sleep, network recovery, opening the
  popover, local Codex/Claude Code activity, and Codex push notifications.
- Errors back off (30 s → 15 min); a server "slow down" is always respected.

## Trust indicators

| Menu bar | Meaning |
|---|---|
| `5h 64%` | Live: fetched within the normal polling window |
| `~5h 64%` | A few minutes old (missed polls or a passive source) |
| gray `~5h 64%` | Older than 15 minutes — check your connection |
| `~5h --` | The window reset after the last read; waiting for a fresh value |
| `5h --` | Not connected yet |

A reset is only assumed to have refilled the quota when it happened within the
last 5 minutes and the value was not stale. Older resets show `--` rather than
guessing 100%: usage on other devices may already have started the new window.

The popover shows `● Live · 12s ago`, the source, and the next check time.
If anything disagrees with the official pages, trust the official pages:
[Claude usage](https://claude.ai/settings/usage) ·
[Codex usage](https://chatgpt.com/codex/settings/usage).

## Connect your accounts

Open the menu bar item; each service has a one-click setup.

**Codex**

- Already signed in to the Codex CLI or app? Nothing to do.
- Otherwise click **Sign in with ChatGPT** — your browser opens, and the
  menu bar updates as soon as sign-in completes.
- Uses the `codex` CLI. It is found in the usual install locations
  (Homebrew, npm, `~/.local/bin`, `~/.codex/bin`) and also inside the
  ChatGPT/Codex desktop apps. If none is found, install it with
  `brew install codex`, or point to it with **Locate codex…**.

**Claude**

- Click **Connect Claude**. macOS asks whether `security` may read
  "Claude Code-credentials" — choose **Always Allow**.
- Not signed in to Claude Code yet? **Sign in via Claude Code** opens
  Terminal and runs `claude` (type `/login`).
- The app never refreshes or rewrites Claude Code's login. If that login
  expires, open Claude Code once and the app recovers by itself.
- Optional: turn on **Claude Code statusline hint** for instant updates while
  Claude Code runs on this Mac. Your existing statusline keeps working (it is
  chained), `~/.claude/settings.json` is backed up first, and turning it off
  restores the original.

## Privacy

- Only usage percentages, reset times, plan name and account email are read.
  Prompts, responses and conversation files are never read or stored.
- Tokens stay in memory and are sent only to the service they belong to.
- The statusline bridge saves only the `rate_limits` object.

## Check connections from Terminal

```sh
swift run howmuchusage-probe          # all sources
swift run howmuchusage-probe codex
swift run howmuchusage-probe claude --json
swift run howmuchusage-probe claude --raw   # unparsed server response (no tokens)
```

The built app bundle also contains the probe:
`/Applications/Howmuchusage.app/Contents/MacOS/howmuchusage-probe`.

## Build from source

Requires macOS 13+ and Xcode 16 / Swift 6 toolchain.

```sh
swift test
Scripts/build-app.sh
open dist/Howmuchusage.app
```

Release zip (universal, optional Developer ID signing and notarization):

```sh
Scripts/package-release.sh
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARIZE=1 NOTARY_PROFILE=howmuchusage-notary Scripts/package-release.sh
```

## Continuous integration and releases

- `.github/workflows/ci.yml` runs on every push and pull request on a macOS
  runner: build, unit tests (including a fake `codex app-server`), app bundle,
  probe smoke test, and a universal release zip uploaded as an artifact.
- `.github/workflows/publish-build.yml` builds the universal zip and commits it
  to `Downloads/`, which is what `Scripts/install.sh` installs. It runs from the
  Actions tab (workflow_dispatch) or on a push whose commit message contains
  `[publish]`.

## Project layout

| Path | Purpose |
|---|---|
| `Sources/UsageCore` | Models, parsers, freshness, adaptive poll policy (Foundation only) |
| `Sources/UsageProviders` | codex app-server client, Claude login + usage client, local sources, statusline bridge |
| `Sources/Howmuchusage` | Menu bar app (AppKit status item + SwiftUI popover) |
| `Sources/HowmuchusageProbe` | Debug CLI |
| `Wiki/` | Design notes and work log (Korean) |
| `docs/v2-design.html` | Interactive design overview |

## License

MIT
