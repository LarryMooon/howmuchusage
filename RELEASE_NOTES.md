# Howmuchusage Release Notes

## 0.1.2

Local snapshot clarity update.

- Menu bar labels now use `~5h` and `~1w` to make the approximate local snapshot source visible.
- Old local snapshots fade to gray in the menu bar.
- Popover now highlights `Local snapshot · Xm ago`.
- Manual button is now `Reload Snapshot` instead of `Refresh`.
- README documents the key limitation: reloading this app only re-reads local Codex logs and cannot force OpenAI/Codex to refresh usage limits.

Download:

1. Download `Howmuchusage-0.1.2-universal-macos.zip`.
2. Unzip it.
3. Move `Howmuchusage.app` to `/Applications`.
4. If macOS blocks the first launch, right-click the app and choose `Open`.

## 0.1.1

Refresh responsiveness and accuracy-labeling update.

- Moved manual refresh work off the main UI thread so the popover reacts immediately.
- Reduced log parsing work by decoding only JSONL lines that contain `rate_limits`.
- Stops scanning older session files once a newer usage snapshot is already confirmed.
- Popover now shows that the data mode is `local Codex session log`.
- README now explains that `Refresh` re-reads local logs and does not query the official OpenAI usage service.

Download:

1. Download `Howmuchusage-0.1.1-universal-macos.zip`.
2. Unzip it.
3. Move `Howmuchusage.app` to `/Applications`.
4. If macOS blocks the first launch, right-click the app and choose `Open`.

## 0.1.0

Initial public build.

- Native macOS menu bar app.
- Two-line compact menu bar display:
  - `5h` for the current 5-hour Codex window.
  - `1w` for the weekly window.
- Remaining quota percent, not used percent.
- Battery-style thin bars.
- Green, yellow, and red thresholds based on remaining quota.
- Popover with reset time, source snapshot, manual refresh, Open Usage, Quit, and Launch at Login.
- Universal macOS build support through `Scripts/package-release.sh`.

Notes:

- Requires local Codex logs under `~/.codex/sessions`.
- This release is a local convenience tool, not an official OpenAI usage API.
- If local values differ from the official Usage panel, trust the official Usage panel.
