#!/usr/bin/env bash
# Write the version ONCE. Loudini's version lives in five places that must agree —
# the app plist, the plugin's package.json + Stream Deck manifest, the landing-page
# footer, and the CHANGELOG heading. Hand-editing five files is how they drift, and
# scripts/preflight.sh fails the release when they do. This writes all five.
#
# Backups of every file go to a temp dir (printed before anything is rewritten, so the path
# is known even when the bump fails halfway) — release.sh refuses to run on a dirty tree.
# Prepares the git commands; it never runs git itself.
#
# Usage: scripts/bump-version.sh 0.3.0
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "${script_dir}/.." && pwd)"
cd "${repo_dir}"

version="${1:-}"
# Same strict N.N.N shape release.sh demands of the plist, so a bump can't produce a
# version release.sh will later reject.
[[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "ERROR: need a strict N.N.N version, e.g. 'scripts/bump-version.sh 0.3.0' (got '${version}')." >&2
  exit 1
}

plist="menubar/Info.plist"
pkg="plugin/package.json"
manifest="plugin/gg.pim.loudini.sdPlugin/manifest.json"
site="docs/index.html"
changelog="CHANGELOG.md"

backup_dir="$(mktemp -d "${TMPDIR:-/tmp}/loudini-bump-$(date +%Y%m%d-%H%M%S)-XXXXXX")"
for f in "${plist}" "${pkg}" "${manifest}" "${site}" "${changelog}"; do
  [[ -f "${f}" ]] || { echo "ERROR: ${f} is missing — cannot bump." >&2; exit 1; }
  cp "${f}" "${backup_dir}/${f//\//_}"
done
# Say this up front: everything below rewrites the tree, and a failure mid-way is exactly
# when the path is needed. Slashes in the names became underscores.
echo "Backups of the five version files: ${backup_dir}"

# Rewrite one file through a temp copy. Keeps every edit below identical in shape and
# sidesteps the BSD-vs-GNU `sed -i` argument difference.
rewrite() {
  local file="$1" expr="$2"
  sed -E "${expr}" "${file}" > "${file}.tmp"
  mv "${file}.tmp" "${file}"
}

# The plist is the source of truth, and release.sh reads it with plistlib — so write it
# with plistlib too rather than with a regex that could silently miss. sort_keys=False
# keeps the existing key order, so a bump shows up as a one-line diff.
python3 - "${plist}" "${version}" <<'PY'
import plistlib, sys

path, version = sys.argv[1], sys.argv[2]
with open(path, 'rb') as f:
    data = plistlib.load(f)
data['CFBundleShortVersionString'] = version
with open(path, 'wb') as f:
    plistlib.dump(data, f, sort_keys=False)
PY

# The JSON/HTML files get a targeted line edit rather than a re-serialise, so formatting
# and key order stay exactly as they were.
rewrite "${pkg}" "s/^([[:space:]]*\"version\": \")[^\"]*(\",?)\$/\1${version}\2/"
# Stream Deck requires a 4-segment version, so the manifest carries N.N.N.0.
rewrite "${manifest}" "s/^([[:space:]]*\"Version\": \")[^\"]*(\",?)\$/\1${version}.0\2/"
rewrite "${site}" "s|&middot; v[0-9]+\.[0-9]+\.[0-9]+|\&middot; v${version}|"

# CHANGELOG skeleton above the newest existing section. Skipped when the section already
# exists, so re-running a bump can't produce two headings for one version.
if grep -qF "## [${version}]" "${changelog}"; then
  echo "note: ${changelog} already has a [${version}] section — left as-is."
else
  awk -v ver="${version}" -v today="$(date +%F)" '
    !inserted && /^## \[/ {
      print "## [" ver "] — " today "\n\n### Added\n- TODO: describe this release before running scripts/release.sh.\n"
      inserted = 1
    }
    { print }
  ' "${changelog}" > "${changelog}.tmp"
  mv "${changelog}.tmp" "${changelog}"
fi

# Prove the write actually landed before telling anyone to commit it. On failure all five
# files are ALREADY rewritten, so say so rather than dying and looking like a no-op.
if ! "${script_dir}/preflight.sh" --allow-changelog-placeholder; then
  echo >&2
  echo "ERROR: the five files were already rewritten to ${version}, but preflight failed." >&2
  echo "Fix the problem above and re-run, or restore from ${backup_dir}." >&2
  exit 1
fi

echo
echo "Bumped to ${version}. Backups: ${backup_dir}"
echo "Fill in the CHANGELOG section — release.sh's preflight rejects the TODO placeholder — then:"
echo "  git add ${plist} ${pkg} ${manifest} ${site} ${changelog}"
echo "  git commit -m \"chore(release): ${version}\""
echo "  git push origin main"
echo "  scripts/release.sh"
