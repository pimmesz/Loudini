import { spawn, type ChildProcess } from 'node:child_process';
import { existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

/** The compiled Swift daemon, bundled next to plugin.js at build time (see build.mjs). It reads
 * ~/.config/loudini/control.json and applies the gain via a driverless Core Audio process tap. */
const HELPER = join(dirname(fileURLToPath(import.meta.url)), 'loudini-helper');

let child: ChildProcess | undefined;

/**
 * Start the audio daemon if it isn't already alive (idempotent — safe to call on every key event).
 * The daemon's tap fails OPEN: if it dies, macOS restores the interface's own audio, so a crash is
 * recoverable, not catastrophic. We respawn lazily on the next action rather than tight-looping.
 */
export function ensureHelper(log: (m: string) => void): void {
  // exitCode stays null when a child dies from a SIGNAL — check both fields,
  // or a crashed helper would never be respawned.
  if (child && child.exitCode === null && child.signalCode === null) return; // still alive
  if (!existsSync(HELPER)) {
    log(`Loudini: helper binary missing at ${HELPER} — build ../helper first.`);
    return;
  }
  child = spawn(HELPER, [], { stdio: 'ignore' });
  child.on('exit', (code, signal) => {
    // Exit 0 is routine: the daemon's flock makes a redundant spawn quit
    // immediately when a LaunchAgent/menu-bar daemon already runs.
    if (code !== 0) log(`Loudini: helper exited (${code ?? `signal ${signal}`}); respawns on next action.`);
  });
  child.on('error', (err) => log(`Loudini: helper failed to start: ${err.message}`));
}

export function stopHelper(): void {
  child?.kill('SIGTERM');
  child = undefined;
}
