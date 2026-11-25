#!/usr/bin/env bash
set -euo pipefail

# Custom UTM v5.0.9 + CocoaSpice patch verification and out-of-repo build helper.
# Owner: @DNPMBHC
# Strictly keeps external source trees and build artifacts outside this repository.

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
MODULE_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
REPO_ROOT=$(CDPATH= cd -- "$MODULE_DIR/../../.." && pwd)
PATCHES_DIR="$MODULE_DIR/patches"
WORK_ROOT="${TMPDIR:-/tmp}/utm-custom-src"
CHECK_ONLY=1

usage() {
    cat <<'EOF'
Usage: build_custom_utm.sh [options]

Validate and apply the minimal UTM v5.0.9 / CocoaSpice patch set in an external
temporary directory (never inside the Whisky repository).

Options:
  --work-root <dir>   External directory for utmapp/UTM & CocoaSpice clones (default: $TMPDIR/utm-custom-src)
  --build             Attempt xcodebuild after applying patches (requires UTM prebuilt QEMU/Spice sysroot)
  --check-only        Run compliance audit and stacked git apply --check only (default)
  -h, --help          Show this help message
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --work-root)
            WORK_ROOT="$2"
            shift 2
            ;;
        --build)
            CHECK_ONLY=0
            shift
            ;;
        --check-only)
            CHECK_ONLY=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "error: unknown option '$1'" >&2
            usage >&2
            exit 2
            ;;
    esac
done

# Ensure WORK_ROOT is strictly outside REPO_ROOT.
python3 - "$REPO_ROOT" "$WORK_ROOT" <<'PY'
import pathlib, sys
repo = pathlib.Path(sys.argv[1]).resolve()
work = pathlib.Path(sys.argv[2]).resolve()
try:
    work.relative_to(repo)
    raise SystemExit("error: --work-root must be outside the repository")
except ValueError:
    pass
PY

python3 "$REPO_ROOT/graphics-lab/utm_custom_patch_verify.py" --patches-dir "$PATCHES_DIR"

mkdir -p "$WORK_ROOT"
UTM_DIR="$WORK_ROOT/UTM"
SPICE_DIR="$WORK_ROOT/CocoaSpice"

if [ ! -d "$UTM_DIR/.git" ]; then
    echo "[utm-custom] Shallow cloning utmapp/UTM v5.0.9 into $UTM_DIR ..."
    git clone --depth 1 --branch v5.0.9 https://github.com/utmapp/UTM.git "$UTM_DIR"
fi
if [ ! -d "$SPICE_DIR/.git" ]; then
    echo "[utm-custom] Shallow cloning utmapp/CocoaSpice into $SPICE_DIR ..."
    git clone --depth 1 https://github.com/utmapp/CocoaSpice.git "$SPICE_DIR"
fi

git -C "$UTM_DIR" reset --hard HEAD >/dev/null
git -C "$SPICE_DIR" reset --hard HEAD >/dev/null

echo "[utm-custom] Verifying stacked git apply --check on UTM v5.0.9 ..."
git -C "$UTM_DIR" apply --check \
    "$PATCHES_DIR/01-default-dxmt-backend.patch" \
    "$PATCHES_DIR/02-cursor-and-fps-capture.patch" \
    "$PATCHES_DIR/03-clean-fullscreen-game-shell.patch"

echo "[utm-custom] Verifying git apply --check on CocoaSpice ..."
git -C "$SPICE_DIR" apply --check "$PATCHES_DIR/02-cocoaspice-cursor-overlay.patch"

if [ "$CHECK_ONLY" -eq 1 ]; then
    echo "[utm-custom] Check-only completed successfully."
    exit 0
fi

echo "[utm-custom] Applying patches and checking UTM macOS build prerequisites..."
git -C "$UTM_DIR" apply \
    "$PATCHES_DIR/01-default-dxmt-backend.patch" \
    "$PATCHES_DIR/02-cursor-and-fps-capture.patch" \
    "$PATCHES_DIR/03-clean-fullscreen-game-shell.patch"
git -C "$SPICE_DIR" apply "$PATCHES_DIR/02-cocoaspice-cursor-overlay.patch"

if [ ! -d "$UTM_DIR/Sysroot-macOS" ]; then
    echo "[utm-custom] Sysroot-macOS (QEMU/GLib/Spice prebuilt dependencies) is not present in $UTM_DIR." >&2
    echo "[utm-custom] Patches applied cleanly; full xcodebuild requires UTM's external sysroot archive." >&2
    exit 3
fi

xcodebuild \
    -project "$UTM_DIR/UTM.xcodeproj" \
    -scheme macOS \
    -configuration Release \
    -destination "platform=macOS,arch=arm64" \
    -derivedDataPath "$WORK_ROOT/DerivedData" \
    CODE_SIGNING_ALLOWED=NO \
    build
