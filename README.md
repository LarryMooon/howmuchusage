# Howmuchusage

Tiny macOS menu bar app for checking how much Codex usage is left.

Howmuchusage reads the local Codex session logs on your Mac, finds the latest
`rate_limits` snapshot, and shows the remaining 5-hour and weekly quota in the
menu bar.

```text
5h 36%  [thin green bar]
1w 44%  [thin green bar]
```

## Download

Download the current macOS zip:

https://github.com/LarryMooon/howmuchusage/raw/main/Downloads/Howmuchusage-0.1.0-macos.zip

Checksum:

https://github.com/LarryMooon/howmuchusage/raw/main/Downloads/Howmuchusage-0.1.0-macos.zip.sha256

Then:

1. Unzip `Howmuchusage-0.1.0-macos.zip`.
2. Move `Howmuchusage.app` to `/Applications`.
3. Open it.
4. If macOS blocks the first launch, right-click the app and choose `Open`.
5. Look for the `5h` / `1w` indicator in the top-right menu bar.

This app has no Dock icon and no normal app window. It lives only in the menu
bar. On launch, it opens its popover once so you can find it.

## Requirements

- macOS 13 or newer.
- Codex must have been used on that Mac at least once.
- Local Codex session logs must exist under `~/.codex/sessions`.

If the menu bar shows `--`, Codex has not written a usable local usage snapshot
yet. Run Codex once, then click `Refresh`.

## What It Shows

- Top row: remaining quota for the current 5-hour Codex window.
- Bottom row: remaining weekly quota.
- Battery-style thin bar for each quota.
- Green by default, yellow at 10% remaining or below, red at 5% remaining or below.
- Popover details: reset time, last local update, source file, `Launch at Login`, and `Open Usage`.

The displayed percent is remaining quota, not used quota.

## Privacy

Howmuchusage reads only local files on your Mac. It does not send your Codex
session logs anywhere.

The parser only extracts `payload.rate_limits` values from local JSONL files:

- `primary.used_percent`
- `primary.window_minutes`
- `primary.resets_at`
- `secondary.used_percent`
- `secondary.window_minutes`
- `secondary.resets_at`

It does not display or store prompts, responses, or conversation content.

## Accuracy

This is a local convenience tool, not an official OpenAI usage API. If the value
differs from the official Codex Usage panel, trust the official panel.

Use `Open Usage` in the popover to open:

https://chatgpt.com/codex/settings/usage

## Build From Source

```sh
swift test
Scripts/build-app.sh
open dist/Howmuchusage.app
```

Create a release zip:

```sh
Scripts/package-release.sh
```

The default release package is a universal macOS binary:

```text
dist/release/Howmuchusage-0.1.0-macos.zip
dist/release/Howmuchusage-0.1.0-macos.zip.sha256
```

To publish the downloadable build in the repository:

```sh
mkdir -p Downloads
cp dist/release/Howmuchusage-0.1.0-macos.zip Downloads/
cp dist/release/Howmuchusage-0.1.0-macos.zip.sha256 Downloads/
```

## Signing And Notarization

The public zip can be signed and notarized with a Developer ID Application
certificate:

```sh
xcrun notarytool store-credentials howmuchusage-notary \
  --apple-id "apple-id@example.com" \
  --team-id "TEAMID" \
  --password "app-specific-password"

CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARIZE=1 \
NOTARY_PROFILE=howmuchusage-notary \
  Scripts/package-release.sh
```

Without Developer ID signing, macOS may show a Gatekeeper warning on first
launch.

## SwiftBar Prototype

If you prefer SwiftBar:

```sh
swift build -c release --product howmuchusage-probe
Scripts/codex-usage.1m.sh
```

Put `Scripts/codex-usage.1m.sh` in your SwiftBar plugins folder or symlink it
there.

## License

MIT
