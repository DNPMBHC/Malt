#!/usr/bin/env bash
set -euo pipefail

# Build, verify, install, or uninstall the minimal macOS kernel vmnet.framework
# LaunchDaemon bridge (`malt-vmnet-bridge`) for unsigned / ad-hoc QEMU instances.
# Owner: @DNPMBHC
# Strictly builds outside this repository ($TMPDIR/utm-custom-build).

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_FILE="$SCRIPT_DIR/malt_vmnet_bridge.c"
PLIST_TEMPLATE="$SCRIPT_DIR/com.malt.vmnet-bridge.plist.template"
BUILD_ROOT="${TMPDIR:-/tmp}/utm-custom-build"
OUT_BIN="$BUILD_ROOT/malt-vmnet-bridge"
INSTALL_BIN="/Library/PrivilegedHelperTools/com.malt.vmnet-bridge"
INSTALL_PLIST="/Library/LaunchDaemons/com.malt.vmnet-bridge.plist"
SOCKET_PATH="/var/run/malt-vmnet-bridge.sock"
ACTION="build-only"

usage() {
    cat <<'EOF'
Usage: install_vmnet_bridge.sh [options]

Options:
  --build-only          Compile malt-vmnet-bridge out of repo and run --self-check (default, no sudo)
  --install             Compile and install LaunchDaemon (requires one-time standard sudo password)
  --uninstall           Stop and remove LaunchDaemon (requires sudo)
  --status              Check daemon socket and LaunchDaemon registration status (no sudo)
  --out-bin <path>      Output binary path outside repository (default: $TMPDIR/utm-custom-build/malt-vmnet-bridge)
  --socket <path>       Unix socket path (default: /var/run/malt-vmnet-bridge.sock)
  -h, --help            Show this help message
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --build-only) ACTION="build-only"; shift ;;
        --install) ACTION="install"; shift ;;
        --uninstall) ACTION="uninstall"; shift ;;
        --status) ACTION="status"; shift ;;
        --out-bin) [ $# -ge 2 ] || { echo "error: missing output path" >&2; exit 2; }; OUT_BIN="$2"; shift 2 ;;
        --socket)
            [ $# -ge 2 ] || { echo "error: missing socket path" >&2; exit 2; }
            [ "$2" = "$SOCKET_PATH" ] || { echo "error: only the fixed system socket is permitted" >&2; exit 2; }
            shift 2 ;;

        -h|--help) usage; exit 0 ;;
        *) echo "error: unknown option '$1'" >&2; usage >&2; exit 2 ;;
    esac
done

build_bridge() {
    mkdir -p "$(dirname "$OUT_BIN")"
    clang -O2 -Wall -Wextra -arch arm64 \
        "$SRC_FILE" \
        -framework vmnet \
        -framework CoreFoundation \
        -o "$OUT_BIN"
    "$OUT_BIN" --self-check
}

case "$ACTION" in
    build-only)
        build_bridge
        ;;
    status)
        active=false
        if [ -S "$SOCKET_PATH" ] && [ ! -L "$SOCKET_PATH" ] &&
           [ "$(stat -f %Lp "$SOCKET_PATH")" = "600" ] &&
           [ "$(stat -f %u "$SOCKET_PATH")" = "$(id -u)" ]; then
            active=true
        fi
        installed=false
        [ -f "$INSTALL_PLIST" ] && installed=true
        printf '{"daemon_label":"com.malt.vmnet-bridge","plist_installed":%s,"socket_path":"%s","socket_active":%s}\n' \
            "$installed" "$SOCKET_PATH" "$active"
        ;;
    install)
        build_bridge
        TMP_PLIST="$BUILD_ROOT/com.malt.vmnet-bridge.plist"
        sed -e "s|__BINARY_PATH__|$INSTALL_BIN|g" \
            -e "s|__SOCKET_PATH__|$SOCKET_PATH|g" \
            "$PLIST_TEMPLATE" > "$TMP_PLIST"
        plutil -lint "$TMP_PLIST" >/dev/null
        # The root phase executes fixed system tools, never a user-writable installer script.
        # Stage copies in a private root-owned directory and pin both hashes before launch.
        BINARY_SHA=$(/usr/bin/shasum -a 256 "$OUT_BIN" | /usr/bin/awk '{print $1}')
        PLIST_SHA=$(/usr/bin/shasum -a 256 "$TMP_PLIST" | /usr/bin/awk '{print $1}')
        IFS= read -r -d '' ROOT_INSTALL <<'ROOT' || true
set -eu
source_binary=$1
source_plist=$2
expected_binary=$3
expected_plist=$4
helper_dir=/Library/PrivilegedHelperTools
binary=/Library/PrivilegedHelperTools/com.malt.vmnet-bridge
plist=/Library/LaunchDaemons/com.malt.vmnet-bridge.plist
[ ! -L "$helper_dir" ] || exit 65
[ ! -L /Library/LaunchDaemons ] || exit 65
/usr/bin/install -d -m 0755 -o root -g wheel "$helper_dir"
[ "$(/usr/bin/stat -f %u "$helper_dir")" = 0 ] || exit 65
case "$(/usr/bin/stat -f %Lp "$helper_dir")" in 755|750|700) ;; *) exit 65 ;; esac
stage=$(/usr/bin/mktemp -d "$helper_dir/.network-install.XXXXXX")
trap '/bin/rm -rf "$stage"' EXIT HUP INT TERM
/bin/cp "$source_binary" "$stage/helper"
/bin/cp "$source_plist" "$stage/daemon.plist"
[ "$(/usr/bin/shasum -a 256 "$stage/helper" | /usr/bin/awk '{print $1}')" = "$expected_binary" ] || exit 65
[ "$(/usr/bin/shasum -a 256 "$stage/daemon.plist" | /usr/bin/awk '{print $1}')" = "$expected_plist" ] || exit 65
/usr/bin/plutil -lint "$stage/daemon.plist" >/dev/null
/usr/sbin/chown root:wheel "$stage/helper" "$stage/daemon.plist"
/bin/chmod 0755 "$stage/helper"
/bin/chmod 0644 "$stage/daemon.plist"
/bin/launchctl bootout system/com.malt.vmnet-bridge >/dev/null 2>&1 || true
/bin/mv -f "$stage/helper" "$binary"
/bin/mv -f "$stage/daemon.plist" "$plist"
/bin/launchctl bootstrap system "$plist"
/bin/launchctl kickstart -k system/com.malt.vmnet-bridge
ROOT
        sudo /bin/bash -c "$ROOT_INSTALL" -- "$OUT_BIN" "$TMP_PLIST" "$BINARY_SHA" "$PLIST_SHA"
        echo "[malt-vmnet-bridge] Installed and active on $SOCKET_PATH"
        ;;
    uninstall)
        # Fixed destinations only; no root execution of a local script or user-supplied path.
        sudo /bin/bash -c '
            /bin/launchctl bootout system/com.malt.vmnet-bridge >/dev/null 2>&1 || true
            /bin/rm -f /Library/LaunchDaemons/com.malt.vmnet-bridge.plist                 /Library/PrivilegedHelperTools/com.malt.vmnet-bridge /var/run/malt-vmnet-bridge.sock
        '

        echo "[malt-vmnet-bridge] Uninstalled cleanly."
        ;;
esac
