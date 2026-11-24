#!/usr/bin/env bash
# Signs dist/Meth.app (or $1) inside-out with a Developer ID Application identity,
# hardened runtime and secure timestamps, then verifies the result.
#   METH_SIGN_IDENTITY  identity name or SHA-1 (default: "Developer ID Application")
source "$(dirname "$0")/common.sh"
require codesign security
APP="${1:-$DIST_DIR/$APP_NAME.app}"
IDENTITY="${METH_SIGN_IDENTITY:-Developer ID Application}"
[[ -d "$APP" ]] || die "$APP not found; run Scripts/build.sh"

security find-identity -v -p codesigning | grep -q "Developer ID Application" \
  || die "No 'Developer ID Application' identity in the keychain. See docs/RELEASE.md#signing."

sign() { codesign --force --options runtime --timestamp --sign "$IDENTITY" "$@"; }

log "Signing Sparkle.framework components"
SPK="$APP/Contents/Frameworks/Sparkle.framework"
sign "$SPK/Versions/B/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$SPK/Versions/B/XPCServices/Downloader.xpc"
sign "$SPK/Versions/B/Autoupdate"
sign "$SPK/Versions/B/Updater.app"
sign "$SPK"

log "Signing Meth executables"
sign --identifier io.github.kroekkarawit.Meth.Agent  "$APP/Contents/MacOS/MethAgent"
sign --identifier io.github.kroekkarawit.Meth.Helper "$APP/Contents/MacOS/MethHelper"
sign --identifier io.github.kroekkarawit.Meth.CLI    "$APP/Contents/Helpers/meth"
sign "$APP"

log "Verifying signatures"
codesign --verify --deep --strict --verbose=2 "$APP"
TEAM="$(codesign -dv "$APP" 2>&1 | awk -F= '/^TeamIdentifier/ {print $2}')"
for bin in MacOS/MethAgent MacOS/MethHelper Helpers/meth; do
  t="$(codesign -dv "$APP/Contents/$bin" 2>&1 | awk -F= '/^TeamIdentifier/ {print $2}')"
  [[ "$t" == "$TEAM" ]] || die "$bin team ($t) differs from app team ($TEAM)"
  info="$(codesign -dv "$APP/Contents/$bin" 2>&1)"
  [[ "$info" == *"(runtime)"* ]] || die "$bin lacks hardened runtime"
done
log "Signed with team $TEAM"
