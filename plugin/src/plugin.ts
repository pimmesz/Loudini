import streamDeck from '@elgato/streamdeck';
import { Mute, VolDown, VolUp } from './actions';
import { ensureHelper, stopHelper } from './helper';

const log = (m: string): void => {
  streamDeck.logger.info(m);
};

// A crash here resets every key on the board — log and keep running instead.
process.on('uncaughtException', (err) => {
  streamDeck.logger.error(`uncaught exception: ${err.stack ?? err.message}`);
});
process.on('unhandledRejection', (reason) => {
  streamDeck.logger.error(`unhandled rejection: ${String(reason)}`);
});

// Graceful exits stop our child daemon (audio fails open). On SIGKILL the
// daemon is orphaned but keeps working; its flock prevents duplicates later.
process.on('SIGTERM', () => {
  stopHelper();
  process.exit(0);
});
process.on('exit', () => stopHelper());

const actions = [new VolUp(), new VolDown(), new Mute()];
for (const a of actions) streamDeck.actions.registerAction(a);

ensureHelper(log);

// Faces track the live level no matter which frontend changes it (CLI,
// menu-bar app, volume keys) — status.json is the shared ground truth.
// Skip a tick while the previous refresh is still draining, so a slow
// (backpressured) Stream Deck WebSocket can't pile up un-awaited repaints.
let refreshing = false;
setInterval(() => {
  if (refreshing) return;
  refreshing = true;
  // allSettled (not all): clear the flag only once EVERY refresh has drained —
  // Promise.all rejects on the first failure and would re-open the gate while
  // other repaints are still pending. allSettled also swallows per-key rejections.
  void Promise.allSettled(actions.map((a) => a.refreshAll())).finally(() => {
    refreshing = false;
  });
}, 1000);

await streamDeck.connect();
log('Loudini plugin connected');
