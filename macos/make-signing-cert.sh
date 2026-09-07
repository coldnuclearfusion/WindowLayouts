#!/bin/bash
# 로컬 서명용 자체 서명 인증서를 로그인 키체인에 만든다. Apple 계정이 필요 없다.
# 이 인증서로 서명하면 앱을 다시 빌드해도 macOS가 같은 앱으로 인식해서
# 손쉬운 사용 권한을 다시 켤 필요가 없다.
#
# 실행 중 macOS 비밀번호 입력 창이 1~2번 뜬다 (키체인 신뢰 설정 변경).
set -euo pipefail
NAME="${1:-WindowLayouts Dev}"

if security find-certificate -c "$NAME" ~/Library/Keychains/login.keychain-db >/dev/null 2>&1; then
  echo "이미 있습니다: $NAME"
  security find-identity -v -p codesigning | grep "$NAME" || true
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
CNF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/cert.p12" -passout pass:temp -name "$NAME"

echo "키체인에 인증서를 넣습니다..."
security import "$TMP/cert.p12" -k ~/Library/Keychains/login.keychain-db -P temp \
  -T /usr/bin/codesign -T /usr/bin/security
echo "코드 서명용으로 신뢰 설정합니다 (비밀번호 입력 창이 뜹니다)..."
security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db "$TMP/cert.pem"

echo
if security find-identity -v -p codesigning | grep -q "$NAME"; then
  echo "완료: '$NAME' 인증서가 준비됐습니다. 이제 ./install.sh 를 실행하면 자동으로 이 인증서로 서명합니다."
  echo "첫 서명 때 '키체인 접근 허용' 창이 뜨면 '항상 허용'을 누르세요."
else
  echo "인증서는 만들었지만 codesign 용으로 인식되지 않습니다. Keychain Access(키체인 접근) 앱에서 '$NAME' 인증서를 열어 '신뢰 › 코드 서명'을 '항상 신뢰'로 바꿔 주세요." >&2
  exit 1
fi
