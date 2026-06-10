#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config/apps.sh
source "$SCRIPT_DIR/config/apps.sh"

# -- parse flags
PLOT=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --plot) PLOT=1; shift ;;
        -h|--help)
            cat <<EOF
Usage: $(basename "$0") [--plot]

Runs one benchmark via bench.sh, saving output to rst/. The app is brought up
(and data-initialized) via start.sh if not already running, then reused
(--keep-server) for the wrk2 run. Settings come from env vars.

Options:
  --plot   render a latency-percentile PNG from the wrk2 -L spectrum
           (requires python3 + numpy + matplotlib)

Env vars: APP WORKLOAD WRK_CORES THREADS CONNECTIONS DURATION
          TARGETRPS TARGETRPS_DIST RUN_TAG
EOF
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# -- settings (env-driven, with defaults)
APP="${APP:-socialNetwork}"
app_config "$APP"
WORKLOAD="${WORKLOAD:-$DEFAULT_WORKLOAD}"
WRK_CORES="${WRK_CORES:-20-29}"

# THREADS defaults to the number of cores in WRK_CORES
if [[ -z "${THREADS:-}" ]]; then
    THREADS=$(count_cores "$WRK_CORES")
    echo "THREADS auto-set to ${THREADS} from WRK_CORES=${WRK_CORES}"
fi

CONNECTIONS="${CONNECTIONS:-300}"
DURATION="${DURATION:-30}"
TARGETRPS="${TARGETRPS:-1000}"
TARGETRPS_DIST="${TARGETRPS_DIST:-fixed}"

# -- output file (encodes app + workload + wrk2 config plus a UTC timestamp)
RST_DIR="$SCRIPT_DIR/rst"
mkdir -p "$RST_DIR"
STAMP=$(date -u +%Y%m%d-%H%M%S)
RUN_TAG="${RUN_TAG:-}"
TAG_PART=""
[[ -n "$RUN_TAG" ]] && TAG_PART="_${RUN_TAG}"
OUT="${RST_DIR}/dsb-${APP}-${WORKLOAD}_wrk-cpu${WRK_CORES}-t${THREADS}-c${CONNECTIONS}-d${DURATION}-R${TARGETRPS}-D${TARGETRPS_DIST}${TAG_PART}_${STAMP}.out"

# -- ensure the app is up and initialized (idempotent; reused across runs)
APP="$APP" "$SCRIPT_DIR/start.sh"

echo "RUN"
START_UTC=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo "Start: $START_UTC" | tee "$OUT"
APP="$APP" WORKLOAD="$WORKLOAD" WRK_CORES="$WRK_CORES" \
    "$SCRIPT_DIR/bench.sh" -t "$THREADS" -c "$CONNECTIONS" -d "$DURATION" \
    --rps "$TARGETRPS" --rps-dist "$TARGETRPS_DIST" --keep-server 2>&1 | tee -a "$OUT"
END_UTC=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo "End:   $END_UTC" | tee -a "$OUT"

# -- self-documenting plot command + optional render
PLOT_OUT="${OUT%.out}.png"
echo "Plot:  python3 $SCRIPT_DIR/plot-latency.py $OUT $PLOT_OUT" | tee -a "$OUT"
if [[ -n "$PLOT" ]]; then
    if python3 "$SCRIPT_DIR/plot-latency.py" "$OUT" "$PLOT_OUT"; then
        echo "Plot saved: $PLOT_OUT" | tee -a "$OUT"
    else
        echo "Plot: generation failed (install: python3 -m pip install matplotlib numpy)" >&2
    fi
fi

echo "DONE -> $OUT"
