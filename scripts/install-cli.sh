#!/usr/bin/env bash
# Symlink the built loudini-helper into ~/.local/bin as `loudini`. No sudo needed.
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper="${repo_dir}/helper/loudini-helper"
bin_dir="${HOME}/.local/bin"
link="${bin_dir}/loudini"

if [[ ! -x "${helper}" ]]; then
  echo "error: ${helper} is missing or not executable. Build it first:" >&2
  echo "  cd helper && swiftc -O -parse-as-library -o loudini-helper \\" >&2
  echo "    loudini-helper.swift ControlFile.swift DDC.swift \\" >&2
  echo "    -framework CoreAudio -framework AudioToolbox -framework Foundation -framework IOKit" >&2
  exit 1
fi

mkdir -p "${bin_dir}"
ln -sfn "${helper}" "${link}"
echo "linked ${link} -> ${helper}"

case ":${PATH}:" in
  *":${bin_dir}:"*) ;;
  *)
    echo "note: ${bin_dir} is not on your PATH. Add this line to your shell profile:"
    echo '  export PATH="$HOME/.local/bin:$PATH"'
    ;;
esac
