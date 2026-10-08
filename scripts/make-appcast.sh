#!/usr/bin/env bash
# Print the Sparkle appcast for one release: a single item pointing at that version's DMG
# on GitHub, with an EdDSA signature from the key in the login Keychain (account
# "loudini"). release.sh uploads it next to the DMG; installed copies read it from
# releases/latest/download/appcast.xml, so it always describes the newest release.
# Usage: scripts/make-appcast.sh <N.N.N> <path/to/Loudini.dmg>
set -euo pipefail

version="${1:-}"
dmg="${2:-}"
[[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "ERROR: version '${version}' is not N.N.N." >&2; exit 1; }
[[ -f "${dmg}" ]] || { echo "ERROR: ${dmg} not found." >&2; exit 1; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "${script_dir}/.." && pwd)"
plist="${repo_dir}/menubar/Info.plist"
sparkle_dir="$("${repo_dir}/menubar/fetch-sparkle.sh")"
plist_value() { python3 -c "import plistlib,sys; print(plistlib.load(open(sys.argv[1],'rb'))[sys.argv[2]])" "${plist}" "$1"; }

# Installed copies trust only the public key in their Info.plist. A Keychain key that does
# not match it would sign updates every client rejects, so refuse before publishing.
keychain_key="$("${sparkle_dir}/bin/generate_keys" --account loudini -p)"
if [[ "${keychain_key}" != "$(plist_value SUPublicEDKey)" ]]; then
  echo "ERROR: the Sparkle key in the Keychain (account 'loudini') does not match SUPublicEDKey in Info.plist." >&2
  exit 1
fi

signature="$("${sparkle_dir}/bin/sign_update" --account loudini -p "${dmg}")"
"${sparkle_dir}/bin/sign_update" --account loudini --verify "${dmg}" "${signature}" >/dev/null
length="$(stat -f %z "${dmg}")"
min_os="$(plist_value LSMinimumSystemVersion)"
pub_date="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
url="https://github.com/pimmesz/Loudini/releases/download/v${version}/Loudini.dmg"

cat <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Loudini</title>
    <item>
      <title>Loudini ${version}</title>
      <pubDate>${pub_date}</pubDate>
      <sparkle:version>${version}</sparkle:version>
      <sparkle:shortVersionString>${version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${min_os}</sparkle:minimumSystemVersion>
      <enclosure url="${url}" length="${length}" type="application/octet-stream" sparkle:edSignature="${signature}"/>
    </item>
  </channel>
</rss>
EOF
