#!/bin/bash
# Pulls Foyer's log file off a paired Apple TV (development builds) and prints the tail.
#   Scripts/device-logs.sh                 # first paired Apple TV, last 80 lines
#   Scripts/device-logs.sh Wohnzimmer 300  # by device name, last 300 lines
# Files land in build/device-logs/ (foyer.log, foyer.log.1 = previous rotation).
set -euo pipefail
cd "$(dirname "$0")/.."
NAME="${1:-}"
LINES="${2:-80}"
OUT="build/device-logs"
mkdir -p "$OUT"
UDID=$(xcrun devicectl list devices --json-output /dev/stdout 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
devs=[x for x in d['result']['devices'] if 'AppleTV' in (x.get('hardwareProperties',{}).get('productType','')) and x.get('hardwareProperties',{}).get('reality')!='simulated' and x.get('deviceProperties',{}).get('name')]
name='$NAME'.lower()
for x in devs:
    if not name or name in x['deviceProperties']['name'].lower():
        print(x['identifier']); break
")
[ -n "$UDID" ] || { echo "No paired physical Apple TV found (xcrun devicectl manage pair --device <name>)." >&2; exit 1; }
for f in foyer.log.1 foyer.log; do
  [ -f "${OUT:?}/${f:?}" ] && mv "${OUT:?}/${f:?}" "${OUT:?}/${f:?}.previous"
  xcrun devicectl device copy from --device "$UDID" --domain-type appDataContainer --domain-identifier com.ralleur.foyer \
    --source "Library/Caches/Logs/$f" --destination "$OUT/$f" >/dev/null 2>&1 || true
done
[ -f "$OUT/foyer.log" ] || { echo "No log file on the device yet (the app writes Library/Caches/Logs/foyer.log after its first launch)." >&2; exit 1; }
echo "== $OUT/foyer.log ($(wc -l < "$OUT/foyer.log" | tr -d ' ') lines$( [ -f "$OUT/foyer.log.1" ] && echo ", plus foyer.log.1" ))"
tail -n "$LINES" "$OUT/foyer.log"
