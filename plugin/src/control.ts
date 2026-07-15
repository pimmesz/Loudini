import { mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

/**
 * The plugin ↔ helper contract (two JSON files in ~/.config/loudini):
 *  - control.json  — plugin WRITES the desired {gain 0-100, muted}; the helper reads it and applies it.
 *  - status.json   — helper WRITES {gain, muted, running, device}; the plugin reads it for display.
 * File-based on purpose: dead simple, survives either side restarting, no socket lifecycle.
 */
const DIR = join(homedir(), '.config', 'loudini');
const CONTROL = join(DIR, 'control.json');
const STATUS = join(DIR, 'status.json');

export interface Control {
  gain: number; // 0-100
  muted: boolean;
}
export interface Status extends Control {
  running: boolean;
  /** True only when the daemon's audio pipeline is actually rendering. */
  pipeline: boolean;
  device: string;
}

const clamp = (n: number): number => Math.max(0, Math.min(100, Math.round(Number.isFinite(n) ? n : 100)));

export function readControl(): Control {
  try {
    const c = JSON.parse(readFileSync(CONTROL, 'utf8')) as Partial<Control>;
    return { gain: clamp(Number(c.gain)), muted: Boolean(c.muted) };
  } catch {
    return { gain: 100, muted: false };
  }
}

let writeSeq = 0;

export function writeControl(c: Control): void {
  mkdirSync(DIR, { recursive: true });
  // Atomic write: unique temp file in the same dir, then rename(2). Several
  // frontends write this file concurrently and the daemon reads it every
  // 100 ms — a reader must never see a half-written file.
  const tmp = join(DIR, `.control.json.${process.pid}.${writeSeq++}.tmp`);
  try {
    writeFileSync(tmp, JSON.stringify({ gain: clamp(c.gain), muted: c.muted }));
    renameSync(tmp, CONTROL);
  } catch (err) {
    rmSync(tmp, { force: true }); // don't leave temp files behind on failure
    throw err;
  }
}

/** The helper's live status, or null if it hasn't written one yet (not running / first launch). */
export function readStatus(): Status | null {
  try {
    const s = JSON.parse(readFileSync(STATUS, 'utf8')) as Partial<Status> & { pid?: number };
    let running = Boolean(s.running);
    // Old status files predate "pipeline"; assume it followed running.
    let pipeline = s.pipeline === undefined ? running : Boolean(s.pipeline);
    // Truthful liveness: a SIGKILLed daemon strands running:true — probe its pid.
    if (running && typeof s.pid === 'number' && s.pid > 0) {
      try {
        process.kill(s.pid, 0);
      } catch (err) {
        if ((err as NodeJS.ErrnoException).code === 'ESRCH') {
          running = false;
          pipeline = false;
        }
      }
    }
    return {
      gain: clamp(Number(s.gain)),
      muted: Boolean(s.muted),
      running,
      pipeline,
      device: String(s.device ?? ''),
    };
  } catch {
    return null;
  }
}

/** Nudge the gain by delta (and un-mute — nudging implies you want to hear it). Returns the new control. */
export function nudge(delta: number): Control {
  const next: Control = { gain: clamp(readControl().gain + delta), muted: false };
  writeControl(next);
  return next;
}

export function toggleMute(): Control {
  const cur = readControl();
  const next: Control = { gain: cur.gain, muted: !cur.muted };
  writeControl(next);
  return next;
}
