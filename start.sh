#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config/apps.sh
source "$SCRIPT_DIR/config/apps.sh"

APP="${APP:-socialNetwork}"
REINIT="${REINIT:-}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-180}"
STATE_DIR="$SCRIPT_DIR/.state"

usage() {
    cat <<EOF
Usage: $(basename "$0") [-h]

Brings up a DeathStarBench application via docker compose, waits for its
frontend, and runs one-time data initialization. No-op for the compose step
if the app is already up; data init is skipped once the marker exists.

Environment:
  APP            which app: ${DSB_APPS[*]}  (default: socialNetwork)
  REINIT         if set, force re-running data initialization
  WAIT_TIMEOUT   seconds to wait for the frontend (default: 180)
EOF
    exit 0
}
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage

app_config "$APP"
command -v docker &>/dev/null || dsb_die "docker not found — run ./setup.sh first"
DC=(docker compose -f "$COMPOSE_FILE")

echo "==> Starting $APP via docker compose..."
"${DC[@]}" up -d

echo "==> Waiting for frontend $FRONTEND_URL (timeout ${WAIT_TIMEOUT}s)..."
deadline=$(( SECONDS + WAIT_TIMEOUT ))
until curl -sS -o /dev/null "$FRONTEND_URL" 2>/dev/null; do
    (( SECONDS < deadline )) || dsb_die "$APP frontend not ready after ${WAIT_TIMEOUT}s — check 'docker compose -f $COMPOSE_FILE logs'"
    sleep 2
done
echo "    frontend is up."

mkdir -p "$STATE_DIR"
MARKER="$STATE_DIR/${APP}.initialized"
if [[ -n "$REINIT" || ! -f "$MARKER" ]]; then
    echo "==> Initializing data for $APP..."
    init_app_data "$APP"
    touch "$MARKER"
    echo "    data initialization complete."
else
    echo "==> Data already initialized (marker: $MARKER); skipping. Set REINIT=1 to force."
fi

echo "DONE: $APP is up at $FRONTEND_URL"
