import crypto from 'node:crypto';
import {
  newReservationId,
  upstashEval,
  utcDay,
  type RedisRestConfig,
  LimiterStoreError,
} from './limiter.js';
import type { VerifiedTransaction } from './storekit-verify.js';
import { UPSTASH_FETCH_TIMEOUT_MS } from './upstash.js';

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
 * Identity: only a server-verified purchase. A `ProSubject` is minted only by
 * `proSubjectFromVerified` from a `VerifiedTransaction` (the output of
 * `verifySignedTransaction`), keyed on SHA-256 of its `originalTransactionId`. Nothing a
 * client sends can name or select the bucket, and the raw id never enters a key or a log.
 *
 * Day boundary: the UTC calendar day, the same as every other daily limit here
 * (`utcDay`), resetting at 00:00 UTC. Counters live 2 days (TTL), like the char counters.
 *
 * Durable only (note §4.3, Sentinel B3): like per-install quotas, the Pro allowance never
 * runs on a per-instance in-memory store in a request path; the handler refuses with 503
 * `store` unless the store is durable.
 */
export const PRO_DAILY_BREAKS = 40;
export const MAX_CLOUD_RENDERS_PER_BREAK = 4;
export const PRO_DAILY_RENDER_ALLOWANCE = PRO_DAILY_BREAKS * MAX_CLOUD_RENDERS_PER_BREAK;

const issued = new WeakSet<object>();

/** One Pro purchase's allowance bucket. Only `proSubjectFromVerified` creates one. */
export interface ProSubject {
  readonly kind: 'pro';
  /** `pro:<sha256(originalTransactionId)>`, never the raw id. */
  readonly bucket: string;
}

/** The Pro subject for a transaction the server verified. Throws on a missing/oversized id. */
export function proSubjectFromVerified(transaction: Pick<VerifiedTransaction, 'originalTransactionId'>): ProSubject {
  const id = transaction?.originalTransactionId;
  if (typeof id !== 'string' || id.length === 0 || id.length > 256) throw new TypeError('invalid transaction');
  const subject: ProSubject = Object.freeze({
    kind: 'pro' as const,
    bucket: `pro:${crypto.createHash('sha256').update(id, 'utf8').digest('hex')}`,
  });
  issued.add(subject);
  return subject;
}

/** True only for a subject minted by `proSubjectFromVerified` (not a hand-built look-alike). */
export function isVerifiedProSubject(value: unknown): value is ProSubject {
  return typeof value === 'object' && value !== null && issued.has(value);
}

export interface ProReservation {
  readonly rid: string;
  readonly bucket: string;
  /** UTC day (YYYY-MM-DD) the render was counted against. */
  readonly day: string;
}

export type ProReserveResult = { readonly ok: true; readonly reservation: ProReservation } | { readonly ok: false };

export interface ProAllowanceStore {
  readonly durable: boolean;
  /** Atomically counts one render for today (UTC), or refuses with no change when the allowance is used up. */
  reserve(subject: ProSubject, now: number): Promise<ProReserveResult>;
  /** Returns one render (floored at zero), at most once per `rid`. True if this call applied it. */
  release(reservation: ProReservation): Promise<boolean>;
}

const KEY_PREFIX = 'aerodj-tts';
const DAY_TTL_SECONDS = 2 * 24 * 60 * 60;
const RID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/** Day counter for one Pro bucket: `aerodj-tts:renders:pro:<sha256>:<day>`. */
export function proDayKey(bucket: string, day: string): string {
  if (!/^pro:[0-9a-f]{64}$/.test(bucket)) throw new TypeError('invalid pro bucket');
  return `${KEY_PREFIX}:renders:${bucket}:${day}`;
}

/** Refund marker for one Pro render: `refund:{aerodj-tts}:pro:<rid>` (separate from char refunds). */
export function proRefundMarkerKey(rid: string): string {
  if (typeof rid !== 'string' || !RID.test(rid)) throw new TypeError('invalid reservation id');
  return `refund:{aerodj-tts}:pro:${rid}`;
}

/**
 * KEYS[1] = Pro day counter; ARGV = allowance, ttl s.
 * Returns -1 (no change) when the counter is already at the allowance, else INCRs it,
 * sets the TTL and returns the new count (1..allowance).
 */
export const PRO_RESERVE_SCRIPT = `local used = tonumber(redis.call('GET', KEYS[1]) or '0')
if used >= tonumber(ARGV[1]) then return -1 end
local n = redis.call('INCR', KEYS[1])
redis.call('EXPIRE', KEYS[1], ARGV[2])
return n`;

/**
 * KEYS[1] = Pro day counter, KEYS[2] = refund marker; ARGV = marker ttl s.
 * At most once per render: SET marker NX EX; if it exists, returns 0. Otherwise
 * decrements the counter (floored at zero, keeping its TTL) and returns 1.
 */
export const PRO_RELEASE_SCRIPT = `if not redis.call('SET', KEYS[2], '1', 'NX', 'EX', ARGV[1]) then return 0 end
local used = tonumber(redis.call('GET', KEYS[1]) or '0')
if used > 0 then redis.call('SET', KEYS[1], used - 1, 'KEEPTTL') end
return 1`;

export class RedisProAllowance implements ProAllowanceStore {
  readonly durable = true;

  constructor(
    private readonly config: RedisRestConfig,
    private readonly allowance: number = PRO_DAILY_RENDER_ALLOWANCE,
    private readonly fetchImpl: typeof fetch = globalThis.fetch,
    private readonly timeoutMs: number = UPSTASH_FETCH_TIMEOUT_MS,
  ) {}

  async reserve(subject: ProSubject, now: number): Promise<ProReserveResult> {
    const day = utcDay(now);
    const result = await upstashEval(this.config, this.fetchImpl, this.timeoutMs, PRO_RESERVE_SCRIPT, [proDayKey(subject.bucket, day)], [
      this.allowance,
      DAY_TTL_SECONDS,
    ]);
    if (result === -1) return { ok: false };
    // Success is the new count: 1..allowance. Anything else is a store fault (503), never a grant.
    if (result < 1 || result > this.allowance) throw new LimiterStoreError('limiter store error');
    return { ok: true, reservation: { rid: newReservationId(), bucket: subject.bucket, day } };
  }

  async release(reservation: ProReservation): Promise<boolean> {
    const result = await upstashEval(
      this.config,
      this.fetchImpl,
      this.timeoutMs,
      PRO_RELEASE_SCRIPT,
      [proDayKey(reservation.bucket, reservation.day), proRefundMarkerKey(reservation.rid)],
      [DAY_TTL_SECONDS],
    );
    if (result !== 0 && result !== 1) throw new LimiterStoreError('limiter store error');
    return result === 1;
  }
}

/** Per-instance counterpart for unit tests only (not durable, so the handler refuses it). */
export class InMemoryProAllowance implements ProAllowanceStore {
  readonly durable = false;
  private readonly counts = new Map<string, number>();
  private readonly refunded = new Set<string>();

  constructor(private readonly allowance: number = PRO_DAILY_RENDER_ALLOWANCE) {}

  async reserve(subject: ProSubject, now: number): Promise<ProReserveResult> {
    const key = proDayKey(subject.bucket, utcDay(now));
    const used = this.counts.get(key) ?? 0;
    if (used >= this.allowance) return { ok: false };
    this.counts.set(key, used + 1);
    return { ok: true, reservation: { rid: newReservationId(), bucket: subject.bucket, day: utcDay(now) } };
  }

  async release(reservation: ProReservation): Promise<boolean> {
    const marker = proRefundMarkerKey(reservation.rid);
    if (this.refunded.has(marker)) return false;
    this.refunded.add(marker);
    const key = proDayKey(reservation.bucket, reservation.day);
    this.counts.set(key, Math.max(0, (this.counts.get(key) ?? 0) - 1));
    return true;
  }

  used(subject: ProSubject, now: number): number {
    return this.counts.get(proDayKey(subject.bucket, utcDay(now))) ?? 0;
  }
}
