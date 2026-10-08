import streamDeck from '@elgato/streamdeck';
import { Mute, VolDown, VolUp } from './actions';
import { ensureHelper, stopHelper } from './helper';

const log = (m: string): void => {
  streamDeck.logger.info(m);
};

// A crash here resets every key on the board: log and keep running instead.
process.on('uncaughtException', (err) => {
  streamDeck.logger.error(`uncaught exception: ${err.stack ?? err.message}`);
});
process.on('unhandledRejection', (reason) => {
  streamDeck.logger.error(`unhandled rejection: ${String(reason)}`);
});

// Graceful exits stop our child daemon (audio fails open). On SIGKILL a running
// daemon is orphaned but keeps working; one still waiting on daemon.lock exits.
process.on('SIGTERM', () => {
  stopHelper();
  process.exit(0);
});
process.on('exit', () => stopHelper());

const actions = [new VolUp(), new VolDown(), new Mute()];
for (const a of actions) streamDeck.actions.registerAction(a);

ensureHelper(streamDeck.logger);

// Faces track the live level no matter which frontend changes it (CLI,
// menu-bar app, volume keys): status.json is the shared ground truth.
// Skip a tick while the previous refresh is still draining, so a slow
// (backpressured) Stream Deck WebSocket can't pile up un-awaited repaints.
let refreshing = false;
// Log a repaint failure once per failure streak, not once a second.
let isRepaintFailing = false;
setInterval(() => {
  if (refreshing) return;
  refreshing = true;
  // allSettled (not all): clear the flag only once EVERY refresh has drained.
  // Promise.all rejects on the first failure and would re-open the gate while
  // other repaints are still pending.
  void Promise.allSettled(actions.map((a) => a.refreshAll()))
    .then((results) => {
      const failed = results.find((r): r is PromiseRejectedResult => r.status === 'rejected');
      if (failed && !isRepaintFailing) streamDeck.logger.error(`Loudini: key repaint failed: ${String(failed.reason)}`);
      isRepaintFailing = failed !== undefined;
    })
    .finally(() => {
      refreshing = false;
    });
}, 1000);

await streamDeck.connect();
log('Loudini plugin connected');
