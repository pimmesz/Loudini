import streamDeck, {
  action,
  type KeyAction,
  type KeyDownEvent,
  SingletonAction,
  type WillAppearEvent,
} from '@elgato/streamdeck';
import { nudge, readControl, readStatus, toggleMute } from './control';
import { ensureHelper } from './helper';

const STEP = 6; // % per press (TODO: expose in the property inspector)
const log = (m: string): void => {
  streamDeck.logger.info(m);
};

/** Face text — prefer the helper's live status (ground truth); "off" when the helper isn't running. */
function levelTitle(): string {
  const s = readStatus();
  const { gain, muted } = s ?? readControl();
  if (s && !s.running) return 'off';
  if (s && !s.pipeline) return '⚠️'; // daemon up but not capturing (permission/device)
  return muted ? '🔇' : `${gain}%`;
}

async function paint(a: KeyAction): Promise<void> {
  await a.setTitle(levelTitle());
}

/** Shared behavior: ensure the daemon is up, apply the press, repaint. Subclasses only define the press. */
abstract class VolumeKey extends SingletonAction {
  protected abstract press(): void;

  override onWillAppear(ev: WillAppearEvent): Promise<void> | void {
    ensureHelper(log);
    if (ev.action.isKey()) return paint(ev.action);
  }

  override async onKeyDown(ev: KeyDownEvent): Promise<void> {
    ensureHelper(log);
    this.press();
    if (ev.action.isKey()) await paint(ev.action);
  }

  /** Repaint every visible instance — called on the plugin's refresh tick so all keys track the level. */
  async refreshAll(): Promise<void> {
    for (const a of this.actions) if (a.isKey()) await paint(a);
  }
}

@action({ UUID: 'gg.pim.loudini.up' })
export class VolUp extends VolumeKey {
  protected press(): void {
    nudge(STEP);
  }
}

@action({ UUID: 'gg.pim.loudini.down' })
export class VolDown extends VolumeKey {
  protected press(): void {
    nudge(-STEP);
  }
}

@action({ UUID: 'gg.pim.loudini.mute' })
export class Mute extends VolumeKey {
  protected press(): void {
    toggleMute();
  }
}
