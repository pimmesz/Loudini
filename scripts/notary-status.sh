#!/usr/bin/env bash
# Show Apple's notarization verdicts. Notarization is a fully automated scan (no human
# review), so a healthy submission goes In Progress -> Accepted in ~2-15 min; anything
# stuck for hours means Apple's notary service is stalling, not that someone is reviewing.
#
#   scripts/notary-status.sh                 # recent submissions + their verdicts
#   scripts/notary-status.sh --watch         # same, re-polled every 60s (Ctrl-C to stop)
#   scripts/notary-status.sh <submission-id> # one submission's status
#   scripts/notary-status.sh <submission-id> log   # Apple's log — WHY it was Invalid
#
# Auth: the 'loudini' notarytool keychain profile by default (NOTARY_PROFILE=... to
# override), or NOTARY_APPLE_ID / NOTARY_TEAM_ID / NOTARY_APP_PW.
set -euo pipefail

profile="${NOTARY_PROFILE:-loudini}"
if [[ -n "${NOTARY_APPLE_ID:-}" && -n "${NOTARY_TEAM_ID:-}" && -n "${NOTARY_APP_PW:-}" ]]; then
  auth=(--apple-id "${NOTARY_APPLE_ID}" --team-id "${NOTARY_TEAM_ID}" --password "${NOTARY_APP_PW}")
else
  auth=(--keychain-profile "${profile}")
fi

case "${1:-}" in
  --watch)
    # Poll in-process: macOS has no `watch` binary.
    while true; do
      printf '\n===== %s =====\n' "$(date +%H:%M:%S)"
      xcrun notarytool history "${auth[@]}" || true
      sleep 60
    done
    ;;
  "")
    xcrun notarytool history "${auth[@]}"
    ;;
  *)
    if [ "${2:-}" = "log" ]; then
      # Only available once the submission reaches a terminal state.
      xcrun notarytool log "$1" "${auth[@]}" /dev/stdout
    else
      xcrun notarytool info "$1" "${auth[@]}"
    fi
    ;;
esac
