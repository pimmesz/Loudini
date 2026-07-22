#!/usr/bin/env bash
# Single source of truth for the release version. Reads CFBundleShortVersionString from
# menubar/Info.plist (its canonical home) and validates it is a strict N.N.N — a typo'd or
# pre-release string (e.g. 0.3.0-beta) sorts as "newer" and would publish an off-scheme
# release. Every release script and the CI workflow call this, so the read + regex live in
# exactly one place. Prints the version on success; exits 1 with a message otherwise.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
plist="${script_dir}/../menubar/Info.plist"

# Pass the plist path as argv, not interpolated into the -c source, so a checkout path
# containing a quote (e.g. .../Pim's Projects/...) can't break the Python literal.
version="$(python3 -c "import plistlib,sys; print(plistlib.load(open(sys.argv[1],'rb'))['CFBundleShortVersionString'])" "${plist}")"
if [[ ! "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "ERROR: CFBundleShortVersionString '${version}' is not a strict N.N.N version." >&2
  exit 1
fi
printf '%s\n' "${version}"
