#!/usr/bin/env bash
# Build a notarized, stapled Loudini.dmg for 1-click install — the whole
# release pipeline: build (release-signed) → notarize the app → staple → make
# the DMG (drag-to-Applications) → sign + notarize + staple the DMG.
#
# One-time setup first (see BUILD.md → Release signing & notarization):
#   1. A "Developer ID Application" cert in your login keychain.
#   2. A notarytool credential profile:
#        xcrun notarytool store-credentials loudini \
#          --apple-id you@example.com --team-id TEAMID --password <app-specific-pw>
#      (override the profile name with NOTARY_PROFILE=... )
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "${script_dir}/.." && pwd)"
app="${repo_dir}/menubar/Loudini.app"
dist="${repo_dir}/dist"
dmg="${dist}/Loudini.dmg"
profile="${NOTARY_PROFILE:-loudini}"

# Timestamped, elapsed-time logging so you can see where the time actually goes.
_t0=$SECONDS
log() { printf '[%s +%2dm%02ds] %s\n' "$(date +%H:%M:%S)" "$(( (SECONDS-_t0)/60 ))" "$(( (SECONDS-_t0)%60 ))" "$*"; }

# --- preflight: the two things only you can set up ---------------------------
devid="$(security find-identity -v -p codesigning 2>/dev/null \
         | grep -o 'Developer ID Application: [^"]*' | head -1 || true)"
if [[ -z "${devid}" ]]; then
  echo "ERROR: no 'Developer ID Application' cert in the keychain." >&2
  echo "       Install it (Xcode → Settings → Accounts → Manage Certificates → + Developer ID Application)." >&2
  exit 1
fi

# Notary auth: direct App Store Connect credentials via env (CI), else a stored notarytool
# keychain profile (the local default). Skipped under SKIP_NOTARIZE — a build+sign check
# needs a signing cert but no notary credentials.
if [ -n "${SKIP_NOTARIZE:-}" ]; then
  notary_auth=()
  notary_desc="(SKIP_NOTARIZE — no notarization)"
elif [[ -n "${NOTARY_APPLE_ID:-}" && -n "${NOTARY_TEAM_ID:-}" && -n "${NOTARY_APP_PW:-}" ]]; then
  notary_auth=(--apple-id "${NOTARY_APPLE_ID}" --team-id "${NOTARY_TEAM_ID}" --password "${NOTARY_APP_PW}")
  notary_desc="App Store Connect credentials (env)"
else
  notary_auth=(--keychain-profile "${profile}")
  notary_desc="keychain profile '${profile}'"
fi
log "signing identity: ${devid}"
log "notary auth:      ${notary_desc}"

# Fail fast + heads-up: confirm the notary credentials work and Apple is answering BEFORE the
# long build, and surface how the account's recent submissions are doing — several stuck
# "In Progress" with none Accepted is the tell-tale of an Apple-side stall (commonly a pending
# Developer Program License Agreement), so you know before waiting on another one.
if [ -z "${SKIP_NOTARIZE:-}" ]; then
  log "checking notary credentials + Apple reachability…"
  if ! hist="$(xcrun notarytool history "${notary_auth[@]}" 2>&1)"; then
    echo "ERROR: notary auth/reachability check failed:" >&2
    printf '%s\n' "${hist}" >&2
    echo "       Fix: xcrun notarytool store-credentials ${profile} --apple-id <you> --team-id <TEAMID> --password <app-specific-pw>" >&2
    echo "            (or set NOTARY_APPLE_ID / NOTARY_TEAM_ID / NOTARY_APP_PW)." >&2
    exit 1
  fi
  inprog="$(grep -c 'status: In Progress' <<<"${hist}" || true)"
  accepted="$(grep -c 'status: Accepted' <<<"${hist}" || true)"
  log "notary reachable — recent submissions: In Progress=${inprog:-0}, Accepted=${accepted:-0}"
  if [ "${inprog:-0}" -ge 3 ] && [ "${accepted:-0}" -eq 0 ]; then
    log "⚠️  ${inprog} recent submissions stuck 'In Progress', none Accepted — Apple is likely"
    log "    stalling this account (commonly a pending Developer Program License Agreement)."
    log "    Check developer.apple.com/account; a long wait below will probably time out too."
  fi
fi

# --- notarize helper: ride ONE submission across bounded waits, with live status ---------
# Apple's notary queue can be slow enough that a single --wait times out with nothing wrong
# on our end, so submit ONCE and keep waiting on the SAME submission (no re-upload). Each
# 15-min chunk streams live status; between chunks we log elapsed time and the authoritative
# status via `notarytool info`. Bounded to 4×15m so a real Apple stall fails in reasonable
# time with an actionable message.
notarize() {
  local file="$1"
  local label="${2:-$(basename "$1")}"
  local sub id out waited=0 max_waits=30 chunk=2m nstart=$SECONDS mins errors=0 max_errors=5

  log "notarize ${label}: uploading $(basename "${file}") to Apple…"
  sub="$(xcrun notarytool submit "${file}" "${notary_auth[@]}" --no-wait 2>&1)" || {
    printf '%s\n' "${sub}" >&2; echo "ERROR: notarytool submit failed for ${label}." >&2; return 1; }
  id="$(awk '/^ *id: /{print $2; exit}' <<<"${sub}")"
  [ -n "${id}" ] || { printf '%s\n' "${sub}" >&2; echo "ERROR: no submission id for ${label}." >&2; return 1; }
  log "notarize ${label}: submission ${id} — polling Apple every 2m for up to $((max_waits * 2))m…"

  while :; do
    set +e
    out="$(xcrun notarytool wait "${id}" "${notary_auth[@]}" --timeout "${chunk}" 2>&1)"
    set -e
    mins=$(( (SECONDS - nstart) / 60 ))
    # Verdict straight from the CAPTURED wait output — reliable, and doesn't depend on a
    # follow-up `info` call that could transiently fail and false-declare a result. (A
    # here-string, not a pipe, so `grep` can't SIGPIPE the producer under set -o pipefail.)
    if grep -q 'status: Accepted' <<<"${out}"; then
      log "notarize ${label}: ✅ Accepted after ${mins}m."
      return 0
    fi
    if grep -qE 'status: (Invalid|Rejected)' <<<"${out}"; then
      log "notarize ${label}: ❌ not Accepted after ${mins}m — Apple log follows:"
      xcrun notarytool log "${id}" "${notary_auth[@]}" /dev/stdout 2>&1 || true
      return 1
    fi
    if grep -q 'Timeout of .* reached' <<<"${out}"; then
      # Genuine timeout: still In Progress. Consume one poll of the bounded 60m budget.
      errors=0
      waited=$((waited + 1))
      if [ "${waited}" -lt "${max_waits}" ]; then
        log "notarize ${label}: still In Progress after ${mins}m (poll ${waited}/${max_waits}) — Apple hasn't returned a verdict…"
        continue
      fi
      log "notarize ${label}: GAVE UP after ${mins}m — Apple never returned a verdict for ${id}."
      log "  Uploads are accepted but never processed = an Apple-side stall, not your build."
      log "  Check developer.apple.com/account for a pending agreement, then:"
      log "    xcrun notarytool history --keychain-profile ${profile}"
      return 1
    fi
    # No terminal status AND no timeout message → `notarytool wait` itself errored (network/
    # auth blip). Don't spend the poll budget on it; back off and retry a bounded number of
    # times, so a transient outage can't false-fail an in-flight (or already-Accepted) build.
    errors=$((errors + 1))
    if [ "${errors}" -ge "${max_errors}" ]; then
      echo "ERROR: notarytool wait kept erroring (${errors}×) after ${mins}m — giving up. Last output:" >&2
      printf '%s\n' "${out}" >&2
      return 1
    fi
    log "notarize ${label}: notarytool wait errored (retry ${errors}/${max_errors}); backing off 30s…"
    sleep 30
  done
}

# --- 1. build (build-app.sh auto-detects the Developer ID → release signing) --
log "building release app…"
"${repo_dir}/menubar/build-app.sh"

# --- 2. verify it really is Developer-ID signed (not ad-hoc / self-signed) ----
# Capture first (|| true), then match the string. Piping codesign into `grep -q` under
# `set -o pipefail` makes the check hinge on codesign's exit code (SIGPIPE from grep -q's
# early exit, or a transient non-zero right after signing) — spuriously failing even when the
# app IS Developer-ID signed. Matching the captured output depends only on the Authority line
# being present, which is what we actually want to verify.
app_sig="$(codesign -dvv "${app}" 2>&1 || true)"
if ! grep -q "Authority=Developer ID Application" <<<"${app_sig}"; then
  echo "ERROR: ${app} is not Developer-ID signed — build-app.sh fell back to dev/ad-hoc signing." >&2
  exit 1
fi
codesign --verify --deep --strict --verbose=2 "${app}"
log "app is Developer-ID signed + valid."

# --- 3. notarize the app (SKIP_NOTARIZE=1 → build+sign check only) -------------
mkdir -p "${dist}"
if [ -z "${SKIP_NOTARIZE:-}" ]; then
  ditto -c -k --keepParent "${app}" "${dist}/Loudini.zip"
  notarize "${dist}/Loudini.zip" "app"
  log "stapling the app…"
  xcrun stapler staple "${app}"
  rm -f "${dist}/Loudini.zip"
else
  log "SKIP_NOTARIZE set — skipping app notarization + staple."
fi

# --- 4. make the DMG (drag-to-Applications) -----------------------------------
log "building the DMG…"
stage="$(mktemp -d)"
cp -R "${app}" "${stage}/"
ln -s /Applications "${stage}/Applications"
rm -f "${dmg}"
hdiutil create -volname "Loudini" -srcfolder "${stage}" -ov -format UDZO "${dmg}" >/dev/null
rm -rf "${stage}"

# --- 5. sign (+ notarize + staple) the DMG so it validates offline -------------
log "signing the DMG…"
codesign --force --timestamp --sign "${devid}" "${dmg}"
if [ -z "${SKIP_NOTARIZE:-}" ]; then
  notarize "${dmg}" "DMG"
  log "stapling + validating the DMG…"
  xcrun stapler staple "${dmg}"
  # stapler validate is reliable — let it abort if the DMG won't validate offline. spctl is
  # advisory (flaky in some environments) so warn only.
  xcrun stapler validate "${dmg}"
  spctl -a -t open --context context:primary-signature "${dmg}" || log "(spctl assessment inconclusive — verify manually before publishing)"
else
  log "SKIP_NOTARIZE set — built + Developer-ID-signed ${dmg} (not notarized)."
fi
log "✅ done in $(( (SECONDS - _t0) / 60 ))m — ${dmg}"
echo
echo "Publish it:  gh release create v0.2.0 \"${dmg}\" --title \"Loudini v0.2.0\" --notes \"…\""
