#!/usr/bin/env bash
# Build Loudini.app (the menu-bar frontend) with the daemon bundled inside.
set -euo pipefail

menubar_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "${menubar_dir}/.." && pwd)"
helper="${repo_dir}/helper/loudini-helper"
app="${menubar_dir}/Loudini.app"

if [[ ! -x "${helper}" ]]; then
  echo "error: ${helper} is missing or not executable. Build it first:" >&2
  echo "  cd helper && swiftc -O -parse-as-library -o loudini-helper \\" >&2
  echo "    loudini-helper.swift ControlFile.swift \\" >&2
  echo "    -framework CoreAudio -framework AudioToolbox -framework Foundation" >&2
  exit 1
fi

rm -rf "${app:?}"
mkdir -p "${app}/Contents/MacOS"

swiftc -O -parse-as-library \
  -o "${app}/Contents/MacOS/Loudini" \
  "${menubar_dir}/LoudiniApp.swift" \
  "${menubar_dir}/VolumeKeyTap.swift" \
  "${menubar_dir}/StatusWatcher.swift" \
  "${menubar_dir}/HUDWindow.swift" \
  "${repo_dir}/helper/ControlFile.swift" \
  -framework AppKit

cp "${menubar_dir}/Info.plist" "${app}/Contents/Info.plist"
printf 'APPL????' > "${app}/Contents/PkgInfo"
mkdir -p "${app}/Contents/Resources"
cp "${menubar_dir}/AppIcon.icns" "${app}/Contents/Resources/AppIcon.icns"
cp "${menubar_dir}/MenuBarIcon.png" "${app}/Contents/Resources/MenuBarIcon.png"
cp "${helper}" "${app}/Contents/MacOS/loudini-helper"
chmod 755 "${app}/Contents/MacOS/loudini-helper"

# Ad-hoc sign so the bundle has a valid code identity. Note: every REBUILD
# produces a new ad-hoc identity, so macOS re-asks for Accessibility / System
# Audio Recording after rebuilding. Unavoidable without a Developer ID.
codesign --force --sign - "${app}/Contents/MacOS/loudini-helper"
codesign --force --sign - "${app}"

echo "built ${app}"
echo "run:   open ${app}"
echo "note:  first run asks for Accessibility (volume keys) and, when it spawns"
echo "       the daemon, System Audio Recording."
