#!/bin/bash
# Smoke tour against a real Jellyfin server on a tvOS simulator (VelaUITests/RealServerTour).
# Credentials come from the environment and are never written to disk:
#   VELA_REAL_SERVER=http://host:8096 VELA_REAL_USER=name VELA_REAL_PASSWORD=secret Scripts/e2e-real.sh
# Optional: VELA_CAPABILITIES=appleTV4K makes the simulator decide like an Apple TV 4K (HEVC/HDR hardware).
# While the tour runs, the script polls /Sessions and logs what the server sees Vela playing.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${VELA_REAL_SERVER:?set VELA_REAL_SERVER}" "${VELA_REAL_USER:?set VELA_REAL_USER}" "${VELA_REAL_PASSWORD:?set VELA_REAL_PASSWORD}"
OUT="${E2E_OUT:-build/e2e-real}"
SHOT_DIR="$(mkdir -p "$OUT" && cd "$OUT" && pwd)/shots"
DEST="${VELA_DESTINATION:-platform=tvOS Simulator,name=Apple TV 4K (3rd generation)}"
DERIVED="${DERIVED_DATA:-build/DerivedData}"
mkdir -p "$SHOT_DIR"

# Session polling with a throw-away token (deleted at the end).
AUTH='MediaBrowser Client="Vela e2e", Device="script", DeviceId="vela-e2e-script", Version="1"'
TOKEN=$(curl -sf -X POST "$VELA_REAL_SERVER/Users/AuthenticateByName" -H "Content-Type: application/json" -H "Authorization: $AUTH" \
  -d "{\"Username\":\"$VELA_REAL_USER\",\"Pw\":\"$VELA_REAL_PASSWORD\"}" | python3 -c "import json,sys; print(json.load(sys.stdin)['AccessToken'])")
(
  while true; do
    curl -sf "$VELA_REAL_SERVER/Sessions?activeWithinSeconds=30" -H "Authorization: $AUTH, Token=\"$TOKEN\"" | python3 -c "
import json,sys,datetime
for s in json.load(sys.stdin):
    if s.get('Client','').startswith('Vela') and s.get('NowPlayingItem'):
        i=s['NowPlayingItem']; p=s.get('PlayState',{}); t=s.get('TranscodingInfo') or {}
        print(datetime.datetime.now().strftime('%H:%M:%S'), i.get('Name'), '|', p.get('PlayMethod'), 'pos', round((p.get('PositionTicks') or 0)/1e7), 's', 'paused', p.get('IsPaused'), '| a', p.get('AudioStreamIndex'), 's', p.get('SubtitleStreamIndex'), '| transcode:', t.get('VideoCodec'), t.get('AudioCodec'), t.get('IsVideoDirect'), t.get('IsAudioDirect'), t.get('TranscodeReasons'))
" 2>/dev/null || true
    sleep 2
  done
) > "$OUT/sessions.log" 2>&1 &
POLL_PID=$!
cleanup() {
  kill $POLL_PID 2>/dev/null || true
  curl -sf -X POST "$VELA_REAL_SERVER/Sessions/Logout" -H "Authorization: $AUTH, Token=\"$TOKEN\"" >/dev/null 2>&1 || true
}
trap cleanup EXIT

ONLY=(-only-testing:VelaUITests/RealServerTour)
for arg in "$@"; do case $arg in -only-testing:*) ONLY=();; esac; done

UDID=$(xcrun simctl list devices available -j | python3 -c "import json,sys; d=json.load(sys.stdin); print(next(dev['udid'] for r,devs in d['devices'].items() if 'tvOS' in r for dev in devs if dev['name']=='Apple TV 4K (3rd generation)'))")
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl uninstall "$UDID" com.ralleur.vela 2>/dev/null || true

TEST_RUNNER_VELA_REAL_SERVER="$VELA_REAL_SERVER" TEST_RUNNER_VELA_REAL_USER="$VELA_REAL_USER" \
TEST_RUNNER_VELA_REAL_PASSWORD="$VELA_REAL_PASSWORD" TEST_RUNNER_VELA_SHOT_DIR="$SHOT_DIR" \
TEST_RUNNER_VELA_CAPABILITIES="${VELA_CAPABILITIES:-}" \
xcodebuild -project Vela.xcodeproj -scheme Vela -destination "$DEST" -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO ${ONLY[@]+"${ONLY[@]}"} "$@" test 2>&1 | tee "$OUT/xcodebuild.log" | grep -E "Test Case|error:|failed|passed|\*\* TEST" || true
echo "Screenshots: $SHOT_DIR"
echo "Server-side sessions: $OUT/sessions.log"
