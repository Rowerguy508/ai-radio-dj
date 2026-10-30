import { USED_TTL_SECONDS, usedKey, verifyChallenge, type ChallengeFailure, type Purpose } from './challenge.js';
import { ChallengeStoreError, type ChallengeStore } from './challenge-store.js';

export type ConsumeResult =
  | { ok: true }
  | { ok: false; status: 400; reason: 'challenge_expired' }
  | { ok: false; status: 401; reason: 'assertion'; detail: ChallengeFailure | 'signature' | 'reused' }
  | { ok: false; status: 503; reason: 'store' };

export interface ConsumeOptions {
  challenge: unknown;
  purpose: Purpose;
  keyId: Buffer | null;
  key: Buffer;
  now: number;
  store: ChallengeStore | null;
  /**
   * The endpoint's signature check (App Attest attestation or assertion). Runs
   * only after the stateless check passes; the challenge is consumed only if
   * it returns true.
   */
  verifySignature: () => Promise<boolean>;
}

/**
 * Order (note §4.1.1, Sentinel B1): stateless check → durable store present →
 * signature → SET NX. A failed check or signature writes nothing. Later PRs
 * move the SET NX into each endpoint's single script; the order stays.
 *
 * Expired challenge (PR 3, Fry/Sentinel/Orion on #246): 400 `challenge_expired`,
 * which the app treats as retryable once with a FRESH challenge. Returned only
 * when the challenge is otherwise valid: `verifyChallenge` checks MAC, version,
 * purpose, key binding and future skew before age, so `expired` implies all of
 * those passed. The request's signature must also verify, and the challenge
 * must not already be marked used (a read-only EXISTS; nothing is written for
 * an expired challenge). Anything else (forged, wrong purpose or key, bad
 * signature, reused) stays 401 `assertion`.
 */
export async function verifyAndConsumeChallenge(opts: ConsumeOptions): Promise<ConsumeResult> {
  const check = verifyChallenge(opts.challenge, { key: opts.key, purpose: opts.purpose, keyId: opts.keyId, now: opts.now });
  const expired = !check.ok && check.reason === 'expired';
  if (!check.ok && !expired) return { ok: false, status: 401, reason: 'assertion', detail: check.reason };
  if (!opts.store || opts.store.durable !== true) return { ok: false, status: 503, reason: 'store' };
  if (!(await opts.verifySignature())) return { ok: false, status: 401, reason: 'assertion', detail: 'signature' };
  if (expired) {
    let used: boolean;
    try {
      used = await opts.store.isUsed(usedKey(opts.challenge as string));
    } catch (error) {
      if (error instanceof ChallengeStoreError) return { ok: false, status: 503, reason: 'store' };
      throw error;
    }
    if (used) return { ok: false, status: 401, reason: 'assertion', detail: 'reused' };
    return { ok: false, status: 400, reason: 'challenge_expired' };
  }
  let first: boolean;
  try {
    first = await opts.store.markUsed(usedKey(opts.challenge as string), USED_TTL_SECONDS);
  } catch (error) {
    if (error instanceof ChallengeStoreError) return { ok: false, status: 503, reason: 'store' };
    throw error;
  }
  return first ? { ok: true } : { ok: false, status: 401, reason: 'assertion', detail: 'reused' };
}
