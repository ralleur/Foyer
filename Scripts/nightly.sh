#!/bin/bash
# Nightly library check (see Tools/Nightly/nightly.py).
#   Scripts/nightly.sh run [--mode new|all|failed] [--deadline HH:MM] [--limit N] [--dry-run]
#   Scripts/nightly.sh install      # launchd agent at 03:00 (deadline 06:00); needs ~/.config/vela/nightly.env
#   Scripts/nightly.sh uninstall | status | summary [DATE]
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$(pwd)"
LABEL="com.ralleur.vela.nightly"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
OUT="${VELA_NIGHTLY_DIR:-$HOME/VelaNightly}"
case "${1:-}" in
  run) shift; exec python3 Tools/Nightly/nightly.py run "$@" ;;
  summary) shift; exec python3 Tools/Nightly/nightly.py summary "$@" ;;
  status) python3 Tools/Nightly/nightly.py status; launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | grep -E "state|last exit|next" | head -3 || echo "launchd agent not installed" ;;
  install)
    [ -f "$HOME/.config/vela/nightly.env" ] || { echo "create ~/.config/vela/nightly.env with JF_SERVER, JF_USER, JF_PW first" >&2; exit 1; }
    mkdir -p "$HOME/Library/LaunchAgents" "$OUT"
    sed -e "s#__REPO__#$REPO#g" -e "s#__OUT__#$OUT#g" Tools/Nightly/com.ralleur.vela.nightly.plist.template > "$PLIST"
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    echo "installed $LABEL (03:00 daily, reports in $OUT)" ;;
  uninstall) launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true; rm -f "$PLIST"; echo "removed $LABEL" ;;
  *) sed -n '2,6p' "$0"; exit 1 ;;
esac
