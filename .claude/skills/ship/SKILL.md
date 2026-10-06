---
name: ship
description: >-
  Loudini's ship gate. Runs this repo's real gate (preflight, ControlFile contract tests,
  plugin typecheck+build, app build), gates on a cross-review, prepares the commit as a
  runnable script and, when the change is release-worthy, walks the version-bump, CHANGELOG,
  push, release.sh sequence. Prepares commands; never runs git writes and never publishes.
  Examples: "ship", "ship it", "ship and release". Pass "skip-review" to bypass the
  cross-review, "commit-only" to skip the gate, "release" to go straight to the release
  sequence.
argument-hint: "[optional: skip-review | commit-only | release]"
---

# Ship gate, Loudini

Project-level skill: **shadows the global `ship`**. Everything the generic version
discovers by reading the repo is pre-encoded here, plus the release sequence, which
the generic version does not cover. There is no root `package.json`, so the shared
gate resolver has nothing to expand here; the gate below is the whole gate.

**Read-only except for running the gate. NEVER run `git` write commands, NEVER run
`scripts/release.sh`, NEVER run `xcrun notarytool`/`stapler`. Prepare them for the
user.** Read-only git (`status`, `diff`, `log`, `rev-parse`, `var`, `remote get-url`)
you run yourself. Publishing is theirs to trigger.

## The gate (mirrors CI exactly)

`.github/workflows/ci.yml` has three jobs and `preflight.yml` a fourth. Run all four,
cheapest first so failures surface early:

```sh
bash scripts/preflight.sh                  # seconds: version agreement + release notes
bash scripts/test.sh                       # ControlFile contract checks; prints the count
(cd plugin && pnpm install --frozen-lockfile && pnpm typecheck && pnpm test && pnpm build)
menubar/build-app.sh                       # slowest: compiles daemon + app
```

Any step red: STOP, show the trimmed failure, offer to fix. Do not prepare a commit.
Run each step in the foreground with the shell timeout at its maximum; a step that does
not finish is neither red nor green, report it as "did not finish" and stop.

`shellcheck -S warning scripts/*.sh` is not in CI but the scripts are held to it.
Run it when the diff touches `scripts/`.

## Repo-specific caveats, surface the ones that apply

- **`build-app.sh` starts with `rm -rf Loudini.app`.** Running the gate destroys a
  stapled app. If a notarized bundle is being preserved for a release, copy it OUT of
  the repo first (`.gitignore` only covers `menubar/Loudini.app/`, so an in-repo backup
  would dirty the tree and trip `release.sh`'s clean check).
- **The contract is frozen.** `~/.config/loudini/control.json` and `status.json` are
  declared "the universal API: do not break it" in BUILD.md. `status.json`'s `apps[]`
  is keyed on `bundleID`; changing a key silently drops users' saved per-app volumes.
  `plugin/src/control.ts` mirrors the shape BY HAND, so a field change must land there too.
- **The daemon must stay fail-open.** No change may leave a path where a crash or a
  wedged pipeline mutes audio permanently.
- **The IOProc is a real-time callback.** No locks, no allocation, no I/O on that path.
- **Tests must never touch the real `~/.config/loudini`.** `scripts/test.sh` isolates via
  `CFFIXED_USER_HOME`; `$HOME` does NOT work, `homeDirectoryForCurrentUser` ignores it.
- **The version lives in five files.** Never hand-edit; `scripts/bump-version.sh` writes
  all five and preflight enforces agreement.

## Cross-review

Same rule as the global skill: print the diff fingerprint, run `cross-review review-only`
on the diff, and treat an unresolved CRITICAL/HIGH as a block. Weight the audio render
path and `scripts/` hardest: a bug there is either silence for the user or a wrong
artifact published under the maintainer's Developer ID.

## Commit

ONE conventional commit for the whole gated unit. Stage by explicit paths from
`git status --porcelain -uall`; screen for secrets first. Note that `docs/og.png` is
binary and `docs/index.html` references it: they must land together or the share card
404s.

**Write the commands to `/tmp/ship-Loudini.sh` and verify its contents at the
destination before telling the user to run it.** Never `/tmp/ship.sh`: `/tmp` is shared
by every session on this machine, and a stale copy from another repo once caused an
unintended push. The script opens with a terminal guard, a `cd`, an origin guard and a
HEAD guard, then commits from a message file:

```sh
#!/usr/bin/env bash
set -euo pipefail
[[ -t 0 ]] || { echo "run this from your own terminal"; exit 1; }
cd /Users/pimzonneveld/Personal/Loudini

origin="$(git remote get-url origin 2>/dev/null || echo '')"
case "${origin}" in *pimmesz/Loudini*) : ;; *) echo "ABORT: origin is '${origin}'" >&2; exit 1 ;; esac
[[ "$(git rev-parse HEAD)" == "<sha at prep time>" ]] || { echo "ABORT: HEAD moved since this script was prepared"; exit 1; }

echo "<the 2 to 4 line effect summary, so it reaches the terminal>"

git add <explicit paths>
git diff --cached --name-status

msgfile="$(mktemp)"
cat >"$msgfile" <<'EOF'
type(scope): summary
EOF
if grep -qiE '^co-authored-by:|generated with' "$msgfile"; then
  echo "commit message carries AI attribution; edit the script"; exit 1
fi
ident="$(git var GIT_AUTHOR_IDENT)"; echo "author: $ident"
case "$ident" in *contact@pim.gg*|*clawd@pim.gg*)
  echo "unverified git identity; set user.email before shipping"; exit 1;; esac
git commit -F "$msgfile"
rm -f "$msgfile"

git push origin main
```

Rules for that script:

- The message goes to a `mktemp` file, never `-m "..."` and never `msg=$(cat <<'EOF' ...)`:
  bodies carry apostrophes and backticks, and macOS bash 3.2 dies on an apostrophe inside
  a heredoc inside `$( )`.
- The attribution grep stays even though `.githooks/commit-msg` is live
  (`core.hooksPath = .githooks`): the hook rejects attribution but knows nothing about
  the author identity, and GitHub cannot resolve `contact@pim.gg` or `clawd@pim.gg`.
- `echo` a marker before each step so a failure is legible; cleanup, if any, goes last,
  after the push, and pauses for a `y` first.
- Then `grep` the written file for `pimmesz/Loudini` and confirm the `cd` line before
  emitting the run-line. **You write the file. The user runs it.** The run line
  (`bash /tmp/ship-Loudini.sh`) is the last thing in your response.

## Release sequence (this is what the generic skill lacks)

Shipping is not releasing. A commit+push publishes nothing: releases are **local-only**
via `scripts/release.sh`. There is no cloud release workflow, and no signing secret
is stored in GitHub (DECISIONS.md, 2026-10-06).

Ask whether the change warrants a release. If yes:

```sh
scripts/bump-version.sh <N.N.N>     # writes all five version homes + a dated CHANGELOG skeleton
$EDITOR CHANGELOG.md                # replace the TODO; preflight REJECTS the placeholder
git add menubar/Info.plist plugin/package.json plugin/gg.pim.loudini.sdPlugin/manifest.json docs/index.html CHANGELOG.md
git commit -m 'chore(release): <N.N.N>'
git push origin main
scripts/release.sh                  # THE IRREVERSIBLE STEP
```

Rules for this sequence:

- **Version choice is the user's.** Recommend one (feature: minor, fix: patch) and say
  why; never bump silently.
- **Stage the five files by name**, exactly as `bump-version.sh` prints them, never
  `git add -u`: a release commit must carry the bump and nothing else. The message is a
  fixed one-liner, so `-m` is safe here, but the identity check from the ship script
  (`git var GIT_AUTHOR_IDENT`, refuse `contact@pim.gg` / `clawd@pim.gg`) applies before
  it is run.
- **Offer to draft the CHANGELOG entry.** It is the only step that needs writing rather
  than running, and it becomes the public release notes verbatim. Lead with what a user
  gets, not the internals. Preview the exact bytes `release.sh` will extract:
  `awk -v ver="N.N.N" '$0 ~ "^## \\[" ver "\\]" {f=1;next} /^## \[/{f=0} f' CHANGELOG.md`
- **Push BEFORE `release.sh`.** It refuses unless HEAD is the pushed tip of `origin/main`,
  and it tags with `--target "${head_sha}"`, so the commit must already be on origin.
- **Know its other exits** so a stop is read correctly: it exits 0 without doing anything
  when `v<N.N.N>` is already published; it refuses (exit 1) a dirty tree, a branch other
  than `main`, a version lower than the latest published release, an existing
  `v<N.N.N>` tag or draft that points at a different commit, and `SKIP_NOTARIZE` being
  set. Each prints its reason and the fix.
- **Nothing to push AFTER.** `gh release create` makes the tag server-side, and every
  artifact (`dist/`, `menubar/Loudini.app/`) is gitignored, so the tree stays clean.
- **Never run `release.sh` yourself.** It publishes publicly under the user's name.
- **Warn about the Apple wait.** TWO notarizations (app, then DMG). Submissions have taken
  11 to 18h each during a queue stall. Ctrl-C is safe: a re-run reuses the stapled app
  when its recorded input hash still matches the sources (`dist/.app-inputs`), and
  resumes the DMG submission from `dist/.notary-state` instead of re-uploading.
- **Verify after**, and say so plainly rather than assuming:
  ```sh
  gh release list --repo pimmesz/Loudini
  curl -sIL -o /dev/null -w "%{http_code}\n" https://github.com/pimmesz/Loudini/releases/latest/download/Loudini.dmg
  ```
  That URL is what loudini.app's download button points at. `200` means shipped.

## Known follow-ups

- The in-app update check only helps users **from the release that introduces it onward**
  (0.4.0): anyone on an older build never learns a new one exists.
- `menubar/Loudini.app` is rebuilt by the gate, so its code identity changes; TCC grants
  survive only with the stable "Loudini Dev" cert (`scripts/make-dev-cert.sh`).
