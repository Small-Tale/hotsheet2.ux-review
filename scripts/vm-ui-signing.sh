#!/bin/bash
# Guest-only stable code-signing identity for the UI-test guest (HS2-07PFQX).
# Runs INSIDE the dedicated Parallels guest as its console user; scripts/vm-ui-provision.sh sends
# it there. Never run it on the developer host.
#
# Ad hoc builds change identity on every rebuild, so TCC drops the runner's Accessibility and
# Screen Recording grants. A self-signed certificate gives the app and UXReviewUITests-Runner a
# designated requirement on the certificate leaf instead, which survives rebuilds.
#
# Creates, once, a dedicated keychain with a generated password (kept 0600 beside it), a
# self-signed code-signing certificate in it, and ~/uxreview-vm/signing/Signing.local.xcconfig.
# vm-ui-e2e.sh unlocks the keychain and copies that xcconfig into each synced tree. Rerunning
# keeps an existing identity, because replacing it would void every grant made for it.
set -euo pipefail
umask 077
DIR="$HOME/uxreview-vm/signing"
KEYCHAIN="$HOME/Library/Keychains/uxreview-ui-signing.keychain-db"
PASSWORD_FILE="$DIR/keychain-password"
XCCONFIG="$DIR/Signing.local.xcconfig"
NAME="UXReview UI Test Signing (guest)"
mkdir -p "$DIR" "$HOME/Library/Keychains"

identity_hash() {  # SHA-1 of the signing certificate in the dedicated keychain, if any
  security find-certificate -a -Z -c "$NAME" "$KEYCHAIN" 2>/dev/null | awk '/^SHA-1 hash:/ {print $3; exit}'
}
add_to_search_list() {  # Xcode looks identities up through the user search list
  local current
  current="$(security list-keychains -d user | tr -d '"' | awk '{$1=$1; print}')"
  grep -qxF "$KEYCHAIN" <<<"$current" && return 0
  # shellcheck disable=SC2086 # keychain paths contain no spaces
  security list-keychains -d user -s $current "$KEYCHAIN"
}

if [[ -f "$KEYCHAIN" && -s "$PASSWORD_FILE" ]] && security unlock-keychain -p "$(cat "$PASSWORD_FILE")" "$KEYCHAIN" 2>/dev/null; then
  HASH="$(identity_hash)"
else
  HASH=""
fi

if [[ -z "$HASH" ]]; then
  echo "Creating the guest signing identity '$NAME'"
  security delete-keychain "$KEYCHAIN" 2>/dev/null || true
  openssl rand -hex 24 > "$PASSWORD_FILE"
  PASSWORD="$(cat "$PASSWORD_FILE")"
  WORK="$(mktemp -d)"
  trap 'rm -rf "$WORK"' EXIT
  cat > "$WORK/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CNF
  openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes -config "$WORK/cert.cnf" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
  openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
    -passout "pass:$PASSWORD" -out "$WORK/identity.p12"
  security create-keychain -p "$PASSWORD" "$KEYCHAIN"
  security set-keychain-settings "$KEYCHAIN"  # no auto-lock; the run script unlocks it anyway
  security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
  security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign >/dev/null
  # Let codesign use the key without a GUI prompt.
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASSWORD" "$KEYCHAIN" >/dev/null
  HASH="$(identity_hash)"
  [[ -n "$HASH" ]] || { echo "The signing certificate was not imported" >&2; exit 1; }
  echo "New identity: approve UXReviewUITests-Runner again in the guest's Device Control and Data Access settings"
else
  echo "Keeping the existing guest signing identity $HASH"
fi
add_to_search_list
# Xcode lists only trusted identities. Trusting the certificate needs a person to authorize it
# once in the guest (docs/09-ui-testing.md), so export the public certificate for that step.
security find-certificate -c "$NAME" -p "$KEYCHAIN" > "$DIR/certificate.pem"
chmod 644 "$DIR/certificate.pem"
if ! security find-identity -v -p codesigning "$KEYCHAIN" | grep -q "$HASH"; then
  echo "Trust needed: in the guest's Terminal run"
  echo "  security add-trusted-cert -r trustRoot -p codeSign -k $KEYCHAIN $DIR/certificate.pem"
  echo "and approve the dialog."
fi
cat > "$XCCONFIG" <<XC
// Guest-only signing written by scripts/vm-ui-signing.sh (HS2-07PFQX). Do not copy to a host.
CODE_SIGN_IDENTITY = $HASH
OTHER_CODE_SIGN_FLAGS = --keychain $KEYCHAIN
// A self-signed certificate has no Team ID, so hardened-runtime library validation rejects
// Xcode's separate debug dylib; link it into the app binary instead.
ENABLE_DEBUG_DYLIB = NO
XC
chmod 644 "$XCCONFIG"
echo "signing identity: $HASH"
