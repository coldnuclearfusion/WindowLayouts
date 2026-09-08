#!/bin/bash
# Swift Package를 릴리스 빌드하고 build/WindowLayouts.app 번들을 만든다.
# 서명: CODESIGN_IDENTITY 환경변수가 있으면 그걸로, 없으면 Apple Development 인증서를 찾고, 그것도 없으면 ad-hoc 서명.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release 2>&1 | grep -Ev "^\[[0-9]+/[0-9]+\]" || true
BIN=".build/release/WindowLayouts"
[ -x "$BIN" ] || { echo "빌드 실패: $BIN 없음" >&2; exit 1; }

APP="build/WindowLayouts.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/WindowLayouts"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp ../shared/strings.json "$APP/Contents/Resources/strings.json"
for lproj in Resources/*.lproj; do
  [ -d "$lproj" ] && cp -R "$lproj" "$APP/Contents/Resources/"
done
printf 'APPL????' > "$APP/Contents/PkgInfo"

IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDS=$(security find-identity -v -p codesigning 2>/dev/null || true)
  # 우선순위: make-signing-cert.sh 로 만든 로컬 인증서 → Apple Development → Developer ID
  for PATTERN in "WindowLayouts Dev" "Apple Development" "Developer ID Application"; do
    IDENTITY=$(echo "$IDS" | grep -F "$PATTERN" | head -1 | sed -E 's/.*"(.*)".*/\1/' || true)
    [ -n "$IDENTITY" ] && break
  done
fi
if [ -n "$IDENTITY" ]; then
  echo "서명: $IDENTITY"
  codesign --force --deep --sign "$IDENTITY" "$APP"
else
  echo "서명: ad-hoc (인증서 없음) — 재빌드마다 손쉬운 사용 권한을 다시 켜야 합니다. ./make-signing-cert.sh 를 한 번 실행하면 해결됩니다."
  codesign --force --deep --sign - "$APP"
fi
echo "완료: $APP"
