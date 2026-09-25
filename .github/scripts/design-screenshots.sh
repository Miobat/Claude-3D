#!/bin/bash
# Real simulator screenshots of production SwiftUI views with isolated demo data.
set -euo pipefail
APP="$RUNNER_TEMP/ScanView3D-iphonesimulator/Debug-iphonesimulator/ScanView3D.app"
OUT="$RUNNER_TEMP/design-screenshots"
mkdir -p "$OUT"
xcrun simctl list devices available -j > "$RUNNER_TEMP/devices.json"
DEVICE=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(next(x["udid"] for k,v in d["devices"].items() if "iOS" in k for x in v if x["name"].startswith("iPhone") and x.get("isAvailable")))' "$RUNNER_TEMP/devices.json")
xcrun simctl boot "$DEVICE" || true
xcrun simctl bootstatus "$DEVICE" -b
xcrun simctl status_bar "$DEVICE" override --time '9:41' --dataNetwork wifi --wifiMode active --wifiBars 3 --batteryState charged --batteryLevel 100
xcrun simctl install "$DEVICE" "$APP"
capture() {
  local SCREEN="$1" NAME="$2"
  xcrun simctl terminate "$DEVICE" com.michael.scanview3d || true
  xcrun simctl launch "$DEVICE" com.michael.scanview3d --design-preview "$SCREEN"
  sleep 6
  xcrun simctl io "$DEVICE" screenshot "$OUT/$NAME.png"
}
for APPEARANCE in light dark; do
  xcrun simctl ui "$DEVICE" appearance "$APPEARANCE"
  for SCREEN in projects library project settings scanner viewer empty; do
    capture "$SCREEN" "$SCREEN-$APPEARANCE"
  done
done
xcrun simctl ui "$DEVICE" content_size accessibility-extra-large
capture projects projects-large-text
capture scanner scanner-large-text
capture viewer viewer-large-text
xcrun simctl ui "$DEVICE" content_size large
xcrun simctl shutdown "$DEVICE"
