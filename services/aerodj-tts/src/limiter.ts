import crypto from 'node:crypto';

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
  /** Returns a reservation's characters to both of its day's buckets (never below zero). */
  release(reservation: Reservation): Promise<void>;
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
    return { ok: true, reservation: { bucket, day, chars } };
  }

  async release(reservation: Reservation): Promise<void> {
    for (const bucket of [reservation.bucket, GLOBAL_BUCKET]) {
      const entry = this.spend.get(bucket);
      if (!entry || entry.day !== reservation.day) continue;
      entry.chars = Math.max(0, entry.chars - reservation.chars);
    }
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

/** KEYS[1] = subject day counter, KEYS[2] = global day counter; ARGV = chars. Decrements both, floored at zero, keeping TTLs. */
export const RELEASE2_SCRIPT = `local c = tonumber(ARGV[1])
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

export class LimiterStoreError extends Error {}

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
  ) {}

  /** One EVAL over Upstash's REST API. Any transport or store error throws (the handler fails closed). */
  private async eval(script: string, keys: string[], args: (string | number)[]): Promise<number> {
    let response: Response;
    try {
      response = await this.fetchImpl(this.config.url, {
        method: 'POST',
        headers: { Authorization: `Bearer ${this.config.token}`, 'Content-Type': 'application/json' },
        body: JSON.stringify(['EVAL', script, keys.length, ...keys, ...args.map(String)]),
      });
    } catch {
      throw new LimiterStoreError('limiter store unreachable');
    }
    if (!response.ok) {
      await response.body?.cancel().catch(() => {});
      throw new LimiterStoreError('limiter store error');
    }
    const payload = (await response.json().catch(() => null)) as { result?: unknown } | null;
    const result = Number(payload?.result);
    if (!payload || 'error' in payload || !Number.isFinite(result)) throw new LimiterStoreError('limiter store error');
    return result;
  }

  async allowRequest(bucket: string, now: number): Promise<boolean> {
    const k = `${KEY_PREFIX}:rate:${bucket}:${utcMinute(now)}`;
    return (await this.eval(RATE_SCRIPT, [k], [this.options.requestsPerMinute, MINUTE_TTL_MS])) === 1;
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
    return { ok: true, reservation: { bucket, day, chars } };
  }

  async release(reservation: Reservation): Promise<void> {
    await this.eval(RELEASE2_SCRIPT, dayKeys(reservation.bucket, reservation.day), [reservation.chars]);
  }
}
