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
# Run functional checks before the screenshot tour. They gate EVERY branch,
# including Claude / main and manual TestFlight releases.
CONTAINER=$(xcrun simctl get_app_container "$DEVICE" com.michael.scanview3d data)
rm -f "$CONTAINER/Documents/navigation-checks.json"
capture navigation-tests navigation-tests
for attempt in $(seq 1 30); do
  [[ -f "$CONTAINER/Documents/navigation-checks.json" ]] && break
  sleep 1
done
cp "$CONTAINER/Documents/navigation-checks.json" "$OUT/navigation-checks.json"
python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(r); assert r["checks"] >= 170 and not r["failures"], "Native capture / navigation / recovery / terrain / texture / automatic measurement / branding checks failed"' "$OUT/navigation-checks.json"
SCREENS="projects settings scanner capture-active capture-settings viewer measure object object-wall object-rejected object-expanded quality retention terrain-ready terrain-settings terrain-active adaptive-settings adaptive-active"
if [[ "${GITHUB_REF:-}" == "refs/heads/codex/tinyscanner-visual-identity" || "${GITHUB_HEAD_REF:-}" == "codex/tinyscanner-visual-identity" ]]; then
  SCREENS="$SCREENS library project empty"
fi
if [[ "${GITHUB_REF:-}" == "refs/heads/codex/design-system-upgrade" || "${GITHUB_HEAD_REF:-}" == "codex/design-system-upgrade" ]]; then
  SCREENS="projects library project settings scanner capture-active capture-settings viewer measure quality empty"
fi
for APPEARANCE in light dark; do
  xcrun simctl ui "$DEVICE" appearance "$APPEARANCE"
  for SCREEN in $SCREENS; do
    capture "$SCREEN" "$SCREEN-$APPEARANCE"
  done
done
xcrun simctl ui "$DEVICE" content_size accessibility-extra-large
capture projects projects-large-text
capture settings settings-large-text
capture scanner scanner-large-text
capture capture-active capture-active-large-text
capture terrain-settings terrain-settings-large-text
capture terrain-active terrain-active-large-text
capture adaptive-settings adaptive-settings-large-text
capture adaptive-active adaptive-active-large-text
capture viewer viewer-large-text
capture object object-large-text
capture object-wall object-wall-large-text
capture object-rejected object-rejected-large-text
capture object-expanded object-expanded-large-text
capture retention retention-large-text
capture quality quality-large-text
xcrun simctl ui "$DEVICE" content_size large
capture joysticks viewer-joysticks
capture walk viewer-walk-selection
capture scanner scanner-landscape --landscape
capture capture-active capture-active-landscape --landscape
capture terrain-ready terrain-ready-landscape --landscape
capture terrain-active terrain-active-landscape --landscape
capture adaptive-active adaptive-active-landscape --landscape
capture viewer viewer-landscape --landscape
capture measure measure-landscape --landscape
capture object object-landscape --landscape
capture object-wall object-wall-landscape --landscape
capture object-expanded object-expanded-landscape --landscape
capture quality quality-landscape --landscape
capture joysticks viewer-joysticks-landscape --landscape
xcrun simctl shutdown "$DEVICE"
