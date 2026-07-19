#!/usr/bin/env bash
# Cut a Loudini release from YOUR Mac — THE release path. Build + notarize + staple +
# publish the current menubar/Info.plist version as a GitHub Release. Releases are
# local-only: the release.yml workflow is a dormant manual (workflow_dispatch) fallback,
# not auto-triggered. Re-running is safe — it bails if the version is already published
# and refuses a foreign/stale draft. Babysit or Ctrl-C the Apple notary wait.
#
# One-time prereqs (see BUILD.md -> Release signing & notarization):
#   - a "Developer ID Application" cert in your login keychain
#   - a notarytool profile 'loudini'  (xcrun notarytool store-credentials loudini …)
#     or export NOTARY_APPLE_ID / NOTARY_TEAM_ID / NOTARY_APP_PW
#   - gh authenticated with push access
#
# Usage: with your version bump already committed + pushed to main, run this.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "${script_dir}/.." && pwd)"
dmg="${repo_dir}/dist/Loudini.dmg"
cd "${repo_dir}"

# Timestamped, elapsed-time logging so you can see how long each phase takes.
_t0=$SECONDS
log() { printf '[%s +%2dm%02ds] %s\n' "$(date +%H:%M:%S)" "$(( (SECONDS-_t0)/60 ))" "$(( (SECONDS-_t0)%60 ))" "$*"; }

# --- preflight: on main, clean, and pushed --------------------------------------
# The release tag must point at a commit that exists on origin, so HEAD has to be
# the pushed tip of main before we publish.
[ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] || { echo "ERROR: not on main." >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "ERROR: working tree not clean — commit first." >&2; exit 1; }
git fetch -q origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || {
  echo "ERROR: HEAD is not the pushed tip of origin/main — 'git push origin main' first, then re-run." >&2
  exit 1
}

version="$(python3 -c "import plistlib; print(plistlib.load(open('menubar/Info.plist','rb'))['CFBundleShortVersionString'])")"
[[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "ERROR: CFBundleShortVersionString '${version}' is not a strict N.N.N version." >&2
  exit 1
}

# Published release tags (drafts excluded; a stuck draft from a prior failed run stays
# retryable). gh failing here trips set -e and aborts (fail closed) rather than guessing
# "no release" — same as the workflow's check job.
tags="$(gh api --paginate 'repos/{owner}/{repo}/releases?per_page=100' --jq '.[] | select(.draft == false) | .tag_name')"

# Already published this version? Nothing to do.
if printf '%s\n' "${tags}" | grep -qxF "v${version}"; then
  echo "v${version} is already published — bump menubar/Info.plist to cut a new one."
  exit 0
fi

# Downgrade guard: only publish when this is the highest published vN.N.N, so an
# accidentally-lowered Info.plist version can't take over 'latest'.
highest="$(printf '%s\n' "${tags}" | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sed 's/^v//' | sort -V | tail -1 || true)"
if [ -n "${highest}" ] && [ "$(printf '%s\n%s\n' "${version}" "${highest}" | sort -V | tail -1)" != "${version}" ]; then
  echo "ERROR: v${version} is lower than the latest release v${highest} — refusing (bump the version)." >&2
  exit 1
fi

# Mispoint guard: gh ignores --target when a tag already exists, so a pre-existing
# v${version} tag at a DIFFERENT commit would publish the wrong source. Resolve any exact
# tag and refuse unless it already points at HEAD. matching-refs returns 200 + [] when the
# tag is absent, so a real API error trips set -e and fails closed. (version is validated
# N.N.N, so splicing it into jq is safe.)
head_sha="$(git rev-parse HEAD)"
ref="$(gh api "repos/{owner}/{repo}/git/matching-refs/tags/v${version}" \
  --jq '.[] | select(.ref == "refs/tags/v'"${version}"'") | "\(.object.type) \(.object.sha)"')"
if [ -n "${ref}" ]; then
  tag_sha="${ref##* }"
  [ "${ref%% *}" = "tag" ] && tag_sha="$(gh api "repos/{owner}/{repo}/git/tags/${tag_sha}" --jq '.object.sha')"
  if [ "${tag_sha}" != "${head_sha}" ]; then
    echo "ERROR: tag v${version} already exists at ${tag_sha} but HEAD is ${head_sha} — refusing to mispoint the release." >&2
    exit 1
  fi
fi

log "cutting release v${version} — building + notarizing (per-phase timing below; Ctrl-C is safe)…"
"${script_dir}/package-dmg.sh"

# Release notes = this version's CHANGELOG section, if present.
notes="$(mktemp)"
trap 'rm -f "${notes}"' EXIT
awk -v ver="${version}" '
  $0 ~ "^## \\[" ver "\\]" { flag=1; next }
  /^## \[/ { flag=0 }
  flag { print }
' CHANGELOG.md > "${notes}" || true
[ -s "${notes}" ] || echo "Signed & notarized build. See CHANGELOG.md." > "${notes}"

# Fresh create, or resume a stuck DRAFT from a prior failed run.
log "publishing v${version} to GitHub…"
if gh release view "v${version}" >/dev/null 2>&1; then
  # Only resume OUR stuck draft AT THIS COMMIT. Anything else — a published release, or a
  # draft whose target is a different commit (stale after a same-version fix, or a concurrent
  # CI run at another commit) — could publish a tag that doesn't match this DMG's source, so
  # refuse rather than clobber. (gh can't move a tag once publishing has created it.)
  rel_draft="$(gh release view "v${version}" --json isDraft --jq '.isDraft')"
  rel_target="$(gh release view "v${version}" --json targetCommitish --jq '.targetCommitish')"
  if [ "${rel_draft}" != "true" ] || [ "${rel_target}" != "${head_sha}" ]; then
    echo "ERROR: a v${version} release already exists (draft=${rel_draft}, target=${rel_target}) that isn't this HEAD build — 'gh release delete v${version} --cleanup-tag --yes' and re-run." >&2
    exit 1
  fi
  gh release upload "v${version}" "${dmg}" --clobber
  gh release edit "v${version}" --draft=false
else
  gh release create "v${version}" "${dmg}" \
    --target "${head_sha}" \
    --title "Loudini v${version}" \
    --notes-file "${notes}"
fi

log "✅ published v${version} in $(( (SECONDS - _t0) / 60 ))m: https://github.com/pimmesz/Loudini/releases/tag/v${version}"
