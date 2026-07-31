# Loudini build plan (agent brief)

> **Status: all four phases shipped (0.1.0, now 0.4.1).** This file is the architecture and contract
> reference, not a to-do list. The build plan below is kept as the record of how it was assembled.
>
> This file is a self-contained brief for an AI agent working **inside `~/Personal/Loudini`**.
> It has no memory of the design conversation, and everything needed is here. Read it top to bottom
> before touching code.

## What Loudini is

A free, open-source **macOS 14.4+** utility that adds a software **master output volume** to any Mac
audio output. It exists because many pro audio interfaces (the **Focusrite Scarlett 2i2** and most
fixed-level interfaces/DACs) expose no software or OS volume at all: the macOS volume keys show the
crossed-out "no volume" HUD and do nothing. Loudini gives those outputs a real, keyboard-drivable
volume.

**The engine** is a driverless Core Audio **process tap** (already built + verified): a Swift daemon
taps every output-producing process except itself, mutes their direct path (`.mutedWhenTapped`), and
re-renders the mix to the current default output through an IOProc that multiplies each sample by a
software gain. It **fails open**: if the daemon dies, `coreaudiod` tears down the private tap/aggregate
and audio returns to normal. No driver, no admin, no kext.

## The architecture: one core, many thin frontends (read this twice)

The **product is the daemon + a one-file control contract.** Every user-facing thing is a thin frontend
that writes that one file. The daemon has no idea who wrote it.

```
  keyboard vol keys ─┐
   (Karabiner / BTT / ├─► CLI:  loudini up|down|mute|set 50|get ─┐
    skhd / Raycast)   │                                          │  atomic write
  menu-bar app ───────┤  (natively grabs the volume keys)        ├─► ~/.config/loudini/control.json
   (zero-config)      │                                          │       │  daemon polls every 100 ms
  Stream Deck plugin ─┘  (thin TS wrapper)                      ─┘       ▼
                                                                    loudini-helper applies gain
                                                                    (Core Audio process tap)
```

**All of it shipped in one pass.** The daemon came first; the remaining three frontends (CLI +
LaunchAgent, menu-bar app, and Stream Deck plugin) landed together so Loudini shipped complete. The
phases below were a **dependency order**, not a stopping point: the menu-bar app reuses the CLI's
atomic-write helper, and both the LaunchAgent and the Stream Deck plugin ship the daemon binary.

| # | Piece | Serves | Status |
|---|-------|--------|--------|
| 1 | Daemon (the tap engine) | everything | ✅ done, verified |
| 2 | **CLI subcommands + LaunchAgent** | anyone, bind volume keys via any hotkey tool | ✅ shipped 0.1.0 |
| 3 | Menu-bar app (grabs volume keys **+ the visual layer**) | everyone: zero-config + on-screen feedback | ✅ shipped 0.1.0 |
| 4 | Stream Deck plugin (thin wrapper) | Stream Deck owners | ✅ shipped 0.1.0 |

## How to work (this brief is written for fable)

- **You are strongest at fast, native macOS/Swift iteration and at *measuring* what you build.** You
  wrote this daemon and proved it with RMS metering. Work the same way: after every change, **verify by
  measurement and by ear** instead of assuming. Prototype quickly, instrument, confirm.
- **Use GPT-5.6 Codex as an independent adversarial reviewer** for the risky code (see the
  *Cross-review* section). You are fast; a second, different strong model catching a real-time-safety or
  concurrency bug is worth more than a third self-review. This is a genuine cross-check, not a rubber
  stamp.
- Keep the daemon **fail-open** at all times: no change may leave a path where a crash mutes audio
  permanently.

## Read the existing scaffold first

- `helper/loudini-helper.swift`: daemon source. Note the existing arg parsing (`--device <UID>`, `-h`)
  near the bottom, and the control/status file IO. You'll extend the arg parsing in Phase 1.
- `helper/loudini-helper`: the compiled arm64 daemon+CLI binary. **Gitignored, so a fresh clone has
  none. Build it first with `menubar/build-app.sh`**, the single source of the build command (source
  list, frameworks, and the `-target` that pins the macOS 14.4 floor); building it by hand risks
  omitting a file. Until it exists, `scripts/install-cli.sh` and `scripts/install-daemon.sh` exit 1
  and `plugin/build.mjs` warns.
- `plugin/src/control.ts`: the TS side of the contract. Exports `readControl()`/`writeControl(c)`/
  `readStatus()`/`nudge(delta)`/`toggleMute()`. Mirror this behavior in the Swift CLI so both frontends
  agree exactly (clamp 0-100; `nudge`/`up`/`down` also **un-mutes**).
- `plugin/src/actions.ts`, `plugin/src/helper.ts`: the Stream Deck frontend (Phase 3).
- `plugin/gg.pim.loudini.sdPlugin/manifest.json`: Elgato manifest, `UUID gg.pim.loudini`.

## The contract (the universal API: do not break it)

- **`~/.config/loudini/control.json`** holds `{"gain": <int 0-100>, "muted": <bool>, "apps"?: {"<bundleID>":
  {"gain": <int 0-100>, "muted": <bool>}}}`. Any frontend WRITES this. The daemon reads it every 100 ms
  (lenient parse: bad/partial JSON keeps the last good value).
  **A writer that owns only `gain`/`muted` MUST read-modify-write, never replace the document.**
  Emitting just `{"gain":…,"muted":…}` erases the `apps` map and every per-app override with it.
- **`~/.config/loudini/status.json`** holds `{"gain","muted","running","pipeline","device","pid","reason"?,"apps"}`.
  `pipeline` is the capture pipeline's health (a daemon can be `running:true` with `pipeline:false` when
  the System Audio Recording grant is missing). `pid` is what readers probe to catch a hard-killed
  daemon: treat the file as `running:false` when that process is gone. Omitting either is how a frontend
  reports a dead engine as fully working. The daemon WRITES this atomically on every change (and
  `running:false` on shutdown). Frontends READ it to show the live level. `apps` is the live read-only
  roster of processes producing audio right now (`kAudioProcessPropertyIsRunningOutput`):
  `[{bundleID,name,pid,gain,muted,active}]`. See `SPEC-per-app-volume.md`. `loudini apps` prints it.
- **`~/.config/loudini/brightness.json`** holds `{"percent": <int 0-100>}`. The single shared source of
  truth for external-display brightness: the CLI (`helper/DDC.swift`) and the menu-bar app
  (`menubar/DDCBrightness.swift`) both write it under `brightness.lock` on every apply, so a relative
  step never runs off a stale base. See `DECISIONS.md`.
- **`~/.config/loudini/control.lock`** guards the read-modify-write itself. The atomic rename stops a
  torn file but not a lost update: a per-app override written between another writer's read and its
  rename vanishes. Every Swift frontend wraps its RMW in an exclusive `flock(2)` on this file
  (`withControlLock` in `ControlFile.swift`). The Node plugin is the documented exception, because
  Node has no `flock(2)`: it writes only master `gain`/`muted` and merges the keys it does not own,
  which narrows the lost-update window but does not close it. See `DECISIONS.md`.
  `brightness.lock` plays the same role for `brightness.json`.
- **All writes to `control.json` MUST be atomic** (write a temp file in the same dir, then `rename()`),
  because up to three frontends may write it concurrently and the daemon reads it mid-write. This is the
  #1 thing to get right and the #1 thing to have Codex check.

**Gate:** `scripts/test.sh`, the contract regression tests (`helper/ControlFileTests.swift`). Run it
after any change to `helper/ControlFile.swift`; `ci.yml`'s `test` job runs it on every push and PR that
touches a non-docs path. It pins the invariants above: per-app overrides survive a master-only write,
lenient parsing keeps the last good value, gains clamp to 0-100, a dead daemon can't claim
`running:true`, and `atomicWrite` leaves no `.tmp` behind. It writes to a throwaway home via
`CFFIXED_USER_HOME` (**not** `$HOME`, which `homeDirectoryForCurrentUser` ignores) so it can never
touch your real `~/.config/loudini`.

---

## Phase 1: CLI + LaunchAgent (the unlock)

Goal: your friend with a Scarlett and **no Stream Deck** can bind his keyboard's Volume Up/Down/Mute to
Loudini in two minutes.

### 1a. Fold a CLI into the daemon binary

Extend `loudini-helper`'s arg parsing so **one binary does both jobs**:

- `loudini-helper` (no args, or `--device <UID>`) → run the daemon (current behavior, unchanged).
- `loudini-helper up [step]` → gain += step (default 6), clamp 0-100, **un-mute**, atomic-write `control.json`, exit 0.
- `loudini-helper down [step]` → gain -= step (default 6), clamp, un-mute, atomic-write, exit 0.
- `loudini-helper mute` → toggle `muted`, atomic-write, exit 0.
- `loudini-helper set <0-100>` → set gain (clamp), atomic-write, exit 0.
- `loudini-helper get` → print current level, reading `status.json` if present (ground truth) else
  `control.json`; print e.g. `gain=42 muted=false running=true pipeline=true device="Scarlett 2i2 USB"`; exit 0.

Key point: **the subcommands never touch Core Audio**. They only read/modify/atomic-write
`control.json` and exit instantly. The already-running daemon applies the change on its next 100 ms
poll. This keeps the CLI safe, fast, and dependency-free.

### 1b. Make it callable as `loudini`

Add `scripts/install-cli.sh` that symlinks the built binary to `~/.local/bin/loudini` (create the dir;
warn if `~/.local/bin` isn't on `PATH`). Then users type `loudini up`, etc. Do **not** require sudo.

### 1c. LaunchAgent to keep the daemon alive

Something must keep the daemon *running* or writes to `control.json` do nothing. Provide:

- `launchd/gg.pim.loudini.plist`: a LaunchAgent that runs `loudini-helper` (daemon mode) with
  `RunAtLoad` + `KeepAlive`, and logs stdout/stderr to `~/.config/loudini/daemon.log`.
- `scripts/install-daemon.sh`: copies the plist to `~/Library/LaunchAgents/`, `launchctl bootstrap`s /
  loads it, and prints the one-time **System Audio Recording** permission note (see Gotchas).
- `scripts/uninstall-daemon.sh`: `launchctl bootout` + remove the plist (clean teardown).

Never auto-`launchctl load` without the user running the script themselves. Print what it will do.

### 1d. Keyboard-binding recipe (docs)

In `README.md`, give a copy-paste **Karabiner-Elements** example mapping the hardware volume keys
(`f10`/`f11`/`f12` → `mute`/`down`/`up`) to `loudini mute|down|up`, plus a one-liner noting the same works
from BetterTouchTool, skhd, or Raycast. This is what makes Loudini usable "in a lot of settings."

### Phase 1 verification (measure, don't assume)

1. Start the daemon. `loudini set 30` → confirm `control.json` shows 30 **and** audio drops (by ear +,
   ideally, `LOUDINI_METER=1` RMS ≈ 0.30×). `loudini up` a few times → rises. `loudini mute` → silence,
   again → restored. `loudini get` prints the live level.
2. Hammer it: run `loudini up` and `loudini down` in a tight loop from two shells at once; confirm
   `control.json` is never left as torn/invalid JSON and the daemon never logs a parse error storm
   (proves the atomic write).
3. Load the LaunchAgent, log out/in (or `launchctl kickstart`), confirm the daemon comes back.

---

## Phase 2: Menu-bar app (grabs volume keys + is Loudini's visual layer)

A native macOS menu-bar app in `menubar/` (SwiftUI `MenuBarExtra` or AppKit `NSStatusItem`) that gives
everyone "my volume keys just work now" with no hotkey tool, **and is the piece that shows how loud
Loudini currently is.**

### 2a. Grab the hardware volume keys

- Install a `CGEventTap` (session tap) for `NSSystemDefined` / `NX_SYSDEFINED` events, handle keycodes
  `NX_KEYTYPE_SOUND_UP` (0) / `NX_KEYTYPE_SOUND_DOWN` (1) / `NX_KEYTYPE_MUTE` (7), **consume** them
  (return `nil` from the callback so macOS doesn't show its useless crossed-out HUD), and call the same
  atomic `control.json` nudge/mute logic as the CLI (share the code, do not reimplement it).
- Requires **Accessibility** permission (`AXIsProcessTrusted`): detect it, guide the user to
  System Settings → Privacy & Security → Accessibility on first run, degrade gracefully (menu + slider
  still work) if not yet granted.
- Re-enable the tap on `kCGEventTapDisabledByTimeout`; never block the main thread in the callback.
- Owns the daemon: spawn it if not running (or defer to the LaunchAgent if installed), and quit cleanly.
- Well-trodden (SoundSource / BeardedSpice do the same key-tap), but the real-time and permission edges
  are exactly where a second reviewer earns its keep. **Have Codex review the tap.**

### 2b. The visual layer: "how loud is Loudini right now?"

This app is where the user *sees* the level. Three surfaces, all driven off `status.json` (the daemon's
ground truth), so they reflect changes from **any** frontend (CLI, Stream Deck, or this app's own keys):

- **Menu-bar indicator**: the status-item icon/title always shows the current level, either a small
  volume glyph whose fill tracks the gain or a compact `42%` / muted state. Updates whenever
  `status.json` changes (watch it with a file-system event source or a light poll).
- **Dropdown slider**: a `0-100` slider bound to the level. Dragging it writes `control.json`
  (atomic), and it also *reflects* external changes. Include a mute toggle and the current output device
  name (from `status.json`).
- **On-screen HUD**: a transient, borderless, click-through overlay (like macOS's own volume HUD) that
  appears for ~1 s on **every** level change and then fades. Because it's triggered by `status.json`
  changes, pressing a Stream Deck key or running `loudini down` in a terminal shows the HUD too. It
  replaces the native HUD we suppress in 2a. Keep it lightweight and non-focus-stealing
  (`NSWindow` with `.statusBar`/`.floating` level, `ignoresMouseEvents = true`).

### Phase 2 verification

Grant Accessibility, press the keyboard volume keys → audio changes, the menu-bar indicator updates, the
HUD appears, and **no** macOS HUD shows. Then run `loudini down` from a terminal → the menu-bar indicator
and HUD react too (proving the visual layer is status-driven, not key-driven). Revoke Accessibility → app
still opens, slider still works. Confirm two frontends driving `control.json` at once never corrupt it.

---

## Phase 3: Stream Deck plugin (thin wrapper)

Complete the existing TS scaffold in `plugin/`. It's the thinnest frontend: it just writes `control.json`
on keypress and paints the level (`42%` / `🔇`) on the key faces, its own bit of the visual layer.

- `plugin/src/plugin.ts`: register the three action instances (`streamDeck.actions.registerAction`),
  `ensureHelper(...)`, a ~1 s `setInterval` calling `refreshAll()` on each so faces track the level, then
  `streamDeck.connect()`; add `unhandledRejection`/`uncaughtException` handlers that log and **continue**
  (a crash resets the board).
- `plugin/package.json` (`type: module`, pnpm, deps `@elgato/streamdeck`, devDeps `esbuild` + `typescript`),
  `plugin/tsconfig.json` (`target: ES2022`, TypeScript 5 **standard** decorators; do NOT add
  `experimentalDecorators`/`useDefineForClassFields`, they break `@action` typechecking),
  `plugin/build.mjs` (esbuild bundle `src/plugin.ts` → `.sdPlugin/bin/plugin.js`,
  **paths resolved relative to the script's own dir**, then copy `../helper/loudini-helper` into
  `.sdPlugin/bin/` and `chmod 0o755` so the plugin ships its own daemon; if the binary is missing, warn +
  print the swiftc line, don't fail).
- `plugin/.gitignore` (`node_modules/`, `.sdPlugin/bin/`, `*.log`, `.DS_Store`).
- Placeholder icons the manifest needs: `.sdPlugin/imgs/actions/{vol-up,vol-down,mute}.png` (**72×72**) and
  `.sdPlugin/imgs/plugin/marketplace.png` (**288×288**). Use real dimensions or the Elgato validator
  rejects them.

### Phase 3 verification

`cd plugin && pnpm install && pnpm build` succeeds and `.sdPlugin/bin/` holds **both** `plugin.js` and an
executable `loudini-helper`. Report honestly; don't claim success you didn't observe.

---

## Cross-review with Codex (GPT-5.6): do this on the risky code

After **Phase 1's Swift changes** and **Phase 2's CGEventTap**, before calling either done, get an
independent review from the **`codex` MCP tool** (the same one `/cross-review` uses):

- Call `codex` with `sandbox: "read-only"`, `approval-policy: "never"`, `cwd`: the repo root, `model`:
  omit for the pinned default or set `gpt-5.6-sol`. In the prompt, name the changed files, tell it to read
  them directly (Codex often won't run `git` under its sandbox), and demand a falsifiable findings list.
  Capture the `threadId`; use `codex-reply` on the same thread to push back on findings.
- **Have it hunt, specifically:**
  - `control.json` **write atomicity / TOCTOU**: can a concurrent CLI + Stream Deck + menu-bar write tear
    the file or lose an update? Is the temp-then-rename correct and same-filesystem?
  - **Real-time safety** in the audio IOProc: any lock, allocation, or file IO on the render thread
    (there must be none) if you touched the daemon's hot path.
  - **CGEventTap**: correct event type mask, correct consume (return `nil`), re-enable on
    `kCGEventTapDisabledByTimeout`, and no main-thread blocking.
  - **launchd plist** correctness: keys, `KeepAlive` semantics, label matching the bootout path.
  - **Fail-open** preserved: no new path where a crash leaves audio muted.
- Verify each finding yourself against the code, drop the ones you can refute, fix the ones that hold, then
  re-measure. Note in your final report what Codex flagged and what you did about it.

## Gotchas you MUST carry into code + docs

- **Background Music (biggest conflict):** BGM must be quit/uninstalled. With BGM as the default output the
  daemon double-captures and feeds back. Loudini *replaces* BGM, so say so prominently in the README.
- **TCC (System Audio Recording):** process taps need this grant for the *responsible* process. Under the
  LaunchAgent it's the daemon's context; under the Stream Deck plugin it's the Stream Deck app; under the
  menu-bar app it's that app. First run triggers the prompt, so document it. A packaged `.app` needs
  `NSAudioCaptureUsageDescription` in its `Info.plist`.
- **Atomic writes** to `control.json` (temp + `rename`) are non-negotiable with multiple frontends.
- **Decorators:** the Stream Deck plugin's `@action` uses TypeScript 5 **standard** (TC39) decorators on
  `target: ES2022`. Do not add `experimentalDecorators`/`useDefineForClassFields`; they break typechecking.

## Constraints

- **Never run any `git` command.** Prepare changes only; the user runs git.
- **Never run `--fix`/`--force`** on any repair/migration tool. Show what it would do.
- **Timestamped backup before editing any config/plist in place.**
- TypeScript strict, **no `any`**. Swift: keep it tight and idiomatic, match the existing daemon's style.
- **No new dependencies** beyond what's named here without justification.
- Keep everything **generic and open-source-clean**: no machine names, no account names, no personal refs.
- Small, composable, surgical changes; every changed line traces to this plan.

## Definition of done (per phase)

1. **CLI + LaunchAgent**: `loudini up/down/mute/set/get` change audio via the running daemon; concurrent
   writes never corrupt `control.json`; LaunchAgent survives logout; README has the Karabiner recipe;
   Codex review clean.
2. **Menu-bar app**: hardware volume keys drive Loudini with no macOS HUD; Accessibility handled
   gracefully; daemon lifecycle owned; **the visual layer works: menu-bar indicator, slider, and a
   status-driven on-screen HUD that reacts to *any* frontend**; Codex review of the tap clean.
3. **Stream Deck plugin**: `pnpm build` yields `.sdPlugin/bin/{plugin.js,loudini-helper}`; key faces show
   the level.

All four ship together: the daemon plus three frontends, with the menu-bar app as the shared visual layer.

## Signing

`build-app.sh` picks the strongest signing identity present, so the same script covers dev and release.
It looks for, in order: a **Developer ID Application** cert (release), the **"Loudini Dev"** self-signed
cert (dev), then falls back to **ad-hoc**.

### Stable signing (dev)

macOS ties every TCC grant (Accessibility, Input Monitoring, Audio) to the app's code identity. Ad-hoc
signing mints a new identity on every build, so grants reset each rebuild and you re-approve permissions
constantly. A stable self-signed cert fixes it: the identity (a fixed certificate leaf) stays constant,
so grants persist. Create it once:

```sh
brew install openssl@3     # once: macOS ships LibreSSL, which has no `-legacy` flag
scripts/make-dev-cert.sh
```

The script needs OpenSSL 3 first on `PATH`. `openssl pkcs12 -export -legacy` is the only way to mint
a PKCS#12 that macOS's Security framework can import, and `-legacy` does not exist in LibreSSL, so on
a Mac without Homebrew's `openssl@3` the script aborts after minting the key and no `Loudini Dev`
identity is created. `build-app.sh` then silently falls back to ad-hoc signing and the grants keep
dying on every rebuild. The script checks this itself and exits with that instruction.

Safe to re-run: it exits early if the cert already exists, because a second leaf would change the
designated requirement and break the grants it exists to preserve. It prints the `tccutil` lines to
run afterwards.

The cert lists as `CSSMERR_TP_NOT_TRUSTED` (self-signed). That's fine: `codesign` still signs with it and
the designated requirement stays stable (`identifier "gg.pim.loudini.menubar" and certificate leaf = H"…"`).
After a build's identity changes (e.g. first switch from ad-hoc), reset any stale grants once:
`tccutil reset Accessibility gg.pim.loudini.menubar` (and `ListenEvent`, `AudioCapture`), then re-approve.

### Release signing & notarization

For distribution to other users, ad-hoc/self-signed is a dead end: Gatekeeper blocks launch and grants
don't persist. You need an Apple Developer account ($99/yr) → a **Developer ID Application** cert. Once
that cert is in your keychain, `build-app.sh` uses it automatically (hardened runtime, secure timestamp,
`loudini.entitlements`). Then notarize and staple:

```sh
# 1. Build (auto-detects the Developer ID and signs release-style).
menubar/build-app.sh

# 2. Store the credentials ONCE in a notarytool keychain profile. Do this instead of passing
#    --password on submit: KERN_PROCARGS2 makes both argv and the environment readable by any
#    same-UID process, and `--wait` keeps that process alive for the whole notarization.
xcrun notarytool store-credentials loudini --apple-id "you@example.com" \
  --team-id "TEAMID" --password "app-specific-pw"

# 3. Zip and submit, authenticating with the stored profile (no secret on the command line).
ditto -c -k --keepParent menubar/Loudini.app /tmp/Loudini.zip
xcrun notarytool submit /tmp/Loudini.zip --keychain-profile loudini --wait

# 4. Staple the ticket into the bundle so it validates offline.
xcrun stapler staple menubar/Loudini.app
```

Notes:
- The private `IOAVService*` symbols (DDC brightness) are fine for notarization; that's not App Store
  review. The Mac App Store is out anyway (private API + Input Monitoring + a bundled daemon); ship via
  direct download or a Homebrew cask.
- `loudini.entitlements` currently declares only `com.apple.security.device.audio-input` (for the audio
  tap under the hardened runtime). Verify at first notarization; add entitlements only if the runtime or
  `notarytool` log flags a specific denial.

### CI / automated releases

Three GitHub Actions workflows (`.github/workflows/`):

- **`preflight.yml`** runs `scripts/preflight.sh` on every push to `main` and every PR: version
  agreement across the five version homes plus the release-notes check. Deliberately has **no**
  `paths-ignore`, unlike `ci.yml`. Two of the homes it guards (`docs/index.html`, `CHANGELOG.md`) are
  exactly the paths `ci.yml` skips, so this workflow alone gates a docs-only or CHANGELOG-only PR.
- **`ci.yml`**: on every push to `main` and every PR that touches something outside `docs/` and
  `**/*.md`, three jobs run. `app` compiles `Loudini.app` (ad-hoc signed) on a macOS runner, `test`
  runs `scripts/test.sh` (the contract regression suite) on the same runner, and `plugin` typechecks +
  builds the Stream Deck plugin on Linux. No secrets; fork PRs build safely because GitHub never
  exposes secrets to them.
  (Developer-ID signing + notarization happen locally in `scripts/release.sh`, not here.)
- **`release.yml`** is a **dormant manual cloud fallback** (`workflow_dispatch` only). Releases are cut
  **locally** with `scripts/release.sh` (below); this workflow only runs when you trigger it from
  Actions → release → Run workflow (e.g. to build the current version in the cloud). When triggered, a
  cheap Linux `check` job reads `CFBundleShortVersionString`; if that version has no published release
  yet (and isn't a downgrade), a macOS job imports your Developer ID cert into a throwaway keychain,
  runs `scripts/package-dmg.sh` (notarizes via credentials in
  `NOTARY_APPLE_ID`/`NOTARY_TEAM_ID`/`NOTARY_APP_PW`), and publishes the signed+notarized
  `Loudini.dmg` as a GitHub Release tagged `vX.Y.Z`. The site's download button points at
  `releases/latest/download/Loudini.dmg`, so it always resolves to the newest release.

**One-time setup: five repository secrets** (Settings → Secrets and variables → Actions → New
repository secret). **Only** the manual `release.yml` cloud fallback uses these. The local
`scripts/release.sh` doesn't touch them (it signs with your keychain cert and notarizes via your
`loudini` notarytool profile), so you can skip this entirely if you only ever release locally:

```sh
# 1. Export the Developer ID Application cert + private key to a .p12, then base64 it.
#    (Keychain Access → your "Developer ID Application" cert → right-click → Export → .p12,
#     set an export password; use that password as DEVELOPER_ID_CERT_PASSWORD below.)
base64 -i DeveloperID.p12 | pbcopy      # paste as DEVELOPER_ID_CERT_P12
```

| Secret | Value |
|---|---|
| `DEVELOPER_ID_CERT_P12` | base64 of the exported `.p12` |
| `DEVELOPER_ID_CERT_PASSWORD` | the password set during that export |
| `APPLE_ID` | Apple ID email used for notarization |
| `APPLE_TEAM_ID` | 10-char Developer Team ID (e.g. `24BDPF6PWJ`) |
| `APPLE_APP_PASSWORD` | an app-specific password from appleid.apple.com |

Cutting a release locally needs three things installed first: a **Developer ID Application** cert, the
`loudini` notarytool keychain profile (both above), and the **GitHub CLI** (`gh`, authenticated with
push access: `brew install gh && gh auth login`). `release.sh` publishes the Release through `gh` and
aborts on its first call without one.

Cut a release (locally, from your Mac): run `scripts/bump-version.sh 0.3.0`. The version lives in five
files that must agree (`menubar/Info.plist`, the plugin's `package.json` + Stream Deck manifest, the
`docs/index.html` footer, and a `CHANGELOG.md` heading); the script backs up all five to a temp dir
(printed before it rewrites anything, so a half-done bump is still recoverable), writes them, and adds a
dated CHANGELOG skeleton. Fill that skeleton in. Preflight rejects the `TODO` placeholder, so a release
can't publish it. Then commit, `git push origin main`, and run `scripts/release.sh`. It builds,
notarizes, staples, and publishes the GitHub Release; re-running is safe (it bails if the version is
already published). If you ever want a cloud build instead, trigger `release.yml` manually
(Actions → release → Run workflow).

`scripts/preflight.sh` is the cheap gate behind that. Before `release.sh` builds anything it asserts the
five versions agree, that this version's CHANGELOG section is actually written (an empty section or the
bump-version `TODO` placeholder fails, because that text would otherwise be published verbatim as the
release notes), and
that no release-version literal (`v0.3.0`, `Loudini-0.3.0`) is baked into `package-dmg.sh`. Drift costs
seconds instead of an hour in Apple's notary queue. It also runs on every push/PR via
`.github/workflows/preflight.yml`. Run it standalone any time.

Tip: `SKIP_NOTARIZE=1 scripts/package-dmg.sh` builds and Developer-ID-signs the DMG while skipping the
Apple notary wait, which is handy for checking packaging/signing locally without waiting on Apple.

Re-running after an aborted notary wait is cheap, within limits. `package-dmg.sh` reuses
`menubar/Loudini.app` only when all three hold: it is this version, it is stapled, and no `.swift` file
in `menubar/` or `helper/` is newer than the built binary. So a source fix made since the aborted run
still forces a rebuild instead of quietly shipping the old binary (the log names the file that triggered
it). Notary resume is **DMG-only**: `dist/.notary-state` maps a DMG's sha256 to its Apple submission id,
so an interrupted wait resumes that submission instead of re-uploading, and a rejected verdict drops the
row again so the fixed re-run uploads fresh bytes rather than replaying the rejection. The app zip can
never resume, because it is deleted on every exit and an unstapled app is rebuilt into different bytes,
so it is never recorded. Use `FORCE_REBUILD=1 scripts/package-dmg.sh` to rebuild from scratch anyway.

Check Apple's verdict with `scripts/notary-status.sh`. No args lists recent submissions and their
statuses, `--watch` re-polls every 60s, `<submission-id>` shows one, and `<submission-id> log` prints
Apple's reasons when a submission comes back `Invalid`. Notarization is an automated scan (no human
review): `In Progress` → `Accepted` normally takes 2 to 15 min, so hours stuck means Apple is stalling.
Note the timestamps it prints are **UTC**.

Notes:
- The signing cert lives in your GitHub secrets, so anyone with push access to `main` (or who can edit
  a workflow) can use your Developer ID identity. Keep collaborators trusted, or protect `main` and
  require review on workflow changes. The identity is revocable at developer.apple.com if ever leaked.
- The runner is Apple Silicon, so the DMG is `arm64`-only, same as a local `build-app.sh` build.
  Intel support would need a universal (`lipo`'d) build; not wired up.
- Hardening option: pin the `actions/*` and `pnpm/action-setup` steps to full commit SHAs instead of
  `@v4` tags.
