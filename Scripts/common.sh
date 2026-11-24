# shellcheck shell=bash
# Shared helpers for Meth's build scripts. Source, don't execute.
# shellcheck disable=SC2034  # variables are used by the scripts that source this file
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/build"
DIST_DIR="$ROOT/dist"
DERIVED="$BUILD_DIR/DerivedData"
PROJECT="$ROOT/Meth.xcodeproj"
APP_NAME="Meth"
GITHUB_REPO="${METH_GITHUB_REPO:-kroekkarawit/meth-macos}"
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-meth-macos}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

require() {
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || die "Required tool not found: $tool"
  done
}

marketing_version() { awk -F' = ' '/^MARKETING_VERSION/ {print $2}' "$ROOT/Config/Version.xcconfig"; }
build_number()      { awk -F' = ' '/^CURRENT_PROJECT_VERSION/ {print $2}' "$ROOT/Config/Version.xcconfig"; }

sparkle_bin() {
  local dir
  dir="$(find "$DERIVED/SourcePackages/artifacts" -type d -name bin -path '*Sparkle*' 2>/dev/null | head -1)"
  [[ -n "$dir" ]] || die "Sparkle tools not found; run Scripts/build.sh first (it resolves packages)."
  echo "$dir"
}

ensure_project() {
  if command -v xcodegen >/dev/null 2>&1; then
    (cd "$ROOT" && xcodegen generate --quiet)
  fi
  [[ -d "$PROJECT" ]] || die "Meth.xcodeproj missing and xcodegen not installed (brew install xcodegen)."
}
