#!/bin/zsh
# Regenerates Resources/AppIcon.icns from scripts/make-icon.swift.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
swift scripts/make-icon.swift "$WORK/icon_1024.png"

ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for px in 16 32 128 256 512; do
  sips -z $px $px "$WORK/icon_1024.png" --out "$ICONSET/icon_${px}x${px}.png" >/dev/null
  sips -z $((px * 2)) $((px * 2)) "$WORK/icon_1024.png" --out "$ICONSET/icon_${px}x${px}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
echo "Wrote Resources/AppIcon.icns"
