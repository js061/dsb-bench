#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config/apps.sh
source "$SCRIPT_DIR/config/apps.sh"

WRK="${WRK:-$DSB_DIR/wrk2/wrk}"

# -- App / workload selection (env-driven)
APP="${APP:-socialNetwork}"
app_config "$APP"
WORKLOAD="${WORKLOAD:-$DEFAULT_WORKLOAD}"

# -- Defaults
THREADS=""
CONNECTIONS="100"
DURATION="30"
TARGET_RPS="1000"           # wrk2 -R (REQUIRED, positive integer)
TARGET_RPS_DIST="fixed"     # wrk2 -D: fixed | exp | zipf | norm
LATENCY="--latency"         # -L; kept on so plot-latency.py has a spectrum
TIMEOUT=""
KEEP_SERVER=""
WRK_TASKSET=()

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Runs one wrk2 benchmark against a DeathStarBench app. App + workload come from
the APP / WORKLOAD env vars; everything else from the options below.

Options:
  -t THREADS      wrk2 threads               (default: WRK_CORES count, else nproc)
  -c CONNECTIONS  concurrent connections     (default: 100)
  -d DURATION     test duration              (default: 30, i.e. 30s)
  --rps RPS       target req/s (wrk2 -R)     (default: 1000; REQUIRED, > 0)
  --rps-dist NAME inter-arrival dist (wrk2 -D): fixed|exp|zipf|norm (default: fixed)
  --timeout SEC   socket timeout
  --no-latency    omit -L (skip latency spectrum)
  --keep-server   do not start/stop the app (assume it is already up)
  -h              show this help

Environment:
  APP        ${DSB_APPS[*]}                  (default: socialNetwork)
  WORKLOAD   app-specific workload name      (default: per-app)
  WRK_CORES  pin wrk2 to CPU cores, e.g. 0-3 or 0,2,4,6 (count must equal -t)
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -t) THREADS="$2";           shift 2 ;;
        -c) CONNECTIONS="$2";       shift 2 ;;
        -d) DURATION="$2";          shift 2 ;;
        --rps)       TARGET_RPS="$2";      shift 2 ;;
        --rps-dist)  TARGET_RPS_DIST="$2"; shift 2 ;;
        --timeout)   TIMEOUT="--timeout $2"; shift 2 ;;
        --no-latency) LATENCY="";   shift ;;
        --keep-server) KEEP_SERVER=1; shift ;;
        -h|--help)   usage ;;
        *) echo "Unknown option: $1" >&2; usage ;;
    esac
done

# -- THREADS defaults to the WRK_CORES count (else nproc), matching nginx-bench
if [[ -z "$THREADS" ]]; then
    if [[ -n "${WRK_CORES:-}" ]]; then
        THREADS=$(count_cores "$WRK_CORES")
    else
        THREADS=$(nproc)
    fi
fi

# -- Validate rate + distribution (wrk2 requires a positive -R)
[[ "$TARGET_RPS" =~ ^[0-9]+$ ]] && (( TARGET_RPS > 0 )) \
    || dsb_die "--rps must be a positive integer (wrk2 -R is mandatory), got: $TARGET_RPS"
case "$TARGET_RPS_DIST" in
    fixed|exp|zipf|norm) ;;
    *) dsb_die "--rps-dist must be one of: fixed, exp, zipf, norm" ;;
esac

workload_config "$APP" "$WORKLOAD"
[[ -x "$WRK" ]] || dsb_die "wrk2 not found at $WRK — run ./install.sh first"

# -- CPU affinity for wrk2 threads (verbatim parser from nginx-bench/bench.sh)
if [[ -n "${WRK_CORES:-}" ]]; then
    command -v taskset &>/dev/null || dsb_die "taskset not found (install util-linux)"
    NUM_CPUS=$(nproc)
    CORES=()
    IFS=',' read -ra TOKENS <<< "$WRK_CORES"
    for token in "${TOKENS[@]}"; do
        if [[ "$token" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            lo="${BASH_REMATCH[1]}"; hi="${BASH_REMATCH[2]}"
            (( lo <= hi )) || dsb_die "invalid range: $token"
            for (( c=lo; c<=hi; c++ )); do CORES+=("$c"); done
        elif [[ "$token" =~ ^[0-9]+$ ]]; then
            CORES+=("$token")
        else
            dsb_die "invalid core spec: $token"
        fi
    done
    for core in "${CORES[@]}"; do
        (( core < NUM_CPUS )) || dsb_die "core $core >= nproc ($NUM_CPUS)"
    done
    if (( ${#CORES[@]} != THREADS )); then
        dsb_die "WRK_CORES lists ${#CORES[@]} core(s) but -t is ${THREADS}; counts must match"
    fi
    WRK_CORE_LIST=$(IFS=,; echo "${CORES[*]}")
    WRK_TASKSET=(taskset -c "$WRK_CORE_LIST")
    echo "CPU affinity: wrk2 pinned to cores [${WRK_CORE_LIST}]"
fi

# -- Build wrk2 command
WRK_CMD=("${WRK_TASKSET[@]}" "$WRK" -t "$THREADS" -c "$CONNECTIONS" -d "$DURATION" \
         -R "$TARGET_RPS" -D "$TARGET_RPS_DIST")
[[ -n "$LATENCY" ]] && WRK_CMD+=("$LATENCY")
[[ -n "$TIMEOUT" ]] && WRK_CMD+=($TIMEOUT)
WRK_CMD+=(-s "$LUA_SCRIPT" "$TARGET_URL")

# -- Bring the app up unless told to reuse a running one
app_started=""
if [[ -z "$KEEP_SERVER" ]]; then
    APP="$APP" "$SCRIPT_DIR/start.sh"
    app_started=1
fi

echo ""
echo "App:      $APP        Workload: $WORKLOAD"
echo "Target:   $TARGET_URL"
echo "Rate:     -R $TARGET_RPS req/s, dist -D $TARGET_RPS_DIST"
echo "Running:  ${WRK_CMD[*]}"
echo ""
"${WRK_CMD[@]}"

# -- Tear down only what we started
if [[ -n "$app_started" ]]; then
    APP="$APP" "$SCRIPT_DIR/stop.sh"
fi
