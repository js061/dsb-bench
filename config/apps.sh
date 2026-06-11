#!/usr/bin/env bash
# Per-app configuration for dsb-bench. Sourced by start.sh, stop.sh, bench.sh, run.sh.
#
# Provides:
#   DSB_DIR                  path to the DeathStarBench checkout
#   app_config <APP>         -> APP_DIR, COMPOSE_FILE, FRONTEND_URL, DEFAULT_WORKLOAD
#   workload_config A WL     -> LUA_SCRIPT (abs path), TARGET_URL
#   init_app_data <APP>      one-time data initialization for the app
#   count_cores <spec>       core count for "0-3" / "0,2,4" / "0-3,6" specs

# DeathStarBench checkout. Defaults to the copy install.sh clones into dist/.
DSB_BENCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DSB_DIR="${DSB_DIR:-$DSB_BENCH_ROOT/dist/DeathStarBench}"

# Valid apps (also the order used when APP=all)
DSB_APPS=(socialNetwork mediaMicroservices hotelReservation)

dsb_die() { echo "ERROR: $*" >&2; exit 1; }

# count_cores SPEC — number of cores in a list/range spec (e.g. 0-3,6 -> 5)
count_cores() {
    local spec="$1" n=0 t
    local IFS=','
    for t in $spec; do
        if [[ "$t" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            n=$(( n + ${BASH_REMATCH[2]} - ${BASH_REMATCH[1]} + 1 ))
        elif [[ "$t" =~ ^[0-9]+$ ]]; then
            n=$(( n + 1 ))
        fi
    done
    echo "$n"
}

# expand_cores SPEC — validate a CPU spec ("0-3", "0,2,4", "0-3,6") against
# nproc and echo the normalized, explicit comma list (e.g. "0-3,6" -> "0,1,2,3,6").
# Suitable for taskset -c and docker --cpuset-cpus. Dies on any malformed token
# or out-of-range core.
expand_cores() {
    local spec="$1" token lo hi c
    local ncpus; ncpus=$(nproc)
    local cores=()
    local IFS=','
    for token in $spec; do
        if [[ "$token" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            lo="${BASH_REMATCH[1]}"; hi="${BASH_REMATCH[2]}"
            (( lo <= hi )) || dsb_die "invalid core range: $token"
            for (( c=lo; c<=hi; c++ )); do cores+=("$c"); done
        elif [[ "$token" =~ ^[0-9]+$ ]]; then
            cores+=("$token")
        else
            dsb_die "invalid core spec: '$token' (use forms like 0-3 or 0,2,4)"
        fi
    done
    (( ${#cores[@]} > 0 )) || dsb_die "empty core spec"
    for c in "${cores[@]}"; do
        (( c < ncpus )) || dsb_die "core $c >= nproc ($ncpus)"
    done
    ( IFS=,; echo "${cores[*]}" )
}

# app_config APP — populate APP_DIR, COMPOSE_FILE, FRONTEND_URL, DEFAULT_WORKLOAD
app_config() {
    local app="$1"
    APP_DIR="$DSB_DIR/$app"
    COMPOSE_FILE="$APP_DIR/docker-compose.yml"
    case "$app" in
        socialNetwork)
            FRONTEND_URL="http://localhost:8080"
            DEFAULT_WORKLOAD="compose-post"
            ;;
        mediaMicroservices)
            FRONTEND_URL="http://localhost:8080"
            DEFAULT_WORKLOAD="compose-review"
            ;;
        hotelReservation)
            FRONTEND_URL="http://localhost:5000"
            DEFAULT_WORKLOAD="mixed-workload_type_1"
            ;;
        *) dsb_die "unknown APP: '$app' (valid: ${DSB_APPS[*]})" ;;
    esac
    [[ -f "$COMPOSE_FILE" ]] || dsb_die "compose file not found: $COMPOSE_FILE"
}

# workload_config APP WORKLOAD — populate LUA_SCRIPT and TARGET_URL
# (app_config must have been called first, for FRONTEND_URL / APP_DIR)
workload_config() {
    local app="$1" wl="$2" rel ep
    case "$app" in
        socialNetwork)
            case "$wl" in
                compose-post)       rel="wrk2/scripts/social-network/compose-post.lua";       ep="/wrk2-api/post/compose" ;;
                read-home-timeline) rel="wrk2/scripts/social-network/read-home-timeline.lua"; ep="/wrk2-api/home-timeline/read" ;;
                read-user-timeline) rel="wrk2/scripts/social-network/read-user-timeline.lua"; ep="/wrk2-api/user-timeline/read" ;;
                mixed-workload)     rel="wrk2/scripts/social-network/mixed-workload.lua";     ep="/wrk2-api/post/compose" ;;
                *) dsb_die "unknown WORKLOAD '$wl' for $app (valid: compose-post read-home-timeline read-user-timeline mixed-workload)" ;;
            esac ;;
        mediaMicroservices)
            case "$wl" in
                compose-review) rel="wrk2/scripts/media-microservices/compose-review.lua"; ep="/wrk2-api/review/compose" ;;
                *) dsb_die "unknown WORKLOAD '$wl' for $app (valid: compose-review)" ;;
            esac ;;
        hotelReservation)
            case "$wl" in
                mixed-workload_type_1) rel="wrk2/scripts/hotel-reservation/mixed-workload_type_1.lua"; ep="" ;;
                *) dsb_die "unknown WORKLOAD '$wl' for $app (valid: mixed-workload_type_1)" ;;
            esac ;;
        *) dsb_die "unknown APP: '$app'" ;;
    esac
    LUA_SCRIPT="$APP_DIR/$rel"
    [[ -f "$LUA_SCRIPT" ]] || dsb_die "lua script not found: $LUA_SCRIPT"
    TARGET_URL="${FRONTEND_URL}${ep}"
}

# init_app_data APP — one-time data initialization (run inside a subshell cd)
init_app_data() {
    local app="$1"
    case "$app" in
        socialNetwork)
            ( cd "$APP_DIR" && python3 scripts/init_social_graph.py \
                --graph=socfb-Reed98 --ip=localhost --port=8080 --compose )
            ;;
        mediaMicroservices)
            ( cd "$APP_DIR" \
                && python3 scripts/write_movie_info.py \
                    -c ./datasets/tmdb/casts.json -m ./datasets/tmdb/movies.json \
                    --server_address http://localhost:8080 \
                && bash scripts/register_users.sh \
                && bash scripts/register_movies.sh )
            ;;
        hotelReservation)
            echo "  (no data initialization required for hotelReservation)"
            ;;
        *) dsb_die "unknown APP: '$app'" ;;
    esac
}
