#!/usr/bin/env bash
# Builds a universal (arm64 + x86_64) Release Meth.app into dist/Meth.app.
# The result is ad-hoc signed; Scripts/sign.sh applies Developer ID signing.
#   ./Scripts/build.sh            # Release
#   ./Scripts/build.sh Debug      # Debug, host architecture only
source "$(dirname "$0")/common.sh"
CONFIG="${1:-Release}"
require xcodebuild
ensure_project

log "Building $APP_NAME $(marketing_version) ($(build_number)) [$CONFIG]"
xcodebuild -project "$PROJECT" -scheme Meth -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" -destination 'generic/platform=macOS' \
  build | tee "$BUILD_DIR/build.log" | grep -E '^(\*\*|error:|warning: )' || true
[[ ${PIPESTATUS[0]} -eq 0 ]] || die "xcodebuild failed; see build/build.log"

APP="$DERIVED/Build/Products/$CONFIG/$APP_NAME.app"
[[ -d "$APP" ]] || die "Build product missing: $APP"

mkdir -p "$DIST_DIR"
rm -rf "$DIST_DIR/$APP_NAME.app"
ditto "$APP" "$DIST_DIR/$APP_NAME.app"

if [[ "$CONFIG" == "Release" ]]; then
  for bin in MacOS/Meth MacOS/MethAgent MacOS/MethHelper Helpers/meth; do
    archs="$(lipo -archs "$DIST_DIR/$APP_NAME.app/Contents/$bin")"
    [[ "$archs" == *arm64* && "$archs" == *x86_64* ]] || die "$bin is not universal ($archs)"
  done
  log "Universal binaries verified (arm64 + x86_64)"
fi
log "Built $DIST_DIR/$APP_NAME.app"
