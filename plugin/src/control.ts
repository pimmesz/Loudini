import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

/**
 * The plugin side of the contract (~/.config/loudini). The plugin never writes control.json:
 * key presses run the bundled CLI (see helper.ts), which takes control.lock like every other
 * writer. It only reads status.json, written by the helper as
 * {gain, muted, running, pipeline, device, pid, reason?, apps}, for display. `pid` is not on
 * the Status interface: readStatus() probes it and forces running:false when that process is
 * gone, so a hard-killed helper cannot read as healthy.
 * Parsing mirrors helper/ControlFile.swift: a field of the wrong type falls back to its default.
 */
const STATUS = join(homedir(), '.config', 'loudini', 'status.json');

export interface Status {
  gain: number; // 0-100
  muted: boolean;
  running: boolean;
  /** True only when the daemon's audio pipeline is actually rendering. */
  pipeline: boolean;
  device: string;
}

// Swift reads numbers with intValue, which truncates toward zero.
const gainOr = (v: unknown, fallback: number): number =>
  typeof v === 'number' && Number.isFinite(v) ? Math.max(0, Math.min(100, Math.trunc(v))) : fallback;
const boolOr = (v: unknown, fallback: boolean): boolean => (typeof v === 'boolean' ? v : fallback);

/** The helper's live status, or null if it hasn't written one yet (not running / first launch). */
export function readStatus(): Status | null {
  let s: unknown;
  try {
    s = JSON.parse(readFileSync(STATUS, 'utf8'));
  } catch {
    return null; // missing or mid-write; the next 1 s tick reads it again
  }
  if (typeof s !== 'object' || s === null || Array.isArray(s)) return null;
  const o = s as Record<string, unknown>;
  let running = boolOr(o.running, false);
  // Old status files predate "pipeline"; assume it followed running.
  let pipeline = boolOr(o.pipeline, running);
  // Truthful liveness: a SIGKILLed daemon strands running:true, so probe its pid.
  if (running && typeof o.pid === 'number' && o.pid > 0) {
    try {
      process.kill(o.pid, 0);
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code === 'ESRCH') {
        running = false;
        pipeline = false;
      }
    }
  }
  return {
    gain: gainOr(o.gain, 100),
    muted: boolOr(o.muted, false),
    running,
    pipeline,
    device: typeof o.device === 'string' ? o.device : '',
  };
}
