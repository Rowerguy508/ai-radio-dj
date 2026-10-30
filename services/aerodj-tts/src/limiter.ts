import crypto from 'node:crypto';
import { UPSTASH_FETCH_TIMEOUT_MS, untilAborted } from './upstash.js';

/**
 * Usage limiter: per-minute request rate plus an atomic daily character budget on two
 * buckets at once: the caller's own bucket (owner, or one install) and a global ceiling.
 *
 * The daily budget is RESERVED before the upstream render and RELEASED (refunded)
 * only when the upstream definitely did not bill (a non-2xx response). A reservation
 * is a single atomic check-and-add, so concurrent requests can never jointly exceed
 * the cap: with 600 characters left, two concurrent 600-character requests get one
 * reservation and one 429.
 *
 * Two implementations:
 * - `RedisUsageLimiter` (durable, shared across all serverless instances): Upstash
 *   Redis over its REST API, each operation one Lua script (atomic in Redis). This is
 *   the only implementation that enforces a hard cap on Vercel.
 * - `InMemoryUsageLimiter`: atomic within ONE instance only. Parallel instances and
 *   cold starts each get fresh counters, so on Vercel it is best-effort. Used by tests
 *   and local dev, and in production only if the owner explicitly opts in
 *   (`AERODJ_TTS_ACCEPT_BEST_EFFORT_LIMITS=true`).
 */
/**
 * Who a request is charged to.
 * - `owner`: the owner bearer token (today's only authenticated caller). It has its own
 *   bucket and cap (`ownerDailyCharCap`, default = the global ceiling, so the owner keeps
 *   today's behaviour of one 9k/day budget), and is still counted in the global ceiling.
 * - `install`: one app install (an App Attest key id, PR 3-4 of the design note). Not
 *   reachable from any request yet: the handler only ever builds `OWNER_SUBJECT`.
 * Every subject also reserves against the global daily ceiling.
 */
export type Subject = { readonly kind: 'owner' } | { readonly kind: 'install'; readonly id: string };

export const OWNER_SUBJECT: Subject = Object.freeze({ kind: 'owner' });

/** Why a reservation was refused. Enum only; it is the 429 `reason` on the wire. */
export type QuotaReason = 'owner_daily' | 'install_daily' | 'global_daily';

/**
 * Store bucket for a subject. Install ids are hashed, so a raw id never becomes part of
 * a store key and no separator or wildcard in it can address another bucket.
 */
export function subjectBucket(subject: Subject): string {
  if (subject.kind === 'owner') return 'owner';
  if (typeof subject.id !== 'string' || subject.id.length === 0 || subject.id.length > 256) {
    throw new TypeError('invalid install id');
  }
  return `install:${crypto.createHash('sha256').update(subject.id, 'utf8').digest('hex')}`;
}

export const GLOBAL_BUCKET = 'global';

export interface Reservation {
  /**
   * Server-generated reservation id (a random UUID, never from the client). A refund is
   * applied at most once per `rid` (Fry D2, note §4.3): the second `release()` of the
   * same reservation is a no-op on both limiters.
   */
  readonly rid: string;
  /** The subject's own bucket (`owner` or `install:<sha256>`). */
  readonly bucket: string;
  /** UTC day (YYYY-MM-DD) the characters were reserved against. */
  readonly day: string;
  readonly chars: number;
}

export type ReserveResult =
  | { readonly ok: true; readonly reservation: Reservation }
  | { readonly ok: false; readonly reason: QuotaReason };

export interface UsageLimiter {
  /** True when backed by a store shared by every instance. */
  readonly durable: boolean;
  /** Counts one request for `bucket`; false if over the per-minute rate. */
  allowRequest(bucket: string, now: number): Promise<boolean>;
  /**
   * Atomically reserves `chars` of today's (UTC) budget on BOTH the subject's bucket and
   * the global bucket, or on neither: a refusal changes no counter.
   */
  reserve(subject: Subject, chars: number, now: number): Promise<ReserveResult>;
  /**
   * Returns a reservation's characters to both of its day's buckets (never below zero),
   * at most once per `reservation.rid`. Resolves true if this call applied the refund,
   * false if that reservation was already refunded.
   */
  release(reservation: Reservation): Promise<boolean>;
}

export interface LimiterOptions {
  /** Global daily ceiling across every caller (owner and installs together). */
  dailyCharCap: number;
  /** Daily cap for the owner bucket. Default: the global ceiling. */
  ownerDailyCharCap?: number;
  /** Daily cap for one install's bucket. Default `DEFAULT_INSTALL_DAILY_CHAR_CAP`. */
  installDailyCharCap?: number;
  requestsPerMinute: number;
}

export const DEFAULT_GLOBAL_DAILY_CHAR_CAP = 9_000;
export const DEFAULT_INSTALL_DAILY_CHAR_CAP = 1_500;
/** Above this a configured cap is treated as a mistake and the default applies (never unlimited). */
export const MAX_CONFIGURED_CHAR_CAP = 10_000_000;
export const DEFAULT_REQUESTS_PER_MINUTE = 12;
/**
 * Above this a configured per-minute rate is treated as a mistake and the default applies,
 * the same rule as the caps (so `1e9`, `Infinity` or `99999999` can never disable the rate limit).
 */
export const MAX_CONFIGURED_REQUESTS_PER_MINUTE = 600;

/** The cap for a subject's own bucket. */
export function subjectCap(subject: Subject, options: LimiterOptions): number {
  return subject.kind === 'owner'
    ? options.ownerDailyCharCap ?? options.dailyCharCap
    : options.installDailyCharCap ?? DEFAULT_INSTALL_DAILY_CHAR_CAP;
}

/** The refusal reason when the subject's own bucket is full. */
function subjectReason(subject: Subject): QuotaReason {
  return subject.kind === 'owner' ? 'owner_daily' : 'install_daily';
}

/** Refund-marker lifetime (s): 2 days, the same as the day counters it protects. */
export const REFUND_MARKER_TTL_SECONDS = 172_800;
const RID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/** A fresh server-side reservation id. */
export function newReservationId(): string {
  return crypto.randomUUID();
}

/** Refund marker key for one reservation (note §4.3): `refund:{aerodj-tts}:<rid>`. */
export function refundMarkerKey(rid: string): string {
  if (typeof rid !== 'string' || !RID.test(rid)) throw new TypeError('invalid reservation id');
  return `refund:{aerodj-tts}:${rid}`;
}

export function utcDay(now: number): string {
  return new Date(now).toISOString().slice(0, 10);
}

export function utcMinute(now: number): number {
  return Math.floor(now / 60_000);
}

export class InMemoryUsageLimiter implements UsageLimiter {
  readonly durable = false;
  private readonly windows = new Map<string, number[]>();
  private readonly spend = new Map<string, { day: string; chars: number }>();
  /** Refunded reservation ids (per instance), with the day each was reserved against. */
  private readonly refunded = new Map<string, string>();

  constructor(private readonly options: LimiterOptions) {}

  // Every method mutates state synchronously, before any await, so each call is
  // atomic with respect to other requests on the same instance.

  async allowRequest(bucket: string, now: number): Promise<boolean> {
    const recent = (this.windows.get(bucket) ?? []).filter((t) => now - t < 60_000);
    if (recent.length >= this.options.requestsPerMinute) {
      this.windows.set(bucket, recent);
      return false;
    }
    recent.push(now);
    this.windows.set(bucket, recent);
    return true;
  }

  async reserve(subject: Subject, chars: number, now: number): Promise<ReserveResult> {
    const day = utcDay(now);
    const bucket = subjectBucket(subject);
    // Same order as RESERVE2_SCRIPT: the subject's own cap first, then the global ceiling.
    if (this.used(bucket, now) + chars > subjectCap(subject, this.options)) return { ok: false, reason: subjectReason(subject) };
    if (this.used(GLOBAL_BUCKET, now) + chars > this.options.dailyCharCap) return { ok: false, reason: 'global_daily' };
    this.spend.set(bucket, { day, chars: this.used(bucket, now) + chars });
    this.spend.set(GLOBAL_BUCKET, { day, chars: this.used(GLOBAL_BUCKET, now) + chars });
    return { ok: true, reservation: { rid: newReservationId(), bucket, day, chars } };
  }

  async release(reservation: Reservation): Promise<boolean> {
    // Per-charge refund marker (Fry D2): the same rule as RELEASE2_SCRIPT's SET NX.
    const marker = refundMarkerKey(reservation.rid);
    if (this.refunded.has(marker)) return false;
    this.refunded.set(marker, reservation.day);
    // Like the Redis marker's 2-day TTL: a marker for a day whose counters are gone can
    // never matter again, so the set stays bounded on a long-lived instance.
    const horizon = Date.parse(`${reservation.day}T00:00:00Z`) - REFUND_MARKER_TTL_SECONDS * 1000;
    for (const [key, day] of this.refunded) if (Date.parse(`${day}T00:00:00Z`) < horizon) this.refunded.delete(key);
    for (const bucket of [reservation.bucket, GLOBAL_BUCKET]) {
      const entry = this.spend.get(bucket);
      if (!entry || entry.day !== reservation.day) continue;
      entry.chars = Math.max(0, entry.chars - reservation.chars);
    }
    return true;
  }

  /** Test/diagnostic helper: characters currently counted for `bucket` today. */
  used(bucket: string, now: number): number {
    const entry = this.spend.get(bucket);
    return entry && entry.day === utcDay(now) ? entry.chars : 0;
  }
}

// --- Durable: Upstash Redis (REST) ------------------------------------------------

/** KEYS[1] = minute counter; ARGV = limit, ttl ms. Returns 1 if allowed, 0 if not. */
export const RATE_SCRIPT = `local n = redis.call('INCR', KEYS[1])
if n == 1 then redis.call('PEXPIRE', KEYS[1], ARGV[2]) end
if n > tonumber(ARGV[1]) then return 0 end
return 1`;

/**
 * KEYS[1] = subject day counter, KEYS[2] = global day counter;
 * ARGV = chars, subject cap, global cap, ttl s.
 * All-or-nothing: returns -1 if the subject's cap would be exceeded, -2 if the global
 * ceiling would be, and changes NO counter in either case. Otherwise increments both and
 * returns the subject's new total.
 */
export const RESERVE2_SCRIPT = `local c = tonumber(ARGV[1])
local used = tonumber(redis.call('GET', KEYS[1]) or '0')
if used + c > tonumber(ARGV[2]) then return -1 end
local total = tonumber(redis.call('GET', KEYS[2]) or '0')
if total + c > tonumber(ARGV[3]) then return -2 end
local n = redis.call('INCRBY', KEYS[1], c)
redis.call('EXPIRE', KEYS[1], ARGV[4])
redis.call('INCRBY', KEYS[2], c)
redis.call('EXPIRE', KEYS[2], ARGV[4])
return n`;

/**
 * KEYS[1] = subject day counter, KEYS[2] = global day counter, KEYS[3] = refund marker
 * (`refund:{aerodj-tts}:<rid>`); ARGV = chars, marker ttl s.
 * At most once per reservation (Fry D2): first `SET marker 1 NX EX ttl`; if the marker
 * already exists, returns 0 and changes nothing. Otherwise decrements both counters,
 * floored at zero, keeping their TTLs, and returns 1.
 */
export const RELEASE2_SCRIPT = `if not redis.call('SET', KEYS[3], '1', 'NX', 'EX', ARGV[2]) then return 0 end
local c = tonumber(ARGV[1])
for i = 1, 2 do
  local used = tonumber(redis.call('GET', KEYS[i]) or '0')
  if used > 0 then
    local n = used - c
    if n < 0 then n = 0 end
    redis.call('SET', KEYS[i], n, 'KEEPTTL')
  end
end
return 1`;

const KEY_PREFIX = 'aerodj-tts';
const DAY_TTL_SECONDS = 2 * 24 * 60 * 60;
const MINUTE_TTL_MS = 120_000;

/**
 * [subject, global] day counters. The owner key is unchanged from the single-bucket
 * limiter (`aerodj-tts:chars:owner:<day>`), so a deploy keeps today's owner count.
 */
export function dayKeys(bucket: string, day: string): [string, string] {
  return [`${KEY_PREFIX}:chars:${bucket}:${day}`, `${KEY_PREFIX}:chars:${GLOBAL_BUCKET}:${day}`];
}

export class LimiterStoreError extends Error {
  /** True when the Upstash call hit its time bound (UPSTASH_FETCH_TIMEOUT_MS), not a store reply. */
  constructor(message: string, readonly timedOut = false) {
    super(message);
  }
}

/**
 * Upstash REST returns a Lua integer reply as a JSON number. Anything else (null from a
 * nil reply, booleans, floats, strings, objects) is a store error, never coerced: with
 * Number(), null read as 0 ("already refunded" / reserve success) and true as 1 (Fry N2).
 */
export function strictRedisInteger(value: unknown): number {
  if (typeof value !== 'number' || !Number.isSafeInteger(value)) throw new LimiterStoreError('limiter store error');
  return value;
}

export interface RedisRestConfig {
  url: string;
  token: string;
}

/** Reads the Upstash REST credentials Vercel's Upstash integration (or Upstash directly) provides. */
export function redisRestConfig(env: Record<string, string | undefined>): RedisRestConfig | null {
  const url = (env.KV_REST_API_URL ?? env.UPSTASH_REDIS_REST_URL)?.trim();
  const token = (env.KV_REST_API_TOKEN ?? env.UPSTASH_REDIS_REST_TOKEN)?.trim();
  if (!url || !token || !url.startsWith('https://')) return null;
  return { url: url.replace(/\/+$/, ''), token };
}

export class RedisUsageLimiter implements UsageLimiter {
  readonly durable = true;

  constructor(
    private readonly config: RedisRestConfig,
    private readonly options: LimiterOptions,
    private readonly fetchImpl: typeof fetch = globalThis.fetch,
    /** Bound on each Upstash call; a timeout is a LimiterStoreError (503 `store`). */
    private readonly timeoutMs: number = UPSTASH_FETCH_TIMEOUT_MS,
  ) {}

  /** One EVAL over Upstash's REST API. Any transport or store error, or a timeout, throws (the handler fails closed). */
  private async eval(script: string, keys: string[], args: (string | number)[]): Promise<number> {
    const signal = AbortSignal.timeout(this.timeoutMs);
    let response: Response;
    try {
      response = await untilAborted(
        this.fetchImpl(this.config.url, {
          method: 'POST',
          headers: { Authorization: `Bearer ${this.config.token}`, 'Content-Type': 'application/json' },
          body: JSON.stringify(['EVAL', script, keys.length, ...keys, ...args.map(String)]),
          signal,
        }),
        signal,
      );
    } catch {
      throw new LimiterStoreError('limiter store unreachable', signal.aborted);
    }
    if (!response.ok) {
      await response.body?.cancel().catch(() => {});
      throw new LimiterStoreError('limiter store error');
    }
    const payload = (await untilAborted(response.json(), signal).catch(() => null)) as { result?: unknown } | null;
    if (!payload || typeof payload !== 'object' || 'error' in payload) throw new LimiterStoreError('limiter store error', signal.aborted);
    return strictRedisInteger(payload.result);
  }

  async allowRequest(bucket: string, now: number): Promise<boolean> {
    const k = `${KEY_PREFIX}:rate:${bucket}:${utcMinute(now)}`;
    const result = await this.eval(RATE_SCRIPT, [k], [this.options.requestsPerMinute, MINUTE_TTL_MS]);
    // RATE_SCRIPT returns only 0 (limited) or 1 (allowed); any other integer is a store fault (503), not 429.
    if (result !== 0 && result !== 1) throw new LimiterStoreError('limiter store error');
    return result === 1;
  }

  async reserve(subject: Subject, chars: number, now: number): Promise<ReserveResult> {
    const day = utcDay(now);
    const bucket = subjectBucket(subject);
    const result = await this.eval(RESERVE2_SCRIPT, dayKeys(bucket, day), [
      chars,
      subjectCap(subject, this.options),
      this.options.dailyCharCap,
      DAY_TTL_SECONDS,
    ]);
    if (result === -1) return { ok: false, reason: subjectReason(subject) };
    if (result === -2) return { ok: false, reason: 'global_daily' };
    if (result < 0) throw new LimiterStoreError('limiter store error');
    // Success is the subject counter after INCRBY chars, so it is at least `chars`; less
    // (0 included) means the store did not apply the reservation.
    if (result < chars) throw new LimiterStoreError('limiter store error');
    return { ok: true, reservation: { rid: newReservationId(), bucket, day, chars } };
  }

  async release(reservation: Reservation): Promise<boolean> {
    const marker = refundMarkerKey(reservation.rid);
    const result = await this.eval(RELEASE2_SCRIPT, [...dayKeys(reservation.bucket, reservation.day), marker], [
      reservation.chars,
      REFUND_MARKER_TTL_SECONDS,
    ]);
    if (result !== 0 && result !== 1) throw new LimiterStoreError('limiter store error');
    return result === 1;
  }
}
