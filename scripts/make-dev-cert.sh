#!/usr/bin/env bash
# Create the stable "Loudini Dev" signing identity (no sudo, one command, safe to re-run).
#
# Why: macOS ties every TCC grant (Accessibility, Input Monitoring, Audio) to the app's code
# identity. Ad-hoc signing mints a new identity on every build, so the grants silently die on
# each rebuild while System Settings still shows the toggles enabled. A fixed self-signed leaf
# keeps the identity constant, so the grants persist. build-app.sh picks this up automatically.
#
# Least privilege: the import below passes -T /usr/bin/codesign but deliberately NOT -A.
# -A would let EVERY application on the machine use this private key without prompting; codesign
# is the only tool that needs it.
set -euo pipefail

keychain="${HOME}/Library/Keychains/login.keychain-db"

# Idempotent by design: a second leaf would change the designated requirement and break the very
# grants this script exists to keep, so having one already is success, not an error.
if security find-identity -p codesigning 2>/dev/null | grep -q "Loudini Dev"; then
  echo "\"Loudini Dev\" is already in your keychain — nothing to do."
  exit 0
fi

# `pkcs12 -export -legacy` below is OpenSSL 3 only, and macOS ships LibreSSL as /usr/bin/openssl.
# Without this check the script dies mid-run with a cryptic "unknown option", after minting the key
# but before creating the identity, and build-app.sh silently falls back to ad-hoc signing.
# `|| true` matters: without brew installed the substitution fails, and under `set -e` an
# assignment takes its exit status, so the script would die here with no message at all.
brew_prefix="$(brew --prefix openssl@3 2>/dev/null || true)"
openssl_bin="openssl"
if [[ -n "${brew_prefix}" && -x "${brew_prefix}/bin/openssl" ]]; then
  openssl_bin="${brew_prefix}/bin/openssl"
fi
openssl_version="$("${openssl_bin}" version 2>/dev/null || true)"
if [[ "${openssl_version}" != OpenSSL\ 3* ]]; then
  echo "error: this needs OpenSSL 3, found \"${openssl_version:-none}\"." >&2
  echo "  fix: brew install openssl@3   (macOS's own LibreSSL has no -legacy flag)" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

cat > "${work}/cert.conf" <<'EOF'
[ req ]
distinguished_name = dn
x509_extensions = v3
prompt = no
[ dn ]
CN = Loudini Dev
[ v3 ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

echo "minting a self-signed code-signing cert…"
"${openssl_bin}" req -x509 -newkey rsa:2048 -days 3650 -nodes \
  -keyout "${work}/key.pem" -out "${work}/cert.pem" -config "${work}/cert.conf"

# -legacy + SHA1 MAC: macOS's Security framework can't import OpenSSL 3's default PKCS#12 MAC.
"${openssl_bin}" pkcs12 -export -legacy -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES \
  -out "${work}/ident.p12" -inkey "${work}/key.pem" -in "${work}/cert.pem" -passout pass:loudini

security import "${work}/ident.p12" -k "${keychain}" -P loudini -T /usr/bin/codesign

echo
echo "done — \"Loudini Dev\" is in your keychain."
echo "It lists as CSSMERR_TP_NOT_TRUSTED (self-signed); that is expected and codesign still uses it."
echo "The first build may ask for keychain access — that is codesign using the key; pick Always Allow."
echo
echo "Your old ad-hoc grants are stale, so clear them once and re-approve on next launch:"
echo "  tccutil reset Accessibility gg.pim.loudini.menubar"
echo "  tccutil reset ListenEvent   gg.pim.loudini.menubar"
echo "  tccutil reset AudioCapture  gg.pim.loudini.menubar"
echo "  menubar/build-app.sh && open menubar/Loudini.app"
