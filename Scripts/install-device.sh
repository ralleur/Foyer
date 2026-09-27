#!/bin/bash
# Builds a signed Debug build and installs + launches it on a paired Apple TV (wireless via Xcode pairing).
#   Scripts/install-device.sh                 # first paired Apple TV
#   Scripts/install-device.sh "Wohnzimmer"    # by device name (substring)
# Pair once: Apple TV › Settings › Remotes and Devices › Remote App and Devices, then on the Mac
#   xcrun devicectl manage pair --device "<Apple TV name>"
# and enter the code shown on the TV (Xcode 27 has no Devices and Simulators window any more).
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
# The concrete device as destination + -allowProvisioningDeviceRegistration lets Xcode register the Apple TV
# in the developer portal on the first build (otherwise: "Your team has no devices…").
BUILD_LOG="$DERIVED/install-device-build.log"
mkdir -p "$DERIVED"
if ! xcodebuild -project Foyer.xcodeproj -scheme Foyer -configuration Debug -destination "platform=tvOS,id=$UDID" \
  -derivedDataPath "$DERIVED" -allowProvisioningUpdates -allowProvisioningDeviceRegistration build > "$BUILD_LOG" 2>&1; then
  grep -E "error:|\*\* BUILD" "$BUILD_LOG" | head -20 >&2
  echo "Build failed; full log: $BUILD_LOG" >&2
  exit 1
fi
grep -E "warning: .*(provision|sign)|\*\* BUILD" "$BUILD_LOG" || true
APP="$DERIVED/Build/Products/Debug-appletvos/Foyer.app"
[ -d "$APP" ] || { echo "Build produced no $APP" >&2; exit 1; }
echo "Installing on ${UDID}…"
xcrun devicectl device install app --device "$UDID" "$APP"
xcrun devicectl device process launch --device "$UDID" com.ralleur.foyer
echo "Foyer is running on the Apple TV."
