#!/usr/bin/env bash
# Regenerates the app icon, README logo and DMG background from the shared vector glyph.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/tools"
mkdir -p "$OUT"
xcrun swiftc -O -o "$OUT/asset-generator" \
  "$ROOT/Scripts/AssetGenerator/main.swift" "$ROOT/Meth/UI/SyringeGlyph.swift"
"$OUT/asset-generator" "$ROOT"
