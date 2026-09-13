#!/bin/bash
# Release-build the Swift package and assemble build/WindowLayouts.app.
# Signing: CODESIGN_IDENTITY if set; otherwise the first identity found in the order
# "WindowLayouts Dev" (local self-signed) → "Apple Development" → "Developer ID Application"; otherwise ad-hoc.
set -euo pipefail
cd "$(dirname "$0")"

# The SwiftUI macros (@State etc. in the macOS 26 SDK) ship only with Xcode's toolchain, not with the
# Command Line Tools, so prefer Xcode when it is installed and no toolchain was chosen explicitly.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

swift build -c release 2>&1 | grep -Ev "^\[[0-9]+/[0-9]+\]" || true
BIN=".build/release/WindowLayouts"
[ -x "$BIN" ] || { echo "Build failed: $BIN not found" >&2; exit 1; }

APP="build/WindowLayouts.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/WindowLayouts"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# UI strings shared by all platforms, and per-language display name / usage descriptions
cp ../shared/strings.json "$APP/Contents/Resources/strings.json"
for lproj in Resources/*.lproj; do
  [ -d "$lproj" ] && cp -R "$lproj" "$APP/Contents/Resources/"
done
printf 'APPL????' > "$APP/Contents/PkgInfo"

IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDS=$(security find-identity -v -p codesigning 2>/dev/null || true)
  for PATTERN in "WindowLayouts Dev" "Apple Development" "Developer ID Application"; do
    IDENTITY=$(echo "$IDS" | grep -F "$PATTERN" | head -1 | sed -E 's/.*"(.*)".*/\1/' || true)
    [ -n "$IDENTITY" ] && break
  done
fi
if [ -n "$IDENTITY" ]; then
  echo "Signing with: $IDENTITY"
  codesign --force --deep --sign "$IDENTITY" "$APP"
else
  echo "Signing: ad-hoc (no certificate found). The Accessibility permission will have to be granted again after every rebuild; run ./make-signing-cert.sh once, or use an Apple Development certificate, to avoid that."
  codesign --force --deep --sign - "$APP"
fi
echo "Done: $APP"
