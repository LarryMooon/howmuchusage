#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN="${HOWMUCHUSAGE_BIN:-$PROJECT_DIR/.build/release/howmuchusage-probe}"

if [[ ! -x "$BIN" ]]; then
  echo "C-- · W--"
  echo "---"
  echo "Build required: swift build -c release --product howmuchusage-probe"
  echo "Project: $PROJECT_DIR"
  exit 0
fi

"$BIN" --format swiftbar

