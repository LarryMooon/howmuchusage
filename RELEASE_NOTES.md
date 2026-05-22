# Howmuchusage 0.1.0

Initial public release.

## Highlights

- Native macOS menu bar app.
- Shows remaining Codex quota for the 5-hour and weekly windows.
- Two compact rows: `5h` and `1w`.
- Thin battery-style bars with green/yellow/red remaining-quota thresholds.
- 1-minute auto refresh.
- Popover with reset time, source snapshot, manual refresh, Open Usage, Quit, and Launch at Login.
- Universal macOS binary for Apple Silicon and Intel Macs.

## Install

1. Download `Howmuchusage-0.1.0-universal-macos.zip`.
2. Unzip it.
3. Move `Howmuchusage.app` to `/Applications`.
4. Open it.
5. If macOS blocks the first launch, right-click the app and choose `Open`.

## Notes

- Requires macOS 13 or newer.
- Requires local Codex logs under `~/.codex/sessions`.
- This release is a local convenience tool, not an official OpenAI usage API.
- If local values differ from the official Usage panel, trust the official Usage panel.
