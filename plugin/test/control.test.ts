// Contract tests for src/control.ts, mirroring helper/ControlFileTests.swift. Run: pnpm test.
//
// control.ts resolves ~/.config/loudini from os.homedir() when it is imported, so HOME must
// point at a throwaway directory BEFORE the import, or these tests would touch the real
// status.json. node --test runs each file in its own process, so the override cannot leak.
import { mkdirSync, mkdtempSync, realpathSync, writeFileSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { test } from 'node:test';
import assert from 'node:assert/strict';

const home = mkdtempSync(join(tmpdir(), 'loudini-plugin-test-'));
process.env.HOME = home;
if (!realpathSync(homedir()).startsWith(realpathSync(tmpdir()))) {
  console.error(`REFUSING TO RUN: home ${homedir()} is not a temp directory`);
  process.exit(2);
}
const dir = join(home, '.config', 'loudini');
mkdirSync(dir, { recursive: true });
const { parseLevel, readStatus } = await import('../src/control.ts');

const writeStatus = (text: string): void => writeFileSync(join(dir, 'status.json'), text);
const deadPid = (): number => spawnSync('/usr/bin/true').pid;

test('a live daemon reads as running with its values', () => {
  writeStatus(JSON.stringify({ gain: 42, muted: true, running: true, pipeline: true, device: 'Scarlett', pid: process.pid }));
  assert.deepEqual(readStatus(), { gain: 42, muted: true, running: true, pipeline: true, device: 'Scarlett' });
});

test('a missing pipeline key follows a live running', () => {
  writeStatus(JSON.stringify({ running: true, pid: process.pid }));
  assert.equal(readStatus()?.pipeline, true);
});

test('a dead daemon pid forces running and pipeline false', () => {
  writeStatus(JSON.stringify({ gain: 80, running: true, pipeline: true, pid: deadPid() }));
  const s = readStatus();
  assert.equal(s?.running, false);
  assert.equal(s?.pipeline, false);
  assert.equal(s?.gain, 80);
});

test('a null gain keeps the default 100, as Swift does', () => {
  writeStatus(JSON.stringify({ gain: null, running: false }));
  assert.equal(readStatus()?.gain, 100);
});

test('string booleans are ignored, as Swift does', () => {
  writeStatus(JSON.stringify({ muted: 'false', running: 'false', pipeline: 'true' }));
  const s = readStatus();
  assert.equal(s?.muted, false);
  assert.equal(s?.running, false);
  assert.equal(s?.pipeline, false);
});

test('a float gain truncates and out-of-range gain clamps', () => {
  writeStatus(JSON.stringify({ gain: 50.6 }));
  assert.equal(readStatus()?.gain, 50);
  writeStatus(JSON.stringify({ gain: 420 }));
  assert.equal(readStatus()?.gain, 100);
  writeStatus(JSON.stringify({ gain: -7 }));
  assert.equal(readStatus()?.gain, 0);
});

test('a non-string device reads as empty', () => {
  writeStatus(JSON.stringify({ device: 7 }));
  assert.equal(readStatus()?.device, '');
});

test('malformed or non-object files read as no status', () => {
  writeStatus('{"gain":70,"mut');
  assert.equal(readStatus(), null);
  writeStatus('[1,2,3]');
  assert.equal(readStatus(), null);
  writeStatus('null');
  assert.equal(readStatus(), null);
});

test('the level the CLI prints after a press parses', () => {
  assert.deepEqual(parseLevel('gain=46 muted=false\n'), { gain: 46, muted: false });
  assert.deepEqual(parseLevel('gain=0 muted=true\n'), { gain: 0, muted: true });
  assert.equal(parseLevel('gain=146 muted=false')?.gain, 100);
});

test('unexpected CLI output falls back to status.json', () => {
  assert.equal(parseLevel(''), null);
  assert.equal(parseLevel('gain=46'), null);
  assert.equal(parseLevel('gain=-1 muted=false'), null);
});
