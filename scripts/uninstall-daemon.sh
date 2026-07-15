#!/usr/bin/env bash
# Stop the Loudini daemon and remove its LaunchAgent. Audio fails open:
# the moment the daemon dies, macOS restores the normal direct audio path.
set -euo pipefail

dest="${HOME}/Library/LaunchAgents/gg.pim.loudini.plist"
label="gg.pim.loudini"
domain="gui/$(id -u)"

echo "stopping daemon: launchctl bootout ${domain}/${label}"
if ! launchctl bootout "${domain}/${label}" 2>/dev/null; then
  # bootout also fails when the job simply isn't loaded — only abort if the
  # job is provably still there (removing the plist then would strand it).
  if launchctl print "${domain}/${label}" >/dev/null 2>&1; then
    echo "error: ${label} is still loaded and could not be stopped — not removing the plist." >&2
    echo "Retry, or log out and back in, then run this script again." >&2
    exit 1
  fi
  echo "(was not loaded)"
fi

if [[ -f "${dest}" ]]; then
  rm "${dest}"
  echo "removed ${dest}"
else
  echo "no plist at ${dest}"
fi

echo "done — audio is back on the direct path. ~/.config/loudini/ is left in place."
