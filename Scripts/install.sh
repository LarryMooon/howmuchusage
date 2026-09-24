#!/bin/bash
# Installs (or updates) Howmuchusage into /Applications and launches it.
#
#   curl -fsSL https://raw.githubusercontent.com/LarryMooon/howmuchusage/refs/heads/claude/intelligent-bohr-u24qu4/Scripts/install.sh | bash
set -euo pipefail

REF="${HOWMUCHUSAGE_REF:-refs/heads/claude/intelligent-bohr-u24qu4}"
VERSION="${HOWMUCHUSAGE_VERSION:-2.0.0}"
BASE="https://raw.githubusercontent.com/LarryMooon/howmuchusage/$REF/Downloads"
ZIP="Howmuchusage-$VERSION-universal-macos.zip"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "→ Downloading $ZIP"
curl -fsSL "$BASE/$ZIP" -o "$TMP/$ZIP"
curl -fsSL "$BASE/$ZIP.sha256" -o "$TMP/$ZIP.sha256"
(cd "$TMP" && shasum -a 256 -c "$ZIP.sha256")

echo "→ Quitting any running Howmuchusage (old versions included)"
osascript -e 'quit app "Howmuchusage"' >/dev/null 2>&1 || true
pkill -x Howmuchusage >/dev/null 2>&1 || true
sleep 1

DEST="/Applications"
if [ ! -w "$DEST" ]; then
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
fi

ditto -x -k "$TMP/$ZIP" "$TMP/app"
rm -rf "$DEST/Howmuchusage.app"
ditto "$TMP/app/Howmuchusage.app" "$DEST/Howmuchusage.app"
# The build is not notarized yet; clear the download flag so it can open.
xattr -dr com.apple.quarantine "$DEST/Howmuchusage.app" >/dev/null 2>&1 || true

echo "→ Launching $DEST/Howmuchusage.app"
open "$DEST/Howmuchusage.app"
echo "✓ Installed. Look for the CL / CX blocks in the menu bar."
