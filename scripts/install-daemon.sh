#!/usr/bin/env bash
# Install the Loudini daemon as a per-user LaunchAgent (no sudo) and start it.
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper="${repo_dir}/helper/loudini-helper"
template="${repo_dir}/launchd/gg.pim.loudini.plist"
dest="${HOME}/Library/LaunchAgents/gg.pim.loudini.plist"
label="gg.pim.loudini"
domain="gui/$(id -u)"

if [[ ! -x "${helper}" ]]; then
  echo "error: ${helper} is missing or not executable. Build it first:" >&2
  echo "  cd helper && swiftc -O -parse-as-library -o loudini-helper \\" >&2
  echo "    loudini-helper.swift ControlFile.swift \\" >&2
  echo "    -framework CoreAudio -framework AudioToolbox -framework Foundation" >&2
  exit 1
fi

mkdir -p "${HOME}/Library/LaunchAgents" "${HOME}/.config/loudini"

# Keep a copy of whatever was there before we overwrite it.
if [[ -f "${dest}" ]]; then
  backup="${dest}.backup-$(date +%Y%m%d-%H%M%S)"
  cp "${dest}" "${backup}"
  echo "existing plist backed up to ${backup}"
fi

# Escape the paths for XML (& < >) and then for the sed replacement (\ & |),
# render to a temp file IN THE DESTINATION DIR (same filesystem -> atomic mv),
# and lint BEFORE touching the destination — a path that breaks the XML must
# not clobber a working plist.
esc() {
  printf '%s' "$1" \
    | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
    | sed -e 's/[&|\\]/\\&/g'
}
tmp_plist="$(mktemp "${dest}.XXXXXX")"
sed -e "s|__HELPER__|$(esc "${helper}")|g" -e "s|__HOME__|$(esc "${HOME}")|g" \
  "${template}" > "${tmp_plist}"
if ! plutil -lint -s "${tmp_plist}"; then
  rm -f "${tmp_plist}"
  echo "error: generated plist failed lint (unusual characters in a path?)" >&2
  exit 1
fi
mv "${tmp_plist}" "${dest}"
echo "installed ${dest}"

echo "unloading any previous instance: launchctl bootout ${domain}/${label}"
launchctl bootout "${domain}/${label}" 2>/dev/null || true
echo "loading + starting the daemon:   launchctl bootstrap ${domain} ${dest}"
launchctl bootstrap "${domain}" "${dest}"

cat <<'EOF'

Loudini daemon installed and started (it now survives logout/reboot).

FIRST RUN: macOS will ask for the "System Audio Recording" permission —
System Settings -> Privacy & Security -> Screen & System Audio Recording.
Loudini captures app audio only to re-render it at your chosen volume;
nothing is recorded or stored. Until you grant it, the daemon retries
every 2 s and your audio keeps playing on the normal path (fail-open).

Logs:      ~/.config/loudini/daemon.log
Try it:    loudini set 50   (after scripts/install-cli.sh)
Uninstall: scripts/uninstall-daemon.sh
EOF
