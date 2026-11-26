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
BUNDLE_EMBEDDED_RUNTIME=1
EMBEDDED_RUNTIME_SOURCE=""
SIGN_IDENTITY=""
SIGN_IDENTITY_KIND="adhoc"
DRY_RUN=0
SKIP_DMG=0
REQUIRE_DISTRIBUTABLE=0

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
  --app-only                      Explicitly build a minimal app without container tools
  --bundle-embedded-runtime        Embed MaltContainerHelper.app (LSUIElement=true) and RuntimeScripts/; guest and Wine require separate setup
  --embedded-runtime-source <app>  Explicit path to UTM-Custom.app to embed (implies --bundle-embedded-runtime)
  --sign-identity <id>             Explicit codesign identity (default: auto-select valid keychain certificate, otherwise ad-hoc)
  --require-distributable          Require Developer ID, Team ID, secure timestamp and notarization
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
        --app-only)
            BUNDLE_EMBEDDED_RUNTIME=0
            shift
            ;;
        --bundle-embedded-runtime)
            BUNDLE_EMBEDDED_RUNTIME=1
            shift
            ;;
        --embedded-runtime-source)
            EMBEDDED_RUNTIME_SOURCE="$2"
            BUNDLE_EMBEDDED_RUNTIME=1
            shift 2
            ;;
        --sign-identity)
            SIGN_IDENTITY="$2"
            shift 2
            ;;
        --require-distributable)
            REQUIRE_DISTRIBUTABLE=1
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
    printf '[dry-run] configuration=%s hardened_runtime=%s embedded_runtime=%d skip_dmg=%d\n' \
        "$CONFIGURATION" "$HARDENED_RUNTIME_SETTING" "$BUNDLE_EMBEDDED_RUNTIME" "$SKIP_DMG"
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

# Resolve an optional certificate while preserving ad-hoc signing as the fallback.
eval "$(python3 - "$SIGN_IDENTITY" <<'PYSIGN'
import re, shlex, subprocess, sys

explicit = sys.argv[1].strip()
if explicit:
    kind = 'adhoc' if explicit == '-' else 'explicit'
    print(f'SIGN_IDENTITY={shlex.quote(explicit)}')
    print(f'SIGN_IDENTITY_KIND={shlex.quote(kind)}')
    raise SystemExit(0)

proc = subprocess.run(['security', 'find-identity', '-v', '-p', 'codesigning'], capture_output=True, text=True)
identities = []
for line in proc.stdout.splitlines():
    m = re.match(r'^\s*\d+\)\s+([0-9A-F]{40})\s+"([^"]+)"', line)
    if m:
        identities.append((m.group(1), m.group(2)))

selected_id = '-'
selected_kind = 'adhoc'
for prefix, kind in (('Developer ID Application:', 'developer_id'),
                     ('Apple Development:', 'apple_development')):
    match = next((h for h, name in identities if name.startswith(prefix)), None)
    if match:
        selected_id = match
        selected_kind = kind
        break
else:
    if identities:
        selected_id = identities[0][0]
        selected_kind = 'local_certificate'

print(f'SIGN_IDENTITY={shlex.quote(selected_id)}')
print(f'SIGN_IDENTITY_KIND={shlex.quote(selected_kind)}')
PYSIGN
)"
echo "[malt-package] Signing identity mode: $SIGN_IDENTITY_KIND"
SIGN_TIMESTAMP_ARGS=(--timestamp=none)
if [ "$SIGN_IDENTITY" != "-" ]; then
    SIGN_TIMESTAMP_ARGS=(--timestamp)
fi

# Container helper and production management dependencies; --app-only is an explicit opt-out.
EMBEDDED_HELPER_BUNDLED=0
EMBEDDED_SCRIPTS_BUNDLED=0
EMBEDDED_RUNTIME_NOTE="disabled"
EMBEDDED_HELPER_APP="$STAGED_APP/Contents/Helpers/MaltContainerHelper.app"
EMBEDDED_SCRIPTS_DIR="$STAGED_APP/Contents/Resources/RuntimeScripts"

if [ "$BUNDLE_EMBEDDED_RUNTIME" -eq 1 ]; then
    RESOLVED_RUNTIME_SOURCE="$EMBEDDED_RUNTIME_SOURCE"
    if [ -z "$RESOLVED_RUNTIME_SOURCE" ]; then
        for candidate in \
            "${TMPDIR:-/tmp}/utm-custom-build/UTM-Custom.app" \
            "/Applications/UTM-Custom.app" \
            "/Applications/Malt.app/Contents/Helpers/MaltContainerHelper.app"
        do
            if [ -d "$candidate" ] && [ -x "$candidate/Contents/MacOS/UTM" ]; then
                if python3 "$SCRIPT_DIR/runtime_payload.py" check-helper-settings --helper-app "$candidate" >/dev/null 2>&1; then
                    RESOLVED_RUNTIME_SOURCE="$candidate"
                    break
                fi
            fi
        done
    fi

    mkdir -p "$EMBEDDED_SCRIPTS_DIR"
    # Runtime scripts are mandatory and verified by the payload builder below.

    if [ -n "$RESOLVED_RUNTIME_SOURCE" ] && [ -d "$RESOLVED_RUNTIME_SOURCE" ]; then
        # Reject stale helper builds before copying, changing metadata, or signing.
        python3 "$SCRIPT_DIR/runtime_payload.py" check-helper-settings --helper-app "$RESOLVED_RUNTIME_SOURCE"
        echo "[malt-package] Embedding container helper into Malt.app/Contents/Helpers/MaltContainerHelper.app (LSUIElement=true)..."
        mkdir -p "$STAGED_APP/Contents/Helpers"
        rm -rf "$EMBEDDED_HELPER_APP"
        ditto "$RESOLVED_RUNTIME_SOURCE" "$EMBEDDED_HELPER_APP"

        python3 - "$EMBEDDED_HELPER_APP/Contents/Info.plist" <<'PYP'
import pathlib, plistlib, sys
plist_path = pathlib.Path(sys.argv[1])
data = plistlib.loads(plist_path.read_bytes())
data['LSUIElement'] = True
plist_path.write_bytes(plistlib.dumps(data, fmt=plistlib.FMT_XML))
PYP

        # Payload embedding signs all helper code inside-out while preserving entitlements.
        EMBEDDED_HELPER_BUNDLED=1
        EMBEDDED_RUNTIME_NOTE="embedded_helper_and_scripts"
    else
        echo "error: embedded container runtime is required; provide --embedded-runtime-source or explicitly choose --app-only" >&2
        exit 1
    fi
fi

if [ "$BUNDLE_EMBEDDED_RUNTIME" -eq 1 ]; then
    python3 "$SCRIPT_DIR/runtime_payload.py" embed --app "$STAGED_APP" --workspace "$WORKSPACE_ROOT" --sign-identity "$SIGN_IDENTITY"
    EMBEDDED_SCRIPTS_BUNDLED=1
fi

ENTITLEMENTS_FILE="$REPO_DIR/Whisky/Whisky.entitlements"
if [ ! -f "$ENTITLEMENTS_FILE" ]; then
    echo "error: entitlements file missing at $ENTITLEMENTS_FILE" >&2
    exit 1
fi

# Sign remaining application code inside-out. Payload-managed code is already signed
# and its hashes must remain stable. Locked optional drivers retain source signatures.
python3 "$SCRIPT_DIR/runtime_payload.py" sign-nested --app "$STAGED_APP" --sign-identity "$SIGN_IDENTITY"
codesign --force --sign "$SIGN_IDENTITY" --options runtime --entitlements "$ENTITLEMENTS_FILE" "${SIGN_TIMESTAMP_ARGS[@]}" \
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

if [ "$BUNDLE_EMBEDDED_RUNTIME" -eq 1 ]; then
    python3 "$SCRIPT_DIR/runtime_payload.py" verify --app "$STAGED_APP" --output "$STAGING_BASE/runtime-payload-verification.json"
fi

# Require independent Developer ID, Team ID, timestamp and notarization evidence.
# Local ad-hoc packages remain valid testing artifacts and report distribution=false.
if [ "$REQUIRE_DISTRIBUTABLE" -eq 1 ]; then
    python3 "$SCRIPT_DIR/runtime_payload.py" assess-distribution --app "$STAGED_APP" \
        --output "$STAGING_BASE/distribution-assessment.json" --require-distributable
else
    python3 "$SCRIPT_DIR/runtime_payload.py" assess-distribution --app "$STAGED_APP" \
        --output "$STAGING_BASE/distribution-assessment.json"
fi

# Reject stale updater dependencies and require four seconds of healthy process survival.
python3 "$SCRIPT_DIR/package_launch_gate.py" \
    --app "$STAGED_APP" \
    --executable-name "$EXECUTABLE_NAME" \
    --output "$STAGING_BASE/launch-smoke.json" --isolated-user-data
LAUNCH_SMOKE_PASSED=1
echo "[package] Launch dyld smoke test (4s survival): passed"

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
    "$STAGING_BASE" "$BUNDLE_EMBEDDED_RUNTIME" "$EMBEDDED_HELPER_BUNDLED" "$EMBEDDED_SCRIPTS_BUNDLED" \
    "$EMBEDDED_RUNTIME_NOTE" "$SIGN_IDENTITY_KIND" "$LAUNCH_SMOKE_PASSED" <<'PY'
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
embedded_requested = int(sys.argv[12]) == 1
embedded_helper_bundled = int(sys.argv[13]) == 1
embedded_scripts_bundled = int(sys.argv[14]) == 1
embedded_runtime_note = sys.argv[15]
sign_identity_kind = sys.argv[16]
launch_smoke_passed = int(sys.argv[17]) == 1

def artifact_manifest_location(path: pathlib.Path, workspace: pathlib.Path) -> dict:
    """Keep artifact locations accurate without disclosing external absolute paths."""
    try:
        relative = path.resolve().relative_to(workspace.resolve())
    except ValueError:
        return {'relativePath': path.name, 'pathScope': 'filename-only'}
    return {'relativePath': relative.as_posix(), 'pathScope': 'workspace-relative'}

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
allowed_embedded_scripts = {
    'contents/resources/runtimescripts/golden_guest_manager.py',
    'contents/resources/runtimescripts/kiosk-app-shell.ps1',
}
leaked = []
for entry in app.rglob('*'):
    rel_lower = str(entry.relative_to(app)).lower()
    if embedded_requested and (
        rel_lower.startswith('contents/helpers/maltcontainerhelper.app')
        or rel_lower == 'contents/helpers/malt-net-proxy'
        or rel_lower in allowed_embedded_scripts
        or rel_lower.startswith('contents/frameworks/python.framework/')
        or rel_lower.startswith('contents/resources/runtimescripts/')
    ):
        continue
    if any(tok in rel_lower for tok in forbidden_tokens) or entry.suffix.lower() in {'.swift', '.pcm', '.o', '.py', '.cpp', '.c'}:
        leaked.append(rel_lower)
if leaked:
    raise SystemExit(f'error: forbidden development/source files leaked into .app bundle: {leaked[:5]}')

embedded_info = {
    'requested': embedded_requested,
    'helperBundled': embedded_helper_bundled,
    'scriptsBundled': embedded_scripts_bundled,
    'note': embedded_runtime_note,
    'lsuiElementEnabled': False,
    'helperBinarySHA256': None,
    'userNetProxyBundled': False,
    'userNetProxySHA256': None,
    'userNetProxySelfCheck': None,
    'bundledScripts': [],
}
if embedded_helper_bundled:
    helper_plist = plistlib.loads((app / 'Contents/Helpers/MaltContainerHelper.app/Contents/Info.plist').read_bytes())
    if helper_plist.get('LSUIElement') is not True:
        raise SystemExit('error: embedded MaltContainerHelper.app must have LSUIElement=true')
    embedded_info['lsuiElementEnabled'] = True
    helper_bin = app / 'Contents/Helpers/MaltContainerHelper.app/Contents/MacOS/UTM'
    if not helper_bin.is_file():
        raise SystemExit('error: embedded MaltContainerHelper binary missing')
    embedded_info['helperBinarySHA256'] = sha256_file(helper_bin)
proxy_bin = app / 'Contents/Helpers/malt-net-proxy'
if embedded_requested and proxy_bin.is_file():
    embedded_info['userNetProxyBundled'] = True
    embedded_info['userNetProxySHA256'] = sha256_file(proxy_bin)
    proxy_check = subprocess.run([str(proxy_bin), '--self-check'], capture_output=True, text=True, timeout=15)
    if proxy_check.returncode != 0:
        raise SystemExit('error: embedded malt-net-proxy --self-check failed')
    embedded_info['userNetProxySelfCheck'] = json.loads(proxy_check.stdout.strip())
if embedded_scripts_bundled:
    scripts_dir = app / 'Contents/Resources/RuntimeScripts'
    embedded_info['bundledScripts'] = sorted(p.name for p in scripts_dir.iterdir() if p.is_file())

dmg_info = None
if skip_dmg == 0:
    if not dmg_path.is_file() or dmg_path.stat().st_size == 0:
        raise SystemExit('error: Malt.dmg missing or empty')
    size_bytes = dmg_path.stat().st_size
    size_mib = round(size_bytes / (1024 * 1024), 3)
    max_mib = 2048 if embedded_helper_bundled else 20
    if size_bytes >= max_mib * 1024 * 1024:
        raise SystemExit(f'error: Malt.dmg exceeds {max_mib} MiB target ({size_mib} MiB)')
    dmg_info = {
        'filename': dmg_path.name,
        **artifact_manifest_location(dmg_path, repo.parent),
        'sizeBytes': size_bytes,
        'sizeMiB': size_mib,
        'sha256': sha256_file(dmg_path),
        'applicationsSymlinkPresent': (app.parent / 'Applications').is_symlink(),
        'readOnlyCompressedUDZO': True,
    }

report = {
    'schema': 'phase-15b-malt-embedded-dmg-v1' if embedded_requested else 'phase-14b-malt-release-dmg-v1',
    'owner': '@DNPMBHC',
    'capturedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'brand': 'Malt',
    'cfBundleDisplayName': display_name,
    'configuration': config,
    'architecture': 'arm64',
    'marketingVersion': marketing_version,
    'hardenedRuntimeEnabled': hardened == 'YES',
    'codesignIdentityKind': sign_identity_kind,
    'codesignVerifyDeepStrictPassed': True,
    'launchSmokeTestPassed': launch_smoke_passed,
    'launchSmokeVerification': json.loads((staging_base / 'launch-smoke.json').read_text()),
    'entitlements': entitlements_dict,
    'forbiddenEntitlementsFound': found_forbidden,
    'hardenedRuntimeVerification': json.loads((staging_base / 'hardened-runtime.json').read_text()),
    'bundlePurityPassed': True,
    'requiredResourcesVerified': True,
    'embeddedRuntime': embedded_info,
    'runtimePayload': json.loads((staging_base / 'runtime-payload-verification.json').read_text()) if embedded_requested else None,
    'externalSetupRequired': True,
    'gameLaunchVerified': False,
    'distributionAssessment': json.loads((staging_base / 'distribution-assessment.json').read_text()),
    'cleanMachineGameLaunchVerified': False,
    'distributionReady': json.loads((staging_base / 'distribution-assessment.json').read_text())['distributable'],
    'notarizationVerified': json.loads((staging_base / 'distribution-assessment.json').read_text())['notarizationVerified'],
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
