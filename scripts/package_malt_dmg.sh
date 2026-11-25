#!/usr/bin/env bash
set -euo pipefail

# Reproducible Release/arm64 Hardened Runtime Malt.app -> Malt.dmg packager.
# Produces compressed read-only Malt.dmg under Whisky/build/release/Malt.dmg (gitignored)
# or an explicit external output directory, and never commits >5 MiB binaries into git.

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
WORKSPACE_ROOT=$(CDPATH= cd -- "$REPO_DIR/.." && pwd)
TASK07_DIR="$WORKSPACE_ROOT/handoff/task-07"

CONFIGURATION="Release"
DESTINATION="platform=macOS,arch=arm64"
OUTPUT_DIR="$REPO_DIR/build/release"
STAGING_BASE="${TMPDIR:-/tmp}/malt-release-staging"
DERIVED_DATA_PATH=""
MANIFEST_OUTPUT=""
KOSMICKRISP_DIR=""
INCLUDE_KOSMICKRISP=1
DRY_RUN=0
SKIP_DMG=0

eval "$(python3 - "$TASK07_DIR" "$WORKSPACE_ROOT" <<'PY'
import hashlib, json, pathlib, shlex, sys
sys.path.insert(0, sys.argv[1])
from verify import discover
repo, project, _, scheme = discover(pathlib.Path(sys.argv[2]))
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
Usage: package_malt_dmg.sh [options]

Build a Release/arm64 Hardened Runtime Malt.app bundle, verify strict codesign
and absence of forbidden debug entitlements, assert bundle purity (no WhiskyKit
source or .build cache), and package a compressed read-only Malt.dmg with an
/Applications drag-and-drop symlink.

Options:
  --configuration <Release|Debug>  Build configuration (default: Release)
  --output-dir <dir>               Output directory for Malt.dmg (default: Whisky/build/release)
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

# Ensure output directory is either outside workspace or under gitignored Whisky/build/.
python3 - "$WORKSPACE_ROOT" "$REPO_DIR" "$OUTPUT_DIR" <<'PY'
import pathlib, sys
ws = pathlib.Path(sys.argv[1]).resolve()
repo_build = (pathlib.Path(sys.argv[2]) / 'build').resolve()
out = pathlib.Path(sys.argv[3]).resolve()
try:
    out.relative_to(ws)
    try:
        out.relative_to(repo_build)
    except ValueError:
        raise SystemExit("error: --output-dir inside workspace must be under Whisky/build/ (gitignored)")
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

if [ -d "$TASK07_DIR/.tools" ]; then
    export PATH="$TASK07_DIR/.tools:$PATH"
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

mkdir -p "$OUTPUT_DIR" "$STAGING_BASE"
BUILD_LOG="$STAGING_BASE/malt-package-build-$(date +%Y%m%d-%H%M%S).log"

SETTINGS_JSON=$("${XCODE_BASE[@]}" -showBuildSettings -json 2>"$STAGING_BASE/show-settings.stderr.log")
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
DMG_FILENAME="Malt.dmg"
DMG_PATH="$OUTPUT_DIR/$DMG_FILENAME"

if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run] configuration=%s hardened_runtime=%s skip_dmg=%d\n' \
        "$CONFIGURATION" "$HARDENED_RUNTIME_SETTING" "$SKIP_DMG"
    printf '[dry-run] build_command: %s build\n' "${XCODE_BASE[*]}"
    printf '[dry-run] app_bundle: %s\n' "$APP_PATH"
    printf '[dry-run] dmg_path: %s\n' "$DMG_PATH"
    exit 0
fi

echo "[malt-package] Building Malt ($CONFIGURATION / arm64, Hardened Runtime=YES)..."
if ! (cd "$REPO_DIR" && "${XCODE_BASE[@]}" build >"$BUILD_LOG" 2>&1); then
    echo "[malt-package] Build failed. Tail of build log ($BUILD_LOG):" >&2
    tail -n 40 "$BUILD_LOG" >&2 || true
    exit 1
fi

STAGING_DIR="$STAGING_BASE/dmg-staging"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
STAGED_APP="$STAGING_DIR/Malt.app"
ditto "$APP_PATH" "$STAGED_APP"
ln -s /Applications "$STAGING_DIR/Applications"

# Validate exact source bytes, process slices and Vulkan features before embedding.
python3 - "$TASK07_DIR" "$STAGED_APP" "$KOSMICKRISP_DIR" "$INCLUDE_KOSMICKRISP" "$STAGING_BASE/vulkan-bundle.json" <<'PYB'
import json, pathlib, sys
sys.path.insert(0, sys.argv[1])
from runtime_bundle_gate import embed_locked_vulkan
result = embed_locked_vulkan(pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3]), sys.argv[4] == '1')
pathlib.Path(sys.argv[5]).write_text(json.dumps(result, indent=2) + '\n')
print('[malt-package] Optional Vulkan bundle: ' + ('verified' if result['bundled'] else
      'explicit MoltenVK fallback (' + result['fallbackReason'] + ')'))
PYB
KOSMICKRISP_BUNDLED=$(python3 - "$STAGING_BASE/vulkan-bundle.json" <<'PYB'
import json, sys
print(int(json.load(open(sys.argv[1]))['bundled']))
PYB
)

ENTITLEMENTS_FILE="$REPO_DIR/Whisky/Whisky.entitlements"
if [ ! -f "$ENTITLEMENTS_FILE" ]; then
    echo "error: entitlements file missing at $ENTITLEMENTS_FILE" >&2
    exit 1
fi

# Sign nested frameworks, plug-ins, CLI binary, and main Malt.app inside-out with Hardened Runtime.
SPARKLE_VER_B="$STAGED_APP/Contents/Frameworks/Sparkle.framework/Versions/B"
if [ -d "$SPARKLE_VER_B" ]; then
    for nested_item in \
        "$SPARKLE_VER_B/XPCServices/Downloader.xpc" \
        "$SPARKLE_VER_B/XPCServices/Installer.xpc" \
        "$SPARKLE_VER_B/Updater.app" \
        "$SPARKLE_VER_B/Autoupdate" \
        "$STAGED_APP/Contents/Frameworks/Sparkle.framework"
    do
        if [ -e "$nested_item" ]; then
            codesign --force --sign - --options runtime --timestamp=none \
                "$nested_item" >>"$STAGING_BASE/sign-nested.log" 2>&1
        fi
    done
fi
if [ -d "$STAGED_APP/Contents/PlugIns/WhiskyThumbnail.appex" ]; then
    codesign --force --sign - --options runtime --timestamp=none \
        "$STAGED_APP/Contents/PlugIns/WhiskyThumbnail.appex" >>"$STAGING_BASE/sign-nested.log" 2>&1
fi
codesign --force --sign - --options runtime --timestamp=none \
    "$STAGED_APP/Contents/Resources/${EXECUTABLE_NAME}Cmd" 2>"$STAGING_BASE/sign-cli.log"
codesign --force --sign - --options runtime --entitlements "$ENTITLEMENTS_FILE" --timestamp=none \
    "$STAGED_APP" 2>"$STAGING_BASE/sign-app.log"

codesign --verify --deep --strict "$STAGED_APP" 2>"$STAGING_BASE/codesign-deep-strict.log"

python3 - "$TASK07_DIR" "$STAGED_APP" "$STAGING_BASE/hardened-runtime.json" <<'PYB'
import json, pathlib, sys
sys.path.insert(0, sys.argv[1])
from runtime_bundle_gate import verify_hardened
result = verify_hardened(pathlib.Path(sys.argv[2]))
pathlib.Path(sys.argv[3]).write_text(json.dumps(result, indent=2) + '\n')
if not result['passed']:
    raise SystemExit('error: Hardened Runtime signature validation failed')
PYB

if [ "$SKIP_DMG" -eq 0 ]; then
    echo "[malt-package] Creating compressed read-only Malt.dmg at $DMG_PATH ..."
    rm -f "$DMG_PATH"
    hdiutil create \
        -volname "Malt" \
        -srcfolder "$STAGING_DIR" \
        -ov \
        -format UDZO \
        "$DMG_PATH" >"$STAGING_BASE/hdiutil.log" 2>&1
    hdiutil verify "$DMG_PATH" >"$STAGING_BASE/dmg-verify.log" 2>&1
fi

python3 - "$REPO_DIR" "$STAGED_APP" "$EXECUTABLE_NAME" "$CONFIGURATION" "$MARKETING_VERSION" \
    "$HARDENED_RUNTIME_SETTING" "$SKIP_DMG" "$DMG_PATH" "$MANIFEST_OUTPUT" "$KOSMICKRISP_BUNDLED" \
    "$STAGING_BASE" <<'PY'
import datetime, hashlib, json, pathlib, plistlib, subprocess, sys

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
staging_base = pathlib.Path(sys.argv[11])

def sha256_file(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda: f.read(65536), b''):
            h.update(chunk)
    return h.hexdigest()

info_plist = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
display_name = info_plist.get('CFBundleDisplayName', '')
if display_name != 'Malt':
    raise SystemExit(f'error: CFBundleDisplayName must be "Malt" (got {display_name!r})')

required = {
    'app_binary': app / 'Contents/MacOS' / exe_name,
    'cli_binary': app / 'Contents/Resources' / f'{exe_name}Cmd',
    'compatibility_matrix': app / 'Contents/Resources/compatibility-matrix.json',
    'runtime_manifest': app / 'Contents/Resources/runtime-manifest.json',
}
for label, p in required.items():
    if not p.is_file() or p.stat().st_size == 0:
        raise SystemExit(f'error: required packaged artifact missing or empty: {label}')

source_res = repo / repo.name / 'Resources'
for res_name, key in (('compatibility-matrix.json', 'compatibility_matrix'),
                      ('runtime-manifest.json', 'runtime_manifest')):
    bundled_bytes = required[key].read_bytes()
    json.loads(bundled_bytes.decode('utf-8'))
    src_path = source_res / res_name
    if src_path.is_file() and sha256_file(src_path) != sha256_file(required[key]):
        raise SystemExit(f'error: bundled {res_name} does not match source resource')

kk_info = json.loads((staging_base / 'vulkan-bundle.json').read_text())
manifest_doc = json.loads(required['runtime_manifest'].read_text(encoding='utf-8'))
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
            raise SystemExit(f'error: KosmicKrisp SHA-256 mismatch for {name}')

# Verify strict codesign --verify --deep --strict and inspect entitlements.
deep_verify = subprocess.run(
    ['codesign', '--verify', '--deep', '--strict', str(app)],
    capture_output=True, text=True
)
if deep_verify.returncode != 0:
    raise SystemExit(f'error: codesign --verify --deep --strict failed: {deep_verify.stderr.strip()}')

ent_proc = subprocess.run(
    ['codesign', '-d', '--entitlements', ':-', str(app)],
    capture_output=True
)
if ent_proc.returncode != 0:
    raise SystemExit('error: failed to read codesign entitlements')
entitlements_dict = plistlib.loads(ent_proc.stdout) if ent_proc.stdout.strip() else {}
forbidden_entitlements = [
    'com.apple.security.get-task-allow',
    'com.apple.security.cs.allow-dyld-environment-variables',
    'com.apple.security.cs.disable-library-validation',
    'com.apple.security.cs.allow-jit',
    'com.apple.security.cs.allow-unsigned-executable-memory',
]
found_forbidden = [k for k in forbidden_entitlements if entitlements_dict.get(k) is True]
if found_forbidden:
    raise SystemExit(f'error: forbidden debug/insecure entitlements found: {found_forbidden}')

# Assert bundle purity (no WhiskyKit source, .build cache, dev logs, or git metadata).
forbidden_tokens = ('whiskykit', '.build', 'graphics-lab', 'windowsprobe', 'module-a', '.dev-logs', 'handoff', '.git')
leaked = []
for entry in app.rglob('*'):
    rel_lower = str(entry.relative_to(app)).lower()
    if any(tok in rel_lower for tok in forbidden_tokens) or entry.suffix.lower() in {'.swift', '.pcm', '.o', '.py', '.cpp', '.c'}:
        leaked.append(rel_lower)
if leaked:
    raise SystemExit(f'error: forbidden development/source files leaked into .app bundle: {leaked[:5]}')

dmg_info = None
if skip_dmg == 0:
    if not dmg_path.is_file() or dmg_path.stat().st_size == 0:
        raise SystemExit('error: Malt.dmg missing or empty')
    size_bytes = dmg_path.stat().st_size
    size_mib = round(size_bytes / (1024 * 1024), 3)
    if size_bytes >= 20 * 1024 * 1024:
        raise SystemExit(f'error: Malt.dmg exceeds 20 MiB target ({size_mib} MiB)')
    dmg_info = {
        'filename': dmg_path.name,
        'relativePath': 'Whisky/build/release/Malt.dmg',
        'sizeBytes': size_bytes,
        'sizeMiB': size_mib,
        'sha256': sha256_file(dmg_path),
        'applicationsSymlinkPresent': (app.parent / 'Applications').is_symlink(),
        'readOnlyCompressedUDZO': True,
    }

report = {
    'schema': 'phase-14b-malt-release-dmg-v1',
    'owner': '@DNPMBHC',
    'capturedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'brand': 'Malt',
    'cfBundleDisplayName': display_name,
    'configuration': config,
    'architecture': 'arm64',
    'marketingVersion': marketing_version,
    'hardenedRuntimeEnabled': hardened == 'YES',
    'codesignVerifyDeepStrictPassed': True,
    'entitlements': entitlements_dict,
    'forbiddenEntitlementsFound': found_forbidden,
    'hardenedRuntimeVerification': json.loads((staging_base / 'hardened-runtime.json').read_text()),
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

echo "[malt-package] Packaged Malt.app ready at: $STAGED_APP"
if [ "$SKIP_DMG" -eq 0 ]; then
    echo "[malt-package] Packaged Malt.dmg ready at: $DMG_PATH"
fi
