#!/bin/bash
# Builds a universal (arm64 + x86_64) SimInstall.app into ./build
# Usage: scripts/build-app.sh [version]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-${VERSION:-0.0.0-dev}}"
VERSION="${VERSION#v}"
APP="build/SimInstall.app"
MIN_OS="14.0"
BUNDLE_ID="${BUNDLE_ID:-io.github.siminstall}"

rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/tmp

echo "→ Compiling arm64 + x86_64"
for arch in arm64 x86_64; do
  swiftc -O -parse-as-library -target "$arch-apple-macos$MIN_OS" \
    Sources/SimInstall.swift -o "build/tmp/SimInstall-$arch"
done
lipo -create build/tmp/SimInstall-arm64 build/tmp/SimInstall-x86_64 -output "$APP/Contents/MacOS/SimInstall"

echo "→ Info.plist ($VERSION)"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>SimInstall</string>
  <key>CFBundleDisplayName</key><string>SimInstall</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>SimInstall</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_OS</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Simulator Build</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>public.item</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

echo "→ Icon"
SET="build/tmp/AppIcon.iconset"; mkdir -p "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s assets/icon.png --out "$SET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) assets/icon.png --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "→ Signing"
if [ -n "${SIGN_IDENTITY:-}" ]; then
  codesign --force --options runtime --timestamp -s "$SIGN_IDENTITY" "$APP"
else
  codesign --force -s - "$APP"   # ad-hoc
fi

rm -rf build/tmp
echo "✓ $APP"
