# Changelog

All notable changes to Loudini are documented here. This project adheres to
[Semantic Versioning](https://semver.org/).

## [0.4.1] — 2026-07-21

### Fixed
- Safari and other WebKit apps showed as **"Safari Graphics and Media"** in the
  per-app list — the name of macOS's media helper. Loudini now trims that suffix,
  so the row reads "Safari". (Two WebKit apps playing at once still share one row;
  see the gotcha in the README.)
- The landing page now carries the icon formats an inline SVG favicon can't cover
  — an Apple touch icon for iOS home-screen bookmarks, and a PNG fallback for
  Safari older than 16.4.

## [0.4.0] — 2026-07-21

### Added
- **The menu shows which version you're running**, next to the Loudini name.
  Worth knowing when a rebuild has quietly invalidated your permissions.
- **Update notifications.** Loudini asks GitHub once a day whether a newer
  release exists, and if so adds a row that opens the releases page. It never
  downloads or installs anything by itself. Turn it off with **Check for
  Updates Automatically** in the menu, and nothing is ever requested.
  This is the first version that can tell you about an update — 0.3.0 and
  earlier have no way to know a new one exists.

### Fixed
- Per-app rows showed **"helper"** instead of the app's name. Browsers and
  Electron apps play audio from helper processes, which macOS doesn't report as
  applications, so the row fell back to the tail of the bundle id. Loudini now
  resolves the parent app, so the row reads "Google Chrome".

### Changed
- The update check is the only network request Loudini makes. It is
  unauthenticated, sends nothing that identifies you or your machine — the
  User-Agent and language headers are pinned so the system can't add your kernel
  build or language list — stores no cookies, and is silent when it fails.

## [0.3.0] — 2026-07-21

### Added
- **Render-stall watchdog** — the daemon now watches its own render heartbeat.
  If the audio pipeline goes quiet while apps are playing, it tears the tap down
  so sound returns to the direct path instead of leaving you in silence, then
  rebuilds. `status.json` reports `reason: "render stalled"` while it recovers.
- **Automated tests** — 55 contract checks over the control/status file
  (`scripts/test.sh`), run on every push. They pin the invariants that matter:
  per-app overrides survive a master-only write, a malformed file keeps the last
  good value, gains clamp to 0–100, and a dead daemon can't claim `running:true`.
- **`scripts/make-dev-cert.sh`** — one idempotent command for the stable
  "Loudini Dev" signing identity, so TCC grants stop resetting on every rebuild.
- **`scripts/bump-version.sh`** — writes the version to all five files that
  carry it, instead of five hand edits.

### Fixed
- The menu named the wrong fix for Background Music: the daemon and the menu-bar
  app kept separate lists of conflicting apps and had drifted apart. Both now
  read one shared list (`helper/Conflicts.swift`).
- Sharing a link to loudini.app showed no preview image, and the page's canonical
  URL pointed at the old github.io address.

### Changed
- Releases now fail fast. A preflight asserts the five version homes agree, that
  no version is hardcoded in the packaging script, and that these release notes
  are actually written — in seconds, before the build and Apple's notary queue,
  rather than an hour into it.
- Re-running a release no longer re-buys work Apple already accepted: a stapled
  app is reused when it matches the current sources, and an interrupted DMG
  notarization resumes instead of re-uploading.

## [0.2.0] — 2026-07-19

### Added
- **Per-app volume** — give each running app its own level on top of the master
  (Spotify at 40% while a call stays at 100%), via per-process Core Audio taps.
  `loudini apps` and `loudini app <id> set <0-100>|mute`, plus per-app rows in
  the menu-bar app.
- **Device-volume sync** — on an output with its own volume (built-in speakers,
  most DACs), the Touch Bar, macOS Sound settings, and Loudini all drive one
  control. Fixed-level interfaces (Focusrite Scarlett) keep the software master.
- **External-monitor brightness** — the brightness keys drive an external DDC
  display, plus a permission-free `loudini brightness up|down|set|get` CLI.
- **Stable code-signing** so TCC grants survive rebuilds; the release build is
  Developer-ID signed, hardened-runtime, and notarization-ready.
- **One-click install** — a signed & notarized `.dmg`, downloadable from
  [loudini.app](https://loudini.app) and each GitHub release, built and notarized
  locally via `scripts/release.sh`.

### Changed
- New **level-bars** app icon and mark across the app, menu bar, and site.
- Now **MIT licensed**.

### Fixed
- Stream Deck volume presses no longer wipe per-app overrides.
- Menu-bar crash-loop from a malformed status file (pid is now bounded).
- Daemon crash from a non-finite device volume reported by a third-party driver.
- A held brightness key corrupting the monitor via unlocked concurrent I2C — the
  brightness read-modify-write now holds a cross-process lock.

## [0.1.0]

Initial release: a software master volume for any audio output via a driverless
Core Audio process tap — with the hardware volume keys, an on-screen HUD, a CLI,
a LaunchAgent, and a Stream Deck plugin.
