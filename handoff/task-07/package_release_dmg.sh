#!/usr/bin/env bash
set -euo pipefail

# Reproducible unsigned Release/Debug single-.app -> .dmg packager with Hardened Runtime
# and strict bundle purity assertions. Never places >5 MiB artifacts inside the repository
# and never modifies global Git configuration.

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
WORKSPACE_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
CONFIGURATION="Release"
DESTINATION="platform=macOS,arch=arm64"
OUTPUT_DIR="${TMPDIR:-/tmp}/my-project-release-packaging"
DERIVED_DATA_PATH=""
MANIFEST_OUTPUT=""
DRY_RUN=0
SKIP_DMG=0

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

usage() {
    cat <<'EOF'
Usage: package_release_dmg.sh [options]

Build an unsigned Hardened Runtime .app bundle, assert resource completeness and
bundle purity, package a clean .dmg in an external temporary directory, and emit
a redacted SHA-256 manifest JSON.

Options:
  --configuration <Release|Debug>  Build configuration (default: Release)
  --output-dir <dir>               Temporary output directory outside workspace
  --derived-data <dir>             Explicit -derivedDataPath for xcodebuild
  --manifest-output <file>         Write redacted packaging manifest JSON to file
  --skip-dmg                       Build and verify .app only without creating .dmg
  --dry-run                        Print planned commands and exit without building
  -h, --help                       Show this help message
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --configuration)
            CONFIGURATION="$2"
            shift 2
            ;;
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --derived-data)
            DERIVED_DATA_PATH="$2"
            shift 2
            ;;
        --manifest-output)
            MANIFEST_OUTPUT="$2"
            shift 2
            ;;
        --skip-dmg)
            SKIP_DMG=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
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

case "$CONFIGURATION" in
    Release|Debug) ;;
    *)
        echo "error: --configuration must be Release or Debug" >&2
        exit 2
        ;;
esac

# Refuse placing large build/dmg output inside the workspace repository.
python3 - "$WORKSPACE_ROOT" "$OUTPUT_DIR" <<'PY'
import pathlib, sys
ws = pathlib.Path(sys.argv[1]).resolve()
out = pathlib.Path(sys.argv[2]).resolve()
try:
    out.relative_to(ws)
    raise SystemExit("error: --output-dir must be outside the workspace to avoid committing >5 MiB artifacts")
except ValueError:
    pass
PY

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
    ENABLE_HARDENED_RUNTIME=YES
    CODE_SIGNING_ALLOWED=NO
)

if [ -n "$DERIVED_DATA_PATH" ]; then
    XCODE_BASE+=(-derivedDataPath "$DERIVED_DATA_PATH")
fi

mkdir -p "$OUTPUT_DIR"
BUILD_LOG="$OUTPUT_DIR/package-build-$(date +%Y%m%d-%H%M%S).log"

SETTINGS_JSON=$("${XCODE_BASE[@]}" -showBuildSettings -json 2>"$OUTPUT_DIR/show-settings.stderr.log")
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
    ('ENABLE_HARDENED_RUNTIME', 'HARDENED_RUNTIME_SETTING'),
    ('MARKETING_VERSION', 'MARKETING_VERSION'),
):
    print(f'{var}={shlex.quote(str(app.get(key, "")))}')
PY
)"

if [ "$HARDENED_RUNTIME_SETTING" != "YES" ]; then
    echo "error: ENABLE_HARDENED_RUNTIME must be YES (got '$HARDENED_RUNTIME_SETTING')" >&2
    exit 1
fi

APP_PATH="$TARGET_BUILD_DIR/$FULL_PRODUCT_NAME"
APP_BINARY="$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"
CLI_BINARY="$APP_PATH/Contents/Resources/${EXECUTABLE_NAME}Cmd"
DMG_FILENAME="my-project-${CONFIGURATION}-arm64.dmg"
DMG_PATH="$OUTPUT_DIR/$DMG_FILENAME"

if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run] configuration=%s hardened_runtime=%s skip_dmg=%d\n' \
        "$CONFIGURATION" "$HARDENED_RUNTIME_SETTING" "$SKIP_DMG"
    printf '[dry-run] build_command: %s build\n' "${XCODE_BASE[*]}"
    printf '[dry-run] app_bundle: %s\n' "$APP_PATH"
    printf '[dry-run] cli_binary: %s\n' "$CLI_BINARY"
    printf '[dry-run] dmg_path: %s\n' "$DMG_PATH"
    exit 0
fi

echo "[package] Building single .app ($CONFIGURATION / arm64, Hardened Runtime=YES, unsigned)..."
if ! (cd "$REPO_DIR" && "${XCODE_BASE[@]}" build >"$BUILD_LOG" 2>&1); then
    echo "[package] Build failed. Tail of build log ($BUILD_LOG):" >&2
    tail -n 40 "$BUILD_LOG" >&2 || true
    exit 1
fi

STAGING_DIR="$OUTPUT_DIR/dmg-staging"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
ditto "$APP_PATH" "$STAGING_DIR/$FULL_PRODUCT_NAME"
ln -s /Applications "$STAGING_DIR/Applications"

STAGED_APP="$STAGING_DIR/$FULL_PRODUCT_NAME"

if [ "$SKIP_DMG" -eq 0 ]; then
    echo "[package] Creating compressed UDZO .dmg at $DMG_PATH ..."
    rm -f "$DMG_PATH"
    hdiutil create \
        -volname "my-project-${CONFIGURATION}" \
        -srcfolder "$STAGING_DIR" \
        -ov \
        -format UDZO \
        "$DMG_PATH" >"$OUTPUT_DIR/hdiutil.log" 2>&1
fi

# Verify bundle completeness, purity, resource digests, and emit redacted manifest JSON.
python3 - "$REPO_DIR" "$STAGED_APP" "$EXECUTABLE_NAME" "$CONFIGURATION" "$MARKETING_VERSION" \
    "$HARDENED_RUNTIME_SETTING" "$SKIP_DMG" "$DMG_PATH" "$MANIFEST_OUTPUT" <<'PY'
import datetime, hashlib, json, pathlib, sys

repo = pathlib.Path(sys.argv[1])
app = pathlib.Path(sys.argv[2])
exe_name = sys.argv[3]
config = sys.argv[4]
marketing_version = sys.argv[5]
hardened = sys.argv[6]
skip_dmg = int(sys.argv[7])
dmg_path = pathlib.Path(sys.argv[8])
manifest_out = sys.argv[9]

def sha256_file(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda: f.read(65536), b''):
            h.update(chunk)
    return h.hexdigest()

required = {
    'app_binary': app / 'Contents/MacOS' / exe_name,
    'cli_binary': app / 'Contents/Resources' / f'{exe_name}Cmd',
    'compatibility_matrix': app / 'Contents/Resources/compatibility-matrix.json',
    'runtime_manifest': app / 'Contents/Resources/runtime-manifest.json',
}
for label, p in required.items():
    if not p.is_file() or p.stat().st_size == 0:
        raise SystemExit(f'error: required packaged artifact missing or empty: {label}')

# Verify bundled JSONs parse cleanly and match source resources byte-for-byte.
source_res = repo / repo.name / 'Resources'
for res_name, key in (('compatibility-matrix.json', 'compatibility_matrix'),
                      ('runtime-manifest.json', 'runtime_manifest')):
    bundled_bytes = required[key].read_bytes()
    json.loads(bundled_bytes.decode('utf-8'))
    src_path = source_res / res_name
    if src_path.is_file() and sha256_file(src_path) != sha256_file(required[key]):
        raise SystemExit(f'error: bundled {res_name} does not match source resource')

# Assert bundle purity (no lab scripts, driver modules, dev logs, or git metadata).
forbidden_tokens = ('graphics-lab', 'windowsprobe', 'module-a', '.dev-logs', 'handoff', '.git')
leaked = []
for entry in app.rglob('*'):
    rel_lower = str(entry.relative_to(app)).lower()
    if any(tok in rel_lower for tok in forbidden_tokens):
        leaked.append(rel_lower)
if leaked:
    raise SystemExit(f'error: forbidden development files leaked into .app bundle: {leaked[:5]}')

dmg_info = None
if skip_dmg == 0:
    if not dmg_path.is_file() or dmg_path.stat().st_size == 0:
        raise SystemExit('error: .dmg file missing or empty')
    dmg_info = {
        'filename': dmg_path.name,
        'sizeBytes': dmg_path.stat().st_size,
        'sha256': sha256_file(dmg_path),
    }

report = {
    'schema': 'task-07-release-package-v1',
    'owner': '@DNPMBHC',
    'capturedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'configuration': config,
    'architecture': 'arm64',
    'marketingVersion': marketing_version,
    'hardenedRuntimeEnabled': hardened == 'YES',
    'codeSigningAllowed': False,
    'bundlePurityPassed': True,
    'requiredResourcesVerified': True,
    'artifacts': {
        'appBinarySHA256': sha256_file(required['app_binary']),
        'cliBinarySHA256': sha256_file(required['cli_binary']),
        'compatibilityMatrixSHA256': sha256_file(required['compatibility_matrix']),
        'runtimeManifestSHA256': sha256_file(required['runtime_manifest']),
        'dmg': dmg_info,
    },
    'passed': True,
}
text = json.dumps(report, ensure_ascii=False, indent=2) + '\n'
if manifest_out:
    out_path = pathlib.Path(manifest_out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(text, encoding='utf-8')
print(text, end='')
PY

echo "[package] Packaged app ready at: $STAGED_APP"
if [ "$SKIP_DMG" -eq 0 ]; then
    echo "[package] Packaged dmg ready at: $DMG_PATH"
fi
