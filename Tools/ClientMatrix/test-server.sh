#!/bin/bash
# Throwaway Jellyfin (same version as production) serving the client-matrix library on port 8097.
# It never touches the production server (8096): own container, own config/cache under build/.
#
#   test-server.sh up        start the container; on first start run the setup wizard, add libraries,
#                            set German language preferences and install the Intro Skipper plugin
#   test-server.sh scan      rescan libraries, then trickplay + media segment tasks
#   test-server.sh down      stop and remove the container (config and media stay)
#   test-server.sh purge     down + delete config/cache (next `up` starts from scratch)
#   test-server.sh token     print the admin access token of the test instance
#
# Test login for clients: user `matrix`, password `matrix`.
set -eo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BASE="$(cd "$HERE/../.." && pwd)/build/client-matrix"
NAME=client-matrix-jellyfin
IMAGE="${JELLYFIN_IMAGE:-jellyfin/jellyfin:10.11.11}"
PORT="${PORT:-8097}"
URL="http://127.0.0.1:$PORT"
AUTH='MediaBrowser Client="ClientMatrix", Device="harness", DeviceId="client-matrix-harness", Version="1.0"'
STATE="$BASE/state.json"
USER_NAME=matrix USER_PASS=matrix

api() { # METHOD PATH [JSON]
  local token=""; [ -f "$STATE" ] && token=$(python3 -c "import json;print(json.load(open('$STATE'))['token'])")
  curl -fsS -X "$1" "$URL$2" -H "Content-Type: application/json" \
    -H "Authorization: $AUTH${token:+, Token=\"$token\"}" ${3:+--data "$3"}
}

wait_ready() {
  for _ in $(seq 1 90); do
    curl -fsS "$URL/System/Info/Public" >/dev/null 2>&1 && return 0; sleep 2
  done
  echo "server did not come up" >&2; exit 1
}

login() {
  curl -fsS -X POST "$URL/Users/AuthenticateByName" -H "Content-Type: application/json" -H "Authorization: $AUTH" \
    --data "{\"Username\":\"$USER_NAME\",\"Pw\":\"$USER_PASS\"}" |
    python3 -c "import json,sys;d=json.load(sys.stdin);json.dump({'token':d['AccessToken'],'userId':d['User']['Id']},open('$STATE','w'))"
}

setup() {
  echo "▶ setup wizard"
  api POST /Startup/Configuration '{"UICulture":"de-DE","MetadataCountryCode":"DE","PreferredMetadataLanguage":"de"}'
  api GET /Startup/User >/dev/null
  api POST /Startup/User "{\"Name\":\"$USER_NAME\",\"Password\":\"$USER_PASS\"}"
  api POST /Startup/RemoteAccess '{"EnableRemoteAccess":true,"EnableAutomaticPortMapping":false}'
  api POST /Startup/Complete
  login
  echo "▶ libraries (no internet metadata, trickplay during scan)"
  local opts='"EnableRealtimeMonitor":false,"EnableTrickplayImageExtraction":true,"ExtractTrickplayImagesDuringLibraryScan":true,"EnableChapterImageExtraction":false,"SaveTrickplayWithMedia":false,"MetadataSavers":[]'
  api POST "/Library/VirtualFolders?name=Movies&collectionType=movies&paths=%2Fmedia%2FMovies&refreshLibrary=false" \
    "{\"LibraryOptions\":{$opts,\"TypeOptions\":[{\"Type\":\"Movie\",\"MetadataFetchers\":[],\"ImageFetchers\":[]}]}}"
  api POST "/Library/VirtualFolders?name=Shows&collectionType=tvshows&paths=%2Fmedia%2FShows&refreshLibrary=false" \
    "{\"LibraryOptions\":{$opts,\"TypeOptions\":[{\"Type\":\"Series\",\"MetadataFetchers\":[],\"ImageFetchers\":[]},{\"Type\":\"Season\",\"MetadataFetchers\":[],\"ImageFetchers\":[]},{\"Type\":\"Episode\",\"MetadataFetchers\":[],\"ImageFetchers\":[]}]}}"
  echo "▶ user preferences: audio ger, subtitles ger, mode Smart, language beats default flag"
  local uid; uid=$(python3 -c "import json;print(json.load(open('$STATE'))['userId'])")
  api GET "/Users/$uid" | python3 -c "
import json,sys
c=json.load(sys.stdin)['Configuration']
c.update(AudioLanguagePreference='ger',SubtitleLanguagePreference='ger',SubtitleMode='Smart',PlayDefaultAudioTrack=False,EnableNextEpisodeAutoPlay=True)
print(json.dumps(c))" > "$BASE/userconfig.json"
  api POST "/Users/$uid/Configuration" "$(cat "$BASE/userconfig.json")"
  echo "▶ Intro Skipper plugin (chapter analysis → media segments)"
  api POST /Repositories '[{"Name":"Jellyfin Stable","Url":"https://repo.jellyfin.org/files/plugin/manifest.json","Enabled":true},{"Name":"Intro Skipper","Url":"https://intro-skipper.org/manifest.json","Enabled":true}]'
  if api POST "/Packages/Installed/Intro%20Skipper?repositoryUrl=https%3A%2F%2Fintro-skipper.org%2Fmanifest.json" 2>/dev/null; then
    sleep 5; api POST /System/Restart || true; sleep 5; wait_ready
  else
    echo "  (plugin install failed — skip intro rows will show 'no segments')"
  fi
}

scan() {
  echo "▶ library scan"
  api POST /Library/Refresh
  sleep 5
  for _ in $(seq 1 120); do
    local running
    running=$(api GET /ScheduledTasks | python3 -c "import json,sys;print(sum(1 for t in json.load(sys.stdin) if t['State']!='Idle'))")
    [ "$running" = 0 ] && break; sleep 3
  done
  echo "▶ trickplay + media segment tasks"
  api GET /ScheduledTasks | python3 -c "
import json,sys
for t in json.load(sys.stdin):
    if any(k in (t.get('Key') or '')+t['Name'] for k in ('Trickplay','MediaSegment','Segment','IntroSkipper','Intro','Credits')):
        print(t['Id'], t['Name'])" | while read -r id name; do
    echo "  run: $name"; api POST "/ScheduledTasks/Running/$id" || true
  done
  sleep 5
  for _ in $(seq 1 200); do
    local running
    running=$(api GET /ScheduledTasks | python3 -c "import json,sys;print(sum(1 for t in json.load(sys.stdin) if t['State']!='Idle'))")
    [ "$running" = 0 ] && break; sleep 3
  done
  echo "✔ scan done"
}

case "${1:-up}" in
  up)
    mkdir -p "$BASE/config" "$BASE/cache" "$BASE/media"
    if ! docker ps --format '{{.Names}}' | grep -qx "$NAME"; then
      docker rm -f "$NAME" >/dev/null 2>&1 || true
      docker run -d --name "$NAME" --restart no -p "$PORT:8096" \
        -v "$BASE/config:/config" -v "$BASE/cache:/cache" -v "$BASE/media:/media:ro" "$IMAGE" >/dev/null
    fi
    wait_ready
    if [ ! -f "$STATE" ]; then setup; scan; else login; fi
    echo "✔ $URL  (LAN: http://$(ipconfig getifaddr en0 2>/dev/null || echo '<mac-ip>'):$PORT)  user $USER_NAME / $USER_PASS"
    ;;
  scan) login; scan ;;
  down) docker rm -f "$NAME" >/dev/null 2>&1 || true; echo "✔ stopped" ;;
  purge) docker rm -f "$NAME" >/dev/null 2>&1 || true; rm -rf "$BASE/config" "$BASE/cache" "$STATE" "$BASE/userconfig.json"; echo "✔ purged" ;;
  token) python3 -c "import json;print(json.load(open('$STATE'))['token'])" ;;
  *) sed -n '2,13p' "$0"; exit 1 ;;
esac
