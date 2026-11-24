#!/usr/bin/env bash
# Packages dist/Meth.app into dist/Meth-<version>.dmg (drag-to-Applications layout)
# and dist/Meth-<version>.zip (the Sparkle update archive).
# Uses dmgbuild, which writes the Finder layout directly (no Finder automation needed).
source "$(dirname "$0")/common.sh"
require hdiutil ditto python3
VERSION="${1:-$(marketing_version)}"
APP="$DIST_DIR/$APP_NAME.app"
DMG="$DIST_DIR/$APP_NAME-$VERSION.dmg"
ZIP="$DIST_DIR/$APP_NAME-$VERSION.zip"
[[ -d "$APP" ]] || die "$APP not found"

VENV="$BUILD_DIR/venv"
if [[ ! -x "$VENV/bin/dmgbuild" ]]; then
  log "Installing dmgbuild into $VENV"
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet 'dmgbuild==1.6.5'
fi

log "Creating $ZIP"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

log "Creating $DMG"
rm -f "$DMG"
"$VENV/bin/dmgbuild" -s "$ROOT/Scripts/dmg/settings.py" \
  -D app="$APP" -D background="$ROOT/Scripts/dmg/background.png" \
  "$APP_NAME" "$DMG"

if [[ -n "${METH_SIGN_IDENTITY:-}" ]] || security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  log "Signing DMG"
  codesign --force --timestamp --sign "${METH_SIGN_IDENTITY:-Developer ID Application}" "$DMG"
fi
hdiutil verify "$DMG" >/dev/null && log "DMG verified"
