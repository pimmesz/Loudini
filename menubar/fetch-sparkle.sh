#!/usr/bin/env bash
# Fetch the pinned Sparkle release (the in-app updater framework plus its signing tools)
# into vendor/, check it against the pinned checksum, and print the directory. Cached, so
# only the first run needs the network. Lives in menubar/ so a version bump here changes
# the app's input hash and package-dmg.sh rebuilds instead of reusing a stapled app.
set -euo pipefail

version="2.10.0"
sha256="c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c"

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dir="${repo_dir}/vendor/sparkle-${version}"

if [[ ! -d "${dir}/Sparkle.framework" ]]; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' EXIT
  url="https://github.com/sparkle-project/Sparkle/releases/download/${version}/Sparkle-${version}.tar.xz"
  echo "fetching Sparkle ${version}…" >&2
  curl -fsSL --retry 3 -o "${tmp}/sparkle.tar.xz" "${url}"
  if ! echo "${sha256}  ${tmp}/sparkle.tar.xz" | shasum -a 256 -c - >/dev/null 2>&1; then
    echo "ERROR: Sparkle ${version} from ${url} does not match the pinned checksum." >&2
    exit 1
  fi
  mkdir -p "${tmp}/x" "${repo_dir}/vendor"
  tar -xJf "${tmp}/sparkle.tar.xz" -C "${tmp}/x"
  rm -rf "${dir}"
  mv "${tmp}/x" "${dir}"
fi
printf '%s\n' "${dir}"
