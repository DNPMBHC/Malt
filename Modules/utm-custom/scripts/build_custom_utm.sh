#!/usr/bin/env bash
set -euo pipefail

# Custom UTM v5.0.9 + CocoaSpice patch verification and out-of-repo macOS arm64 builder.
# Owner: @DNPMBHC
# Strictly keeps external source trees and build artifacts outside this repository,
# and never modifies /Applications/UTM.app.

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
MODULE_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
REPO_ROOT=$(CDPATH= cd -- "$MODULE_DIR/../../.." && pwd)
PATCHES_DIR="$MODULE_DIR/patches"
WORK_ROOT="${TMPDIR:-/tmp}/utm-custom-src"
BUILD_ROOT="${TMPDIR:-/tmp}/utm-custom-build"
OUTPUT_APP="$BUILD_ROOT/UTM-Custom.app"
BASE_UTM_APP="/Applications/UTM.app"
CHECK_ONLY=1

usage() {
    cat <<'EOF'
Usage: build_custom_utm.sh [options]

Validate and apply the minimal UTM v5.0.9 / CocoaSpice patch set in an external
temporary directory (never inside the Whisky repository), and optionally build
a runnable, ad-hoc signed UTM-Custom.app out of repo.

Options:
  --work-root <dir>   External directory for utmapp/UTM & CocoaSpice clones (default: $TMPDIR/utm-custom-src)
  --build-root <dir>  External directory for DerivedData & UTM-Custom.app (default: $TMPDIR/utm-custom-build)
  --output-app <path> Output .app path outside repo (default: <build-root>/UTM-Custom.app)
  --build             Build and ad-hoc sign UTM-Custom.app out of repo (Path A)
  --check-only        Run compliance audit and standalone+stacked git apply --check only (default)
  -h, --help          Show this help message
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --work-root)
            WORK_ROOT="$2"
            shift 2
            ;;
        --build-root)
            BUILD_ROOT="$2"
            OUTPUT_APP="$BUILD_ROOT/UTM-Custom.app"
            shift 2
            ;;
        --output-app)
            OUTPUT_APP="$2"
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

# Ensure external directories are strictly outside REPO_ROOT and never /Applications/UTM.app.
python3 - "$REPO_ROOT" "$WORK_ROOT" "$BUILD_ROOT" "$OUTPUT_APP" "$BASE_UTM_APP" <<'PY'
import pathlib, sys
repo = pathlib.Path(sys.argv[1]).resolve()
base_utm = pathlib.Path(sys.argv[5]).resolve()
for raw in sys.argv[2:5]:
    target = pathlib.Path(raw).resolve()
    try:
        target.relative_to(repo)
        raise SystemExit(f"error: path '{target}' must be outside the repository")
    except ValueError:
        pass
    if target == base_utm:
        raise SystemExit("error: refusing to overwrite /Applications/UTM.app")
PY

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

# Reset external clones cleanly back to upstream base before applying/checking.
git -C "$UTM_DIR" reset --hard v5.0.9 >/dev/null 2>&1 || git -C "$UTM_DIR" reset --hard HEAD >/dev/null
git -C "$UTM_DIR" clean -fd -e sysroot-macOS-arm64 >/dev/null 2>&1 || true
SPICE_BASE_REV="e239fab0828ebafc3a5a973fa84039400d7ac703"
if git -C "$SPICE_DIR" cat-file -e "${SPICE_BASE_REV}^{commit}" 2>/dev/null; then
    git -C "$SPICE_DIR" checkout -B main "$SPICE_BASE_REV" >/dev/null 2>&1 || git -C "$SPICE_DIR" reset --hard "$SPICE_BASE_REV" >/dev/null
else
    git -C "$SPICE_DIR" reset --hard HEAD >/dev/null
fi
git -C "$SPICE_DIR" clean -fd >/dev/null 2>&1 || true

UTM_PATCHES=(
    "$PATCHES_DIR/01-default-dxmt-backend.patch"
    "$PATCHES_DIR/02-cursor-and-fps-capture.patch"
    "$PATCHES_DIR/03-clean-fullscreen-game-shell.patch"
    "$PATCHES_DIR/04-pure-relative-mouse-option.patch"
    "$PATCHES_DIR/05-render-thread-qos-and-dxmt-cache.patch"
    "$PATCHES_DIR/06-high-polling-mouse-coalescing.patch"
    "$PATCHES_DIR/07-game-shell-key-guard-and-mapping.patch"
)
SPICE_PATCHES=(
    "$PATCHES_DIR/02-cocoaspice-cursor-overlay.patch"
    "$PATCHES_DIR/05-cocoaspice-frame-backpressure.patch"
)

python3 -B "$REPO_ROOT/graphics-lab/utm_custom_patch_verify.py" \
    --patches-dir "$PATCHES_DIR" \
    --utm-repo "$UTM_DIR" \
    --cocoaspice-repo "$SPICE_DIR" >/dev/null

echo "[utm-custom] Compliance + standalone/stacked git apply --check passed (7 UTM + 2 CocoaSpice patches)."

if [ "$CHECK_ONLY" -eq 1 ]; then
    echo "[utm-custom] Check-only completed successfully."
    exit 0
fi

if [ ! -d "$BASE_UTM_APP/Contents/Frameworks" ]; then
    echo "error: $BASE_UTM_APP is required as read-only source of prebuilt QEMU/Spice/DXMT frameworks." >&2
    exit 3
fi

export PATH="/opt/homebrew/bin:$PATH"

echo "[utm-custom] Applying CocoaSpice patches in external clone..."
git -C "$SPICE_DIR" apply "${SPICE_PATCHES[@]}"
if ! xcrun metal --version >/dev/null 2>&1; then
    PREBUILT_METALLIB="$BASE_UTM_APP/Contents/Resources/CocoaSpice_CocoaSpiceRenderer.bundle/Contents/Resources/default.metallib"
    if [ -f "$PREBUILT_METALLIB" ]; then
        echo "[utm-custom] Host Metal Toolchain unavailable; reusing unmodified official default.metallib for unchanged CSShaders.metal..."
        cp "$PREBUILT_METALLIB" "$SPICE_DIR/Sources/CocoaSpiceRenderer/default.metallib"
        python3 - "$SPICE_DIR/Package.swift" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
text = p.read_text(encoding="utf-8")
old = '            resources: [\n                .process("CSShaders.metal")]),'
new = '            exclude: ["CSShaders.metal"],\n            resources: [\n                .copy("default.metallib")]),'
assert old in text, "Expected CSShaders.metal resource entry not found in Package.swift"
p.write_text(text.replace(old, new, 1), encoding="utf-8")
PY
    fi
fi
git -C "$SPICE_DIR" add -A
git -C "$SPICE_DIR" -c user.name="utm-custom-builder" -c user.email="utm-custom@local" \
    commit -m "Apply Phase 11B CocoaSpice cursor overlay & backpressure patches" >/dev/null
SPICE_CUSTOM_REV=$(git -C "$SPICE_DIR" rev-parse HEAD)
echo "[utm-custom] Patched CocoaSpice revision: $SPICE_CUSTOM_REV"

echo "[utm-custom] Applying UTM v5.0.9 patches in external clone..."
git -C "$UTM_DIR" apply "${UTM_PATCHES[@]}"

# Ensure GStreamer 1.19.1 static plugins matching UTM 5.0.9 ABI exist in $WORK_ROOT/gst-prefix
GST_PREFIX="$WORK_ROOT/gst-prefix"
if [ ! -f "$GST_PREFIX/lib/gstreamer-1.0/libgstosxaudio.a" ] || [ ! -f "$GST_PREFIX/lib/gstreamer-1.0/libgstcoreelements.a" ]; then
    echo "[utm-custom] Building GStreamer 1.19.1 static plugins in $WORK_ROOT/gst-build ..."
    GST_WORK="$WORK_ROOT/gst-build"
    mkdir -p "$GST_WORK" "$GST_PREFIX"
    (
        cd "$GST_WORK"
        [ -f gstreamer-1.19.1.tar.xz ] || curl -fsSLO https://gstreamer.freedesktop.org/src/gstreamer/gstreamer-1.19.1.tar.xz
        [ -f gst-plugins-base-1.19.1.tar.xz ] || curl -fsSLO https://gstreamer.freedesktop.org/src/gst-plugins-base/gst-plugins-base-1.19.1.tar.xz
        [ -f gst-plugins-good-1.19.1.tar.xz ] || curl -fsSLO https://gstreamer.freedesktop.org/src/gst-plugins-good/gst-plugins-good-1.19.1.tar.xz
        rm -rf gstreamer-1.19.1 gst-plugins-base-1.19.1 gst-plugins-good-1.19.1
        tar -xf gstreamer-1.19.1.tar.xz
        tar -xf gst-plugins-base-1.19.1.tar.xz
        tar -xf gst-plugins-good-1.19.1.tar.xz
        patch -d gst-plugins-base-1.19.1 -p1 < "$UTM_DIR/patches/gst-plugins-base-1.19.1.patch"
        patch -d gst-plugins-good-1.19.1 -p1 < "$UTM_DIR/patches/gst-plugins-good-1.19.1.patch"
        export PKG_CONFIG_PATH="$GST_PREFIX/lib/pkgconfig:/opt/homebrew/lib/pkgconfig:/opt/homebrew/share/pkgconfig"
        export CFLAGS="-arch arm64 -mmacosx-version-min=12.0 -O2"
        export OBJCFLAGS="-arch arm64 -mmacosx-version-min=12.0 -O2"
        export LDFLAGS="-arch arm64 -mmacosx-version-min=12.0"
        meson setup gstreamer-1.19.1/build gstreamer-1.19.1 --prefix="$GST_PREFIX" --buildtype=release \
            -Ddefault_library=both -Dtests=disabled -Dexamples=disabled -Dbenchmarks=disabled \
            -Dintrospection=disabled -Dnls=disabled -Dtools=disabled -Dregistry=false \
            -Dbash-completion=disabled -Ddoc=disabled -Dgst_parse=false
        ninja -C gstreamer-1.19.1/build install
        meson setup gst-plugins-base-1.19.1/build gst-plugins-base-1.19.1 --prefix="$GST_PREFIX" --buildtype=release \
            -Ddefault_library=both -Dtests=disabled -Dexamples=disabled -Dintrospection=disabled \
            -Dnls=disabled -Dtools=disabled -Ddoc=disabled -Dgl=disabled -Dauto_features=disabled \
            -Dadder=enabled -Dapp=enabled -Daudioconvert=enabled -Daudiorate=enabled \
            -Daudioresample=enabled -Daudiotestsrc=enabled -Dgio=enabled -Dplayback=enabled \
            -Dtypefind=enabled -Dvideoconvert=enabled -Dvideorate=enabled -Dvideoscale=enabled \
            -Dvideotestsrc=enabled -Dvolume=enabled
        ninja -C gst-plugins-base-1.19.1/build install
        meson setup gst-plugins-good-1.19.1/build gst-plugins-good-1.19.1 --prefix="$GST_PREFIX" --buildtype=release \
            -Ddefault_library=both -Dtests=disabled -Dexamples=disabled -Dnls=disabled -Ddoc=disabled \
            -Dauto_features=disabled -Dautodetect=enabled -Djpeg=enabled -Dosxaudio=enabled -Dvideofilter=enabled
        ninja -C gst-plugins-good-1.19.1/build install
    )
fi

# Ensure pure C headers from Homebrew bottles (without installing/modifying host brew packages)
BOTTLE_EXTRACT="$WORK_ROOT/bottle-extract"
if [ ! -d "$BOTTLE_EXTRACT/spice-gtk" ] || [ ! -d "$BOTTLE_EXTRACT/spice-protocol" ] || [ ! -d "$BOTTLE_EXTRACT/libusb" ]; then
    echo "[utm-custom] Fetching header-only Homebrew bottles into $BOTTLE_EXTRACT ..."
    HOMEBREW_NO_AUTO_UPDATE=1 /opt/homebrew/bin/brew fetch --force libusb spice-protocol spice-gtk >/dev/null
    mkdir -p "$BOTTLE_EXTRACT"
    for pkg in libusb spice-protocol spice-gtk; do
        tarball=$(/opt/homebrew/bin/brew --cache "$pkg")
        tar -xzf "$tarball" -C "$BOTTLE_EXTRACT"
    done
fi

echo "[utm-custom] Assembling sysroot-macOS-arm64 (read-only symlinks to /Applications/UTM.app frameworks)..."
SYSROOT="$UTM_DIR/sysroot-macOS-arm64"
rm -rf "$SYSROOT"
mkdir -p "$SYSROOT/include" "$SYSROOT/lib/glib-2.0" "$SYSROOT/lib/gstreamer-1.0" "$SYSROOT/share" "$SYSROOT/libexec"

ln -s "$BASE_UTM_APP/Contents/Frameworks" "$SYSROOT/Frameworks"
ln -s "$BASE_UTM_APP/Contents/Resources/qemu" "$SYSROOT/share/qemu"
ln -s "$BASE_UTM_APP/Contents/Resources/vulkan" "$SYSROOT/share/vulkan"
cp "$BASE_UTM_APP/Contents/XPCServices/QEMUHelper.xpc/Contents/MacOS/QEMURenderServer.app/Contents/MacOS/QEMURenderServer" "$SYSROOT/libexec/virgl_render_server"
chmod u+w "$SYSROOT/libexec/virgl_render_server"
install_name_tool -delete_rpath "@executable_path/../../../../../../../Frameworks" "$SYSROOT/libexec/virgl_render_server" >/dev/null 2>&1 || true

ln -s "/opt/homebrew/include/glib-2.0" "$SYSROOT/include/glib-2.0"
ln -s "/opt/homebrew/lib/glib-2.0/include" "$SYSROOT/lib/glib-2.0/include"
ln -s "$GST_PREFIX/include/gstreamer-1.0" "$SYSROOT/include/gstreamer-1.0"
if [ -d "/opt/homebrew/opt/openssl@3/include/openssl" ]; then
    ln -s "/opt/homebrew/opt/openssl@3/include/openssl" "$SYSROOT/include/openssl"
elif [ -d "/opt/homebrew/opt/openssl/include/openssl" ]; then
    ln -s "/opt/homebrew/opt/openssl/include/openssl" "$SYSROOT/include/openssl"
fi
cp -R "$BOTTLE_EXTRACT"/libusb/*/include/libusb-1.0 "$SYSROOT/include/libusb-1.0"
cp -R "$BOTTLE_EXTRACT"/spice-protocol/*/include/spice-1 "$SYSROOT/include/spice-1"
cp -R "$BOTTLE_EXTRACT"/spice-gtk/*/include/spice-client-glib-2.0 "$SYSROOT/include/spice-client-glib-2.0"
cp "$GST_PREFIX"/lib/gstreamer-1.0/*.a "$SYSROOT/lib/gstreamer-1.0/"

# Add UTM's spice-gtk-0.42 header declaration for spice_util_set_main_context (already exported by UTM's framework).
python3 - "$SYSROOT/include/spice-client-glib-2.0/spice-util.h" <<'PY'
import pathlib, sys
hdr = pathlib.Path(sys.argv[1])
text = hdr.read_text(encoding="utf-8")
decl = "void spice_util_set_main_context(GMainContext *context);"
if decl not in text:
    anchor = "G_END_DECLS"
    assert anchor in text, "G_END_DECLS not found in spice-util.h"
    text = text.replace(anchor, f"{decl}\n\n{anchor}", 1)
    hdr.write_text(text, encoding="utf-8")
PY

echo "[utm-custom] Redirecting UTM.xcodeproj CocoaSpice SPM reference to local patched clone..."
python3 - "$UTM_DIR/UTM.xcodeproj/project.pbxproj" \
    "$UTM_DIR/UTM.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" \
    "file://$SPICE_DIR" "$SPICE_CUSTOM_REV" <<'PY'
import json, pathlib, sys
pbx_path = pathlib.Path(sys.argv[1])
resolved_path = pathlib.Path(sys.argv[2])
local_url = sys.argv[3]
local_rev = sys.argv[4]

pbx = pbx_path.read_text(encoding="utf-8")
old_url = "https://github.com/utmapp/CocoaSpice.git"
if old_url not in pbx:
    raise SystemExit("CocoaSpice.git reference not found in project.pbxproj")
pbx_path.write_text(pbx.replace(old_url, local_url), encoding="utf-8")

resolved = json.loads(resolved_path.read_text(encoding="utf-8"))
for pin in resolved.get("pins", []):
    if pin.get("identity") == "cocoaspice":
        pin["location"] = local_url
        pin["state"] = {"branch": "main", "revision": local_rev}
resolved_path.write_text(json.dumps(resolved, indent=2) + "\n", encoding="utf-8")
PY

mkdir -p "$BUILD_ROOT"
echo "[utm-custom] Running xcodebuild (macOS Release arm64)..."
xcodebuild \
    -project "$UTM_DIR/UTM.xcodeproj" \
    -scheme macOS \
    -configuration Release \
    -destination "platform=macOS,arch=arm64" \
    ARCHS=arm64 \
    -derivedDataPath "$BUILD_ROOT/DerivedData" \
    -skipPackagePluginValidation \
    CODE_SIGNING_ALLOWED=NO \
    build

BUILT_APP="$BUILD_ROOT/DerivedData/Build/Products/Release/UTM.app"
if [ ! -d "$BUILT_APP" ]; then
    echo "error: expected built app not found at $BUILT_APP" >&2
    exit 4
fi

echo "[utm-custom] Copying and ad-hoc signing $OUTPUT_APP (official unsigned entitlement flow)..."
rm -rf "$OUTPUT_APP"
cp -a "$BUILT_APP" "$OUTPUT_APP"

ENT_DIR="$BUILD_ROOT/entitlements"
rm -rf "$ENT_DIR" && mkdir -p "$ENT_DIR"
cp "$UTM_DIR/Platform/macOS/macOS-unsigned.entitlements" "$ENT_DIR/utm.entitlements"
cp "$UTM_DIR/QEMULauncher/QEMULauncher-unsigned.entitlements" "$ENT_DIR/launcher.entitlements"
cp "$UTM_DIR/QEMURenderServer/QEMURenderServer-unsigned.entitlements" "$ENT_DIR/renderer.entitlements"
cp "$UTM_DIR/QEMUHelper/QEMUHelper-unsigned.entitlements" "$ENT_DIR/helper.entitlements"
cp "$UTM_DIR/utmctl/utmctl-unsigned.entitlements" "$ENT_DIR/cli.entitlements"

APP_GROUP=$(/usr/libexec/PlistBuddy -c "Print :AppGroupIdentifier" "$OUTPUT_APP/Contents/Info.plist")
APP_GROUP="${APP_GROUP#invalid.}"
/usr/libexec/PlistBuddy -c "Set :com.apple.security.application-groups:0 ${APP_GROUP}" "$ENT_DIR/utm.entitlements"
/usr/libexec/PlistBuddy -c "Set :com.apple.security.application-groups:0 ${APP_GROUP}" "$ENT_DIR/helper.entitlements"
sed -i '' "s/\$(PRODUCT_BUNDLE_PREFIX:default=com.utmapp)/com.utmapp/g" "$ENT_DIR/cli.entitlements"

find "$OUTPUT_APP/Contents/Frameworks" -maxdepth 1 -type d -name '*.framework' -exec codesign --force --sign - --timestamp=none {} \;
codesign --force --sign - --entitlements "$ENT_DIR/launcher.entitlements" --timestamp=none --options runtime \
    "$OUTPUT_APP/Contents/XPCServices/QEMUHelper.xpc/Contents/MacOS/QEMULauncher.app/Contents/MacOS/QEMULauncher"
codesign --force --sign - --entitlements "$ENT_DIR/renderer.entitlements" --timestamp=none --options runtime \
    "$OUTPUT_APP/Contents/XPCServices/QEMUHelper.xpc/Contents/MacOS/QEMURenderServer.app/Contents/MacOS/QEMURenderServer"
codesign --force --sign - --entitlements "$ENT_DIR/helper.entitlements" --timestamp=none --options runtime \
    "$OUTPUT_APP/Contents/XPCServices/QEMUHelper.xpc/Contents/MacOS/QEMUHelper"
codesign --force --sign - --entitlements "$ENT_DIR/cli.entitlements" --timestamp=none --options runtime \
    "$OUTPUT_APP/Contents/MacOS/utmctl"
codesign --force --sign - --entitlements "$ENT_DIR/utm.entitlements" --timestamp=none --options runtime \
    "$OUTPUT_APP/Contents/MacOS/UTM"

echo "[utm-custom] Verifying code signature, Game Mode Info.plist keys, and patch markers..."
codesign --verify --deep --strict "$OUTPUT_APP"
APP_CATEGORY=$(/usr/libexec/PlistBuddy -c "Print :LSApplicationCategoryType" "$OUTPUT_APP/Contents/Info.plist")
LS_GAME_MODE=$(/usr/libexec/PlistBuddy -c "Print :LSSupportsGameMode" "$OUTPUT_APP/Contents/Info.plist")
GC_GAME_MODE=$(/usr/libexec/PlistBuddy -c "Print :GCSupportsGameMode" "$OUTPUT_APP/Contents/Info.plist")
if [ "$APP_CATEGORY" != "public.app-category.games" ] || [ "$LS_GAME_MODE" != "true" ] || [ "$GC_GAME_MODE" != "true" ]; then
    echo "error: Game Mode Info.plist validation failed (category=$APP_CATEGORY, LS=$LS_GAME_MODE, GC=$GC_GAME_MODE)" >&2
    exit 5
fi
echo "[utm-custom] Build succeeded: $OUTPUT_APP (Game Mode verified)"
