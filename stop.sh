#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config/apps.sh
source "$SCRIPT_DIR/config/apps.sh"

APP="${APP:-socialNetwork}"
KEEP_DATA="${KEEP_DATA:-}"   # if set, keep volumes (and the init marker) across stop
STATE_DIR="$SCRIPT_DIR/.state"

usage() {
    cat <<EOF
Usage: $(basename "$0") [-h]

Tears down a DeathStarBench application. By default removes the compose
volumes too (clean slate) so the next start re-initializes data consistently.

Environment:
  APP         which app: ${DSB_APPS[*]}  (default: socialNetwork)
  KEEP_DATA   if set, keep volumes and the init marker (faster restart)
EOF
    exit 0
}
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage

app_config "$APP"
command -v docker &>/dev/null || dsb_die "docker not found — run ./setup.sh first"
DC=(docker compose -f "$COMPOSE_FILE")

if [[ -z "$("${DC[@]}" ps -q 2>/dev/null)" ]]; then
    echo "$APP is not running"
else
    if [[ -n "$KEEP_DATA" ]]; then
        "${DC[@]}" down
    else
        "${DC[@]}" down -v
    fi
    echo "$APP stopped"
fi

# Drop the init marker unless data volumes were preserved
if [[ -z "$KEEP_DATA" ]]; then
    rm -f "$STATE_DIR/${APP}.initialized"
fi
