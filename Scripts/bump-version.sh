#!/usr/bin/env bash
# Sets MARKETING_VERSION and increments CURRENT_PROJECT_VERSION (monotonic build number).
#   ./Scripts/bump-version.sh 0.2.0
source "$(dirname "$0")/common.sh"
VERSION="${1:?usage: bump-version.sh <semver>}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Not a semantic version: $VERSION"
CURRENT="$(marketing_version)"
BUILD="$(build_number)"
if [[ "$VERSION" == "$CURRENT" ]]; then
  log "Version already $VERSION (build $BUILD)"
  exit 0
fi
# Refuse to go backwards.
[[ "$(printf '%s\n%s\n' "$CURRENT" "$VERSION" | sort -V | tail -1)" == "$VERSION" ]] \
  || die "$VERSION is older than current $CURRENT"
NEW_BUILD=$((BUILD + 1))
cat > "$ROOT/Config/Version.xcconfig" <<XC
// Updated by Scripts/bump-version.sh — do not edit by hand during a release.
MARKETING_VERSION = $VERSION
CURRENT_PROJECT_VERSION = $NEW_BUILD
XC
log "Version $CURRENT ($BUILD) -> $VERSION ($NEW_BUILD)"
