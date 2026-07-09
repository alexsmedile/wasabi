#!/usr/bin/env bash
# Create a STABLE self-signed code-signing identity for Wasabi, so the app's
# code signature (and therefore its keychain access ACL) is consistent across
# rebuilds and launches. This stops macOS prompting for the keychain password
# every time the app opens — the prompt happens because ad-hoc signatures have
# no stable identity, so the WKWebsiteDataStore encryption key's ACL never
# matches on the next launch.
#
# Run ONCE. It will:
#   1. generate a self-signed code-signing cert "Wasabi Dev" in your login keychain
#   2. mark it trusted for code signing
# After this, scripts/build-app.sh signs with it automatically.
#
# This may prompt for your login password ONCE (to create the key) — that is
# expected and is the last time you should be bothered.
set -euo pipefail

CERT_NAME="Wasabi Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
P12_PASS="wasabi"   # transient — only used to move the key into the keychain

# Already present? (look it up by name in the full identity list — the cert is
# self-signed and NOT system-trusted, so the -p codesigning filter won't show it,
# but it is still usable for local signing via its hash.)
# NOTE: use `find-identity` WITHOUT -v. The -v flag only lists identities valid
# for the default trust policy; our self-signed cert is untrusted
# (CSSMERR_TP_NOT_TRUSTED) so -v would hide it even though it's perfectly usable
# for local signing by hash.
if security find-identity 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "==> Identity '$CERT_NAME' already exists — nothing to do."
    security find-identity | grep "$CERT_NAME"
    exit 0
fi

echo "==> Creating self-signed code-signing identity: $CERT_NAME"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
CONFIG="$TMP/cert.conf"

cat > "$CONFIG" <<EOF
[ req ]
distinguished_name = dn
x509_extensions = v3
prompt = no
[ dn ]
CN = $CERT_NAME
[ v3 ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -config "$CONFIG" >/dev/null 2>&1

# IMPORTANT: export with -legacy + -macalg sha1. OpenSSL 3.x defaults to a
# PKCS#12 MAC that Apple's `security` cannot verify ("MAC verification failed").
# The legacy MAC + a real (transient) password is what macOS accepts.
openssl pkcs12 -export -legacy -macalg sha1 \
    -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$CERT_NAME" -out "$TMP/wasabi.p12" -passout "pass:$P12_PASS" >/dev/null 2>&1

# Import into the login keychain. -T codesign lets codesign use the key without
# a UI prompt on every build.
security import "$TMP/wasabi.p12" -k "$KEYCHAIN" -P "$P12_PASS" \
    -T /usr/bin/codesign -T /usr/bin/security

# Allow codesign to use the private key non-interactively (best-effort; if it
# fails the first build may prompt once for "Always Allow").
security set-key-partition-list -S apple-tool:,apple:,codesign: \
    -s -k "$P12_PASS" "$KEYCHAIN" >/dev/null 2>&1 || true

# NOTE: we deliberately DO NOT mark the cert system-trusted. That requires sudo
# and is NOT needed to sign locally — codesign signs fine with an untrusted
# self-signed identity (referenced by hash in build-app.sh). System trust only
# matters for third parties verifying the signature, which we don't need.

echo ""
HASH="$(security find-identity | grep "$CERT_NAME" | grep -oE '[0-9A-F]{40}' | head -1)"
if [ -n "$HASH" ]; then
    echo "==> Done. Identity created: $CERT_NAME ($HASH)"
    echo "    (shows 'CSSMERR_TP_NOT_TRUSTED' — that's expected and fine for local signing)"
    echo ""
    echo "Next: rebuild with scripts/build-app.sh — it will sign with this identity by hash."
else
    echo "==> WARNING: identity not found after import. Check 'security find-identity -v'."
    exit 1
fi
