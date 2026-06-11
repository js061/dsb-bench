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
  APP_CORES      pin all app containers to these cores, e.g. 0-7 or 0,2,4
                 (unset = no pinning; use a set disjoint from WRK_CORES)
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

# -- Optional CPU pinning: confine every app container to APP_CORES so the app
# and the wrk2 load generator (WRK_CORES) can run on disjoint cores. Applied
# live via 'docker update', so it also re-pins an already-running stack.
if [[ -n "${APP_CORES:-}" ]]; then
    APP_CORE_LIST=$(expand_cores "$APP_CORES")
    echo "==> Pinning $APP containers to cores [${APP_CORE_LIST}]..."
    cids=$("${DC[@]}" ps -q)
    [[ -n "$cids" ]] || dsb_die "no containers found to pin for $APP"
    for cid in $cids; do
        docker update --cpuset-cpus "$APP_CORE_LIST" "$cid" >/dev/null \
            || dsb_die "failed to set cpuset on container $cid"
    done
fi

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
