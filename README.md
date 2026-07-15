# Loudini

A free, open-source **macOS 14.4+** utility that adds a real, keyboard-drivable **software master
volume** to any audio output — including pro interfaces like the **Focusrite Scarlett 2i2** and other
fixed-level interfaces/DACs where the macOS volume keys just show the crossed-out "no volume" HUD.

No driver, no kext, no admin rights. Loudini uses a driverless Core Audio **process tap**
(macOS 14.4+): a small daemon taps every app's output, mutes the direct path, and re-renders the mix
to your output device through a software gain. It **fails open** — if the daemon ever dies, macOS
instantly restores the normal direct audio path. A crash can never leave you muted.

> **⚠️ Replaces Background Music.** If you use [Background Music](https://github.com/kyleneideck/BackgroundMusic),
> quit/uninstall it first. With BGM as the default output device, Loudini double-captures the mix and
> feeds back. Loudini covers the same "software volume" job without a driver.

## Quick start (menu-bar app — the easiest path)

```sh
# 1. Build the engine (one binary: daemon + CLI)
cd helper
swiftc -O -parse-as-library -o loudini-helper \
  loudini-helper.swift ControlFile.swift \
  -framework CoreAudio -framework AudioToolbox -framework Foundation

# 2. Build and open the menu-bar app (bundles the daemon inside)
cd ../menubar && ./build-app.sh && open Loudini.app
```

First run, in order:

1. If you downloaded this instead of building it: right-click → Open once (Gatekeeper), or
   `xattr -d com.apple.quarantine Loudini.app`.
2. Grant **Accessibility** when prompted — this is what lets Loudini own your volume keys.
3. Grant **System Audio Recording** when the daemon starts — this is the volume engine itself.
   (Loudini captures app audio only to re-render it at your chosen volume; nothing is recorded.)
4. Verify: `../helper/loudini-helper get` should print `running=true pipeline=true` and your device name
   — or just look at the menu bar: the Loudini item shows the live level, and a ⚠︎ badge if anything
   still needs attention (the dropdown then contains the fix).

> **⚠️ After every rebuild, re-grant.** The app is ad-hoc signed, so each rebuild changes its code
> identity: macOS silently invalidates both grants **while the Settings toggles still show enabled**.
> Fix: the menu's **Repair Volume-Key Permission…** item, or
> `tccutil reset Accessibility gg.pim.loudini.menubar` + relaunch.

## Pick your frontend

| Frontend | Needs | What you get |
|---|---|---|
| **Menu-bar app** (`menubar/`) | Accessibility | Volume keys just work; live level in the menu bar (+ ⚠︎ when broken); slider, mute, HUD; Start at Login; self-repair actions |
| **CLI** (`scripts/install-cli.sh`) | nothing | `loudini up/down/mute/set/get/doctor` from any terminal or hotkey tool |
| **Stream Deck** (`plugin/`) | Stream Deck app | Up/Down/Mute keys, faces show the live level (`42%` / 🔇 / ⚠︎) |
| **Karabiner / BTT / skhd** | that tool | Bind any key to the CLI — recipe in the appendix |

Run **exactly one daemon** — it enforces this itself with a lock file, so worst case a second daemon
exits immediately. The menu-bar app prefers your LaunchAgent when one is installed (and revives it if
it died); otherwise it runs its own bundled daemon.

### Keep the daemon alive without the app (LaunchAgent)

```sh
scripts/install-daemon.sh     # installs + starts; survives logout/reboot
scripts/uninstall-daemon.sh   # clean removal
```

Logs go to `~/.config/loudini/daemon.log`.

### The `loudini` command

```sh
scripts/install-cli.sh        # symlinks the binary to ~/.local/bin/loudini
```

```
loudini up [step]     volume += step (default 6), un-mutes
loudini down [step]   volume -= step (default 6), un-mutes
loudini mute          toggle mute
loudini set <0-100>   set the volume
loudini get           print: gain=42 muted=false running=true pipeline=true device="Scarlett 2i2 USB"
loudini doctor        diagnose the whole setup (daemon, permissions, conflicts) with fixes
```

The subcommands only write `control.json` and exit instantly — the running daemon applies the change
within 100 ms. Debug metering: `LOUDINI_METER=1 loudini-helper` logs per-second in/out RMS.

## Stream Deck plugin

Build and install with the Stream Deck app running:

```sh
cd plugin
pnpm install && pnpm build
pnpm --package=@elgato/cli dlx streamdeck link gg.pim.loudini.sdPlugin   # register with Stream Deck
```

## Scripting: the control contract

Two JSON files in `~/.config/loudini/` are the whole API:

- `control.json` — `{"gain": 0-100, "muted": bool}`. Write it (atomically: temp file in the same
  directory, then rename) and the daemon applies it within 100 ms. Malformed content is ignored —
  the daemon keeps its last good values.
- `status.json` — written by the daemon on every change:
  - `gain`, `muted` — the applied level.
  - `running` — daemon alive (`false` after a clean shutdown). Readers should also probe `pid`:
    Loudini's own frontends treat the file as `running:false` when that process is gone, so a
    hard-killed daemon can't leave a lying status behind.
  - `pipeline` — `true` only when audio is actually being captured and re-rendered.
    `running:true, pipeline:false` almost always means the System Audio Recording permission is
    missing (or `reason:"no-device"`: no output device).
  - `device` — current output device name; `pid` — the daemon's process id; `reason` — why the
    pipeline is down (omitted when it's up).

## Troubleshooting

Start with **`loudini doctor`** — it checks the config dir (with a real atomic write), the daemon
(via its lock file, immune to stale files), the audio pipeline, launchd, and known conflicting apps,
and prints the exact fix for anything broken.

- **Volume keys do nothing, but Accessibility shows Loudini enabled.** Stale grant after a rebuild —
  see the warning in Quick start. Menu → **Repair Volume-Key Permission…** fixes it in one click.
- **Menu says "No audio permission — click to fix" / key faces show ⚠︎.** The daemon can't create
  its tap — grant System Audio Recording to whichever app runs the daemon. Audio keeps playing
  normally until then (fail-open), and the volume keys deliberately fall through to macOS so you see
  the native crossed-out HUD instead of fake feedback.
- **Keys work only sometimes.** Another media-key app (MonitorControl, BeardedSpice) may grab them
  first — the menu warns when one is running. Disable its volume-key handling or launch Loudini
  after it.
- **Menu-bar icon is dimmed.** Loudini isn't controlling audio right now — open the menu; the broken
  row names the problem and is usually clickable as the fix.

## Gotchas

- **Background Music**: must be quit/uninstalled — see the warning at the top.
- **System Audio Recording permission** is granted per responsible process: under the LaunchAgent
  that's the daemon itself; when the Stream Deck app or the menu-bar app spawns the daemon, the
  prompt names *that* app instead. Grant it once per host.
- The macOS volume HUD stays the crossed-out one unless you use the menu-bar app (which replaces it
  with its own HUD) — Karabiner/BTT bindings change the volume without any HUD.

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

</details>

The same one-liners work anywhere that can run a shell command: **BetterTouchTool** (Execute Shell
Script → `~/.local/bin/loudini up`), **skhd** (`f12 : ~/.local/bin/loudini up`), or a **Raycast**
script command.
