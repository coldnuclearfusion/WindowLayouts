#!/bin/bash
# WindowLayouts (Linux, X11) 설치: 패키지를 ~/.local/share/windowlayouts 에 복사하고
# ~/.local/bin/windowlayouts 실행 파일과 앱 메뉴 항목을 만든 뒤 실행한다.
set -euo pipefail
cd "$(dirname "$0")"

echo "== 의존성 확인"
missing=()
python3 -c "import gi; gi.require_version('Gtk','3.0'); from gi.repository import Gtk" 2>/dev/null || missing+=("python3-gi + GTK 3 (gir1.2-gtk-3.0)")
python3 -c "import Xlib" 2>/dev/null || missing+=("python3-xlib")
if [ ${#missing[@]} -gt 0 ]; then
  echo "다음이 필요합니다: ${missing[*]}"
  echo "  Debian/Ubuntu: sudo apt install python3-gi gir1.2-gtk-3.0 python3-xlib gir1.2-ayatanaappindicator3-0.1"
  echo "  Fedora:        sudo dnf install python3-gobject gtk3 python3-xlib libappindicator-gtk3"
  echo "  Arch:          sudo pacman -S python-gobject gtk3 python-xlib libappindicator-gtk3"
  exit 1
fi
python3 -c "import gi; gi.require_version('AyatanaAppIndicator3','0.1')" 2>/dev/null \
  || python3 -c "import gi; gi.require_version('AppIndicator3','0.1')" 2>/dev/null \
  || echo "(참고) AppIndicator가 없어 Gtk.StatusIcon으로 트레이를 표시합니다. GNOME에서는 AppIndicator 확장이 필요할 수 있습니다."

DEST="$HOME/.local/share/windowlayouts"
BIN="$HOME/.local/bin"
mkdir -p "$DEST" "$BIN" "$HOME/.local/share/applications" "$HOME/.local/share/icons/hicolor/256x256/apps"

pkill -f "windowlayouts" 2>/dev/null || true
sleep 0.5
rm -rf "$DEST/windowlayouts"
cp -R windowlayouts "$DEST/"
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
Comment=창 배치 저장/복원
Exec=$BIN/windowlayouts
Icon=windowlayouts
Terminal=false
Categories=Utility;
StartupNotify=false
DESKTOP
update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true

echo "설치됨: $DEST (실행 파일: $BIN/windowlayouts)"
case ":$PATH:" in *":$BIN:"*) ;; *) echo "(참고) $BIN 이 PATH에 없습니다. 셸 설정에 추가하세요.";; esac
if [ "${XDG_SESSION_TYPE:-}" = "wayland" ]; then
  echo "(주의) 현재 세션이 Wayland입니다. 다른 앱의 창을 옮기려면 X11(Xorg) 세션으로 로그인해야 합니다."
fi
"$BIN/windowlayouts" &
echo "실행했습니다."
