# Loudini — per-app volume control (spec)

> Design spec, not built yet. Written in the BUILD.md house style: everything needed is here.
> Read top to bottom before touching code. The master-volume engine described in BUILD.md/README.md
> is the baseline; this extends it.

## Goal

Give each **running audio app** its own volume slider, on top of Loudini's software master. So the
user can pull Spotify to 40% while a Zoom call stays at 100%, all downstream of the same driverless
process tap — no per-app OS control exists today.

**Hard requirement (the reason this spec exists):** the picker must show **only apps that are
actively producing audio right now** — not every app that has ever touched Core Audio. A machine can
accumulate dozens of dormant audio clients; a raw process list is a wall of noise. We want the short
"what's making sound" list, the way macOS's own per-app volume in Sound settings behaves.

## Why the current engine can't just do it

Today the daemon creates **one global tap** that mixes *every* output-producing process into a single
stereo stream, then the IOProc multiplies that mix by **one** master gain (`helper/loudini-helper.swift`,
`stereoGlobalTapButExcludeProcesses` → aggregate → single-`g` render loop). Individual apps are gone
by the time we see samples — there is nothing to attenuate per app.

Per-app gain needs the audio to stay **separated per process** until after we apply gain. Two viable
shapes:

- **A. Per-process taps (recommended).** One `CATapDescription(mono/stereoMixdownOfProcesses: [proc])`
  (or the per-process variant) per app we want to control, each feeding its own gain, all summed to the
  output. Master gain stays as a final multiply on the summed bus. Apps *without* an override just ride
  the existing global tap (excluding the individually-tapped ones) so we never regress the untouched
  case. This is the clean model but multiplies tap/aggregate objects.
- **B. Single global tap, per-process gain in the render loop.** Keep one tap but request a
  **non-mixed** description so each process's audio arrives on its own buffer/stream, then apply the
  right gain per stream inside the IOProc. Fewer HAL objects, but relies on stable per-process stream
  layout in the tap ABL, which is less documented and riskier for the real-time path.

**Recommendation: prototype A first** (it composes with the proven global-tap code and keeps the
fail-open story intact per tap), measure object/CPU cost, fall back to B only if A is too heavy.
This choice is the main open engineering risk and should be settled by measurement, the BUILD.md way.

## The "actively producing audio" filter (the core ask)

Core Audio already tells us this — no metering heuristics needed for the primary signal:

- `kAudioHardwarePropertyProcessObjectList` → every process object Core Audio knows (superset, noisy).
- Per process object, read:
  - `kAudioProcessPropertyIsRunningOutput` (Bool) — **the filter.** True only while the process is
    actively rendering output audio. This is exactly "producing volume." Gate the list on this.
  - `kAudioProcessPropertyPID` → pid, to resolve identity.
  - `kAudioProcessPropertyBundleID` → bundle id for name + icon (via `NSRunningApplication`
    `runningApplication(withProcessIdentifier:)` → `localizedName` / `icon`). Fall back to the process
    name when there's no bundle (CLI/helper audio sources).
- Subscribe to `kAudioProcessPropertyIsRunningOutput` **and** the process-object-list address with
  `AudioObjectAddPropertyListenerBlock`, so the list is push-updated: an app appears the instant it
  starts playing and drops when it stops — no polling, no stale rows.

**Anti-flicker.** Raw `IsRunningOutput` toggles on every gap (pause, silence between tracks, UI
click sounds). To keep the list from twitching:

- **Linger / debounce:** once an app appears, keep it for a short grace window (e.g. ~5 s, tunable)
  after `IsRunningOutput` goes false before removing it, so a paused track or inter-song gap doesn't
  make Spotify vanish and reappear.
- **Sticky overrides:** any app the user has *set a non-100% volume for* stays listed while it's
  running at all (even briefly idle), so their choice remains reachable; it only drops when the app
  fully quits. Non-default per-app gains persist by bundle id across launches (see State).
- Exclude Loudini's own helper/app process objects (already excluded from the tap).

Net: the picker shows a tight, live list — typically the 1–5 things actually making sound — which is
the whole point of the requirement.

## Control contract (the extension)

Keep the "one file, atomic write, daemon polls" contract. `control.json` today is
`{"gain": 0-100, "muted": bool}` (master). Extend, staying backward compatible (absent = defaults):

```jsonc
{
  "gain": 70,            // master, unchanged
  "muted": false,        // master, unchanged
  "apps": {              // NEW — per-app overrides, keyed by bundle id
    "com.spotify.client": { "gain": 40, "muted": false },
    "us.zoom.xos":        { "gain": 100, "muted": false }
  }
}
```

- Keyed by **bundle id** (stable across relaunch) not pid. Daemon resolves bundle id → live process
  object(s) each cycle; one bundle can have several audio processes (Chrome helpers) — apply the gain
  to all of them.
- Absent app ⇒ rides master only (effective gain = master). Effective per-app level = `master × app`.
- Malformed/unknown keys ignored, last-good kept — same rule as today.

`status.json` gains a published, read-only roster so frontends render without their own Core Audio
access:

```jsonc
{
  "gain": 70, "muted": false, "running": true, "pipeline": true, "device": "...", "pid": 1234,
  "apps": [                    // NEW — the live "producing audio" list
    { "bundleID": "com.spotify.client", "name": "Spotify", "pid": 5678,
      "gain": 40, "muted": false, "active": true }
  ]
}
```

`gain`/`muted` per entry echo the **applied** override — the value only appears once that app's
per-app tap is actually built. An app that fell open to the master path (tap create failed, the
aggregate/IOProc build dropped it, or the pipeline is down) receives master-only gain, so its row
reports the default 100/false, never the requested override. `active` reflects `IsRunningOutput`
(vs. lingering in the grace window). Frontends render straight from this array.

## Frontend surface

- **Menu-bar app** (`menubar/LoudiniApp.swift`): under the master slider, a section that renders one
  compact row per entry in `status.json.apps` — app icon + name + a slider + mute toggle. Empty state
  when nothing's playing: a muted "No apps are playing audio" line, *not* a long list. Writing a row
  updates `control.json.apps[bundleID]` via the existing atomic-write helper (`ControlFile.swift`).
  Reuse `StatusWatcher.swift` to react to the roster.
- **CLI** (`helper/loudini-helper.swift` subcommands): additive, master commands unchanged.
  - `loudini apps` — list apps currently producing audio: `bundleID  name  gain  muted`.
  - `loudini app <bundleID|name> set <0-100> | mute | get` — set/toggle/read one app.
  - Name match is a convenience (fuzzy, case-insensitive over the live roster); bundle id is exact.
- **Stream Deck** (`plugin/`): out of scope for v1; the contract additions leave room for a later
  "target app" action. Note only.

## State & persistence

- Per-app overrides persist by bundle id (they live in `control.json`, already user-owned config).
- On daemon start / app relaunch, re-apply a stored override the first time that bundle appears with
  `IsRunningOutput`.
- A "Reset all apps to 100%" affordance (menu + `loudini apps reset`) clears the `apps` map.

## Fail-open & real-time safety (non-negotiable, per BUILD.md)

- Every per-app tap is a private HAL object owned by the daemon: if the daemon dies, coreaudiod tears
  them **all** down and audio returns to the normal direct path — same guarantee as today. No per-app
  path may create a state where a crash leaves an app muted.
- If a per-app tap fails to create, **fall back to routing that app through the master path** (log it),
  never drop its audio. Fail-open extends **past tap creation**: if a tap creates fine but then makes
  the aggregate-device or IOProc build fail, drop **every** per-app tap to the master path and retry
  the pipeline global-only (rather than isolating the single culprit, which would cost an O(n) rebuild
  probe) — the global/master gain path must never be silenced by one bad per-app tap.
- The render loop stays allocation-free and lock-free; per-app gains are plain floats updated by the
  100 ms control poll, read unsynchronized in the IOProc exactly like the master `gain` today.
- Master mute and master gain still apply on top — per-app is strictly a pre-master attenuation.

## Open questions (decide by prototype/measurement)

1. **A vs. B** — settle with a real object-count + CPU measurement on ~5 simultaneous apps.
2. **Tap-object ceiling** — is there a practical limit on simultaneous private taps/aggregates? Test.
3. **Chrome/Electron multi-process** — confirm bundle-id grouping applies one gain across all helpers
   cleanly (Loudini's own multi-process handling not yet exercised this way).
4. **Grace-window length** — tune the linger so pauses don't flicker but quit apps drop promptly.

## Rollout

1. Daemon: publish the live "producing audio" roster to `status.json` (read-only) + `loudini apps`.
   Ships the visible half of the feature with zero render-path risk — validates the filter first.
2. Daemon: per-app gain via approach A behind the `control.json.apps` map; master untouched.
3. Menu-bar per-app rows + persistence + reset.
4. Measure, then decide whether B is worth it.

Phase 1 alone already answers the headline requirement — *only show apps actively producing volume* —
and is the safe first landing.
