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
  shift 2
  xcrun simctl terminate "$DEVICE" com.michael.scanview3d || true
  xcrun simctl launch "$DEVICE" com.michael.scanview3d --design-preview "$SCREEN" "$@"
  sleep 6
  xcrun simctl io "$DEVICE" screenshot "$OUT/$NAME.png"
}
SCREENS="projects library project settings scanner capture-settings viewer measure empty"
if [[ "${GITHUB_REF:-}" == "refs/heads/codex/live-capture-navigation" || "${GITHUB_HEAD_REF:-}" == "codex/live-capture-navigation" ]]; then
  SCREENS="scanner capture-settings viewer measure"
fi
for APPEARANCE in light dark; do
  xcrun simctl ui "$DEVICE" appearance "$APPEARANCE"
  for SCREEN in $SCREENS; do
    capture "$SCREEN" "$SCREEN-$APPEARANCE"
  done
done
xcrun simctl ui "$DEVICE" content_size accessibility-extra-large
capture projects projects-large-text
capture scanner scanner-large-text
capture viewer viewer-large-text
xcrun simctl ui "$DEVICE" content_size large
capture joysticks viewer-joysticks
capture walk viewer-walk-selection
capture navigation-tests navigation-tests
CONTAINER=$(xcrun simctl get_app_container "$DEVICE" com.michael.scanview3d data)
cp "$CONTAINER/Documents/navigation-checks.json" "$OUT/navigation-checks.json"
python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(r); assert r["checks"] >= 18 and not r["failures"], "Native navigation checks failed"' "$OUT/navigation-checks.json"
capture scanner scanner-landscape --landscape
capture viewer viewer-landscape --landscape
capture measure measure-landscape --landscape
capture joysticks viewer-joysticks-landscape --landscape
xcrun simctl shutdown "$DEVICE"
