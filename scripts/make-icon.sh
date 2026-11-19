#!/usr/bin/env bash
# Regenerates Assets/AppIcon.icns (and Assets/AppIcon.png) from scripts/make-icon.swift.
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p Assets
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

swift scripts/make-icon.swift "$TMP/icon_1024.png"

SET="$TMP/AppIcon.iconset"
mkdir -p "$SET"
for size in 16 32 128 256 512; do
  sips -z $size $size "$TMP/icon_1024.png" --out "$SET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double "$TMP/icon_1024.png" --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$SET" -o Assets/AppIcon.icns
cp "$TMP/icon_1024.png" Assets/AppIcon.png
echo "Wrote Assets/AppIcon.icns"
