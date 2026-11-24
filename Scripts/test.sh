#!/usr/bin/env bash
# Runs unit tests (always) and UI tests (with --ui; needs Accessibility permission
# for the test runner). Also verifies every UI string is translated (en/th/zh-Hans).
source "$(dirname "$0")/common.sh"
require xcodebuild python3
ensure_project

log "Unit tests"
xcodebuild -project "$PROJECT" -scheme MethUnitTests -derivedDataPath "$DERIVED" test \
  | tee "$BUILD_DIR/test.log" | grep -E '(Test Suite .* (passed|failed)|error:|failed|Executed|\*\* TEST)' || true
[[ ${PIPESTATUS[0]} -eq 0 ]] || die "Unit tests failed; see build/test.log"

log "Building app to check localization coverage"
xcodebuild -project "$PROJECT" -scheme Meth -configuration Debug -derivedDataPath "$DERIVED" build >/dev/null \
  || die "Debug build failed"
python3 "$ROOT/Scripts/i18n/build-catalog.py" --check "$DERIVED"
git -C "$ROOT" diff --quiet -- Meth/Resources/Localizable.xcstrings 2>/dev/null \
  || warn "Localizable.xcstrings changed; commit it."

if [[ "${1:-}" == "--ui" ]]; then
  log "UI tests"
  xcodebuild -project "$PROJECT" -scheme Meth -derivedDataPath "$DERIVED" \
    -only-testing:MethUITests test | tee "$BUILD_DIR/uitest.log" | grep -E '(error:|failed|Executed|\*\* TEST)' || true
  [[ ${PIPESTATUS[0]} -eq 0 ]] || die "UI tests failed; see build/uitest.log"
fi
log "All tests passed"
