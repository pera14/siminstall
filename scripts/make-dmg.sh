#!/bin/bash
# Packages build/SimInstall.app into a styled build/SimInstall-<version>.dmg
# Uses create-dmg (brew install create-dmg) for the custom window; falls back to a plain DMG.
# Optional notarization: set APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD (and sign with SIGN_IDENTITY).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-${VERSION:-0.0.0-dev}}"; VERSION="${VERSION#v}"
APP="build/SimInstall.app"
DMG="build/SimInstall-$VERSION.dmg"
[ -d "$APP" ] || { echo "Run scripts/build-app.sh first"; exit 1; }

STAGE="build/dmg"
rm -rf "$STAGE" "$DMG"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"

if command -v create-dmg >/dev/null; then
  echo "→ Styled DMG (create-dmg)"
  # Retina-aware background: combine @1x and @2x into one TIFF
  tiffutil -cathidpicheck assets/dmg-background.png assets/dmg-background@2x.png \
    -out build/dmg-background.tiff >/dev/null
  create-dmg \
    --volname "SimInstall" \
    --volicon "$APP/Contents/Resources/AppIcon.icns" \
    --background build/dmg-background.tiff \
    --window-pos 200 120 \
    --window-size 660 400 \
    --icon-size 128 \
    --text-size 13 \
    --icon "SimInstall.app" 170 190 \
    --hide-extension "SimInstall.app" \
    --app-drop-link 490 190 \
    "$DMG" "$STAGE"
else
  echo "→ Plain DMG (install create-dmg for the styled window)"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "SimInstall" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
fi
rm -rf "$STAGE" build/dmg-background.tiff

if [ -n "${SIGN_IDENTITY:-}" ]; then
  codesign --force --timestamp -s "$SIGN_IDENTITY" "$DMG"
fi

if [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ] && [ -n "${APPLE_APP_PASSWORD:-}" ]; then
  echo "→ Notarizing"
  xcrun notarytool submit "$DMG" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_PASSWORD" --wait
  xcrun stapler staple "$DMG"
fi

shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "✓ $DMG"
