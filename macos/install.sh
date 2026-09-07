#!/bin/bash
# 빌드 후 /Applications 에 설치하고 실행한다. (이미 실행 중이면 종료 후 교체)
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
echo "설치됨: $DEST"
open "$DEST"
echo "실행했습니다. 처음이라면 시스템 설정 › 개인정보 보호 및 보안 › 손쉬운 사용 에서 WindowLayouts 를 허용하세요."
