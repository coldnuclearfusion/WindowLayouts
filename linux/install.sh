#!/bin/bash
# Install WindowLayouts (Linux, X11): copy the package to ~/.local/share/windowlayouts,
# create the ~/.local/bin/windowlayouts launcher and an application menu entry, then start it.
set -euo pipefail
cd "$(dirname "$0")"

echo "== Checking dependencies"
missing=()
python3 -c "import gi; gi.require_version('Gtk','3.0'); from gi.repository import Gtk" 2>/dev/null || missing+=("python3-gi + GTK 3 (gir1.2-gtk-3.0)")
python3 -c "import Xlib" 2>/dev/null || missing+=("python3-xlib")
if [ ${#missing[@]} -gt 0 ]; then
  echo "Missing: ${missing[*]}"
  echo "  Debian/Ubuntu: sudo apt install python3-gi gir1.2-gtk-3.0 python3-xlib gir1.2-ayatanaappindicator3-0.1"
  echo "  Fedora:        sudo dnf install python3-gobject gtk3 python3-xlib libappindicator-gtk3"
  echo "  Arch:          sudo pacman -S python-gobject gtk3 python-xlib libappindicator-gtk3"
  exit 1
fi
python3 -c "import gi; gi.require_version('AyatanaAppIndicator3','0.1')" 2>/dev/null \
  || python3 -c "import gi; gi.require_version('AppIndicator3','0.1')" 2>/dev/null \
  || echo "(note) AppIndicator is not available; the tray icon falls back to Gtk.StatusIcon. GNOME may need an AppIndicator extension."

DEST="$HOME/.local/share/windowlayouts"
BIN="$HOME/.local/bin"
mkdir -p "$DEST" "$BIN" "$HOME/.local/share/applications" "$HOME/.local/share/icons/hicolor/256x256/apps"

pkill -f "windowlayouts" 2>/dev/null || true
sleep 0.5
rm -rf "$DEST/windowlayouts"
cp -R windowlayouts "$DEST/"
# UI strings shared by all platforms
cp ../shared/strings.json "$DEST/windowlayouts/assets/strings.json"

cat > "$BIN/windowlayouts" <<LAUNCHER
#!/bin/sh
export PYTHONPATH="$DEST\${PYTHONPATH:+:\$PYTHONPATH}"
exec python3 -m windowlayouts "\$@"
LAUNCHER
chmod +x "$BIN/windowlayouts"

cp windowlayouts/assets/windowlayouts.png "$HOME/.local/share/icons/hicolor/256x256/apps/windowlayouts.png"
cat > "$HOME/.local/share/applications/windowlayouts.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=WindowLayouts
Comment=Save and restore window layouts
Exec=$BIN/windowlayouts
Icon=windowlayouts
Terminal=false
Categories=Utility;
StartupNotify=false
DESKTOP
update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true

echo "Installed: $DEST (launcher: $BIN/windowlayouts)"
case ":$PATH:" in *":$BIN:"*) ;; *) echo "(note) $BIN is not on your PATH; add it in your shell configuration.";; esac
if [ "${XDG_SESSION_TYPE:-}" = "wayland" ]; then
  echo "(warning) This is a Wayland session. Moving other apps' windows requires an X11 (Xorg) session."
fi
"$BIN/windowlayouts" &
echo "Started."
