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

# --- preflight: the two things only you can set up ---------------------------
devid="$(security find-identity -v -p codesigning 2>/dev/null \
         | grep -o 'Developer ID Application: [^"]*' | head -1 || true)"
if [[ -z "${devid}" ]]; then
  echo "ERROR: no 'Developer ID Application' cert in the keychain." >&2
  echo "       Install it (Xcode → Settings → Accounts → Manage Certificates → + Developer ID Application)." >&2
  exit 1
fi

# Notary auth: direct App Store Connect credentials via env (CI), else a stored
# notarytool keychain profile (the local default). Skipped entirely under SKIP_NOTARIZE
# — a build+sign check needs a signing cert but no notary credentials.
if [ -n "${SKIP_NOTARIZE:-}" ]; then
  notary_auth=()
  notary_desc="(SKIP_NOTARIZE — no notarization)"
elif [[ -n "${NOTARY_APPLE_ID:-}" && -n "${NOTARY_TEAM_ID:-}" && -n "${NOTARY_APP_PW:-}" ]]; then
  notary_auth=(--apple-id "${NOTARY_APPLE_ID}" --team-id "${NOTARY_TEAM_ID}" --password "${NOTARY_APP_PW}")
  notary_desc="App Store Connect credentials (env)"
else
  notary_auth=(--keychain-profile "${profile}")
  notary_desc="keychain profile '${profile}'"
  if ! xcrun notarytool history --keychain-profile "${profile}" >/dev/null 2>&1; then
    echo "ERROR: notarytool profile '${profile}' not found." >&2
    echo "       Run: xcrun notarytool store-credentials ${profile} --apple-id <you> --team-id <TEAMID> --password <app-specific-pw>" >&2
    echo "       (or set NOTARY_APPLE_ID / NOTARY_TEAM_ID / NOTARY_APP_PW for credential auth)." >&2
    exit 1
  fi
fi
echo "signing identity: ${devid}"
echo "notary auth:      ${notary_desc}"

# --- notarize helper: ride ONE submission across bounded waits ----------------
# Apple's notary queue is sometimes slow enough that a single --wait times out with
# nothing wrong on our end (a build once sat "In Progress" for 30 min, then failed).
# So submit once and keep waiting on the SAME submission instead of re-uploading or
# giving up. A genuine rejection dumps Apple's log and fails fast; the total wait is
# bounded (4x15m) so a real outage still fails in reasonable time.
notarize() {
  local file="$1" out rc id waited=0 max_waits=4 chunk=15m

  set +e
  out="$(xcrun notarytool submit "${file}" "${notary_auth[@]}" --no-wait 2>&1)"
  rc=$?
  set -e
  printf '%s\n' "${out}"
  [ "${rc}" -eq 0 ] || { echo "ERROR: notarytool submit failed (exit ${rc})." >&2; return "${rc}"; }
  id="$(printf '%s\n' "${out}" | awk '/^ *id: /{print $2; exit}')"
  [ -n "${id}" ] || { echo "ERROR: notarytool submit returned no submission id." >&2; return 1; }

  echo "==> waiting for notarization ${id} (Apple queue can be slow)…"
  while :; do
    set +e
    out="$(xcrun notarytool wait "${id}" "${notary_auth[@]}" --timeout "${chunk}" 2>&1)"
    rc=$?
    set -e
    printf '%s\n' "${out}"
    if [ "${rc}" -eq 0 ]; then
      # Some notarytool versions exit 0 even on a terminal Invalid/Rejected. Surface Apple's
      # log here (instead of a cryptic downstream stapler failure) if the status is bad.
      if grep -qE 'status: (Invalid|Rejected)' <<<"${out}"; then
        echo "ERROR: notarization ${id} was not Accepted; Apple log follows:" >&2
        xcrun notarytool log "${id}" "${notary_auth[@]}" /dev/stdout 2>&1 || true
        return 1
      fi
      return 0
    fi
    waited=$((waited + 1))
    if grep -q 'Timeout of .* reached' <<<"${out}" && [ "${waited}" -lt "${max_waits}" ]; then
      echo "   still processing on Apple's side; continuing to wait (${waited}/${max_waits})…" >&2
      continue
    fi
    echo "ERROR: notarization ${id} did not succeed (exit ${rc}); Apple log follows:" >&2
    xcrun notarytool log "${id}" "${notary_auth[@]}" /dev/stdout 2>&1 || true
    return "${rc}"
  done
}

# --- 1. build (build-app.sh auto-detects the Developer ID → release signing) --
echo "==> building release app…"
"${repo_dir}/menubar/build-app.sh"

# --- 2. verify it really is Developer-ID signed (not ad-hoc / self-signed) ----
# Capture first (|| true), then match the string. Piping codesign into `grep -q` under
# `set -o pipefail` makes the check hinge on codesign's exit code (SIGPIPE from grep -q's
# early exit, or a transient non-zero right after signing) — which spuriously fails even
# when the app IS Developer-ID signed. Matching the captured output depends only on the
# Authority line being present, which is what we actually want to verify.
app_sig="$(codesign -dvv "${app}" 2>&1 || true)"
if ! grep -q "Authority=Developer ID Application" <<<"${app_sig}"; then
  echo "ERROR: ${app} is not Developer-ID signed — build-app.sh fell back to dev/ad-hoc signing." >&2
  exit 1
fi
codesign --verify --deep --strict --verbose=2 "${app}"

# --- 3. notarize the app (SKIP_NOTARIZE=1 → build+sign check only) -------------
mkdir -p "${dist}"
if [ -z "${SKIP_NOTARIZE:-}" ]; then
  echo "==> notarizing the app (uploads to Apple, takes a few minutes)…"
  ditto -c -k --keepParent "${app}" "${dist}/Loudini.zip"
  notarize "${dist}/Loudini.zip"
  xcrun stapler staple "${app}"
  rm -f "${dist}/Loudini.zip"
else
  echo "==> SKIP_NOTARIZE set — skipping app notarization + staple."
fi

# --- 4. make the DMG (drag-to-Applications) -----------------------------------
echo "==> building the DMG…"
stage="$(mktemp -d)"
cp -R "${app}" "${stage}/"
ln -s /Applications "${stage}/Applications"
rm -f "${dmg}"
hdiutil create -volname "Loudini" -srcfolder "${stage}" -ov -format UDZO "${dmg}" >/dev/null
rm -rf "${stage}"

# --- 5. sign (+ notarize + staple) the DMG so it validates offline -------------
echo "==> signing the DMG…"
codesign --force --timestamp --sign "${devid}" "${dmg}"
if [ -z "${SKIP_NOTARIZE:-}" ]; then
  echo "==> notarizing the DMG…"
  notarize "${dmg}"
  xcrun stapler staple "${dmg}"
  # stapler validate is reliable — let it abort the script if the DMG won't
  # validate offline. spctl is advisory (flaky in some environments) so warn only.
  xcrun stapler validate "${dmg}"
  spctl -a -t open --context context:primary-signature "${dmg}" || echo "  (spctl assessment inconclusive — verify manually before publishing)"
else
  echo "==> SKIP_NOTARIZE set — built + Developer-ID-signed ${dmg} (not notarized)."
fi
echo
echo "✅ ${dmg}"
echo
echo "Publish it:  gh release create v0.2.0 \"${dmg}\" --title \"Loudini v0.2.0\" --notes \"…\""
