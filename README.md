# Loudini

A free, open-source **macOS 14.4+** utility that adds a real, keyboard-drivable **software master
volume** to any audio output — including pro interfaces like the **Focusrite Scarlett 2i2** and other
fixed-level interfaces/DACs where the macOS volume keys just show the crossed-out "no volume" HUD.

No driver, no kext, no admin rights. Loudini uses a driverless Core Audio **process tap**
(macOS 14.4+): a small daemon taps every app's output, mutes the direct path, and re-renders the mix
to your output device through a software gain. It **fails open** — if the daemon ever dies, macOS
instantly restores the normal direct audio path. A crash can never leave you muted.

## Quick start (menu-bar app — the easiest path)

```sh
menubar/build-app.sh && open menubar/Loudini.app
```

One command: it compiles the engine (`helper/loudini-helper`, the daemon + CLI binary), builds the
app, and bundles the daemon inside.

First run, in order:

1. If you downloaded this instead of building it: right-click → Open once (Gatekeeper), or
   `xattr -dr com.apple.quarantine Loudini.app` (recursive — quarantine sits on every file inside).
2. Grant **Accessibility** when prompted — this is what lets Loudini own your volume keys.
3. Grant **System Audio Recording** when the daemon starts — this is the volume engine itself.
   (Loudini captures app audio only to re-render it at your chosen volume; nothing is recorded.)
4. Verify: `helper/loudini-helper get` should print `running=true pipeline=true` and your device name
   — or just look at the menu bar: the Loudini item shows the live level, and a ⚠︎ badge if anything
   still needs attention (the dropdown then contains the fix).

> **⚠️ Ad-hoc builds: re-grant after every rebuild.** With ad-hoc signing each rebuild changes the
> app's code identity, so macOS silently invalidates both grants **while the Settings toggles still
> show enabled**. Fix: the menu's **Repair Volume-Key Permission…** item (Accessibility) and the
> **Audio capture not working — click to fix** row (System Audio Recording), or
> `tccutil reset Accessibility gg.pim.loudini.menubar` + relaunch. **This goes away once you set up the
> stable "Loudini Dev" cert** (see BUILD.md → Signing) — grants then survive rebuilds.

## Pick your frontend

| Frontend | Needs | What you get |
|---|---|---|
| **Menu-bar app** (`menubar/`) | Accessibility + System Audio Recording | Volume keys just work (hold **⇧ Shift** for 1% fine steps); live level in the menu bar (+ ⚠︎ when broken); volume + brightness sliders, mute, HUD; Start at Login; self-repair actions |
| **CLI** (`scripts/install-cli.sh`) | a running daemon (app or LaunchAgent) | `loudini up/down/mute/set/get/doctor` from any terminal or hotkey tool |
| **Stream Deck** (`plugin/`) | Stream Deck app | Up/Down/Mute keys, faces show the live level (`42%` / 🔇 / ⚠︎) |
| **Karabiner / BTT / skhd** | that tool + the CLI | Bind any key to the CLI — recipe in the appendix |

Every frontend needs the engine built once — `menubar/build-app.sh` does that (or run the `swiftc`
line inside it if you only want the binary).

Run **exactly one daemon** — it enforces this itself with a lock file, so worst case a second daemon
exits immediately. The menu-bar app prefers your LaunchAgent when one is installed (and revives it if
it died); otherwise it runs its own bundled daemon.

### External-monitor brightness (menu-bar app, Apple Silicon)

With an external DDC-capable monitor attached, the menu-bar app also controls its **brightness**
(DDC/CI, the same mechanism MonitorControl uses — no extra permission needed):

- The hardware **brightness keys** drive it — but only when no built-in display is active, so a
  MacBook with the lid open keeps native control of its own panel. Toggle with
  **Grab Brightness Keys** in the menu.
- A second slider (sun icons) appears in the dropdown, and brightness changes get their own HUD.
- All external displays move together for now. Intel Macs: the feature simply stays hidden.

**The universal fallback — a hotkey bound to the CLI.** Some keyboards can't be reached by key
capture at all: boards with no brightness keys, a Bluetooth Magic Keyboard with Touch ID (it hides its
special keys over BT), or keys rerouted by vendor software (Logitech G HUB / Options+). For every one
of these, bind the permission-free CLI to any shortcut instead:

```sh
loudini brightness up      # +6%   (loudini brightness down / set 50 / get)
```

DDC writes need no permission at all, so this works from macOS Shortcuts, Karabiner, BetterTouchTool, a
Stream Deck key, or Raycast — see the appendix for a Karabiner recipe. This is the recommended path
whenever the built-in key grab doesn't cover your keyboard.

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
loudini brightness up|down [step] | set <0-100> | get
                      external-monitor brightness over DDC — needs NO permission, bind it to any key
```

The subcommands only write `control.json` and exit instantly — the running daemon applies the change
within 100 ms. Debug metering: `LOUDINI_METER=1 loudini` runs the daemon with per-second in/out RMS
logging (stop the normal daemon first — the single-instance lock makes a second one exit).

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
  - `apps` — the live roster of apps currently producing audio (read-only):
    `[{bundleID,name,pid,gain,muted,active}]`. Populated from
    `kAudioProcessPropertyIsRunningOutput`; `loudini apps` prints it. See `SPEC-per-app-volume.md`.

## Troubleshooting

Start with **`loudini doctor`** — it checks the config dir (with a real atomic write), the daemon
(via its lock file, immune to stale files), the audio pipeline, launchd, and known conflicting apps,
and prints the exact fix for anything broken.

- **Volume keys do nothing, but Accessibility shows Loudini enabled.** Stale grant after a rebuild —
  see the warning in Quick start. Menu → **Repair Volume-Key Permission…** fixes it in one click.
- **Menu says "Audio capture not working — click to fix" / key faces show ⚠︎.** The daemon can't create
  its tap — grant System Audio Recording to whichever app runs the daemon. Audio keeps playing
  normally until then (fail-open), and the volume keys deliberately fall through to macOS so you see
  the native crossed-out HUD instead of fake feedback.
- **Keys work only sometimes.** Another media-key app (MonitorControl, BeardedSpice) may grab them
  first — the menu warns when one is running. Disable its volume-key handling or launch Loudini
  after it.
- **Menu-bar icon is dimmed.** Loudini isn't controlling audio right now — open the menu; the broken
  row names the problem and is usually clickable as the fix.
- **Brightness keys don't respond.** They're only grabbed when an external DDC display is present
  AND no built-in display is active (lid closed / desktop Mac); check the **Grab Brightness Keys**
  toggle. The slider in the menu always works when the row is visible.

## Gotchas

- **Virtual audio devices as your default output** (Background Music, BlackHole routed as default,
  eqMac): quit/uninstall them. Loudini taps the default output and re-renders back to it; a virtual
  device that re-plays that audio creates a feedback loop. Loudini covers the same "software volume"
  job without a driver, so it *replaces* Background Music rather than running alongside it.
- **System Audio Recording permission** is granted per responsible process: under the LaunchAgent
  that's the daemon itself; when the Stream Deck app or the menu-bar app spawns the daemon, the
  prompt names *that* app instead. Grant it once per app identity (with ad-hoc signing that means again
  after each rebuild — see the Quick start warning; the stable "Loudini Dev" cert removes that).
- The macOS volume HUD stays the crossed-out one unless you use the menu-bar app (which replaces it
  with its own HUD) — Karabiner/BTT bindings change the volume without any HUD.
- **AirPlay speakers work — as a system output.** Pick an AirPlay device in Control Center → Sound and
  Loudini controls its volume like any other output (it follows the default output automatically). What
  it *can't* touch is **in-app AirPlay** — the AirPlay button inside a Safari video or the Music/TV app,
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

Add external-monitor **brightness** the same way (Karabiner captures these keys at the HID level, below
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

The same one-liners work anywhere that can run a shell command: **BetterTouchTool** (Execute Shell
Script → `~/.local/bin/loudini up`), **skhd** (`f12 : ~/.local/bin/loudini up`), or a **Raycast**
script command.
