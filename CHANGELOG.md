# Changelog

All notable changes to Loudini are documented here. This project adheres to
[Semantic Versioning](https://semver.org/).

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
