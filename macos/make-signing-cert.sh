#!/bin/bash
# Create a local self-signed code-signing certificate in the login keychain. No Apple account needed.
# Signing with it keeps the app's identity stable across rebuilds, so macOS keeps the Accessibility
# permission instead of asking again after every build.
#
# macOS will show a password prompt once or twice (keychain trust settings change).
set -euo pipefail
NAME="${1:-WindowLayouts Dev}"

if security find-certificate -c "$NAME" ~/Library/Keychains/login.keychain-db >/dev/null 2>&1; then
  echo "Already exists: $NAME"
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

echo "Importing the certificate into the login keychain..."
security import "$TMP/cert.p12" -k ~/Library/Keychains/login.keychain-db -P temp \
  -T /usr/bin/codesign -T /usr/bin/security
echo "Marking it as trusted for code signing (a password prompt will appear)..."
security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db "$TMP/cert.pem"

echo
if security find-identity -v -p codesigning | grep -q "$NAME"; then
  echo "Done: the '$NAME' certificate is ready. ./install.sh will now sign with it automatically."
  echo "If a keychain access prompt appears on the first signing, choose 'Always Allow'."
else
  echo "The certificate was created but codesign does not accept it. Open it in Keychain Access and set Trust › Code Signing to 'Always Trust'." >&2
  exit 1
fi
