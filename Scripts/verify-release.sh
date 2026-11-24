#!/usr/bin/env bash
# Verifies the published release: download URLs, checksums, appcast entry and signatures.
source "$(dirname "$0")/common.sh"
VERSION="${1:?version}"; TAG="v$VERSION"
require curl shasum
FEED="https://kroekkarawit.github.io/meth-macos/appcast.xml"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/meth-verify.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

for f in "Meth-$VERSION.dmg" "Meth-$VERSION.zip" checksums.txt; do
  url="https://github.com/$GITHUB_REPO/releases/download/$TAG/$f"
  curl -fsSL --retry 5 --retry-delay 5 -o "$TMP/$f" "$url" || die "Not downloadable: $url"
  log "OK $url"
done
(cd "$TMP" && shasum -a 256 -c checksums.txt) || die "Checksum mismatch"

log "Waiting for appcast to list $VERSION"
for i in $(seq 1 30); do
  if curl -fsSL "$FEED?nocache=$RANDOM" | grep -q "<sparkle:shortVersionString>$VERSION<"; then
    log "OK $FEED lists $VERSION"; break
  fi
  [[ $i -eq 30 ]] && die "Appcast does not list $VERSION yet ($FEED)"
  sleep 10
done
curl -fsSL "$FEED" | grep -q "releases/download/$TAG/Meth-$VERSION.zip" || die "Appcast URL mismatch"

hdiutil attach -nobrowse -readonly -mountpoint "$TMP/mnt" "$TMP/Meth-$VERSION.dmg" >/dev/null
spctl --assess --type execute --verbose=2 "$TMP/mnt/Meth.app" || { hdiutil detach "$TMP/mnt" >/dev/null; die "Gatekeeper rejected the app"; }
hdiutil detach "$TMP/mnt" >/dev/null
spctl --assess --type open --context context:primary-signature --verbose=2 "$TMP/Meth-$VERSION.dmg"
log "Release $VERSION verified"
