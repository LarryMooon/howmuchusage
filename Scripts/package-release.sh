#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_NAME="${APP_NAME:-Howmuchusage}"
BUNDLE_ID="${BUNDLE_ID:-com.larrymoon.howmuchusage}"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
DIST_DIR="${DIST_DIR:-$PROJECT_DIR/dist}"
RELEASE_DIR="${RELEASE_DIR:-$DIST_DIR/release}"
APP_DIR="$DIST_DIR/$APP_NAME.app"
ZIP_PATH="$RELEASE_DIR/$APP_NAME-$VERSION-macos.zip"
NOTARY_ZIP_PATH="$RELEASE_DIR/$APP_NAME-$VERSION-notary.zip"

CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
NOTARIZE="${NOTARIZE:-0}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
NOTARY_APPLE_ID="${NOTARY_APPLE_ID:-}"
NOTARY_TEAM_ID="${NOTARY_TEAM_ID:-}"
NOTARY_PASSWORD="${NOTARY_PASSWORD:-}"
UNIVERSAL="${UNIVERSAL:-1}"

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required tool: $1" >&2
    exit 1
  fi
}

sign_app() {
  if [[ -z "$CODESIGN_IDENTITY" ]]; then
    echo "No CODESIGN_IDENTITY set; creating an unsigned development zip."
    echo "Set CODESIGN_IDENTITY='Developer ID Application: ...' for public distribution."
    return
  fi

  echo "Signing $APP_DIR"
  /usr/bin/codesign \
    --force \
    --timestamp \
    --options runtime \
    --sign "$CODESIGN_IDENTITY" \
    "$APP_DIR/Contents/MacOS/$APP_NAME"

  /usr/bin/codesign \
    --force \
    --timestamp \
    --options runtime \
    --sign "$CODESIGN_IDENTITY" \
    "$APP_DIR"

  /usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_DIR"
}

create_zip() {
  local source_app="$1"
  local output_zip="$2"

  rm -f "$output_zip"
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$source_app" "$output_zip"
}

submit_notarization() {
  if [[ "$NOTARIZE" != "1" ]]; then
    return
  fi

  if [[ -z "$CODESIGN_IDENTITY" ]]; then
    echo "NOTARIZE=1 requires CODESIGN_IDENTITY." >&2
    exit 1
  fi

  create_zip "$APP_DIR" "$NOTARY_ZIP_PATH"

  echo "Submitting notarization: $NOTARY_ZIP_PATH"
  if [[ -n "$NOTARY_PROFILE" ]]; then
    xcrun notarytool submit "$NOTARY_ZIP_PATH" \
      --keychain-profile "$NOTARY_PROFILE" \
      --wait
  elif [[ -n "$NOTARY_APPLE_ID" && -n "$NOTARY_TEAM_ID" && -n "$NOTARY_PASSWORD" ]]; then
    xcrun notarytool submit "$NOTARY_ZIP_PATH" \
      --apple-id "$NOTARY_APPLE_ID" \
      --team-id "$NOTARY_TEAM_ID" \
      --password "$NOTARY_PASSWORD" \
      --wait
  else
    echo "Notarization requires NOTARY_PROFILE or NOTARY_APPLE_ID/NOTARY_TEAM_ID/NOTARY_PASSWORD." >&2
    exit 1
  fi

  echo "Stapling notarization ticket"
  xcrun stapler staple "$APP_DIR"
  xcrun stapler validate "$APP_DIR"
}

assess_app() {
  if [[ -z "$CODESIGN_IDENTITY" ]]; then
    return
  fi

  /usr/sbin/spctl --assess --type execute --verbose=4 "$APP_DIR" || {
    echo "spctl assessment did not pass. If notarization was skipped, this is expected for local Developer ID test builds." >&2
  }
}

require_tool swift
require_tool xcrun
require_tool ditto
require_tool shasum

mkdir -p "$RELEASE_DIR"

export APP_NAME BUNDLE_ID VERSION BUILD_NUMBER DIST_DIR UNIVERSAL
"$SCRIPT_DIR/build-app.sh"

sign_app
submit_notarization
assess_app

create_zip "$APP_DIR" "$ZIP_PATH"
shasum -a 256 "$ZIP_PATH" > "$ZIP_PATH.sha256"

echo "Release zip: $ZIP_PATH"
echo "Checksum: $ZIP_PATH.sha256"
