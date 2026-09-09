#!/bin/bash
# Build, install to /Applications (or ~/Applications if /Applications is not writable), and launch.
# A running instance is stopped and replaced.
set -euo pipefail
cd "$(dirname "$0")"
./build.sh

DEST="/Applications/WindowLayouts.app"
if [ ! -w /Applications ]; then
  DEST="$HOME/Applications/WindowLayouts.app"
  mkdir -p "$HOME/Applications"
fi

pkill -x WindowLayouts 2>/dev/null || true
sleep 0.5
rm -rf "$DEST"
cp -R build/WindowLayouts.app "$DEST"
echo "Installed: $DEST"
open "$DEST"
echo "Launched. On first use, allow WindowLayouts under System Settings › Privacy & Security › Accessibility."
