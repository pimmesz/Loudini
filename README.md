# Loudini

A free, open-source macOS 14.4+ utility that adds a real, keyboard-drivable software master volume to
any audio output, including fixed-level pro interfaces and DACs (the Focusrite Scarlett 2i2, for
example) where the macOS volume keys only show the crossed-out "no volume" HUD.

It installs no driver and no kernel extension, and it needs no admin rights. Loudini uses a driverless
Core Audio process tap (macOS 14.4+): a small daemon taps every app's output, mutes the direct path,
and re-renders the mix to your output device through a software gain. It fails open. If the daemon
ever dies, macOS restores the normal direct audio path immediately, so a crash can never leave you
muted.

## Download

**[Download Loudini.dmg](https://github.com/pimmesz/Loudini/releases/latest/download/Loudini.dmg)**
(Developer ID signed and notarized by Apple, Apple Silicon, macOS 14.4+).
More at [loudini.app](https://loudini.app) · [all releases](https://github.com/pimmesz/Loudini/releases)

Open the `.dmg`, drag Loudini to Applications, then follow **First run** below.

## Build from source

Requires macOS 14.4+ and the Xcode Command Line Tools (`xcode-select --install`), because
`build-app.sh` uses `swiftc` and `codesign`. `scripts/make-dev-cert.sh` needs OpenSSL 3 first on
`PATH` (`brew install openssl@3`), because macOS ships LibreSSL, which has no `-legacy` flag. The
release scripts also need `python3` and the GitHub CLI (`gh`, authenticated with push access:
`brew install gh && gh auth login`).

```sh
menubar/build-app.sh && open menubar/Loudini.app
```

That one command compiles the engine (`helper/loudini-helper`, the daemon and CLI binary), builds the
app, and bundles the daemon inside.

## First run

1. **Built it yourself?** Ad-hoc-signed builds are unsigned as far as macOS is concerned: right-click →
   Open once, or `xattr -dr com.apple.quarantine Loudini.app` (recursive, because quarantine sits on
   every file inside). The DMG from Releases needs none of this: it is signed and notarized, and opens
   on a normal double-click.
2. Grant **Accessibility** when prompted. That is what lets Loudini own your volume keys.
3. Grant **System Audio Recording** when the daemon starts. That is the volume engine itself.
   (Loudini captures app audio only to re-render it at your chosen volume; nothing is recorded.)
4. Only if you want the hardware **brightness keys**: grant **Input Monitoring** as well. The menu's
   **Enable Brightness Keys (Input Monitoring)…** row prompts for it. Volume needs nothing extra.
5. Verify: `/Applications/Loudini.app/Contents/MacOS/loudini-helper get` (DMG install) or
   `helper/loudini-helper get` (built from source) should print `running=true pipeline=true` and your
   device name. Or look at the menu bar: the Loudini item shows the live level, and a ⚠︎ badge if
   anything still needs attention (the dropdown then contains the fix).

> **⚠️ Ad-hoc builds: re-grant after every rebuild.** With ad-hoc signing each rebuild changes the
> app's code identity, so macOS silently invalidates the grants while the Settings toggles still show
> enabled. Run `scripts/make-dev-cert.sh` once (it needs OpenSSL 3 on `PATH`, see the prerequisites
> above) and this stops happening: grants then survive rebuilds.
> To recover a build you already have, use the menu's **Repair Volume-Key Permission…** item
> (Accessibility), the **Audio capture not working** row (System Audio Recording), and the **Enable
> Brightness Keys (Input Monitoring)…** row (Input Monitoring).

## Pick your frontend

| Frontend | Needs | What you get |
|---|---|---|
| **Menu-bar app** (`menubar/`) | Accessibility + System Audio Recording (+ Input Monitoring for the brightness keys) | Volume keys work (hold **⇧ Shift** for 1% fine steps); live level in the menu bar (+ ⚠︎ when broken); volume + brightness sliders, mute, HUD; Start at Login; self-repair actions |
| **CLI** (`scripts/install-cli.sh`) | a running daemon for the volume commands; `brightness` and `doctor` need nothing | `loudini up/down/mute/set/get/apps/app/brightness/doctor` from any terminal or hotkey tool |
| **Stream Deck** (`plugin/`) | Stream Deck app | Up/Down/Mute keys, faces show the live level (`42%` / 🔇 / ⚠︎) |
| **Karabiner / BTT / skhd** | that tool + the CLI | Bind any key to the CLI (recipe in the appendix) |

Every frontend needs the engine built once. `menubar/build-app.sh` does that (or run the `swiftc` line
inside it if you only want the binary).

Run exactly one daemon. It enforces this itself with a lock file, so at worst a second daemon exits
immediately. The menu-bar app prefers your LaunchAgent when one is installed (and revives it if it
died); otherwise it runs its own bundled daemon.

### External-monitor brightness (menu-bar app, Apple Silicon)

With an external DDC-capable monitor attached, the menu-bar app also controls its brightness over
DDC/CI, the same mechanism MonitorControl uses. The DDC writes themselves need no permission:

- The hardware brightness keys drive it, but only when no built-in display is active, so a MacBook
  with the lid open keeps native control of its own panel. Toggle with **Grab Brightness Keys** in the
  menu.
- Grabbing those keys needs **Input Monitoring** (System Settings → Privacy & Security → Input
  Monitoring), and like the other grants it dies on every ad-hoc rebuild. The menu's **Enable
  Brightness Keys (Input Monitoring)…** row appears exactly when that grant is what's missing. The
  slider, a hotkey and the CLI all work without it.
- A second slider (sun icons) appears in the dropdown, and brightness changes get their own HUD.
- All external displays move together for now. On Intel Macs the feature stays hidden.

**The universal fallback: a hotkey bound to the CLI.** Some keyboards can't be reached by key capture
at all: boards with no brightness keys, a Bluetooth Magic Keyboard with Touch ID (it hides its special
keys over BT), or keys rerouted by vendor software (Logitech G HUB / Options+). For any of these, bind
the permission-free CLI to a shortcut instead:

```sh
loudini brightness up      # +6%   (loudini brightness down / set 50 / get)
```

DDC writes need no permission at all, so this works from macOS Shortcuts, Karabiner, BetterTouchTool, a
Stream Deck key, or Raycast (see the appendix for a Karabiner recipe). Use it whenever the built-in key
grab doesn't cover your keyboard.

### Keep the daemon alive without the app (LaunchAgent)

```sh
scripts/install-daemon.sh     # installs + starts; survives logout/reboot
scripts/uninstall-daemon.sh   # clean removal
```

Logs go to `~/.config/loudini/daemon.log`.

### The `loudini` command

```sh
scripts/install-cli.sh        # from a source checkout: symlinks the binary to ~/.local/bin/loudini
```

Installed from the DMG instead? There is no checkout for `install-cli.sh` to link, so link the copy
inside the app bundle:

```sh
mkdir -p ~/.local/bin
ln -sfn /Applications/Loudini.app/Contents/MacOS/loudini-helper ~/.local/bin/loudini
```

If `~/.local/bin` is not already on your `PATH`, add `export PATH="$HOME/.local/bin:$PATH"` to your
shell profile. `install-cli.sh` prints the same note when it needs to.

```
loudini up [step]     volume += step (default 6), un-mutes
loudini down [step]   volume -= step (default 6), un-mutes
loudini mute          toggle mute
loudini set <0-100>   set the volume
loudini get           print: gain=42 muted=false running=true pipeline=true device="Scarlett 2i2 USB"
loudini apps          list apps currently producing audio (from status.json)
loudini apps reset    reset every per-app volume to 100% (clears overrides)
loudini app <id|name> set <0-100> | mute | get
                      set/toggle/read one app's volume (bundle id exact, name fuzzy)
loudini doctor        diagnose the whole setup (daemon, permissions, conflicts) with fixes
loudini brightness up|down [step] | set <0-100> | get
                      external-monitor brightness over DDC (needs NO permission, bind it to any key)
```

The writing subcommands (`up`/`down`/`mute`/`set`, `apps reset`, and `app <id> set|mute`) only write
`control.json` and exit immediately; the running daemon applies the change within 100 ms. The reading
ones (`get`, `apps`, `app <id> get`) write nothing: they prefer `status.json`, the daemon's applied
truth, and fall back to `control.json` when no daemon has written one. Only `apps` needs a live
daemon, since its roster comes from `status.json` alone and is empty otherwise. `brightness` needs no daemon at all: it talks to the display over DDC directly. `doctor`
changes nothing you care about: it writes and immediately deletes one probe file to prove the config
dir is writable, never touches your volume, and exits non-zero when it finds problems, so it is safe
to use in a script's health check. For debug metering, `LOUDINI_METER=1 loudini` runs the daemon with
per-second in/out RMS logging (stop the normal daemon first, since the single-instance lock makes a
second one exit).

## Stream Deck plugin

Build and install with the Stream Deck app running:

```sh
cd plugin
pnpm install && pnpm build
pnpm --package=@elgato/cli dlx streamdeck link gg.pim.loudini.sdPlugin   # register with Stream Deck
```

## Scripting: the control contract

Three JSON files in `~/.config/loudini/` are the whole API, plus one lock file that guards writes to
the first:

- `control.json`: `{"gain": 0-100, "muted": bool, "apps"?: {"<bundleID>": {"gain": 0-100, "muted": bool}}}`.
  Write it (atomically: temp file in the same directory, then rename) and the daemon applies it within
  100 ms. Malformed content is ignored and the daemon keeps its last good values.
  **If you only own `gain`/`muted`, read-modify-write. Never replace the document.** Writing just
  `{"gain":…,"muted":…}` erases the whole `apps` map and every per-app volume with it.
- `control.lock`: hold an exclusive `flock(2)` on it around that read-modify-write, then do the atomic
  rename. The rename stops a torn file but not a lost update: a per-app override written between
  another writer's read and its rename disappears without the lock. Every first-party Swift frontend
  takes it. The Stream Deck plugin is the one exception, because Node has no `flock(2)`: it merges
  the keys it does not own, which narrows the lost-update window but does not close it. See
  `DECISIONS.md`.
- `status.json`, written by the daemon on every change:
  - `gain`, `muted`: the applied level.
  - `running`: daemon alive (`false` after a clean shutdown). Readers should also probe `pid`:
    Loudini's own frontends treat the file as `running:false` when that process is gone, so a
    hard-killed daemon can't leave a lying status behind.
  - `pipeline`: `true` only when audio is actually being captured and re-rendered.
    `running:true, pipeline:false` almost always means the System Audio Recording permission is
    missing (or `reason:"no-device"`: no output device; `reason:"render stalled"`: the daemon tore
    the tap down after the render callbacks went quiet while apps were playing, and is rebuilding it).
  - `device`: current output device name. `pid`: the daemon's process id. `reason`: why the pipeline
    is down (omitted when it's up).
  - `apps`: the live roster of apps currently producing audio (read-only):
    `[{bundleID,name,pid,gain,muted,active}]`. Populated from
    `kAudioProcessPropertyIsRunningOutput`; `loudini apps` prints it. Set one app with
    `loudini app <id|name> set <0-100>|mute`, clear all with `loudini apps reset`, or use the
    per-app rows under the master slider in the menu-bar app. See `SPEC-per-app-volume.md`.
- `brightness.json`: `{"percent": 0-100}`, the shared source of truth for external-display
  brightness. Both the CLI and the menu-bar app write it under `brightness.lock` on every apply, so a
  relative step never starts from a stale base. A third brightness frontend must do the same. See
  `DECISIONS.md`.

## Troubleshooting

Start with `loudini doctor`. It checks the config dir (with a real atomic write), the daemon (via its
lock file, immune to stale files), the audio pipeline, launchd, and known conflicting apps, and prints
the exact fix for anything broken.

- **Volume keys do nothing, but Accessibility shows Loudini enabled.** Stale grant after a rebuild;
  see the [First run](#first-run) warning. Menu → **Repair Volume-Key Permission…** fixes it in one
  click.
- **Menu says "Audio capture not working", or key faces show ⚠︎.** The daemon can't create its tap, so
  grant System Audio Recording to whichever app runs the daemon. Audio keeps playing normally until
  then (fail-open), and the volume keys deliberately fall through to macOS so you see the native
  crossed-out HUD instead of fake feedback.
- **Keys work only sometimes.** Another media-key app (MonitorControl, BeardedSpice) may grab them
  first, and the menu warns when one is running. Disable its volume-key handling or launch Loudini
  after it.
- **Menu-bar icon is dimmed.** Loudini isn't controlling audio right now. Open the menu: the broken
  row names the problem and is usually clickable as the fix.
- **Brightness keys don't respond.** First suspect: the **Input Monitoring** grant, which dies on
  every ad-hoc rebuild. The menu's **Enable Brightness Keys (Input Monitoring)…** row grants it in one
  click. Beyond that, the keys are only grabbed when an external DDC display is present AND no
  built-in display is active (lid closed / desktop Mac); check the **Grab Brightness Keys** toggle.
  The slider in the menu always works when the row is visible.

## Gotchas

- **WebKit apps share one per-app row.** Safari and anything embedding WebKit (Citrix Workspace,
  Zscaler, many Electron-ish wrappers) all play audio from a helper process reporting the *same*
  bundle id, `com.apple.WebKit.GPU`. Per-app volumes are keyed on that id, so if two of them play
  at once they collapse into a single row and share one level, and the row is named after
  whichever was seen last. Chrome is unaffected (it uses its own id). Splitting them needs a
  different key than the bundle id, which `status.json`, the CLI and the menu-bar app all
  match on, so it is a deliberate breaking change rather than a quick fix. The master volume is
  unaffected either way: it applies to everything.
- **Virtual audio devices as your default output** (Background Music, BlackHole routed as default,
  eqMac): quit/uninstall them. Loudini taps the default output and re-renders back to it; a virtual
  device that re-plays that audio creates a feedback loop. Loudini covers the same "software volume"
  job without a driver, so it *replaces* Background Music rather than running alongside it.
- **System Audio Recording permission** is granted per responsible process: under the LaunchAgent
  that's the daemon itself; when the Stream Deck app or the menu-bar app spawns the daemon, the
  prompt names *that* app instead. Grant it once per app identity. With ad-hoc signing that means
  again after each rebuild (see the [First run](#first-run) warning); the stable "Loudini Dev" cert
  removes that.
- The macOS volume HUD stays the crossed-out one unless you use the menu-bar app (which replaces it
  with its own HUD). Karabiner/BTT bindings change the volume without any HUD.
- **AirPlay speakers work as a system output.** Pick an AirPlay device in Control Center → Sound and
  Loudini controls its volume like any other output (it follows the default output automatically). What
  it *can't* touch is in-app AirPlay: the AirPlay button inside a Safari video or the Music/TV app,
  which streams straight to the speaker and never passes through the Mac's audio output. No tap-based
  tool can reach that path.

## Appendix: bind keys with Karabiner / BTT / skhd

<details>
<summary>Karabiner-Elements complex modification (volume keys → Loudini)</summary>

Paste into `~/.config/karabiner/assets/complex_modifications/loudini.json`, then enable it in
Karabiner → Complex Modifications → Add rule:

```json
{
  "title": "Loudini volume keys",
  "rules": [
    {
      "description": "Hardware volume keys → Loudini (F10/F11/F12 positions: mute/down/up)",
      "manipulators": [
        {
          "type": "basic",
          "from": { "consumer_key_code": "volume_increment", "modifiers": { "optional": ["any"] } },
          "to": [{ "shell_command": "$HOME/.local/bin/loudini up" }]
        },
        {
          "type": "basic",
          "from": { "consumer_key_code": "volume_decrement", "modifiers": { "optional": ["any"] } },
          "to": [{ "shell_command": "$HOME/.local/bin/loudini down" }]
        },
        {
          "type": "basic",
          "from": { "consumer_key_code": "mute", "modifiers": { "optional": ["any"] } },
          "to": [{ "shell_command": "$HOME/.local/bin/loudini mute" }]
        }
      ]
    }
  ]
}
```

If your keyboard sends plain function keys instead (you enabled "Use F1, F2, etc. keys as standard
function keys"), swap each `from` for `{ "key_code": "f12" }` / `"f11"` / `"f10"`.

Add external-monitor brightness the same way (Karabiner captures these keys at the HID level, below
where the menu-bar app's tap loses them):

```json
{
  "type": "basic",
  "from": { "consumer_key_code": "display_brightness_increment", "modifiers": { "optional": ["any"] } },
  "to": [{ "shell_command": "$HOME/.local/bin/loudini brightness up" }]
},
{
  "type": "basic",
  "from": { "consumer_key_code": "display_brightness_decrement", "modifiers": { "optional": ["any"] } },
  "to": [{ "shell_command": "$HOME/.local/bin/loudini brightness down" }]
}
```

</details>

The same one-liners work anywhere that can run a shell command: BetterTouchTool (Execute Shell
Script → `~/.local/bin/loudini up`), skhd (`f12 : ~/.local/bin/loudini up`), or a Raycast script
command.
