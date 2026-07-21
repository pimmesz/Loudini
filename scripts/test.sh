#!/usr/bin/env bash
# Loudini's test gate — contract regression tests for helper/ControlFile.swift.
#
# ControlFile.swift is the one file linked into BOTH the daemon and the menu-bar app, and it
# encodes the invariants BUILD.md calls non-negotiable: atomic writes, lenient parsing,
# clamping, and telling the truth about a dead daemon. It is pure Foundation file+JSON with no
# Core Audio, so it can be tested with nothing but swiftc — no audio hardware, no TCC grants,
# no XCTest, no SPM, no new dependencies. Runs in about a second; safe to run any time.
#
# SAFETY — read before changing anything here. The tests WRITE control.json and status.json.
# ControlFile.swift resolves those from FileManager.homeDirectoryForCurrentUser, which asks OS
# directory services and therefore IGNORES $HOME: overriding HOME would look like it sandboxed
# the run while actually overwriting the developer's real ~/.config/loudini. CFFIXED_USER_HOME
# is the override CoreFoundation honours. It is exported before the binary starts because
# `configDir` is a lazily initialised global — a setenv() from inside the process could come
# too late and freeze the real path. The test binary re-checks this itself and exits 2 rather
# than run unsandboxed; we prove that guard still works below before trusting it.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "${script_dir}/.." && pwd)"
cd "${repo_dir}"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
binary="${work}/control-file-tests"

echo "compiling contract tests…"
swiftc -parse-as-library -o "${binary}" \
  helper/ControlFile.swift helper/ControlFileTests.swift \
  -framework Foundation

# Prove the safety net before relying on it: with no sandbox the binary must refuse (exit 2).
# Checking the exact code matters — a plain "did it fail?" would also be satisfied by a normal
# test failure (exit 1) and would quietly stop verifying anything.
set +e
env -u CFFIXED_USER_HOME "${binary}" >/dev/null 2>&1
guard_status=$?
set -e
if [[ "${guard_status}" -ne 2 ]]; then
  echo "ERROR: the sandbox guard in helper/ControlFileTests.swift did not refuse an unsandboxed run" >&2
  echo "       (expected exit 2, got ${guard_status}). Refusing to continue: the tests could" >&2
  echo "       overwrite your real ~/.config/loudini." >&2
  exit 1
fi

# A throwaway home for this run only; the trap above deletes it.
home="${work}/home"
mkdir -p "${home}/.config/loudini"
CFFIXED_USER_HOME="${home}" "${binary}"
