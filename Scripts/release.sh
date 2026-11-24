#!/usr/bin/env bash
# Produces a signed, notarized, stapled release and (with --publish) ships it.
#
#   ./Scripts/release.sh 0.1.0              # build + sign + notarize + package into dist/
#   ./Scripts/release.sh 0.1.0 --publish    # ...then tag, GitHub Release, appcast on Pages
#
# Needs: Developer ID Application identity, notary credentials (NOTARY_PROFILE or
# NOTARY_KEY_*), Sparkle private key in the keychain (account $SPARKLE_ACCOUNT) or
# SPARKLE_KEY_FILE, and `gh` auth for --publish. See docs/RELEASE.md.
source "$(dirname "$0")/common.sh"
VERSION="${1:?usage: release.sh <semver> [--publish]}"
PUBLISH="${2:-}"
TAG="v$VERSION"
require xcodebuild codesign xcrun shasum python3 git
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Not a semantic version: $VERSION"
grep -qE "^## \[?$VERSION\]?" "$ROOT/CHANGELOG.md" || die "Add a '## [$VERSION]' section to CHANGELOG.md first"

if [[ "$PUBLISH" == "--publish" ]]; then
  require gh
  gh auth status >/dev/null 2>&1 || die "gh is not authenticated"
  [[ -z "$(git -C "$ROOT" status --porcelain -- . ':!Config/Version.xcconfig')" ]] || die "Working tree not clean"
  gh release view "$TAG" -R "$GITHUB_REPO" >/dev/null 2>&1 && die "Release $TAG already exists"
fi

"$ROOT/Scripts/bump-version.sh" "$VERSION"
BUILD="$(build_number)"

rm -rf "$DIST_DIR"; mkdir -p "$DIST_DIR"
"$ROOT/Scripts/build.sh" Release
"$ROOT/Scripts/sign.sh"
"$ROOT/Scripts/notarize.sh" "$DIST_DIR/$APP_NAME.app"
"$ROOT/Scripts/package-dmg.sh" "$VERSION"
"$ROOT/Scripts/notarize.sh" "$DIST_DIR/$APP_NAME-$VERSION.dmg"

DMG="$APP_NAME-$VERSION.dmg"
ZIP="$APP_NAME-$VERSION.zip"
(cd "$DIST_DIR" && shasum -a 256 "$DMG" "$ZIP" > checksums.txt)
log "Checksums:"; cat "$DIST_DIR/checksums.txt"

log "Signing Sparkle update archive (EdDSA)"
SB="$(sparkle_bin)"
if [[ -n "${SPARKLE_KEY_FILE:-}" ]]; then
  SIG_ATTRS="$("$SB/sign_update" --ed-key-file "$SPARKLE_KEY_FILE" "$DIST_DIR/$ZIP")"
else
  SIG_ATTRS="$("$SB/sign_update" --account "$SPARKLE_ACCOUNT" "$DIST_DIR/$ZIP")"
fi
ED_SIG="$(sed -E 's/.*sparkle:edSignature="([^"]+)".*/\1/' <<<"$SIG_ATTRS")"
LENGTH="$(sed -E 's/.*length="([0-9]+)".*/\1/' <<<"$SIG_ATTRS")"
[[ -n "$ED_SIG" && -n "$LENGTH" ]] || die "Could not parse sign_update output: $SIG_ATTRS"

PAGES="$BUILD_DIR/gh-pages"
rm -rf "$PAGES"
if git -C "$ROOT" ls-remote --exit-code origin gh-pages >/dev/null 2>&1; then
  git -C "$ROOT" fetch -q origin gh-pages
  git -C "$ROOT" worktree prune
  git -C "$ROOT" worktree add -f "$PAGES" origin/gh-pages >/dev/null
else
  mkdir -p "$PAGES"
fi
URL="https://github.com/$GITHUB_REPO/releases/download/$TAG/$ZIP"
python3 "$ROOT/Scripts/appcast.py" "$PAGES/appcast.xml" "$VERSION" "$BUILD" "$URL" "$LENGTH" "$ED_SIG" "14.0" "$ROOT/CHANGELOG.md"
cp "$PAGES/appcast.xml" "$DIST_DIR/appcast.xml"
log "Release artifacts:"; ls -lh "$DIST_DIR"

[[ "$PUBLISH" == "--publish" ]] || { log "Dry run complete. Re-run with --publish to ship."; exit 0; }

log "Tagging $TAG"
git -C "$ROOT" add Config/Version.xcconfig
git -C "$ROOT" diff --cached --quiet || git -C "$ROOT" commit -q -m "Release $VERSION"
git -C "$ROOT" tag -a "$TAG" -m "Meth $VERSION"
git -C "$ROOT" push -q origin HEAD "$TAG"

log "Creating GitHub Release"
NOTES="$(python3 - "$ROOT/CHANGELOG.md" "$VERSION" <<'PY'
import re,sys
t=open(sys.argv[1]).read()
m=re.search(rf"^## \[?{re.escape(sys.argv[2])}\]?.*?$(.*?)(?=^## |\Z)",t,re.S|re.M)
print(m.group(1).strip())
PY
)"
gh release create "$TAG" -R "$GITHUB_REPO" --title "Meth $VERSION" --notes "$NOTES" \
  "$DIST_DIR/$DMG" "$DIST_DIR/$ZIP" "$DIST_DIR/checksums.txt"

log "Publishing appcast to GitHub Pages"
"$ROOT/Scripts/publish-appcast.sh" "$PAGES" "$VERSION"

log "Verifying public URLs"
"$ROOT/Scripts/verify-release.sh" "$VERSION"
