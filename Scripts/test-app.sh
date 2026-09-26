#!/bin/bash
# Builds and tests the tvOS app on a simulator. Requires Xcode 16+ with the tvOS platform installed.
set -euo pipefail
cd "$(dirname "$0")/.."
DEST="${FOYER_DESTINATION:-platform=tvOS Simulator,name=Apple TV 4K (3rd generation)}"
xcodebuild -project Foyer.xcodeproj -scheme Foyer -destination "$DEST" -only-testing:FoyerTests test "$@"
