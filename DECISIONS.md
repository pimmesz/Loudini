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

**Proper fix (deferred).** Make the single-instance loser BLOCK on `daemon.lock`
(`flock(LOCK_EX)`) instead of `exit(0)`, so it waits and takes over when the winner
exits — no spam, no dormancy. That's a daemon-behaviour change needing launchd
runtime testing, so it's out of scope for the audit-fix pass.
