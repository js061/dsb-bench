#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -- number of times to repeat the whole sweep
REPEATS=1

# -- setting arrays (edit to define a sweep)
APP_arr=(socialNetwork)
WORKLOAD_arr=(compose-post)
WRK_CORES_arr=(8-9)
THREADS_arr=(2)
CONNECTIONS_arr=(100 200 300)
DURATION_arr=(30)
TARGETRPS_arr=(1000 5000)
TARGETRPS_DIST_arr=(fixed)

[[ -x "$SCRIPT_DIR/run.sh" ]] || { echo "ERROR: run.sh not found or not executable" >&2; exit 1; }

total=$(( REPEATS \
    * ${#APP_arr[@]} * ${#WORKLOAD_arr[@]} \
    * ${#WRK_CORES_arr[@]} * ${#THREADS_arr[@]} \
    * ${#CONNECTIONS_arr[@]} * ${#DURATION_arr[@]} \
    * ${#TARGETRPS_arr[@]} * ${#TARGETRPS_DIST_arr[@]} ))
count=0
prev_app=""

echo "batch-run: $total run(s) total — $REPEATS repeat(s) of the sweep"

for rep in $(seq 1 "$REPEATS"); do                  # top layer: repeats
  for ap in "${APP_arr[@]}"; do                     # sub-layers: settings
    # different apps may share ports (social/media both use 8080), so tear
    # down the previous app before switching
    if [[ -n "$prev_app" && "$prev_app" != "$ap" ]]; then
      APP="$prev_app" "$SCRIPT_DIR/stop.sh"
    fi
    prev_app="$ap"
    for wl in "${WORKLOAD_arr[@]}"; do
      for wc in "${WRK_CORES_arr[@]}"; do
        for th in "${THREADS_arr[@]}"; do
          for cn in "${CONNECTIONS_arr[@]}"; do
            for du in "${DURATION_arr[@]}"; do
              for tr in "${TARGETRPS_arr[@]}"; do
                for trd in "${TARGETRPS_DIST_arr[@]}"; do
                  count=$(( count + 1 ))
                  echo ""
                  echo "=== [batch $count/$total] repeat=$rep | app=$ap workload=$wl | wrk-cores=$wc threads=$th conn=$cn dur=$du rps=$tr dist=$trd ==="
                  APP="$ap" \
                  WORKLOAD="$wl" \
                  WRK_CORES="$wc" \
                  THREADS="$th" \
                  CONNECTIONS="$cn" \
                  DURATION="$du" \
                  TARGETRPS="$tr" \
                  TARGETRPS_DIST="$trd" \
                  RUN_TAG="rep${rep}" \
                  "$SCRIPT_DIR/run.sh"
                done
              done
            done
          done
        done
      done
    done
  done
done

# tear down the last app left running
[[ -n "$prev_app" ]] && APP="$prev_app" "$SCRIPT_DIR/stop.sh"

echo ""
echo "batch-run: all $total run(s) complete -> see rst/"
