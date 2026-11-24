#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${SCRIPT_DIR}/build/GraphicsLabHost.app"
BIN_SRC="${SCRIPT_DIR}/build/metal_host"

"${SCRIPT_DIR}/restart_metal_host.sh" --build-only >/dev/null

rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"
cp "${BIN_SRC}" "${APP_DIR}/Contents/MacOS/GraphicsLabHost"

cat > "${APP_DIR}/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>GraphicsLabHost</string>
  <key>CFBundleIdentifier</key>
  <string>local.graphicslab.gamemode-probe</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>GraphicsLabHost</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.games</string>
  <key>LSSupportsGameMode</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
EOF

codesign --force --sign - "${APP_DIR}" 2>/dev/null || true

PLIST_SHA="$(shasum -a 256 "${APP_DIR}/Contents/Info.plist" | awk '{print $1}')"
EXEC_SHA="$(shasum -a 256 "${APP_DIR}/Contents/MacOS/GraphicsLabHost" | awk '{print $1}')"

cat <<EOF
app_bundle=build/GraphicsLabHost.app
info_plist_sha256=${PLIST_SHA}
executable_sha256=${EXEC_SHA}
EOF
