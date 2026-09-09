#!/bin/bash
# Render the 1024px icon with tools/makeicon.swift and rebuild Resources/AppIcon.icns.
# To change the artwork, edit makeicon.swift and run this script again.
set -euo pipefail
cd "$(dirname "$0")/.."
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
swiftc -O -o "$TMP/makeicon" tools/makeicon.swift
"$TMP/makeicon" "$TMP/icon_1024.png"
mkdir "$TMP/AppIcon.iconset"
while read -r px name; do
  sips -z "$px" "$px" "$TMP/icon_1024.png" --out "$TMP/AppIcon.iconset/$name.png" >/dev/null
done <<'LIST'
16 icon_16x16
32 icon_16x16@2x
32 icon_32x32
64 icon_32x32@2x
128 icon_128x128
256 icon_128x128@2x
256 icon_256x256
512 icon_256x256@2x
512 icon_512x512
1024 icon_512x512@2x
LIST
iconutil -c icns "$TMP/AppIcon.iconset" -o Resources/AppIcon.icns
echo "Done: Resources/AppIcon.icns"
