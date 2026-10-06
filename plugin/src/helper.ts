import { execFile, spawn, type ChildProcess } from 'node:child_process';
import { closeSync, existsSync, mkdirSync, openSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

/** The compiled Swift daemon, bundled next to plugin.js at build time (see build.mjs). It reads
 * ~/.config/loudini/control.json and applies the gain via a driverless Core Audio process tap. */
const HELPER = join(dirname(fileURLToPath(import.meta.url)), 'loudini-helper');
const CONFIG_DIR = join(homedir(), '.config', 'loudini');

/** Append to the daemon.log the app and LaunchAgent daemons share, so a plugin-owned daemon's
 * history is not lost. Falls back to discarding output if the log cannot be opened. */
function openDaemonLog(log: Log): number | 'ignore' {
  try {
    mkdirSync(CONFIG_DIR, { recursive: true, mode: 0o700 });
    return openSync(join(CONFIG_DIR, 'daemon.log'), 'a', 0o600);
  } catch (err) {
    log.error(`Loudini: cannot open daemon.log (${(err as Error).message}); daemon output will be lost.`);
    return 'ignore';
  }
}

/** Structural match for streamDeck.logger, so this file stays free of the SDK import. */
export interface Log {
  info(m: string): unknown;
  error(m: string): unknown;
}

let child: ChildProcess | undefined;

/**
 * Start the audio daemon if it isn't already alive (idempotent — safe to call on every key event).
 * The daemon's tap fails OPEN: if it dies, macOS restores the interface's own audio, so a crash is
 * recoverable, not catastrophic. We respawn lazily on the next action rather than tight-looping.
 */
export function ensureHelper(log: Log): void {
  // exitCode stays null when a child dies from a SIGNAL — check both fields,
  // or a crashed helper would never be respawned.
  if (child && child.exitCode === null && child.signalCode === null) return; // still alive
  if (!existsSync(HELPER)) {
    log.error(`Loudini: helper binary missing at ${HELPER}; build it with menubar/build-app.sh first.`);
    return;
  }
  const out = openDaemonLog(log);
  child = spawn(HELPER, [], { stdio: ['ignore', out, out] });
  // The child holds its own copy of the fd.
  if (out !== 'ignore') closeSync(out);
  log.info(`Loudini: started helper pid ${child.pid ?? 'unknown'}`);
  const pid = child.pid;
  child.on('exit', (code, signal) => {
    // Drop the handle so the next ensureHelper respawns instead of treating a
    // dead child as alive. A spawn made while another daemon runs does not exit:
    // it waits on daemon.lock and takes over when that daemon goes away.
    child = undefined;
    if (code !== 0) log.error(`Loudini: helper pid ${pid} exited (${code ?? `signal ${signal}`}); respawns on next action.`);
  });
  child.on('error', (err) => {
    // A spawn failure emits 'error' with NO following 'exit', so exitCode and
    // signalCode both stay null — the liveness guard would read that as alive
    // and never retry. Clear the handle so the next action respawns.
    child = undefined;
    log.error(`Loudini: helper failed to start: ${err.message}`);
  });
}

/** Verbs run one at a time in press order: control.lock stops two writes from overlapping,
 * but not Up-then-Mute from landing as Mute-then-Up (which would leave audio unmuted). */
let verbQueue: Promise<void> = Promise.resolve();

/** Apply a volume verb (`up 6`, `down 6`, `mute`) through the bundled CLI. It takes
 * control.lock like every Swift writer, which Node cannot do itself (no flock). */
export function runVerb(args: string[]): Promise<void> {
  const run = verbQueue.then(
    () =>
      new Promise<void>((resolve, reject) => {
        execFile(HELPER, args, { timeout: 5000 }, (err) => (err ? reject(err) : resolve()));
      }),
  );
  // The next verb waits for this one whether it succeeded or failed.
  verbQueue = run.catch(() => undefined);
  return run;
}

export function stopHelper(): void {
  child?.kill('SIGTERM');
  child = undefined;
}
