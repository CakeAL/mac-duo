#!/bin/bash
#
# Builds MacDuo.app into ./dist
#
#   ./build.sh            release (default)
#   ./build.sh debug      debug
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${1:-release}"
APP_NAME="MacDuo"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
SCRATCH="$ROOT/.scratch"

cd "$ROOT"
mkdir -p "$SCRATCH"

# Keep every compiler cache inside the project so the build never writes to
# shared user-level caches (and works under a sandbox).
export CLANG_MODULE_CACHE_PATH="$SCRATCH/clang-modules"
export SWIFT_MODULECACHE_PATH="$SCRATCH/swift-modules"

SWIFT_FLAGS=(--scratch-path "$SCRATCH" --disable-sandbox)

echo "==> Regenerating embedded shader source"
python3 Tools/embed-shader.py

echo "==> Compiling ($CONFIG)"
swift build -c "$CONFIG" "${SWIFT_FLAGS[@]}"

BIN_PATH="$(swift build -c "$CONFIG" "${SWIFT_FLAGS[@]}" --show-bin-path)"
BIN="$BIN_PATH/$APP_NAME"
if [[ ! -x "$BIN" ]]; then
  echo "error: built binary not found at $BIN" >&2
  exit 1
fi

# A prebuilt metallib is optional: it only exists when the Xcode Metal toolchain
# is installed, and the renderer falls back to compiling the embedded source.
if xcrun -sdk macosx metal --version >/dev/null 2>&1; then
  echo "==> Compiling shaders (prebuilt metallib)"
  mkdir -p "$SCRATCH/shaders"
  xcrun -sdk macosx metal -O -c "$ROOT/Sources/MacDuoCore/Render/MetalFrost.metal" \
    -o "$SCRATCH/shaders/MetalFrost.air"
  xcrun -sdk macosx metallib "$SCRATCH/shaders/MetalFrost.air" \
    -o "$BIN_PATH/default.metallib"
  PRECOMPILED_METALLIB="$BIN_PATH/default.metallib"
else
  echo "==> Metal toolchain not installed; the app will compile the embedded shader at run time"
  PRECOMPILED_METALLIB=""
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
if [[ -n "$PRECOMPILED_METALLIB" ]]; then
  cp "$PRECOMPILED_METALLIB" "$APP/Contents/Resources/default.metallib"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>zh_CN</string>
	<key>CFBundleExecutable</key>
	<string>MacDuo</string>
	<key>CFBundleIdentifier</key>
	<string>local.macduo.app</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>MacDuo</string>
	<key>CFBundleDisplayName</key>
	<string>MacDuo</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1.1</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSSupportsAutomaticGraphicsSwitching</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string>Local build. Lid-angle technique derived from samhenrigold/LidAngleSensor (MIT).</string>
</dict>
</plist>
PLIST

# Ad-hoc signature. Screen Recording permission is keyed to the signature, so an
# unsigned binary would be re-prompted on every rebuild.
echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - --identifier "local.macduo.app" "$APP"

# Refresh Launch Services so the bundle behaves like a real installed app.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$APP" >/dev/null 2>&1 || true

echo
echo "Done: $APP"
echo "Run it with:  open \"$APP\""
echo
echo "首次运行需要在「系统设置 → 隐私与安全性 → 屏幕录制」里勾选 MacDuo。"
