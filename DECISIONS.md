# Decisions

Durable record of design calls that an audit would otherwise keep re-raising.
Each entry: the decision, why, the rejected alternatives, and any accepted residual.

## 2026-07-22 — Brightness source of truth = `brightness.json`

**Decision.** `~/.config/loudini/brightness.json` is the single shared source of
truth for external-display brightness. Both frontends write it under
`brightness.lock`: the CLI (`helper/DDC.swift`) already did; the menu-bar app
(`menubar/DDCBrightness.swift`) now writes it on every apply too. The app seeds a
relative step from its own monitor read at `rediscover` (the monitor is the
physical ground truth and reflects CLI changes).

**Why.** The CLI computes relative nudges from `brightness.json`; before this the
app never wrote it, so after an app slider change a `loudini brightness up/down`
stepped from a stale base and jumped the monitor (e.g. 68% → 56%). Making the app
publish the cache closes that.

**Rejected.**
- *(b) CLI always reads the live monitor, cache as fallback only* — pays a
  latency-bound DDC read per nudge and lets held-key repeats collapse into one step.
- *(c) Route all brightness through the long-lived daemon* — cleanest single-writer
  but a large change to an audio-focused daemon; not worth it for brightness.

**Accepted residual.** The app UI reflects an *out-of-band* CLI brightness change
only at the next `rediscover` (screen-parameter change / relaunch), not live — it
does not poll. Low-frequency and pre-existing.

## 2026-07-22 — Stream Deck plugin stays OUT of `control.lock`

**Superseded 2026-10-06** (see "Stream Deck plugin writes through the bundled CLI" below).
The premise was wrong: the plugin's merge rewrites the whole file, so it can revert a
per-app write that lands between its read and its rename.

**Decision.** The Node plugin (`plugin/src/control.ts`) does NOT take the
cross-process `control.lock` that the Swift daemon/CLI/menu-bar app now hold around
their `control.json` read-modify-write. It keeps its atomic temp-file + rename write.

**Why.** Node core has no `flock(2)`. Real mutual exclusion against the Swift
`flock(2)` would need either a native-binding dependency (e.g. `fs-ext`, which pulls
in node-gyp/native compilation and complicates the bundled plugin) or switching
*both* sides to a different lock primitive (a bigger, riskier change than the finding
warrants). The plugin writes only master `gain`/`muted` — its `writeControl` merges
and preserves the per-app `apps` map — so it can never cause the per-app lost-update
that motivated `control.lock`; that class is fully closed by the Swift-side lock. The
only residual is a plugin-vs-daemon master-gain race, which is last-writer-wins —
exactly what `control.json`'s contract already documents as acceptable.

**Revisit if.** The plugin gains the ability to write the `apps` map, or a native
file-lock dependency becomes justified for another reason.

## 2026-07-22 — LaunchAgent keeps unconditional `KeepAlive=true`

**Decision.** `launchd/gg.pim.loudini.plist` keeps `KeepAlive=true`, accepting the
known ~10s restart-loop + log spam that happens when the menu-bar app's bundled
daemon already holds `daemon.lock` (the agent's daemon loses the flock, `exit(0)`s,
and is relaunched until it wins the lock).

**Why not `KeepAlive={SuccessfulExit=false}`.** It stops the spam but introduces a
worse failure: the app terminates its bundled daemon on quit
(`applicationWillTerminate`), and a `SuccessfulExit=false` agent that already gave up
(clean `exit(0)`) is never relaunched — so after the app quits, NO daemon runs at all
and audio control is offline until next login. The restart loop, ugly as it is, is
also the mechanism that lets the agent take over once the app frees the lock.

**Proper fix (done 2026-10-06).** A losing daemon with no terminal attached (launchd,
the app, the Stream Deck plugin) now blocks on `daemon.lock` (`flock(LOCK_EX)`) before
touching any audio and takes over when the winner exits, so there is no restart loop
and no dormancy; `KeepAlive=true` stays for crashes. A daemon started from a terminal
still exits at once with the "already running" message.

## 2026-10-06: Verdicts on the 2026-10-05 audit needs-decision items

Recorded with audit-decide so the next audit run finds them instead of re-raising them.
Finding ids are the audits' own (ledger `~/.claude/audit-ledger/Loudini/*-2026-10-05*.md`).

### Stream Deck plugin writes through the bundled CLI (do now)

`plugin/src/control.ts:50` (check-then-act-1, file-write-races-1). Key presses call
`loudini-helper up/down/mute`, which take `control.lock`; the plugin's own `writeControl`,
`nudge` and `toggleMute` go. Costs one process spawn per press.

### Plugin contract tests run on Node 24 in CI (do now)

`plugin/src/control.ts` (TSA-12, refactor type-safety-1, error-handling-1..4). A
`node --test` harness under a temp HOME, run on Node 24 in CI. The shipped plugin runtime
stays on Node 20 until the SDK upgrade below.

### Stream Deck SDK, TypeScript and Node runtime upgrades (deferred)

`plugin/package.json:16`, `:21`, `manifest.json:11` (unmaintained-1, upgrade-debt-1..3).
Semver-major, and nothing here can smoke-test a real Stream Deck.
**Trigger:** the next plugin change that gets a hands-on deck test, or a Marketplace
submission. Order: @elgato/streamdeck 1.x to 3.x, then TypeScript, with Node 24 alongside.

### Update check stays on by default, disclosed (do now)

`menubar/LoudiniApp.swift:71` (lawful-basis-and-eprivacy-1, third-party-sharing-1).
Keep default-on; disclose it in README and on the landing page, and say plainly that the
request carries your IP address to GitHub and nothing else.

### Cloud release workflow removed (do now)

`.github/workflows/release.yml` (ci-pipelines-1..3, secrets-config-1, docs claims-features-7).
Releases are local-only via `scripts/release.sh`; the dormant workflow and the BUILD.md
secrets section go, so no signing secret can ever be readable by a branch workflow.

### GitHub Actions stay on major tags (accepted)

`.github/workflows/ci.yml:53` (ci-pipelines-4, lockfile-integrity-3). First-party
actions/* and pnpm/action-setup, and CI holds no secrets. SHA pinning plus Dependabot is
upkeep without a matching risk. **Revisit if** a third-party action or a secret enters CI.

### Daemon-health gaps, decided after the render-stall investigation

`helper/loudini-helper.swift:366`, `:921`, `:1011` (signal-less-failure-paths-1,
health-and-readiness-checks-1, -2), first deferred, then decided the same day with the
daemon.log and `pmset -g log` evidence:

- **Render stalls are a sleep artefact (do now).** Since 2026-09-29, 40 of 41 stalls
  fired during DarkWake: the built-in speakers do not run, Chrome still reports output,
  and the uptime clock advances, so the watchdog tore the pipeline down and rebuilt it all
  night. One rebuild after a real wake never started (2026-10-06 10:43 local). Every one of
  the 314 "never produced an IO callback" stalls had the Chrome per-app tap. Fix: the
  watchdog notices a sleep gap (wall clock ahead of uptime) and pauses stall checks for
  90 s of uptime after it.
- **Silent render with a moving heartbeat (do now, diagnostics only).** The IOProc counts
  callbacks that lacked a tap buffer, and the log reports it when no complete callback
  arrives within 60 s. Decide on a behaviour change once that counter shows non-zero.
- **Hung HAL call and unbounded SIGTERM wait (accepted).** 79 days of daemon.log show no
  hang. **Revisit if** a running daemon stops logging or updating status.json, or quit
  hangs.

### Extract the CLI resolver and the stall math for tests (do now)

`helper/loudini-helper.swift:1470` and `:1058` (TSA-13, TSA-14). Move `resolveAppTarget`,
the CLI argument guards, the stall verdict and the stall-rebuild delay into Foundation-only
files and table-test them in `scripts/test.sh`.

### Identity per-app overrides are pruned on write (do now)

`helper/ControlFile.swift` writeControl (perf NEW-2). An override of 100% unmuted is the
same as none, so it is not written. That drops the extra per-app tap an identity entry
keeps alive.

### AppRoster full rescan per notification (accepted)

`helper/loudini-helper.swift:665` (perf NPLUS1-04). Off the engine queue and never
measured. **Revisit if** a counter or profile shows roster refreshes matter.

### Per-app rows are not sticky (accepted)

`SPEC-per-app-volume.md:65` (claims-features-5). Rows drop 5 s after an app goes quiet,
overrides or not; the spec bullet is marked not implemented. Overrides still persist in
control.json and Reset App Volumes shows whenever any exist.

### Brightness docs narrowed to the recorded residual (do now)

`README.md:199` (claims-features-2). The 2026-07-22 brightness decision stands; README and
BUILD.md say the CLI steps from brightness.json and the app steps from its own level.

### Logging hygiene items (do now)

`helper/loudini-helper.swift:891` (signal-less-failure-paths-4), `menubar/LoudiniApp.swift:1117`
(health-and-readiness-checks-3), `plugin/src/plugin.ts:41` (error-tracker-5,
error-handling-3), `plugin/src/actions.ts:13` (error-handling-4).

### Landing page advisories (do now)

`docs/index.html:193`, `:258`, `:345` (contrast-visual-2, semantic-structure-2, -3).

### Different-build daemon shown as a tooltip (do now)

The menu-bar Output row gets a warning tooltip when the running daemon's build differs from
the app's; `loudini doctor` already warns. No new menu row.

## 2026-10-08: Verdicts on the 2026-10-06 concurrency audit needs-decision items

Recorded with audit-decide. Finding ids are the audit's own (ledger
`~/.claude/audit-ledger/Loudini/concurrency-audit-2026-10-06-063bd81.md`); lead ids are
the three Swift findings its gate dropped, checked by hand.

### control.lock wait stays bounded, now logged (do now, residual accepted)

`helper/ControlFile.swift:219` (check-then-act-1, file-write-races-1). After 100 x 5 ms
`withControlLock` still runs the read-modify-write without the lock, so a stuck holder
cannot freeze the daemon's engine queue. It now logs a warning when that happens.
**Accepted residual:** a holder stopped for more than 0.5 s (SIGSTOP, a debugger, heavy
swapping) can lose one other writer's volume step, mute or per-app edit. README and
BUILD.md say the lock is bounded. **Revisit if** daemon.log shows the warning outside a
debugging session.

### A waiting daemon polls and steps aside for a newer build or a dead parent (do now)

`helper/loudini-helper.swift:1917` (overlapping-runs-1, cancellation-cleanup-1). A daemon
that lost `daemon.lock` tries `LOCK_NB` once a second instead of a blocking wait. Before
each try it exits if its own executable changed on disk, so its spawner starts the new
build, and, when it was not started by launchd, if its parent is gone. A daemon that
already holds the lock keeps running as before. Cost: takeover can lag by up to 1 s.

### The CLI prints the level after up, down and mute (do now)

`plugin/src/actions.ts:44` (ordering-1). The plugin paints the key from that output
instead of a status.json the daemon has not rewritten yet.

### daemon.log rotates by copy and truncate (do now)

`menubar/LoudiniApp.swift:1243` (lead file-write-races-2). A rename stranded every other
daemon that holds the log open in daemon.log.1, and the next rotation deleted it. Copy
then truncate keeps them on the live file; a few ms of lines can be lost in between.

### A press during the 0.3 s rebuild after an output switch loses to the restore (accepted)

`helper/loudini-helper.swift:1076`, `:1286` (leads ordering-2, shared-mutable-state-1).
Bringing back the fixed-level output's own level is the point; a press in that window is
pressed again. A stale ControlWatcher snapshot applied after the restore heals on the next
100 ms poll. **Revisit if** a switch is seen to land at the wrong level and stay there.

