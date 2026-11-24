#!/usr/bin/env bash
# Notarizes and staples a .app, .zip or .dmg with notarytool.
#   ./Scripts/notarize.sh dist/Meth.app
#   ./Scripts/notarize.sh dist/Meth-0.1.0.dmg
# Credentials (one of):
#   NOTARY_PROFILE=meth-notary   keychain profile from `xcrun notarytool store-credentials`
#   NOTARY_KEY_PATH + NOTARY_KEY_ID + NOTARY_ISSUER   App Store Connect API key (CI)
source "$(dirname "$0")/common.sh"
require xcrun ditto
TARGET="${1:?usage: notarize.sh <path to .app|.dmg|.zip>}"
[[ -e "$TARGET" ]] || die "$TARGET not found"

if [[ -n "${NOTARY_KEY_PATH:-}" ]]; then
  AUTH=(--key "$NOTARY_KEY_PATH" --key-id "${NOTARY_KEY_ID:?}" --issuer "${NOTARY_ISSUER:?}")
else
  AUTH=(--keychain-profile "${NOTARY_PROFILE:-meth-notary}")
fi

SUBMIT="$TARGET"
if [[ "$TARGET" == *.app ]]; then
  SUBMIT="$BUILD_DIR/notarize-$(basename "$TARGET" .app).zip"
  rm -f "$SUBMIT"
  ditto -c -k --sequesterRsrc --keepParent "$TARGET" "$SUBMIT"
fi

log "Submitting $(basename "$SUBMIT") to Apple notary service (this can take a few minutes)"
OUT="$(xcrun notarytool submit "$SUBMIT" "${AUTH[@]}" --wait --output-format json)" || die "notarytool failed: $OUT"
echo "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("   id:", d.get("id"), "status:", d.get("status"))'
STATUS="$(echo "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))')"
if [[ "$STATUS" != "Accepted" ]]; then
  ID="$(echo "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))')"
  xcrun notarytool log "$ID" "${AUTH[@]}" || true
  die "Notarization status: $STATUS"
fi

if [[ "$TARGET" != *.zip ]]; then
  log "Stapling"
  xcrun stapler staple "$TARGET"
  xcrun stapler validate "$TARGET"
fi

log "Gatekeeper assessment"
case "$TARGET" in
  *.app) spctl --assess --type execute --verbose=2 "$TARGET" ;;
  *.dmg) spctl --assess --type open --context context:primary-signature --verbose=2 "$TARGET" ;;
esac
