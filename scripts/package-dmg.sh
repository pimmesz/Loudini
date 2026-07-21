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
# Derived, never hardcoded — the publish hint at the end of this script has to name the
# version actually being built. Read from the plist exactly as release.sh reads it.
version="$(python3 -c "import plistlib; print(plistlib.load(open('${repo_dir}/menubar/Info.plist','rb'))['CFBundleShortVersionString'])")"

# dist/ holds the artifacts; .notary-state remembers which Apple submission id belongs to
# which exact DMG bytes, so an interrupted DMG wait can be resumed instead of re-uploaded.
# DMG only — see notarize() for why the app zip can never resume.
mkdir -p "${dist}"
state_file="${dist}/.notary-state"

# The zip is only an upload container for the app. Delete it on ANY exit — including a
# Ctrl-C during the long Apple wait — so an aborted run leaves no stale artifact behind.
# INT/TERM turn into a normal exit so the EXIT trap actually runs.
cleanup() { rm -f "${dist}/Loudini.zip"; }
trap cleanup EXIT
trap 'exit 130' INT TERM

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

# The Apple submission id we last recorded for these exact bytes, empty when there is none.
# Keyed on the file's digest on purpose: changed bytes can never resume a stale submission.
notary_id_for() {
  [[ -f "${state_file}" ]] || return 0
  local digest
  digest="$(shasum -a 256 "$1" | awk '{print $1}')"
  awk -v d="${digest}" '$1 == d { id = $2 } END { if (id != "") print id }' "${state_file}"
}

# Drop whatever we recorded for these bytes. Used when Apple returns a rejected verdict: a
# recorded rejection would be resumed (and re-reported) on every later run, wedging the
# release until someone found and hand-deleted this dotfile.
forget_notary_id() {
  [[ -f "${state_file}" ]] || return 0
  local digest tmp
  digest="$(shasum -a 256 "$1" | awk '{print $1}')"
  tmp="$(mktemp)"
  awk -v d="${digest}" '$1 != d' "${state_file}" > "${tmp}"
  mv "${tmp}" "${state_file}"
}

# --- notarize helper: ride ONE submission across bounded waits, with live status ---------
# Apple's notary queue can be slow enough that a single --wait times out with nothing wrong
# on our end, so submit ONCE and keep waiting on the SAME submission (no re-upload). Each
# 2-min chunk streams live status; between chunks we log elapsed time and the poll count.
# Bounded to 30×2m (60m) so a real Apple stall fails in reasonable time with an actionable
# message.
notarize() {
  local file="$1"
  local label="${2:-$(basename "$1")}"
  local resume="${3:-}"
  local sub id out waited=0 max_waits=30 chunk=2m nstart=$SECONDS mins errors=0 max_errors=5

  # Resume rather than re-upload when Apple already has these exact bytes — that turns a
  # Ctrl-C'd or timed-out wait into one more poll instead of another full round trip. Only
  # the caller that passes `resume` gets this, and only the DMG does: the app zip is deleted
  # on every exit and the app it is made from is rebuilt whenever it isn't stapled, so a zip
  # digest can never repeat and its state rows would be dead weight.
  id=""
  if [[ -n "${resume}" ]]; then
    id="$(notary_id_for "${file}")"
  fi
  if [[ -n "${id}" ]]; then
    log "notarize ${label}: Apple already has these bytes — resuming submission ${id} (no re-upload)."
  else
    log "notarize ${label}: uploading $(basename "${file}") to Apple…"
    sub="$(xcrun notarytool submit "${file}" "${notary_auth[@]}" --no-wait 2>&1)" || {
      printf '%s\n' "${sub}" >&2; echo "ERROR: notarytool submit failed for ${label}." >&2; return 1; }
    id="$(awk '/^ *id: /{print $2; exit}' <<<"${sub}")"
    [ -n "${id}" ] || { printf '%s\n' "${sub}" >&2; echo "ERROR: no submission id for ${label}." >&2; return 1; }
    if [[ -n "${resume}" ]]; then
      printf '%s %s\n' "$(shasum -a 256 "${file}" | awk '{print $1}')" "${id}" >> "${state_file}"
    fi
  fi
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
      # Forget it, so a fixed re-run uploads fresh bytes instead of resuming this verdict.
      forget_notary_id "${file}"
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
# Skip the rebuild when the app on disk is already finished. build-app.sh opens with
# `rm -rf "${app:?}"`, so an unconditional rebuild destroys a stapled app and buys another
# 30-60m Apple wait for work Apple already accepted. "Finished" = this version, stapled, AND
# built from the sources as they are now (step 2 below still proves it is Developer-ID
# signed). Without that last part a source fix made since the last run would be silently
# left out of the published DMG. FORCE_REBUILD=1 rebuilds anyway.
app_ready=""
inputs_file="${dist}/.app-inputs"

# Fingerprint every input the app is built from: the sources, the files build-app.sh copies
# in or signs with, AND build-app.sh itself — it decides the compile list and the signing
# flags, so editing it changes the product. Hashing the SET (names + contents) rather than
# comparing mtimes is what makes a DELETED source count: removing a file leaves nothing
# "newer" to find, but it does change this hash.
app_inputs_hash() {
  find "${repo_dir}/menubar" "${repo_dir}/helper" -maxdepth 1 -type f \
    \( -name '*.swift' -o -name '*.plist' -o -name '*.icns' -o -name '*.png' \
       -o -name '*.entitlements' -o -name '*.sh' \) \
    -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256 | awk '{print $1}'
}
inputs_now="$(app_inputs_hash)"

if [[ -z "${FORCE_REBUILD:-}" && -d "${app}" ]]; then
  app_version="$(python3 -c "import plistlib; print(plistlib.load(open('${app}/Contents/Info.plist','rb'))['CFBundleShortVersionString'])" 2>/dev/null || true)"
  inputs_built="$(cat "${inputs_file}" 2>/dev/null || true)"
  if [[ "${inputs_built}" != "${inputs_now}" ]]; then
    log "build inputs changed since the app was built — rebuilding."
  elif [[ "${app_version}" == "${version}" ]] && xcrun stapler validate "${app}" >/dev/null 2>&1; then
    app_ready=1
    log "app is v${version}, stapled and built from these exact inputs — reusing (FORCE_REBUILD=1 to rebuild)."
  fi
fi
if [[ -z "${app_ready}" ]]; then
  log "building release app…"
  "${repo_dir}/menubar/build-app.sh"
  # Record what it was built FROM, only after a successful build.
  printf '%s\n' "${inputs_now}" > "${inputs_file}"
fi

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
if [[ -n "${app_ready}" ]]; then
  log "app is already stapled — skipping notarization."
elif [ -z "${SKIP_NOTARIZE:-}" ]; then
  ditto -c -k --keepParent "${app}" "${dist}/Loudini.zip"
  notarize "${dist}/Loudini.zip" "app"
  log "stapling the app…"
  xcrun stapler staple "${app}"
else
  log "SKIP_NOTARIZE set — skipping app notarization + staple."
fi

# --- 4. make + sign the DMG (drag-to-Applications) -----------------------------
# Keep the DMG on disk only when the app wasn't rebuilt AND Apple already has those exact
# bytes: rebuilding it (or re-signing it) changes the bytes and orphans that submission.
if [[ -n "${app_ready}" && -f "${dmg}" && -n "$(notary_id_for "${dmg}")" ]]; then
  log "reusing the existing DMG — Apple already has these bytes."
else
  log "building the DMG…"
  stage="$(mktemp -d)"
  cp -R "${app}" "${stage}/"
  ln -s /Applications "${stage}/Applications"
  rm -f "${dmg}"
  hdiutil create -volname "Loudini" -srcfolder "${stage}" -ov -format UDZO "${dmg}" >/dev/null
  rm -rf "${stage}"

  log "signing the DMG…"
  codesign --force --timestamp --sign "${devid}" "${dmg}"
fi

# --- 5. notarize + staple the DMG so it validates offline ----------------------
if [ -z "${SKIP_NOTARIZE:-}" ]; then
  notarize "${dmg}" "DMG" resume
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
echo "Publish it:  gh release create v${version} \"${dmg}\" --title \"Loudini v${version}\" --notes \"…\""
