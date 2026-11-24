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
KOSMICKRISP_DIR=""
INCLUDE_KOSMICKRISP=1
DRY_RUN=0
SKIP_DMG=0

eval "$(python3 - "$SCRIPT_DIR" "$WORKSPACE_ROOT" <<'PY'
import hashlib, json, pathlib, shlex, sys
sys.path.insert(0, sys.argv[1])
from verify import discover
repo, project, _, scheme = discover(pathlib.Path(sys.argv[2]))
print(f'REPO_DIR={shlex.quote(str(repo))}')
print(f'PROJECT_PATH={shlex.quote(str(project))}')
print(f'SCHEME={shlex.quote(scheme)}')
manifest = next(repo.glob('*/Resources/runtime-manifest.json'), None)
components = json.loads(manifest.read_text())['components'] if manifest else []
component = next((c for c in components if c.get('requiredVulkanFeatures')), None)
source = pathlib.Path('/missing-runtime')
if component:
    driver = next((a for a in component['artifacts'] if a['name'].startswith('libvulkan_')), None)
    if driver:
        candidates = (pathlib.Path.home() / 'Library/Application Support').glob(
            '*/wine-engine/downloads/*/lib/' + driver['name'])
        for candidate in candidates:
            try:
                if hashlib.sha256(candidate.read_bytes()).hexdigest() == driver['sha256']:
                    source = candidate.parents[1]
                    break
            except OSError:
                continue
print(f'KOSMICKRISP_DIR={shlex.quote(str(source))}')
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
  --kosmickrisp-dir <dir>          Directory containing lib/libvulkan.1.dylib and lib/libvulkan_kosmickrisp.dylib
  --without-kosmickrisp            Skip bundling KosmicKrisp (explicit MoltenVK fallback)
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
        --kosmickrisp-dir)
            KOSMICKRISP_DIR="$2"
            INCLUDE_KOSMICKRISP=1
            shift 2
            ;;
        --without-kosmickrisp)
            INCLUDE_KOSMICKRISP=0
            shift
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

# Validate exact source bytes, process slices and Vulkan features before embedding.
python3 - "$SCRIPT_DIR" "$STAGED_APP" "$KOSMICKRISP_DIR" "$INCLUDE_KOSMICKRISP" "$OUTPUT_DIR/vulkan-bundle.json" <<'PYB'
import json, pathlib, sys
sys.path.insert(0, sys.argv[1])
from runtime_bundle_gate import embed_locked_vulkan
result = embed_locked_vulkan(pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3]), sys.argv[4] == '1')
pathlib.Path(sys.argv[5]).write_text(json.dumps(result, indent=2) + '\n')
print('[package] Optional Vulkan bundle: ' + ('verified' if result['bundled'] else
      'explicit MoltenVK fallback (' + result['fallbackReason'] + ')'))
PYB
KOSMICKRISP_BUNDLED=$(python3 - "$OUTPUT_DIR/vulkan-bundle.json" <<'PYB'
import json, sys
print(int(json.load(open(sys.argv[1]))['bundled']))
PYB
)

# Local ad-hoc signing enforces actual Hardened Runtime while preserving locked driver bytes.
codesign --force --sign - --options runtime --timestamp=none \
    "$STAGED_APP/Contents/Resources/${EXECUTABLE_NAME}Cmd" 2>"$OUTPUT_DIR/sign-cli.log"
codesign --force --sign - --options runtime --timestamp=none \
    "$STAGED_APP" 2>"$OUTPUT_DIR/sign-app.log"
python3 - "$SCRIPT_DIR" "$STAGED_APP" "$OUTPUT_DIR/hardened-runtime.json" <<'PYB'
import json, pathlib, sys
sys.path.insert(0, sys.argv[1])
from runtime_bundle_gate import verify_hardened
result = verify_hardened(pathlib.Path(sys.argv[2]))
pathlib.Path(sys.argv[3]).write_text(json.dumps(result, indent=2) + '\n')
if not result['passed']:
    raise SystemExit('error: actual Hardened Runtime signature validation failed')
PYB

if [ "$SKIP_DMG" -eq 0 ]; then
    echo "[package] Creating compressed UDZO .dmg at $DMG_PATH ..."
    rm -f "$DMG_PATH"
    hdiutil create \
        -volname "my-project-${CONFIGURATION}" \
        -srcfolder "$STAGING_DIR" \
        -ov \
        -format UDZO \
        "$DMG_PATH" >"$OUTPUT_DIR/hdiutil.log" 2>&1
    hdiutil verify "$DMG_PATH" >"$OUTPUT_DIR/dmg-verify.log" 2>&1
fi

# Verify bundle completeness, purity, resource digests, and emit redacted manifest JSON.
python3 - "$REPO_DIR" "$STAGED_APP" "$EXECUTABLE_NAME" "$CONFIGURATION" "$MARKETING_VERSION" \
    "$HARDENED_RUNTIME_SETTING" "$SKIP_DMG" "$DMG_PATH" "$MANIFEST_OUTPUT" "$KOSMICKRISP_BUNDLED" <<'PY'
import datetime, hashlib, json, pathlib, subprocess, sys
sys.path.insert(0, str(pathlib.Path(__file__).parent) if "__file__" in globals() else "")

repo = pathlib.Path(sys.argv[1])
app = pathlib.Path(sys.argv[2])
exe_name = sys.argv[3]
config = sys.argv[4]
marketing_version = sys.argv[5]
hardened = sys.argv[6]
skip_dmg = int(sys.argv[7])
dmg_path = pathlib.Path(sys.argv[8])
manifest_out = sys.argv[9]
kk_bundled = int(sys.argv[10]) == 1

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

# Verify locked KosmicKrisp SHA-256, x86_64 slice, and relative ICD path when bundled.
manifest_doc = json.loads(required['runtime_manifest'].read_text(encoding='utf-8'))
kk_info = json.loads((dmg_path.parent / 'vulkan-bundle.json').read_text())
if kk_bundled:
    kk_comp = next((c for c in manifest_doc.get('components', []) if c.get('requiredVulkanFeatures')), None)
    if kk_comp is None:
        raise SystemExit('error: kosmicKrisp entry missing in runtime-manifest.json')
    expected_map = {a['name']: a['sha256'].lower() for a in kk_comp.get('artifacts', [])}
    loader_path = app / 'Contents/Frameworks/libvulkan.1.dylib'
    kk_dylib_path = app / 'Contents/Frameworks/libvulkan_kosmickrisp.dylib'
    icd_path = app / 'Contents/Resources/vulkan/icd.d/kosmickrisp_icd.json'
    for name, fpath in (('libvulkan.1.dylib', loader_path),
                        ('libvulkan_kosmickrisp.dylib', kk_dylib_path),
                        ('kosmickrisp_icd.json', icd_path)):
        actual = sha256_file(fpath)
        if expected_map.get(name) != actual:
            raise SystemExit(f'error: KosmicKrisp SHA-256 mismatch for {name}: {actual} != {expected_map.get(name)}')
    lipo_out = subprocess.run(['lipo', '-info', str(kk_dylib_path)], capture_output=True, text=True, check=True).stdout
    if 'x86_64' not in lipo_out:
        raise SystemExit(f'error: libvulkan_kosmickrisp.dylib missing x86_64 slice: {lipo_out.strip()}')
    icd_json = json.loads(icd_path.read_text(encoding='utf-8'))
    lib_rel = icd_json.get('ICD', {}).get('library_path', '')
    if not lib_rel or lib_rel.startswith('/'):
        raise SystemExit(f'error: kosmickrisp_icd.json must use a relative library_path (got {lib_rel!r})')
    resolved_target = (icd_path.parent / lib_rel).resolve()
    if resolved_target != kk_dylib_path.resolve():
        raise SystemExit('error: kosmickrisp_icd.json relative path does not resolve to bundled dylib')
    kk_info = {
        **kk_info,
        'bundled': True,
        'x86_64SliceVerified': True,
        'relativeICDPathVerified': True,
        'vulkanLoaderSHA256': sha256_file(loader_path),
        'driverSHA256': sha256_file(kk_dylib_path),
        'icdManifestSHA256': sha256_file(icd_path),
    }

# Assert bundle purity (no lab scripts, driver modules, dev logs, or git metadata).
forbidden_tokens = ('graphics-lab', 'windowsprobe', 'module-a', '.dev-logs', 'handoff', '.git')
leaked = []
for entry in app.rglob('*'):
    rel_lower = str(entry.relative_to(app)).lower()
    if any(tok in rel_lower for tok in forbidden_tokens) or entry.suffix.lower() in {'.swift', '.pcm', '.o', '.py', '.cpp', '.c'}:
        leaked.append(rel_lower)
if leaked:
    raise SystemExit(f'error: forbidden development files leaked into .app bundle: {leaked[:5]}')

dmg_info = None
if skip_dmg == 0:
    if not dmg_path.is_file() or dmg_path.stat().st_size == 0:
        raise SystemExit('error: .dmg file missing or empty')
    dmg_info = {
        'filename': 'demo-app.dmg',
        'sizeBytes': dmg_path.stat().st_size,
        'sha256': sha256_file(dmg_path),
    }

report = {
    'schema': 'task-07-release-package-v2',
    'owner': '@DNPMBHC',
    'capturedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'configuration': config,
    'architecture': 'arm64',
    'marketingVersion': marketing_version,
    'hardenedRuntimeEnabled': hardened == 'YES',
    'codeSigningAllowed': False,
    'localAdHocSigned': True,
    'hardenedRuntimeVerification': json.loads((dmg_path.parent / 'hardened-runtime.json').read_text()),
    'bundlePurityPassed': True,
    'requiredResourcesVerified': True,
    'vulkanBackend': kk_info,
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
