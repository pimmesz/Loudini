#!/usr/bin/env bash
# Build Loudini.app (the menu-bar frontend) with the daemon bundled inside.
set -euo pipefail

menubar_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "${menubar_dir}/.." && pwd)"
helper="${repo_dir}/helper/loudini-helper"
app="${menubar_dir}/Loudini.app"

# Always (re)build the engine first — one command builds everything, and the
# bundled daemon can never go stale relative to the sources.
echo "building loudini-helper (daemon + CLI)…"
(cd "${repo_dir}/helper" && swiftc -O -parse-as-library -o loudini-helper \
  loudini-helper.swift ControlFile.swift DDC.swift \
  -framework CoreAudio -framework AudioToolbox -framework Foundation -framework AppKit -framework IOKit)

rm -rf "${app:?}"
mkdir -p "${app}/Contents/MacOS"

swiftc -O -parse-as-library \
  -o "${app}/Contents/MacOS/Loudini" \
  "${menubar_dir}/LoudiniApp.swift" \
  "${menubar_dir}/VolumeKeyTap.swift" \
  "${menubar_dir}/StatusWatcher.swift" \
  "${menubar_dir}/HUDWindow.swift" \
  "${menubar_dir}/DDCBrightness.swift" \
  "${menubar_dir}/BrightnessKeyListener.swift" \
  "${repo_dir}/helper/ControlFile.swift" \
  -framework AppKit

cp "${menubar_dir}/Info.plist" "${app}/Contents/Info.plist"
printf 'APPL????' > "${app}/Contents/PkgInfo"
mkdir -p "${app}/Contents/Resources"
cp "${menubar_dir}/AppIcon.icns" "${app}/Contents/Resources/AppIcon.icns"
cp "${menubar_dir}/MenuBarIcon.png" "${app}/Contents/Resources/MenuBarIcon.png"
cp "${helper}" "${app}/Contents/MacOS/loudini-helper"
chmod 755 "${app}/Contents/MacOS/loudini-helper"

# Signing picks the best identity present, in order:
#   1. Developer ID Application → RELEASE build: hardened runtime + secure
#      timestamp + entitlements, the form notarization requires. Set this up
#      once (see "Release signing & notarization" in BUILD.md) and this branch
#      lights up automatically — no edits here.
#   2. "Loudini Dev" self-signed cert → DEV build: stable identity so the TCC
#      grants (Accessibility / Input Monitoring / Audio) survive rebuilds.
#   3. ad-hoc → every rebuild re-asks for permissions.
entitlements="${menubar_dir}/loudini.entitlements"
# `|| true`: grep exits non-zero when no Developer ID is installed, which would
# abort the script under `set -e`. An empty devid just means "not a release build".
devid="$(security find-identity -v -p codesigning 2>/dev/null \
         | grep -o 'Developer ID Application: [^"]*' | head -1 || true)"
if [[ -n "${devid}" ]]; then
  sign=(--force --options runtime --timestamp --entitlements "${entitlements}" --sign "${devid}")
  echo "signing RELEASE with: ${devid}"
elif security find-identity -p codesigning 2>/dev/null | grep -q "Loudini Dev"; then
  sign=(--force --timestamp=none --sign "Loudini Dev")
  echo "signing DEV with: Loudini Dev (self-signed, stable)"
else
  sign=(--force --timestamp=none --sign -)
  echo "signing AD-HOC (no cert) — permissions reset on every rebuild"
fi
# Sign the nested helper before the outer bundle (inside-out, as codesign wants).
codesign "${sign[@]}" "${app}/Contents/MacOS/loudini-helper"
codesign "${sign[@]}" "${app}"
# The LaunchAgent (scripts/install-daemon.sh) runs the repo helper directly —
# sign it too, or its identity churns every rebuild and the audio grant dies.
codesign "${sign[@]}" "${helper}"

echo "built ${app}"
echo "run:   open ${app}"
echo "note:  first run asks for Accessibility (volume keys) and, when it spawns"
echo "       the daemon, System Audio Recording."
