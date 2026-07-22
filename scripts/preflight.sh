#!/usr/bin/env bash
# Fail a bad release in seconds, not in an hour. release.sh builds, Developer-ID signs,
# and only THEN sits in a long Apple notary poll — so a trivial version mismatch used to
# surface after all of that. These checks are cheap and deterministic:
#
#   1. the five version homes agree with menubar/Info.plist (the source of truth), and this
#      version's CHANGELOG section is actually written rather than the bump-version skeleton
#   2. no hardcoded version literal is left in scripts/package-dmg.sh, which would print
#      a stale publish command the moment the version moves
#
# Reports EVERY failure in one run rather than stopping at the first, so one fix-up pass
# is enough. Safe to run any time; release.sh runs it before it builds anything.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "${script_dir}/.." && pwd)"
cd "${repo_dir}"

failures=0
fail() { echo "ERROR: $*" >&2; failures=$((failures + 1)); }

# bump-version.sh writes the CHANGELOG section as a TODO skeleton and then runs preflight to
# prove the version write landed, so it — and only it — passes this flag. release.sh runs
# preflight with no arguments, so the release gate itself can never be waved through.
allow_placeholder=0
if [[ "${1:-}" == "--allow-changelog-placeholder" ]]; then allow_placeholder=1; fi

# Source of truth for the version — the plist read + N.N.N validation live in version.sh.
# Explicit `|| exit 1`: a failing command substitution in an assignment does not trip set -e.
version="$(bash "${script_dir}/version.sh")" || exit 1

# --- 1. the other four homes must match ----------------------------------------
pkg_version="$(python3 -c "import json; print(json.load(open('plugin/package.json'))['version'])")"
[[ "${pkg_version}" == "${version}" ]] ||
  fail "plugin/package.json is ${pkg_version}, expected ${version}."

# Stream Deck mandates a 4-segment version, so the manifest carries N.N.N.0.
manifest_version="$(python3 -c "import json; print(json.load(open('plugin/gg.pim.loudini.sdPlugin/manifest.json'))['Version'])")"
[[ "${manifest_version}" == "${version}.0" ]] ||
  fail "Stream Deck manifest is ${manifest_version}, expected ${version}.0."

# The landing-page footer is the version every visitor sees.
grep -qF "&middot; v${version}<" docs/index.html ||
  fail "docs/index.html footer does not show v${version}."

# release.sh pulls this release's notes out of the CHANGELOG by heading, so the section must
# exist AND be written. The bump-version.sh skeleton is a literal TODO line — without this it
# passes the gate and gets published verbatim as the public release notes.
notes="$(awk -v ver="${version}" '
  $0 ~ "^## \\[" ver "\\]" { flag=1; next }
  /^## \[/ { flag=0 }
  flag { print }
' CHANGELOG.md)"
if ! grep -qF "## [${version}]" CHANGELOG.md; then
  fail "CHANGELOG.md has no '## [${version}]' section — release notes would be empty."
elif [[ -z "${notes//[[:space:]]/}" ]]; then
  fail "CHANGELOG.md's '## [${version}]' section is empty — release notes would be empty."
elif [[ "${allow_placeholder}" -eq 0 ]] && grep -qF 'TODO: describe this release' <<<"${notes}"; then
  fail "CHANGELOG.md's '## [${version}]' section still holds the bump-version.sh TODO placeholder — write the release notes."
fi

# --- 2. no version literal may survive in package-dmg.sh -----------------------
# It must derive the version from the plist; a baked-in one goes silently wrong on the
# next bump (it printed 'gh release create v0.2.0' regardless of the actual version).
# Whole-line comments are skipped, so prose about macOS 14.4.1 can't block a good release,
# but every line of actual code is checked — including a literal inside a string, which a
# naive "strip from the first #" would hide. Deliberately strict about the leftovers: a
# trailing "# see 1.2.3" on a code line trips this. A false alarm costs one visible edit,
# a miss silently ships a stale publish command.
if literals="$(grep -vE '^[[:space:]]*#' scripts/package-dmg.sh | grep -nE '[0-9]+\.[0-9]+\.[0-9]+')"; then
  fail "scripts/package-dmg.sh has a hardcoded version literal — derive it from Info.plist:"
  printf '%s\n' "${literals}" >&2
fi

if [[ "${failures}" -gt 0 ]]; then
  echo "preflight FAILED (${failures} problem(s)) — fix these before releasing; 'scripts/bump-version.sh <N.N.N>' fixes version drift." >&2
  exit 1
fi

echo "preflight OK — v${version} agrees across Info.plist, plugin package + manifest, site footer, and CHANGELOG."
