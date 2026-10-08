import streamDeck, {
  action,
  type KeyAction,
  type KeyDownEvent,
  SingletonAction,
  type WillAppearEvent,
} from '@elgato/streamdeck';
import { parseLevel, readStatus } from './control';
import { ensureHelper, runVerb } from './helper';

const STEP = 6; // % per press (TODO: expose in the property inspector)

/** The level the last press wrote (from the CLI's output), and when. status.json lags it by
 * up to one daemon poll, so for a short while it wins, also on the refresh tick. */
let lastPress: { gain: number; muted: boolean; at: number } | null = null;
const PRESS_WINS_MS = 1000;

/** Face text from the helper's live status (ground truth). "off" until a helper has written
 * one, so a missing or failed helper never shows a level that is not being applied. */
function levelTitle(): string {
  const s = readStatus();
  if (!s || !s.running) return 'off';
  if (!s.pipeline) return '⚠️'; // daemon up but not capturing (permission/device)
  const recent = lastPress && Date.now() - lastPress.at < PRESS_WINS_MS ? lastPress : null;
  const { gain, muted } = recent ?? s;
  return muted ? '🔇' : `${gain}%`;
}

async function paint(a: KeyAction): Promise<void> {
  await a.setTitle(levelTitle());
}

/** Shared behavior: ensure the daemon is up, apply the press, repaint. Subclasses only define the press. */
abstract class VolumeKey extends SingletonAction {
  protected abstract press(): Promise<string>;

  override onWillAppear(ev: WillAppearEvent): Promise<void> | void {
    ensureHelper(streamDeck.logger);
    if (ev.action.isKey()) return paint(ev.action);
  }

  override async onKeyDown(ev: KeyDownEvent): Promise<void> {
    ensureHelper(streamDeck.logger);
    let out = '';
    try {
      out = await this.press();
    } catch (err) {
      // A failed press must not swallow the repaint: otherwise the key face keeps
      // showing the stale level and the user can't tell the press was lost.
      streamDeck.logger.error(`Loudini: volume change failed: ${String(err)}`);
    }
    const level = parseLevel(out);
    if (level) lastPress = { ...level, at: Date.now() };
    if (ev.action.isKey()) await paint(ev.action);
  }

  /** Repaint every visible instance, called on the plugin's refresh tick so all keys track the
   * level. allSettled so one failed key does not skip the rest; the first failure is rethrown. */
  async refreshAll(): Promise<void> {
    const keys = [...this.actions].filter((a): a is KeyAction => a.isKey());
    const results = await Promise.allSettled(keys.map((a) => paint(a)));
    const failed = results.find((r): r is PromiseRejectedResult => r.status === 'rejected');
    if (failed) throw failed.reason;
  }
}

@action({ UUID: 'gg.pim.loudini.up' })
export class VolUp extends VolumeKey {
  protected press(): Promise<string> {
    return runVerb(['up', String(STEP)]);
  }
}

@action({ UUID: 'gg.pim.loudini.down' })
export class VolDown extends VolumeKey {
  protected press(): Promise<string> {
    return runVerb(['down', String(STEP)]);
  }
}

@action({ UUID: 'gg.pim.loudini.mute' })
export class Mute extends VolumeKey {
  protected press(): Promise<string> {
    return runVerb(['mute']);
  }
}
