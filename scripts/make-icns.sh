#!/usr/bin/env bash
# Regenerate Resources/AppIcon.icns from the icon art.
# 1) renders a 1024px master via make-icon.swift, 2) builds all sizes, 3) packs .icns.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MASTER="$ROOT/Resources/icon-1024.png"
ICONSET="$(mktemp -d)/Wasabi.iconset"
mkdir -p "$ICONSET" "$ROOT/Resources"

echo "==> Rendering 1024px master"
swiftc -O -framework AppKit "$ROOT/scripts/make-icon.swift" -o "$(dirname "$ICONSET")/make-icon"
"$(dirname "$ICONSET")/make-icon" "$MASTER"

echo "==> Generating iconset sizes"
for spec in "16:16x16" "32:16x16@2x" "32:32x32" "64:32x32@2x" \
            "128:128x128" "256:128x128@2x" "256:256x256" "512:256x256@2x" \
            "512:512x512" "1024:512x512@2x"; do
    px="${spec%%:*}"; name="${spec##*:}"
    sips -z "$px" "$px" "$MASTER" --out "$ICONSET/icon_${name}.png" >/dev/null
done

echo "==> Packing AppIcon.icns"
iconutil -c icns "$ICONSET" -o "$ROOT/Resources/AppIcon.icns"
echo "==> Done: Resources/AppIcon.icns"
