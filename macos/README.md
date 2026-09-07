# WindowLayouts for macOS (창 배치)

저장소 전체 소개와 다른 운영체제 버전은 [상위 README](../README.md)를 보세요.

macOS 메뉴 바에 상주하면서 저장해 둔 창 배치를 즉시 되돌려 주는 앱입니다.

## 요구사항 대응

| # | 요구사항 | 구현 |
|---|---|---|
| 1 | 현재 창 배치 저장 | 메뉴 바 › **현재 창 배치 저장…**, 또는 설정 창의 **+** 버튼 |
| 2 | 창 배치 직접 편집 | 설정 창 표에서 제목·좌표·크기·찾기 방식 편집. `layouts.json`을 텍스트 에디터로 고쳐도 자동 반영 |
| 3 | 한 프로그램의 여러 창 | 창 단위로 저장. 적용 시 제목 → 순서 순으로 창을 짝지음 |
| 4 | 로그인 시 실행, 메뉴 바 상주 | Dock 아이콘 없이 메뉴 바에만 표시. **일반 설정 › 로그인할 때 자동으로 실행** |
| 5 | 메뉴에서 즉시 전환, 상세 설정 창 | 메뉴 상단에 배치 목록(클릭 즉시 적용). **상세 설정…**으로 창 열기 |
| 6 | 실행 안 된 앱 처리 선택 | 배치마다 *매번 물어보기 / 실행하고 새 창 열기 / 지금 있는 창만 배치* 선택. 실행 중이지만 창이 하나도 없는 앱도 같은 정책으로 처리(새 창을 열어 줌). 물어볼 때 "다시 묻지 않기" 체크 가능 |
| 7 | 저장 시 포함할 프로그램 선택 | 저장 시트에서 앱별·창별 체크박스. "창 제목도 저장"을 끄면 제목 없이 순서로만 찾는 항목으로 저장 |
| 8 | 배치 이름 | 저장 시 입력, 설정 창 상단에서 언제든 변경 |
| + | 적용 시 창을 맨 위로 | 배치마다 켜고 끌 수 있음(기본 켜짐). 표의 순서가 앞뒤 순서이며 위 항목이 가장 앞. `^` `v` 버튼으로 순서 조정 |
| + | 모니터 구성별 배치 | 저장 시 연결된 모니터 구성을 함께 기록. 메뉴와 목록에서 현재 구성의 배치가 먼저 나오고, 다른 구성 배치는 "다른 구성" 서브메뉴에. 다른 구성 배치를 적용하면 창이 있던 모니터를 찾아 상대 위치로 옮기고, 없으면 주 화면에 맞춰 넣음 |

## 빌드 / 설치

Xcode 없이 Command Line Tools만으로 빌드됩니다 (macOS 15 이상).

```bash
./install.sh     # 빌드 → /Applications/WindowLayouts.app 설치 → 실행
```

빌드만 하려면 `./build.sh` (결과물: `build/WindowLayouts.app`).

처음 실행하면 **손쉬운 사용** 권한 요청이 뜹니다. 시스템 설정 › 개인정보 보호 및 보안 › 손쉬운 사용에서 WindowLayouts를 켜 주세요. 이 권한 없이는 창 목록을 읽거나 옮길 수 없습니다.

### 서명 (권한을 매번 다시 켜지 않으려면)

서명 인증서가 없으면 ad-hoc 서명을 합니다. 이 경우 **앱을 다시 빌드할 때마다** macOS가 다른 앱으로 인식해서 손쉬운 사용 권한을 다시 켜야 합니다 (시스템 설정 목록에서 WindowLayouts를 `−`로 지우고 다시 추가).

권장: 아래 "여러 Mac에 설치하기"의 Xcode + 무료 Apple ID 방법. Apple 계정을 쓰고 싶지 않으면 로컬 자체 서명 인증서를 한 번 만들어 두는 방법도 있습니다 (Mac마다 따로 만들어야 함).

```bash
./make-signing-cert.sh     # 비밀번호 창 1~2번. 로그인 키체인에 "WindowLayouts Dev" 인증서 생성
./install.sh               # 이후로는 자동으로 이 인증서로 서명
```

이렇게 서명한 뒤 손쉬운 사용 권한을 **한 번만 더** 켜면, 그 뒤 재빌드에서는 유지됩니다. Apple Development / Developer ID 인증서가 있으면 그것도 자동으로 씁니다. `CODESIGN_IDENTITY="..." ./build.sh` 로 직접 지정할 수도 있습니다.

Apple 개발자 프로그램(유료, 연 129,000원)은 **다른 사람에게 배포**(공증, Developer ID)할 때만 필요합니다. 본인 Mac에서만 쓰는 지금 용도에는 필요 없습니다.

## 여러 Mac에 설치하기 (무료 Apple ID + Xcode)

Apple Development 인증서는 **팀 ID** 기준으로 앱을 식별하므로, 각 Mac에서 같은 Apple ID로 인증서를 받으면 어느 Mac에서 재빌드해도 손쉬운 사용 권한이 유지됩니다. 유료 개발자 프로그램은 필요 없습니다.

각 Mac에서 한 번씩:

1. App Store에서 **Xcode** 설치. 처음 한 번 실행해서 라이선스에 동의하고 추가 구성요소를 설치합니다.
2. Xcode › Settings(⌘,) › **Accounts** › `+` › Apple ID로 로그인. "Personal Team"이 생깁니다.
3. 같은 화면에서 그 팀을 선택하고 **Manage Certificates…** › `+` › **Apple Development**. 로그인 키체인에 `Apple Development: 이메일 (팀ID)` 인증서가 만들어집니다.
4. 저장소를 받아 macOS 폴더에서 설치합니다:

   ```bash
   git clone https://github.com/coldnuclearfusion/WindowLayouts.git ~/WindowLayouts
   ```

   ```bash
   ~/WindowLayouts/macos/install.sh
   ```

   `build.sh`가 Apple Development 인증서를 자동으로 찾아 서명합니다. 인증서가 여러 개면 `CODESIGN_IDENTITY="Apple Development: …" ./build.sh` 로 지정하세요.
5. 손쉬운 사용 권한을 한 번 허용합니다. 이후로는 재빌드해도 유지됩니다.

주의: **빌드된 .app을 AirDrop 등으로 다른 Mac에 복사하지 마세요.** Apple Development 서명은 공증 대상이 아니라서, 격리 속성이 붙은 채 복사되면 Gatekeeper가 실행을 막습니다. 각 Mac에서 소스로 빌드하는 것이 정석입니다. 꼭 복사해야 한다면 복사 후 아래 명령으로 격리 속성을 지우면 됩니다.

```bash
xattr -dr com.apple.quarantine /Applications/WindowLayouts.app
```

## 데이터 파일

`~/Library/Application Support/WindowLayouts/layouts.json`

```json
{
  "version": 1,
  "layouts": [
    {
      "id": "…",
      "name": "코딩",
      "launchPolicy": "ask",
      "windows": [
        {
          "bundleID": "com.apple.Terminal",
          "appName": "터미널",
          "title": "zsh",
          "titleMatch": "auto",
          "x": 0, "y": 25, "width": 960, "height": 1055,
          "enabled": true
        }
      ]
    }
  ]
}
```

- `displayConfig`: 저장 당시 모니터 구성. 지우면 "구성 무관" 배치가 되어 모든 구성에서 보이고 좌표를 그대로 적용합니다.
- 창의 `displayID`: 저장 당시 그 창이 있던 모니터. 모니터 구성이 달라졌을 때 이 모니터를 찾아 상대 위치로 옮깁니다.
- 좌표는 주 화면 왼쪽 위가 (0, 0)이고 아래로 갈수록 y가 커집니다. 다른 모니터는 주 화면 기준 상대 좌표입니다.
- `launchPolicy`: `ask` / `launchMissing` / `runningOnly`
- `raiseWindows`: `true`면 적용 후 이 배치의 창들을 다른 창들 위로 올림. `windows` 배열의 앞 항목이 더 위에 옴
- `titleMatch`: `auto`(제목 먼저, 없으면 순서) / `title`(제목 맞는 창만) / `order`(제목 무시)
- `id`, `appName`, `titleMatch`, `enabled` 등은 생략해도 됩니다. 파일을 저장하면 앱이 자동으로 다시 읽습니다.

## 구조

```
Sources/WindowLayouts/
  App.swift             메뉴 바(MenuBarExtra) + 설정 창 Scene
  SystemMonitor.swift   권한/모니터 연결 상태 감시, 현재 모니터 구성 읽기
  Models.swift          WindowLayout / WindowEntry / 정책 enum
  LayoutStore.swift     JSON 저장·읽기, 파일 변경 감시
  AX.swift              Accessibility API로 창 읽기/옮기기
  WindowCapture.swift   현재 열린 창 수집 (앞→뒤 순서)
  LayoutApplier.swift   창 짝짓기, 앱 실행 대기, 적용
  Views/                메뉴, 메인 창, 상세 편집, 저장 시트, 일반 설정
Resources/AppIcon.icns  앱 아이콘 (tools/make-icon.sh 로 재생성)
tools/makeicon.swift    아이콘을 CoreGraphics로 그리는 스크립트
```
