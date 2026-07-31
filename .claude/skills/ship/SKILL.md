---
name: ship
description: Loudini's ship gate. Runs this repo's real gate (app build, 55 contract tests, preflight, plugin typecheck+build), gates on a cross-review, prepares the commit — and, when the change is release-worthy, walks the full version-bump → CHANGELOG → push → release.sh sequence. Prepares commands; never runs git writes and never publishes. Examples: "ship", "ship it", "ship and release". Pass "skip-review" to bypass the cross-review, "commit-only" to skip the gate, "release" to go straight to the release sequence.
argument-hint: "[optional: skip-review | commit-only | release]"
---

# Ship gate — Loudini

Project-level skill: **shadows the global `ship`**. Everything the generic version
discovers by reading the repo is pre-encoded here, plus the release sequence, which
the generic version does not cover.

**Read-only except for running the gate. NEVER run `git` write commands, NEVER run
`scripts/release.sh`, NEVER run `xcrun notarytool`/`stapler` — prepare them for the
user.** Publishing is theirs to trigger.

## The gate (mirrors CI exactly)

`.github/workflows/ci.yml` has three jobs and `preflight.yml` a fourth. Run all four,
cheapest first so failures surface early:

```sh
bash scripts/preflight.sh                  # seconds — version agreement + release notes
bash scripts/test.sh                       # 55 contract checks over ControlFile
(cd plugin && pnpm install --frozen-lockfile && pnpm typecheck && pnpm build)
menubar/build-app.sh                       # slowest — compiles daemon + app
```

Any step red → STOP, show the trimmed failure, offer to fix. Do not prepare a commit.

`shellcheck -S warning scripts/*.sh` is not in CI but the scripts are held to it —
run it when the diff touches `scripts/`.

## Repo-specific caveats — surface the ones that apply

- **`build-app.sh` starts with `rm -rf Loudini.app`.** Running the gate destroys a
  stapled app. If a notarized bundle is being preserved for a release, copy it OUT of
  the repo first (`.gitignore` only covers `menubar/Loudini.app/`, so an in-repo backup
  would dirty the tree and trip `release.sh`'s clean check).
- **The contract is frozen.** `~/.config/loudini/control.json` and `status.json` are
  declared "the universal API: do not break it" in BUILD.md. `status.json`'s `apps[]`
  is keyed on `bundleID`; changing a key silently drops users' saved per-app volumes.
  `plugin/src/control.ts` mirrors the shape BY HAND — a field change must land there too.
- **The daemon must stay fail-open.** No change may leave a path where a crash or a
  wedged pipeline mutes audio permanently.
- **The IOProc is a real-time callback.** No locks, no allocation, no I/O on that path.
- **Tests must never touch the real `~/.config/loudini`.** `scripts/test.sh` isolates via
  `CFFIXED_USER_HOME` — `$HOME` does NOT work, `homeDirectoryForCurrentUser` ignores it.
- **The version lives in five files.** Never hand-edit; `scripts/bump-version.sh` writes
  all five and preflight enforces agreement.

## Cross-review

Same rule as the global skill: run `cross-review review-only` on the diff and treat an
unresolved CRITICAL/HIGH as a block. Weight the audio render path and `scripts/` hardest
— a bug there is either silence for the user or a wrong artifact published under the
maintainer's Developer ID.

## Commit

ONE conventional commit for the whole gated unit. Stage by explicit paths from
`git status --porcelain`; screen for secrets first. Note that `docs/og.png` is binary and
`docs/index.html` references it — they must land together or the share card 404s.

**Write the commands to a UNIQUELY NAMED script and verify its contents at the
destination before telling the user to run it.** Never `/tmp/ship.sh`: that name is
shared across projects, and a stale copy from another repo once caused an unintended
push. Give the script a `cd` + an origin guard:

```sh
origin="$(git remote get-url origin 2>/dev/null || echo '')"
case "${origin}" in *pimmesz/Loudini*) : ;; *) echo "ABORT: origin is '${origin}'" >&2; exit 1 ;; esac
```

Then `grep` the written file for the repo name and confirm the `cd` line before emitting
the run-line.

## Release sequence (this is what the generic skill lacks)

Shipping ≠ releasing. A commit+push publishes nothing — releases are **local-only** via
`scripts/release.sh` (`.github/workflows/release.yml` is dormant, and the signing secrets
were deliberately removed from GitHub).

Ask whether the change warrants a release. If yes:

```sh
scripts/bump-version.sh <N.N.N>     # writes all five version homes + a dated CHANGELOG skeleton
$EDITOR CHANGELOG.md                # replace the TODO — preflight REJECTS the placeholder
git add -u && git commit -m 'chore(release): <N.N.N>'
git push origin main
scripts/release.sh                  # THE IRREVERSIBLE STEP
```

Rules for this sequence:

- **Version choice is the user's.** Recommend one (feature → minor, fix → patch) and say
  why; never bump silently.
- **Offer to draft the CHANGELOG entry** — it is the only step that needs writing rather
  than running, and it becomes the public release notes verbatim. Lead with what a user
  gets, not the internals. Preview the exact bytes `release.sh` will extract:
  `awk -v ver="N.N.N" '$0 ~ "^## \\[" ver "\\]" {f=1;next} /^## \[/{f=0} f' CHANGELOG.md`
- **Push BEFORE `release.sh`.** It refuses unless HEAD is the pushed tip of `origin/main`,
  and it tags with `--target "${head_sha}"`, so the commit must already be on origin.
- **Nothing to push AFTER.** `gh release create` makes the tag server-side, and every
  artifact (`dist/`, `menubar/Loudini.app/`) is gitignored — the tree stays clean.
- **Never run `release.sh` yourself.** It publishes publicly under the user's name.
- **Warn about the Apple wait.** TWO notarizations (app, then DMG). Submissions have taken
  11–18h each during a queue stall. Ctrl-C is safe: a re-run reuses the stapled app when it
  matches current sources, and resumes the DMG submission instead of re-uploading.
- **Verify after**, and say so plainly rather than assuming:
  ```sh
  gh release list --repo pimmesz/Loudini
  curl -sIL -o /dev/null -w "%{http_code}\n" https://github.com/pimmesz/Loudini/releases/latest/download/Loudini.dmg
  ```
  That URL is what loudini.app's download button points at. `200` means shipped.

## Known follow-ups

- The in-app update check only helps users **from the release that introduces it onward** —
  anyone on an older build never learns a new one exists.
- `menubar/Loudini.app` is rebuilt by the gate, so its code identity changes; TCC grants
  survive only with the stable "Loudini Dev" cert (`scripts/make-dev-cert.sh`).
