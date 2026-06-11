#!/usr/bin/env bash
set -euo pipefail

# Installs prerequisites for dsb-bench:
#   docker engine + compose plugin  — deploy DeathStarBench apps
#   gcc/g++, make                   — build the wrk2 load generator
#   openssl/libssl, zlib            — wrk2 TLS / compression deps
#   luajit + headers                — wrk2 Lua scripting
#   luasocket (Lua 5.1)             — wrk2 workload scripts require("socket")
#   curl                            — readiness probes / downloads
#   python3 + pip                   — data-init scripts + plot-latency.py
# plus pip packages: numpy matplotlib aiohttp asyncio (init + plotting).

PKGS_DEBIAN="build-essential libssl-dev zlib1g-dev luajit libluajit-5.1-dev lua-socket curl python3 python3-pip"
PKGS_RPM="gcc gcc-c++ make openssl-devel zlib-devel luajit luajit-devel luarocks curl python3 python3-pip"
PKGS_ARCH="base-devel openssl zlib luajit lua51-socket curl python python-pip"
PIP_PKGS="numpy matplotlib aiohttp asyncio"

info() { echo "==> $*"; }
ok()   { echo "  [OK]  $*"; }
fail() { echo "  [MISSING] $*"; }

# -- Distro detection (mirrors nginx-bench/setup.sh)
detect_os() {
    if [[ "$(uname)" == "Darwin" ]]; then echo "macos"; return; fi
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        case "${ID:-}" in
            ubuntu|debian|linuxmint|pop)     echo "debian" ;;
            rhel|centos|rocky|almalinux|ol)  echo "rhel"   ;;
            fedora)                          echo "fedora" ;;
            arch|manjaro|endeavouros)        echo "arch"   ;;
            *)
                case "${ID_LIKE:-}" in
                    *debian*)        echo "debian" ;;
                    *rhel*|*fedora*) echo "rhel"   ;;
                    *arch*)          echo "arch"   ;;
                    *)               echo "unknown" ;;
                esac ;;
        esac
    else
        echo "unknown"
    fi
}

install_docker() {
    if command -v docker &>/dev/null; then
        ok "docker already installed ($(command -v docker))"
        return
    fi
    info "Installing Docker via get.docker.com convenience script..."
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sudo sh /tmp/get-docker.sh
    sudo systemctl enable --now docker 2>/dev/null || true
    info "Add your user to the docker group (then re-login): sudo usermod -aG docker \"$USER\""
}

# wrk2's bundled LuaJIT loads the workload scripts, which start with
# require("socket"). LuaJIT is Lua-5.1 ABI but searches ONLY /usr/local paths
# (/usr/local/share/lua/5.1, /usr/local/lib/lua/5.1) — not the distro dirs
# (/usr/share/lua/5.1, /usr/lib/<arch>/lua/5.1) where the lua-socket package
# lands its files. So we locate the Lua-5.1 socket.lua + socket/core.so and
# symlink them onto LuaJIT's path. luarocks (which installs into /usr/local
# directly) is only a fallback for distros without a Lua-5.1 socket package.
#
# wrk2 loads the script with this exact restricted path; mirror it to verify.
LUAJIT_PATH='/usr/local/share/lua/5.1/?.lua;/usr/local/share/lua/5.1/?/init.lua'
LUAJIT_CPATH='/usr/local/lib/lua/5.1/?.so'
luajit_has_socket() {
    luajit -e "package.path=[[$LUAJIT_PATH]]; package.cpath=[[$LUAJIT_CPATH]]; require('socket')" &>/dev/null
}

install_luasocket() {
    if luajit_has_socket; then
        ok "luasocket already on luajit's path"
        return
    fi

    # Find the Lua-5.1 build dropped by the distro package (lua-socket etc.).
    local socket_lua socket_core
    socket_lua=$(find /usr/share/lua/5.1 /usr/local/share/lua/5.1 -name socket.lua 2>/dev/null | head -1)
    socket_core=$(find /usr/lib /usr/local/lib -path '*/lua/5.1/socket/core.so' 2>/dev/null | head -1)

    if [[ -n "$socket_lua" && -n "$socket_core" ]]; then
        info "Linking luasocket onto luajit's path (/usr/local/{share,lib}/lua/5.1)..."
        sudo mkdir -p /usr/local/share/lua/5.1 /usr/local/lib/lua/5.1/socket
        sudo ln -sf "$socket_lua"  /usr/local/share/lua/5.1/socket.lua
        sudo ln -sf "$socket_core" /usr/local/lib/lua/5.1/socket/core.so
    elif command -v luarocks &>/dev/null; then
        info "No Lua-5.1 socket package found; installing via luarocks (into /usr/local)..."
        sudo luarocks --lua-version=5.1 install luasocket \
            || sudo luarocks install luasocket || true
    fi

    luajit_has_socket \
        && ok "luasocket linked for luajit" \
        || fail "luasocket not available to luajit — wrk2 scripts using require(\"socket\") will fail"
}

OS="$(detect_os)"
info "Detected OS: $OS"

case "$OS" in
    debian)
        info "Installing packages via apt-get..."
        sudo apt-get update -qq
        # shellcheck disable=SC2086
        sudo apt-get install -y $PKGS_DEBIAN
        install_docker
        ;;
    rhel|fedora)
        info "Installing packages via dnf/yum..."
        if command -v dnf &>/dev/null; then
            # shellcheck disable=SC2086
            sudo dnf install -y $PKGS_RPM
        else
            # shellcheck disable=SC2086
            sudo yum install -y $PKGS_RPM
        fi
        install_docker
        ;;
    arch)
        info "Installing packages via pacman..."
        # shellcheck disable=SC2086
        sudo pacman -S --noconfirm $PKGS_ARCH docker docker-compose
        sudo systemctl enable --now docker 2>/dev/null || true
        ;;
    macos)
        echo "ERROR: On macOS install Docker Desktop manually (https://docker.com/products/docker-desktop)," >&2
        echo "       then: brew install luajit luarocks openssl zlib python3 && luarocks --lua-version=5.1 install luasocket" >&2
        exit 1
        ;;
    *)
        echo "ERROR: Unrecognised OS. Install manually: docker + compose, gcc/make, openssl+zlib dev," >&2
        echo "       luajit + headers, luarocks + luasocket, curl, python3 + pip." >&2
        exit 1
        ;;
esac

install_luasocket

# -- Python packages
info "Installing Python packages: $PIP_PKGS"
# shellcheck disable=SC2086
python3 -m pip install --user $PIP_PKGS 2>/dev/null \
    || python3 -m pip install --user --break-system-packages $PIP_PKGS

# -- Verify
echo ""
info "Verifying required tools..."
ALL_OK=1
for cmd in docker make gcc curl python3; do
    if command -v "$cmd" &>/dev/null; then
        ok "$cmd  ($(command -v "$cmd"))"
    else
        fail "$cmd"; ALL_OK=0
    fi
done
if docker compose version &>/dev/null; then
    ok "docker compose ($(docker compose version | head -1))"
else
    fail "docker compose plugin"; ALL_OK=0
fi
python3 -c "import numpy, matplotlib" 2>/dev/null && ok "python: numpy + matplotlib" || { fail "python numpy/matplotlib"; ALL_OK=0; }
luajit_has_socket && ok "luajit: luasocket (on /usr/local path)" || { fail "luajit luasocket (wrk2 scripts need require(\"socket\"))"; ALL_OK=0; }

echo ""
if [[ "$ALL_OK" -eq 1 ]]; then
    info "All prerequisites satisfied. Run ./install.sh to build wrk2 and warm app images."
else
    echo "ERROR: Some tools are still missing — check the output above." >&2
    echo "       (You may need to re-login for docker group membership to take effect.)" >&2
    exit 1
fi
