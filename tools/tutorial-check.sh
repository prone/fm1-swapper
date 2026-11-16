#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 FM-1 Swapper contributors
# Play a tutorial in the iPad simulator, every step's "Show me" demo included, and screenshot each
# step for review.  tools/tutorial-check.sh <tutorial-id> <package.fwsc> [out-dir]
# Needs a Debug simulator build (see README). The package is the firmware the tutorial is for.
set -euo pipefail
ID="$1"; PKG="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"; OUT="${3:-build/tutorial-check/$ID}"
[[ "$ID" =~ ^[a-z0-9-]+$ ]] || { echo "tutorial id must be lowercase letters, digits and dashes" >&2; exit 2; }
SIM="${SIM:-$(xcrun simctl list devices available | grep -m1 'iPad Pro 13' | grep -oE '[0-9A-F-]{36}')}"
DD="${DD:-build/dd}"
NAME="$(basename "$PKG")"   # name M-VAVE's package FM-1.fwsc so the emulator treats it as stock
cd "$(dirname "$0")/.."
python3 tools/validate_tutorials.py "Tutorials/$ID.json"
xcodebuild -project FM1Swapper.xcodeproj -scheme FM1Swapper -destination "id=$SIM" -derivedDataPath "$DD" \
  build CODE_SIGNING_ALLOWED=NO FM1_CLOUD_SYNC=NO -quiet
xcrun simctl boot "$SIM" 2>/dev/null || true
APP="$DD/Build/Products/Debug-iphonesimulator/FM1Swapper.app"
BUNDLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"
xcrun simctl install "$SIM" "$APP"
xcrun simctl terminate "$SIM" "$BUNDLE" 2>/dev/null || true
rm -rf "$OUT"; mkdir -p "$OUT"
LOG="$OUT/log.txt"
xcrun simctl spawn "$SIM" log stream --style compact --predicate 'eventMessage CONTAINS "TUTSTEP" OR eventMessage CONTAINS "TUTDONE"' > "$LOG" &
LP=$!
trap 'kill $LP 2>/dev/null || true' EXIT
sleep 2
SIMCTL_CHILD_FM1_DEMO_EMULATOR="$PKG" SIMCTL_CHILD_FM1_DEMO_AUTOSTART=1 \
SIMCTL_CHILD_FM1_DEMO_TUTORIAL="$ID" SIMCTL_CHILD_FM1_DEMO_NAME="$NAME" \
  xcrun simctl launch "$SIM" "$BUNDLE" >/dev/null
seen=0
for _ in $(seq 1 600); do
  sleep 0.5
  n=$(grep -c "FM1Swapper.*TUTSTEP .* shown" "$LOG" || true)
  while (( seen < n )); do
    seen=$((seen + 1))
    xcrun simctl io "$SIM" screenshot "$OUT/step-$(printf %02d $seen).png" >/dev/null 2>&1
  done
  grep -q "FM1Swapper.*TUTDONE" "$LOG" && break
done
grep "FM1Swapper" "$LOG" | grep -o "TUTSTEP.*" | sed 's/^/  /'
echo "screenshots: $OUT"
