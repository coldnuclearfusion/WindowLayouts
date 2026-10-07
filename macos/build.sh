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

# Show the build output without the per-file progress lines, and stop if the build failed:
# otherwise a binary left over from an earlier build would be packaged and installed as if it were new.
LOG="$(mktemp -t windowlayouts-build)"
set +e
swift build -c release 2>&1 | tee "$LOG" | grep -Ev "^\[[0-9]+/[0-9]+\]"
STATUS=${PIPESTATUS[0]}
set -e
if [ "$STATUS" -ne 0 ]; then
  if grep -q "agreed to the Xcode license" "$LOG"; then
    # Plain "sudo xcodebuild" fails when xcode-select points at the Command Line Tools, so name Xcode's own copy
    echo "Xcode's license has not been accepted yet (this is needed again after every Xcode update)." >&2
    echo "Open Xcode once and agree, or run:" >&2
    echo "  sudo \"${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}/usr/bin/xcodebuild\" -license" >&2
  fi
  rm -f "$LOG"
  echo "Build failed (swift build exited with $STATUS); nothing was packaged." >&2
  exit 1
fi
rm -f "$LOG"
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
