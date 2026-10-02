#!/bin/bash
# End-to-end run against the mock Jellyfin server on a tvOS simulator:
#   1. generates the synthetic media library if missing (Tools/MockJellyfin/make-media.sh),
#   2. starts Tools/MockJellyfin/server.py,
#   3. reinstalls the app on the simulator (fresh state) and runs VelaUITests/MockServerTour,
#   4. leaves screenshots in $SHOT_DIR and the server log next to them.
# Usage: Scripts/e2e-mock.sh [-only-testing:VelaUITests/MockServerTour/test00HomeAndResumeInAdvancedPlayer]
set -euo pipefail
cd "$(dirname "$0")/.."
PORT="${MOCK_PORT:-8097}"
MEDIA="${MOCK_MEDIA:-Tools/MockJellyfin/media}"
OUT="${E2E_OUT:-build/e2e}"
SHOT_DIR="$(cd "$(dirname "$OUT")" 2>/dev/null && pwd || pwd)/$(basename "$OUT")/shots"
DEST="${VELA_DESTINATION:-platform=tvOS Simulator,name=Apple TV 4K (3rd generation)}"
DERIVED="${DERIVED_DATA:-build/DerivedData}"
mkdir -p "$SHOT_DIR"

[ -d "$MEDIA/Movies" ] || Tools/MockJellyfin/make-media.sh "$MEDIA"

# Always start a fresh server so watch state begins at the fixture defaults (Boreal resumable, E01 watched).
pkill -f "MockJellyfin/server.py" 2>/dev/null || true
for _ in $(seq 1 10); do lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1 || break; sleep 0.5; done
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then echo "port $PORT is still in use; stop that process or set MOCK_PORT"; exit 1; fi
python3 Tools/MockJellyfin/server.py --media "$MEDIA" --port "$PORT" > "$(dirname "$SHOT_DIR")/mock-server.log" 2>&1 &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null || true' EXIT
for _ in $(seq 1 20); do curl -sf "http://127.0.0.1:$PORT/System/Info/Public" >/dev/null && break; sleep 0.5; done
curl -sf "http://127.0.0.1:$PORT/System/Info/Public" >/dev/null || { echo "mock server did not start (port $PORT busy?)"; exit 1; }

# Fresh app state so onboarding runs (accounts live in UserDefaults + Keychain of the app container).
UDID=$(xcrun simctl list devices available -j | python3 -c "import json,sys; d=json.load(sys.stdin); print(next(dev['udid'] for r,devs in d['devices'].items() if 'tvOS' in r for dev in devs if dev['name']=='Apple TV 4K (3rd generation)'))")
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl uninstall "$UDID" com.ralleur.vela 2>/dev/null || true

# Default to the whole tour unless the caller narrows it with -only-testing:… .
ONLY=(-only-testing:VelaUITests/MockServerTour)
for arg in "$@"; do case $arg in -only-testing:*) ONLY=();; esac; done

# TEST_RUNNER_* environment variables (not build settings) reach the test runner process.
TEST_RUNNER_VELA_MOCK_SERVER="http://127.0.0.1:$PORT" TEST_RUNNER_VELA_SHOT_DIR="$SHOT_DIR" \
xcodebuild -project Vela.xcodeproj -scheme Vela -destination "$DEST" -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  ${ONLY[@]+"${ONLY[@]}"} "$@" test 2>&1 | tee "$(dirname "$SHOT_DIR")/xcodebuild.log" | grep -E "Test Case|error:|failed|passed|\*\* TEST" || true
echo "Screenshots: $SHOT_DIR"
