import crypto from 'node:crypto';
import { PRO_BUCKET } from './limiter.js';
import { isVerifiedTransaction, type VerifiedTransaction } from './storekit-verify.js';

/**
 * Pro daily allowance (owner decision, 2026-10-29 9:19 PM ET, relayed by Orion):
 * "Pro gets 40 premium breaks a day", then the app uses the on-device voice for the
 * rest of the day.
 *
 * The proxy cannot see a break: the app renders each cloud cue of a break as its own
 * `/api/tts` request (VoiceRenderer renders a handoff cue by cue). So the server counts
 * RENDERS (accepted `/api/tts` requests, each still under the 600-character cap) and
 * sizes the allowance so a Pro user never gets fewer than 40 full breaks:
 *
 *   max cloud renders in one break = 4 (DJScriptWriter.plan, DJNarration.swift):
 *     transition break: opener (greeting | artist focus | back-announce) + color
 *                       + continuation + closing line = 4
 *     briefing break:   opener + briefing lead + briefing outro + closing line = 4
 *                       (the briefing items themselves are personal and local-only,
 *                       VoiceRenderer.mayLeaveDevice, so they never reach the proxy)
 *   allowance = 40 breaks x 4 renders = 160 renders per Pro user per UTC day.
 *
 * Cache hits never reach the proxy, so a typical day gets more than 40 breaks; never fewer.
 *
 * Identity (Sentinel's B2): a `ProSubject` is minted only by `proSubjectFromVerified`, and
 * only from the frozen, branded `VerifiedTransaction` that `verifySignedTransaction`
 * returned; a hand-built `{ originalTransactionId }` throws. It holds only SHA-256 of
 * `originalTransactionId`. Nothing a client sends (body field or header) can name or
 * select the bucket, and the raw id never enters a key or a log.
 *
 * Deployment (Sentinel's B3): every Pro key (renders, chars, rate) carries the deployment
 * from `VERCEL_ENV` on a strict allow-list (production | preview | development; anything
 * else, unset included, is 500 `misconfig` on the Pro path), so a Preview Sandbox
 * purchase never writes a key Production reads: bucket `pro:<deployment>:<sha256>`.
 *
 * Counting (src/limiter.ts `reservePro`, ONE atomic EVAL), in this order: the global
 * ceiling first (Sentinel), then the render allowance, then the subscriber's own daily
 * char cap (`AERODJ_TTS_PRO_DAILY_CHARS`, clamped to the global ceiling). Any refusal
 * changes no counter. Pro traffic never charges the owner or an install bucket (B1), so
 * the per-install 1,500/day cap does not apply to a verified Pro subject; global still does.
 *
 * Day boundary: the UTC calendar day, the same as every other daily limit here
 * (`utcDay`), resetting at 00:00 UTC. Counters live 2 days (TTL), like the char counters.
 *
 * Durable only (note §4.3): like per-install quotas, the Pro allowance never runs on a
 * per-instance in-memory store in a request path; the handler refuses a Pro request with
 * 503 `store` unless the limiter is durable.
 */
export const PRO_DAILY_BREAKS = 40;
export const MAX_CLOUD_RENDERS_PER_BREAK = 4;
export const PRO_DAILY_RENDER_ALLOWANCE = PRO_DAILY_BREAKS * MAX_CLOUD_RENDERS_PER_BREAK;

const issued = new WeakSet<object>();

/** One Pro purchase. Only `proSubjectFromVerified` creates one. */
export interface ProSubject {
  readonly kind: 'pro';
  /** SHA-256 hex of `originalTransactionId`, never the raw id. */
  readonly hash: string;
}

/**
 * The Pro subject for a transaction `verifySignedTransaction` verified. Throws for anything
 * else, a hand-built `{ originalTransactionId }` included (B2), and for a missing or oversized id.
 */
export function proSubjectFromVerified(transaction: VerifiedTransaction): ProSubject {
  if (!isVerifiedTransaction(transaction)) throw new TypeError('unverified transaction');
  const id = transaction.originalTransactionId;
  if (typeof id !== 'string' || id.length === 0 || id.length > 256) throw new TypeError('invalid transaction');
  const subject: ProSubject = Object.freeze({
    kind: 'pro' as const,
    hash: crypto.createHash('sha256').update(id, 'utf8').digest('hex'),
  });
  issued.add(subject);
  return subject;
}

/** True only for a subject minted by `proSubjectFromVerified` (not a hand-built look-alike). */
export function isVerifiedProSubject(value: unknown): value is ProSubject {
  return typeof value === 'object' && value !== null && issued.has(value);
}

export type ProDeployment = 'production' | 'preview' | 'development';

/** `VERCEL_ENV` on a strict allow-list; null (500 `misconfig` on the Pro path) for anything else, unset included. */
export function proDeployment(env: Readonly<Record<string, string | undefined>>): ProDeployment | null {
  const v = env.VERCEL_ENV;
  return v === 'production' || v === 'preview' || v === 'development' ? v : null;
}

/** The bucket every Pro key (renders, chars, rate) derives from: `pro:<deployment>:<sha256>`. */
export function proBucket(subject: ProSubject, deployment: ProDeployment): string {
  const bucket = `pro:${deployment}:${subject.hash}`;
  if (!PRO_BUCKET.test(bucket)) throw new TypeError('invalid pro bucket');
  return bucket;
}
