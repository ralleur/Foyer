#!/bin/bash
# Builds a signed Debug build and installs + launches it on a paired Apple TV (wireless via Xcode pairing).
#   Scripts/install-device.sh                 # first paired Apple TV
#   Scripts/install-device.sh "Wohnzimmer"    # by device name (substring)
# Pair once: Apple TV › Settings › Remotes and Devices › Remote App and Devices, then Xcode › Window › Devices
# and Simulators › select the Apple TV › Pair and enter the code shown on the TV.
set -euo pipefail
cd "$(dirname "$0")/.."
NAME="${1:-}"
DERIVED="${DERIVED_DATA:-build/DerivedData-device}"
UDID=$(xcrun devicectl list devices --json-output /dev/stdout 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
devs=[x for x in d['result']['devices'] if 'AppleTV' in (x.get('hardwareProperties',{}).get('productType','')) and x.get('hardwareProperties',{}).get('reality')!='simulated' and x.get('deviceProperties',{}).get('name')]
name='$NAME'.lower()
for x in devs:
    if not name or name in x['deviceProperties']['name'].lower():
        print(x['identifier']); break
")
[ -n "$UDID" ] || { echo "No paired physical Apple TV found. Pair it in Xcode › Window › Devices and Simulators first." >&2; exit 1; }
echo "Building for device…"
xcodebuild -project Foyer.xcodeproj -scheme Foyer -configuration Debug -destination "generic/platform=tvOS" \
  -derivedDataPath "$DERIVED" -allowProvisioningUpdates build 2>&1 | grep -E "error:|\*\* BUILD" || true
APP="$DERIVED/Build/Products/Debug-appletvos/Foyer.app"
[ -d "$APP" ] || { echo "Build failed (no $APP)" >&2; exit 1; }
echo "Installing on $UDID…"
xcrun devicectl device install app --device "$UDID" "$APP"
xcrun devicectl device process launch --device "$UDID" com.ralleur.foyer
echo "Foyer is running on the Apple TV."
