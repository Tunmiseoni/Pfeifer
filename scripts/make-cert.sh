#!/bin/bash
# Create and import the "Pfeifer Development" self-signed code-signing
# certificate into the login keychain, so scripts/make-app.sh signs with
# a stable identity and the TCC Accessibility grant survives rebuilds.
# One-time setup: `make cert`. No Keychain Access GUI needed.
#
# The private key lives in the login keychain (protected by the keychain
# itself, with codesign on its access ACL); the temporary key/cert/p12
# files are deleted after import. If the keychain item is ever lost,
# re-run this script and re-grant Accessibility once.
set -euo pipefail

CERT_NAME="Pfeifer Development"
ORG="Pfeifer Dev"
DAYS=3650

if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$CERT_NAME\""; then
  echo "'$CERT_NAME' codesigning identity already installed — nothing to do."
  exit 0
fi

LOGIN_KC="$(security login-keychain 2>/dev/null | tr -d '"' || true)"
if [[ -z "$LOGIN_KC" || ! -f "$LOGIN_KC" ]]; then
  LOGIN_KC="$HOME/Library/Keychains/login.keychain-db"
fi
if [[ ! -f "$LOGIN_KC" ]]; then
  echo "error: login keychain not found at $LOGIN_KC" >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if security find-certificate -c "$CERT_NAME" 2>/dev/null | grep -q keychain; then
  # Leftover from an interrupted run: the cert+key are in the keychain but
  # not yet trusted — resume at the trust step instead of re-importing.
  echo "found an untrusted '$CERT_NAME' certificate — completing its setup…"
  security find-certificate -c "$CERT_NAME" -p > "$TMP/cert.pem"
else
  command -v openssl >/dev/null || { echo "error: openssl not found" >&2; exit 1; }

  # Extensions via a config file: works on both OpenSSL and LibreSSL,
  # unlike req -addext. The codeSigning EKU and digitalSignature are what
  # codesign requires of a signing identity.
  cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $CERT_NAME
O = $ORG
[v3]
basicConstraints = CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = codeSigning
subjectKeyIdentifier = hash
EOF

  openssl req -new -newkey rsa:2048 -nodes \
    -keyout "$TMP/key.pem" -x509 -days "$DAYS" \
    -out "$TMP/cert.pem" -config "$TMP/cert.cnf" >/dev/null 2>&1

  # Random p12 password held in memory only; needed once, at import time.
  # SHA1/3DES wrapping: Apple's `security import` can't parse OpenSSL 3's
  # AES/PBKDF2 default and fails with a bogus "MAC verification failed".
  PW="$(openssl rand -hex 24)"
  openssl pkcs12 -export -name "$CERT_NAME" \
    -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -macalg sha1 -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES \
    -passout "pass:$PW" -out "$TMP/cert.p12" >/dev/null 2>&1

  security import "$TMP/cert.p12" -k "$LOGIN_KC" \
    -P "$PW" -T /usr/bin/codesign -T /usr/bin/security
fi

# The codesigning policy only accepts the identity once the self-signed
# cert is trusted — without this, find-identity reports 0 valid and
# codesign can't use it. This is the piece Certificate Assistant would
# otherwise wire up. Must be admin domain: user-domain trust settings
# are rejected outright on current macOS. On some setups this step needs
# an admin authorization prompt or sudo.
if ! security add-trusted-cert -d -r trustRoot "$TMP/cert.pem" 2>/dev/null; then
  echo "error: could not set admin-domain trust settings. Run:" >&2
  echo "  sudo security add-trusted-cert -d -r trustRoot '$TMP/cert.pem'" >&2
  echo "(this script's temp copy of the certificate is gone after exit —" >&2
  echo " re-export it first: security find-certificate -c '$CERT_NAME' -p)" >&2
  exit 1
fi

if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$CERT_NAME\""; then
  echo "error: trust settings applied but the identity is still not valid —" >&2
  echo "check 'security find-identity -v -p codesigning' output" >&2
  exit 1
fi

security find-identity -v -p codesigning | grep "$CERT_NAME"
echo "installed '$CERT_NAME' in $(basename "$LOGIN_KC") (trusted, admin domain)"
echo "next: 'make app OPEN=1', then remove and re-add Pfeifer in"
echo "System Settings > Privacy & Security > Accessibility (one last time)."
