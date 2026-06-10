#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config/apps.sh
source "$SCRIPT_DIR/config/apps.sh"

DIST_DIR="$SCRIPT_DIR/dist"
WRK="$DSB_DIR/wrk2/wrk"

# -- DeathStarBench source (cloned into dist/, like nginx-bench downloads into dist/)
DSB_REPO="${DSB_REPO:-https://github.com/delimitrou/DeathStarBench.git}"
DSB_REF="${DSB_REF:-master}"

# APP=all (default) warms images for every app; APP=<name> just that one.
APP="${APP:-all}"
PULL="${PULL:-1}"   # set PULL=0 to skip docker image pull/build

info() { echo "==> $*"; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [-h]

Clones DeathStarBench into dist/, builds its wrk2 load generator, and
(optionally) warms the docker images for the application(s).

Environment:
  DSB_REPO  DeathStarBench git URL   (default: $DSB_REPO)
  DSB_REF   branch/tag/commit        (default: $DSB_REF)
  DSB_DIR   checkout location        (default: $DSB_DIR)
  APP       which app images to warm: all | ${DSB_APPS[*]}  (default: all)
  PULL      1 = docker compose pull/build images, 0 = skip  (default: 1)
EOF
    exit 0
}
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage

command -v git &>/dev/null || dsb_die "git not found — run ./setup.sh first"

# -- Clone (or update) DeathStarBench into dist/, with submodules (wrk2 LuaJIT)
mkdir -p "$DIST_DIR"
if [[ -d "$DSB_DIR/.git" ]]; then
    info "DeathStarBench already cloned at $DSB_DIR — updating to $DSB_REF..."
    git -C "$DSB_DIR" fetch --depth 1 origin "$DSB_REF"
    git -C "$DSB_DIR" checkout -q FETCH_HEAD
    git -C "$DSB_DIR" submodule update --init --recursive --depth 1 wrk2/deps/luajit
else
    info "Cloning DeathStarBench ($DSB_REF) into $DSB_DIR ..."
    git clone --depth 1 --branch "$DSB_REF" --recurse-submodules --shallow-submodules \
        "$DSB_REPO" "$DSB_DIR" \
        || dsb_die "clone failed — check DSB_REPO/DSB_REF or network"
fi

# Belt-and-suspenders: wrk2 needs the bundled LuaJIT submodule checked out.
if [[ ! -f "$DSB_DIR/wrk2/deps/luajit/src/Makefile" ]]; then
    info "Initializing wrk2 LuaJIT submodule..."
    git -C "$DSB_DIR" submodule update --init --recursive wrk2/deps/luajit \
        || dsb_die "failed to init LuaJIT submodule"
fi

# -- Build wrk2
info "Building wrk2 in $DSB_DIR/wrk2 ..."
make -C "$DSB_DIR/wrk2" -j "$(nproc)"
[[ -x "$WRK" ]] || dsb_die "wrk2 build failed — $WRK not found"
info "wrk2 binary: $WRK"

# -- Warm docker images
if [[ "$PULL" == "1" ]]; then
    command -v docker &>/dev/null || dsb_die "docker not found — run ./setup.sh first"
    if [[ "$APP" == "all" ]]; then
        apps=("${DSB_APPS[@]}")
    else
        apps=("$APP")
    fi
    for a in "${apps[@]}"; do
        app_config "$a"
        info "Warming images for $a ($COMPOSE_FILE) ..."
        docker compose -f "$COMPOSE_FILE" pull --ignore-pull-failures || true
        docker compose -f "$COMPOSE_FILE" build || true
    done
fi

echo ""
echo "Installation complete."
echo ""
echo "  DeathStarBench : $DSB_DIR"
echo "  wrk2 binary    : $WRK"
echo "  apps           : ${DSB_APPS[*]}"
echo ""
echo "Usage:"
echo "  ./start.sh                       # bring up socialNetwork + init data"
echo "  ./run.sh                         # single run -> rst/"
echo "  APP=hotelReservation ./run.sh    # benchmark a different app"
echo "  ./batch-run.sh                   # sweep (edit arrays at top first)"
echo "  ./stop.sh                        # tear down"
