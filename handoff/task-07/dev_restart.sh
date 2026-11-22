#!/usr/bin/env bash
set -euo pipefail

# Development incremental rebuild & safe restart helper for the macOS app.
# Dynamically discovers project/scheme without hardcoding repository or user paths
# and never modifies global Git configuration.

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
WORKSPACE_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
CONFIGURATION="Debug"
DESTINATION="platform=macOS,arch=arm64"

eval "$(python3 - "$SCRIPT_DIR" "$WORKSPACE_ROOT" <<'PY'
import pathlib, shlex, sys
sys.path.insert(0, sys.argv[1])
from verify import discover
repo, project, _, scheme = discover(pathlib.Path(sys.argv[2]))
print(f'REPO_DIR={shlex.quote(str(repo))}')
print(f'PROJECT_PATH={shlex.quote(str(project))}')
print(f'SCHEME={shlex.quote(scheme)}')
PY
)"

DO_BUILD=1
DO_CLEAN=0
DO_LAUNCH=1
DRY_RUN=0
DERIVED_DATA_PATH=""

usage() {
    cat <<'EOF'
Usage: dev_restart.sh [options]

Rebuild Debug/arm64 (unsigned, locked package caches), safely stop running app
instances, and relaunch the newly built application bundle.

Options:
  --no-build              Skip xcodebuild and restart the latest built app
  --clean                 Run xcodebuild clean before build
  --no-launch             Build and stop old instances without relaunching GUI
  --dry-run               Resolve settings and print planned steps without mutating state
  --derived-data <path>   Pass an explicit -derivedDataPath to xcodebuild
  -h, --help              Show this help message
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --no-build)
            DO_BUILD=0
            shift
            ;;
        --clean)
            DO_CLEAN=1
            shift
            ;;
        --no-launch)
            DO_LAUNCH=0
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --derived-data)
            if [ $# -lt 2 ]; then
                echo "error: --derived-data requires a path argument" >&2
                exit 2
            fi
            DERIVED_DATA_PATH="$2"
            shift 2
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

if [ ! -d "$PROJECT_PATH" ]; then
    echo "error: Xcode project not found under workspace" >&2
    exit 1
fi

# Process-scoped Git HTTPS rewrite (never touches ~/.gitconfig).
GIT_COUNT="${GIT_CONFIG_COUNT:-0}"
export GIT_CONFIG_COUNT=$((GIT_COUNT + 2))
export "GIT_CONFIG_KEY_${GIT_COUNT}=url.https://github.com/.insteadOf"
export "GIT_CONFIG_VALUE_${GIT_COUNT}=git@github.com:"
export "GIT_CONFIG_KEY_$((GIT_COUNT + 1))=url.https://github.com/.insteadOf"
export "GIT_CONFIG_VALUE_$((GIT_COUNT + 1))=ssh://git@github.com/"
export GIT_TERMINAL_PROMPT=0

if [ -d "$SCRIPT_DIR/.tools" ]; then
    export PATH="$SCRIPT_DIR/.tools:$PATH"
fi

XCODE_BASE=(
    xcodebuild
    -project "$PROJECT_PATH"
    -scheme "$SCHEME"
    -configuration "$CONFIGURATION"
    -destination "$DESTINATION"
    -scmProvider system
    -skipPackageUpdates
    -disableAutomaticPackageResolution
    -onlyUsePackageVersionsFromResolvedFile
    CODE_SIGNING_ALLOWED=NO
)

if [ -n "$DERIVED_DATA_PATH" ]; then
    XCODE_BASE+=(-derivedDataPath "$DERIVED_DATA_PATH")
fi

BUILD_LOG_DIR="$SCRIPT_DIR/.dev-logs"
mkdir -p "$BUILD_LOG_DIR"
BUILD_LOG="$BUILD_LOG_DIR/dev-build-$(date +%Y%m%d-%H%M%S).log"

# Resolve exact target build settings via xcodebuild JSON output.
SETTINGS_JSON=$("${XCODE_BASE[@]}" -showBuildSettings -json 2>"$BUILD_LOG_DIR/show-settings.stderr.log")
eval "$(python3 - "$SETTINGS_JSON" <<'PY'
import json, shlex, sys

targets = json.loads(sys.argv[1])
app = None
for item in targets:
    bs = item.get('buildSettings', {})
    if bs.get('PRODUCT_TYPE') == 'com.apple.product-type.application':
        app = bs
        break
if app is None:
    raise SystemExit('error: application target settings not found')
for key, var in (
    ('TARGET_BUILD_DIR', 'TARGET_BUILD_DIR'),
    ('FULL_PRODUCT_NAME', 'FULL_PRODUCT_NAME'),
    ('EXECUTABLE_NAME', 'EXECUTABLE_NAME'),
    ('PRODUCT_BUNDLE_IDENTIFIER', 'BUNDLE_ID'),
):
    print(f'{var}={shlex.quote(app.get(key, ""))}')
PY
)"

APP_PATH="$TARGET_BUILD_DIR/$FULL_PRODUCT_NAME"
APP_BINARY="$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"
CLI_BINARY="$APP_PATH/Contents/Resources/${EXECUTABLE_NAME}Cmd"
APP_LOGS_DIR="$HOME/Library/Logs/$BUNDLE_ID"

BUILD_ACTIONS=()
if [ "$DO_CLEAN" -eq 1 ]; then
    BUILD_ACTIONS+=(clean)
fi
BUILD_ACTIONS+=(build)

if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run] build=%d clean=%d launch=%d\n' "$DO_BUILD" "$DO_CLEAN" "$DO_LAUNCH"
    printf '[dry-run] build_command: %s %s\n' "${XCODE_BASE[*]}" "${BUILD_ACTIONS[*]}"
    printf '[dry-run] app_bundle: %s\n' "$APP_PATH"
    printf '[dry-run] cli_binary: %s\n' "$CLI_BINARY"
    printf '[dry-run] bundle_id: %s\n' "$BUNDLE_ID"
    printf '[dry-run] build_log: %s\n' "$BUILD_LOG"
    printf '[dry-run] app_logs_dir: %s\n' "$APP_LOGS_DIR"
    exit 0
fi

if [ "$DO_BUILD" -eq 1 ]; then
    echo "[dev_restart] Building $SCHEME ($CONFIGURATION / arm64, unsigned, locked caches)..."
    if ! (cd "$REPO_DIR" && "${XCODE_BASE[@]}" "${BUILD_ACTIONS[@]}" >"$BUILD_LOG" 2>&1); then
        echo "[dev_restart] Build failed. Tail of build log ($BUILD_LOG):" >&2
        tail -n 40 "$BUILD_LOG" >&2 || true
        exit 1
    fi
    echo "[dev_restart] Build succeeded. Log: $BUILD_LOG"
fi

if [ ! -d "$APP_PATH" ] || [ ! -x "$APP_BINARY" ]; then
    echo "[dev_restart] error: built application executable missing at $APP_BINARY" >&2
    exit 1
fi

find_running_pids() {
    pgrep -x "$EXECUTABLE_NAME" 2>/dev/null || true
}

OLD_PIDS=$(find_running_pids)
if [ -n "$OLD_PIDS" ]; then
    echo "[dev_restart] Stopping running $EXECUTABLE_NAME instance(s): $(echo "$OLD_PIDS" | tr '\n' ' ')"
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true

    for _ in $(seq 1 25); do
        if [ -z "$(find_running_pids)" ]; then
            break
        fi
        sleep 0.2
    done

    REMAINING=$(find_running_pids)
    if [ -n "$REMAINING" ]; then
        kill -TERM $REMAINING 2>/dev/null || true
        for _ in $(seq 1 15); do
            if [ -z "$(find_running_pids)" ]; then
                break
            fi
            sleep 0.2
        done
    fi

    STILL_ALIVE=$(find_running_pids)
    if [ -n "$STILL_ALIVE" ]; then
        echo "[dev_restart] Force stopping stubborn instance(s): $(echo "$STILL_ALIVE" | tr '\n' ' ')"
        kill -KILL $STILL_ALIVE 2>/dev/null || true
        sleep 0.3
    fi
else
    echo "[dev_restart] No running $EXECUTABLE_NAME instance found."
fi

if [ "$DO_LAUNCH" -eq 0 ]; then
    echo "[dev_restart] --no-launch set; skipping GUI launch."
    echo "[dev_restart] App bundle: $APP_PATH"
    echo "[dev_restart] CLI binary: $CLI_BINARY"
    exit 0
fi

echo "[dev_restart] Launching $APP_PATH ..."
open -n "$APP_PATH"

NEW_PID=""
for _ in $(seq 1 25); do
    NEW_PID=$(find_running_pids | head -n 1 || true)
    if [ -n "$NEW_PID" ]; then
        break
    fi
    sleep 0.2
done

echo "[dev_restart] Relaunch complete."
echo "  App bundle : $APP_PATH"
echo "  CLI binary : $CLI_BINARY"
echo "  PID        : ${NEW_PID:-pending}"
echo "  Build log  : $BUILD_LOG"
echo "  Runtime log: $APP_LOGS_DIR (local diagnostics only; do not share unredacted)"
