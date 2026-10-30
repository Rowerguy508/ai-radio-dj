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

/**
 * The Vercel deployment the owner, install and Pro day counters are scoped by (#264 N5,
 * Fry), the same strict allow-list as the Pro keys (Sentinel's B3, `proDeployment`), so
 * Preview and Production never share an owner, install or Pro budget. The GLOBAL ceiling
 * is NOT scoped (#287 B1, Sentinel): it is one account-wide key, because every deployment
 * may carry the same ElevenLabs key. Non-production deployments also get their own low
 * sub-cap (`envDayKey`, `DEFAULT_NONPROD_DAILY_CHAR_CAP`).
 */
export type Deployment = 'production' | 'preview' | 'development';

export function isDeployment(value: unknown): value is Deployment {
  return value === 'production' || value === 'preview' || value === 'development';
}

/** `pro:<production|preview|development>:<sha256 hex>` (src/pro-allowance.ts, Sentinel's B3). */
export const PRO_BUCKET = /^pro:(production|preview|development):[0-9a-f]{64}$/;

/**
 * One verified Pro render (#264). Charged to the Pro purchase's OWN buckets, never the
 * owner's or an install's (Sentinel's B1): its render counter, its char counter (cap
 * clamped to the global ceiling) and the shared global ceiling, in ONE atomic step.
 */
export interface ProCharge {
  /** `pro:<deployment>:<sha256(originalTransactionId)>`, from `proBucket`. */
  readonly bucket: string;
  readonly chars: number;
  /** Configured per-subscriber daily chars (`AERODJ_TTS_PRO_DAILY_CHARS`); clamped by `effectiveProCharCap`. */
  readonly charCap: number;
  /** Renders per UTC day (`PRO_DAILY_RENDER_ALLOWANCE`). */
  readonly renderAllowance: number;
}

/** Why a Pro reservation was refused: global ceiling, render allowance, or the subscriber's char cap. */
export type ProRefusal = 'global_daily' | 'pro_renders' | 'pro_chars';

export type ProReserveResult =
  | { readonly ok: true; readonly reservation: ProReservation }
  | { readonly ok: false; readonly reason: ProRefusal };

export interface ProReservation {
  readonly rid: string;
  readonly bucket: string;
  readonly day: string;
  readonly chars: number;
}

/**
 * The subscriber's effective daily char cap: the configured value clamped to the global
 * ceiling (Orion): 12,000 configured with 9,000 global is 9,000; a lower value wins.
 */
export function effectiveProCharCap(configured: number, globalCap: number): number {
  return Math.min(configured, globalCap);
}

function checkProCharge(p: ProCharge): void {
  if (typeof p.bucket !== 'string' || !PRO_BUCKET.test(p.bucket)) throw new TypeError('invalid pro bucket');
  for (const n of [p.chars, p.charCap, p.renderAllowance]) {
    if (!Number.isSafeInteger(n) || n < 1) throw new TypeError('invalid pro charge');
  }
}

/**
 * The account-wide global day counter, shared by EVERY deployment (#287 B1, Sentinel):
 * `aerodj-tts:chars:global:<day>`, exactly the pre-#287 name, so a deploy keeps today's
 * count and Production + Preview + Development together never pass the global ceiling.
 */
export function globalDayKey(day: string): string {
  return `aerodj-tts:chars:${GLOBAL_BUCKET}:${day}`;
}

/** Default and maximum daily sub-cap for each non-production deployment (#287 B1). */
export const DEFAULT_NONPROD_DAILY_CHAR_CAP = 1_000;

/**
 * The non-production sub-cap counter (#287 B1): `aerodj-tts:chars:env:<preview|development>:<day>`.
 * Every Preview / Development reservation is ALSO charged to the shared global key, so
 * this only lowers what a non-production deployment can spend. Production has no sub-cap
 * key (null): its ceiling is the global one.
 */
export function envDayKey(deployment: Deployment, day: string): string | null {
  if (!isDeployment(deployment)) throw new TypeError('invalid deployment');
  return deployment === 'production' ? null : `aerodj-tts:chars:env:${deployment}:${day}`;
}

/**
 * The sub-cap a non-production deployment actually gets: the configured value, but never
 * above `DEFAULT_NONPROD_DAILY_CHAR_CAP` (configurable only downward). Anything that is
 * not a positive safe integer is the default.
 */
export function effectiveNonprodCap(configured: number | undefined): number {
  if (configured === undefined || !Number.isSafeInteger(configured) || configured < 1) return DEFAULT_NONPROD_DAILY_CHAR_CAP;
  return Math.min(configured, DEFAULT_NONPROD_DAILY_CHAR_CAP);
}

/**
 * [global chars, Pro chars, Pro renders] day counters for one Pro bucket. The global key is
 * the limiter's deployment; a Pro bucket from another deployment is refused (never mixed).
 */
export function proDayKeys(bucket: string, day: string, deployment: Deployment): [string, string, string] {
  if (!PRO_BUCKET.test(bucket)) throw new TypeError('invalid pro bucket');
  if (!isDeployment(deployment) || !bucket.startsWith(`pro:${deployment}:`)) throw new TypeError('pro bucket deployment mismatch');
  return [
    globalDayKey(day),
    `aerodj-tts:chars:${bucket}:${day}`,
    `aerodj-tts:renders:${bucket}:${day}`,
  ];
}

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
  /** Counts one request for `bucket`; false if over the per-minute rate (`limit`, default the configured rate). */
  allowRequest(bucket: string, now: number, limit?: number): Promise<boolean>;
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
  /**
   * Pro only (#264): ONE atomic check-and-add, in this order: the global ceiling first
   * (Sentinel), then the render allowance, then the subscriber's (clamped) char cap. Any
   * refusal changes NO counter. Optional so older test doubles stay valid; the handler
   * treats a limiter without it (or a non-durable one) as 503 `store`.
   */
  reservePro?(charge: ProCharge, now: number): Promise<ProReserveResult>;
  /** Returns a Pro reservation's chars (global and Pro) and its render, at most once per `rid`. */
  releasePro?(reservation: ProReservation): Promise<boolean>;
}

export interface LimiterOptions {
  /** Global daily ceiling across every caller AND every deployment (one shared key, #287 B1). */
  dailyCharCap: number;
  /**
   * Daily sub-cap for a Preview or Development deployment (#287 B1), charged on top of the
   * shared global key. Default and maximum `DEFAULT_NONPROD_DAILY_CHAR_CAP`; ignored on
   * Production and by the in-memory limiter.
   */
  nonprodDailyCharCap?: number;
  /**
   * Required by `RedisUsageLimiter` (it throws without a valid one): the deployment every
   * durable day key is scoped by. `limiterOptions` reads it from `VERCEL_ENV` via
   * `proDeployment`; unset or unknown leaves it undefined, and `selectLimiter` then returns
   * null (500 `misconfig`, the same fail-closed answer as B3). The in-memory limiter is
   * per instance (nothing shared), so it ignores this.
   */
  deployment?: Deployment;
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

  async allowRequest(bucket: string, now: number, limit: number = this.options.requestsPerMinute): Promise<boolean> {
    const recent = (this.windows.get(bucket) ?? []).filter((t) => now - t < 60_000);
    if (recent.length >= limit) {
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

  async reservePro(charge: ProCharge, now: number): Promise<ProReserveResult> {
    checkProCharge(charge);
    const day = utcDay(now);
    const renders = `renders:${charge.bucket}`;
    // Same order as PRO_RESERVE_SCRIPT.
    if (this.used(GLOBAL_BUCKET, now) + charge.chars > this.options.dailyCharCap) return { ok: false, reason: 'global_daily' };
    if (this.used(renders, now) >= charge.renderAllowance) return { ok: false, reason: 'pro_renders' };
    if (this.used(charge.bucket, now) + charge.chars > effectiveProCharCap(charge.charCap, this.options.dailyCharCap)) {
      return { ok: false, reason: 'pro_chars' };
    }
    this.spend.set(GLOBAL_BUCKET, { day, chars: this.used(GLOBAL_BUCKET, now) + charge.chars });
    this.spend.set(charge.bucket, { day, chars: this.used(charge.bucket, now) + charge.chars });
    this.spend.set(renders, { day, chars: this.used(renders, now) + 1 });
    return { ok: true, reservation: { rid: newReservationId(), bucket: charge.bucket, day, chars: charge.chars } };
  }

  async releasePro(reservation: ProReservation): Promise<boolean> {
    const marker = refundMarkerKey(reservation.rid);
    if (this.refunded.has(marker)) return false;
    this.refunded.set(marker, reservation.day);
    for (const [bucket, by] of [[GLOBAL_BUCKET, reservation.chars], [reservation.bucket, reservation.chars], [`renders:${reservation.bucket}`, 1]] as const) {
      const entry = this.spend.get(bucket);
      if (entry && entry.day === reservation.day) entry.chars = Math.max(0, entry.chars - by);
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
 * KEYS[1] = subject day counter, KEYS[2] = global day counter (shared by every deployment),
 * optional KEYS[3] = non-production sub-cap counter (#287 B1);
 * ARGV = chars, subject cap, global cap, ttl s, [sub-cap].
 * All-or-nothing: returns -1 if the subject's cap would be exceeded, -2 if the global
 * ceiling would be, -5 if the sub-cap would be, and changes NO counter in any case.
 * Otherwise increments every counter and returns the subject's new total.
 */
export const RESERVE2_SCRIPT = `local c = tonumber(ARGV[1])
local used = tonumber(redis.call('GET', KEYS[1]) or '0')
if used + c > tonumber(ARGV[2]) then return -1 end
local total = tonumber(redis.call('GET', KEYS[2]) or '0')
if total + c > tonumber(ARGV[3]) then return -2 end
if KEYS[3] then
  local e = tonumber(redis.call('GET', KEYS[3]) or '0')
  if e + c > tonumber(ARGV[5]) then return -5 end
end
local n = redis.call('INCRBY', KEYS[1], c)
redis.call('EXPIRE', KEYS[1], ARGV[4])
redis.call('INCRBY', KEYS[2], c)
redis.call('EXPIRE', KEYS[2], ARGV[4])
if KEYS[3] then
  redis.call('INCRBY', KEYS[3], c)
  redis.call('EXPIRE', KEYS[3], ARGV[4])
end
return n`;

/**
 * KEYS[1] = subject day counter, KEYS[2] = global day counter, KEYS[3] = refund marker
 * (`refund:{aerodj-tts}:<rid>`), optional KEYS[4] = non-production sub-cap counter;
 * ARGV = chars, marker ttl s.
 * At most once per reservation (Fry D2): first `SET marker 1 NX EX ttl`; if the marker
 * already exists, returns 0 and changes nothing. Otherwise decrements every counter,
 * floored at zero, keeping their TTLs, and returns 1.
 */
export const RELEASE2_SCRIPT = `if not redis.call('SET', KEYS[3], '1', 'NX', 'EX', ARGV[2]) then return 0 end
local c = tonumber(ARGV[1])
for _, i in ipairs({1, 2, 4}) do
  if KEYS[i] then
  local used = tonumber(redis.call('GET', KEYS[i]) or '0')
  if used > 0 then
    local n = used - c
    if n < 0 then n = 0 end
    redis.call('SET', KEYS[i], n, 'KEEPTTL')
  end
  end
end
return 1`;

/**
 * Pro reserve (#264). KEYS[1] = global chars (shared by every deployment), KEYS[2] = Pro
 * chars, KEYS[3] = Pro renders, optional KEYS[4] = non-production sub-cap (#287 B1);
 * ARGV = chars, global cap, effective Pro char cap, render allowance, ttl s, [sub-cap].
 * Order: global ceiling (-2), sub-cap (-5), then render allowance (-4), then Pro char cap
 * (-3); a refusal changes NO counter. Otherwise adds chars to every char counter and 1 to
 * the render counter, sets their TTLs, and returns the new render count (1..allowance).
 */
export const PRO_RESERVE_SCRIPT = `local c = tonumber(ARGV[1])
local g = tonumber(redis.call('GET', KEYS[1]) or '0')
if g + c > tonumber(ARGV[2]) then return -2 end
if KEYS[4] then
  local e = tonumber(redis.call('GET', KEYS[4]) or '0')
  if e + c > tonumber(ARGV[6]) then return -5 end
end
local r = tonumber(redis.call('GET', KEYS[3]) or '0')
if r >= tonumber(ARGV[4]) then return -4 end
local p = tonumber(redis.call('GET', KEYS[2]) or '0')
if p + c > tonumber(ARGV[3]) then return -3 end
redis.call('INCRBY', KEYS[1], c)
redis.call('EXPIRE', KEYS[1], ARGV[5])
redis.call('INCRBY', KEYS[2], c)
redis.call('EXPIRE', KEYS[2], ARGV[5])
if KEYS[4] then
  redis.call('INCRBY', KEYS[4], c)
  redis.call('EXPIRE', KEYS[4], ARGV[5])
end
local n = redis.call('INCR', KEYS[3])
redis.call('EXPIRE', KEYS[3], ARGV[5])
return n`;

/**
 * KEYS[1..3] as PRO_RESERVE_SCRIPT, KEYS[4] = refund marker, optional KEYS[5] = the
 * non-production sub-cap; ARGV = chars, marker ttl s.
 * At most once per reservation (SET NX); then chars off every char counter and 1 off the
 * render counter, each floored at zero, keeping TTLs. Returns 1, or 0 if already refunded.
 */
export const PRO_RELEASE_SCRIPT = `if not redis.call('SET', KEYS[4], '1', 'NX', 'EX', ARGV[2]) then return 0 end
local c = tonumber(ARGV[1])
for _, i in ipairs({1, 2, 3, 5}) do
  if KEYS[i] then
  local by = c
  if i == 3 then by = 1 end
  local used = tonumber(redis.call('GET', KEYS[i]) or '0')
  if used > 0 then
    local n = used - by
    if n < 0 then n = 0 end
    redis.call('SET', KEYS[i], n, 'KEEPTTL')
  end
  end
end
return 1`;

const KEY_PREFIX = 'aerodj-tts';
const DAY_TTL_SECONDS = 2 * 24 * 60 * 60;
const MINUTE_TTL_MS = 120_000;

/**
 * [subject, global] day counters. The subject key is scoped by deployment (#264 N5):
 * `aerodj-tts:chars:owner:<deployment>:<day>`, `aerodj-tts:chars:install:<deployment>:<sha256>:<day>`.
 * The global key is the shared account-wide `aerodj-tts:chars:global:<day>` (#287 B1, the
 * pre-#287 name), so a deploy keeps today's global count. The owner key is new in N5, so
 * on the first deploy the owner's count starts fresh for that UTC day; the owner cap is the
 * global cap, which did not reset, so that adds no spend.
 */
export function dayKeys(bucket: string, day: string, deployment: Deployment): [string, string] {
  if (!isDeployment(deployment)) throw new TypeError('invalid deployment');
  let scoped: string;
  if (bucket === 'owner') scoped = `owner:${deployment}`;
  else if (/^install:[0-9a-f]{64}$/.test(bucket)) scoped = `install:${deployment}:${bucket.slice('install:'.length)}`;
  else throw new TypeError('invalid subject bucket');
  return [`${KEY_PREFIX}:chars:${scoped}:${day}`, globalDayKey(day)];
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

/**
 * One EVAL over Upstash's REST API, bounded by `timeoutMs` from request to parsed body.
 * Any transport or store error, a non-integer reply or a timeout throws LimiterStoreError
 * (the handler fails closed with 503 `store`). Shared by the usage limiter and the Pro
 * allowance so both keep the same timeout, strict-integer and error rules.
 */
export async function upstashEval(
  config: RedisRestConfig,
  fetchImpl: typeof fetch,
  timeoutMs: number,
  script: string,
  keys: string[],
  args: (string | number)[],
): Promise<number> {
  const signal = AbortSignal.timeout(timeoutMs);
  let response: Response;
  try {
    response = await untilAborted(
      fetchImpl(config.url, {
        method: 'POST',
        headers: { Authorization: `Bearer ${config.token}`, 'Content-Type': 'application/json' },
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
  let payload: { result?: unknown } | null;
  try {
    payload = (await untilAborted(response.json(), signal)) as { result?: unknown } | null;
  } catch {
    // The same bound covers the body read: a body cut off by it is a timeout, exactly
    // like a fetch cut off by it (Fry's nit on #259); a body that fails on its own
    // (bad JSON, stream error) is a store error.
    throw new LimiterStoreError('limiter store error', signal.aborted);
  }
  // A reply that arrived in full is never a timeout, whatever its shape.
  if (!payload || typeof payload !== 'object' || 'error' in payload) throw new LimiterStoreError('limiter store error');
  return strictRedisInteger(payload.result);
}

export class RedisUsageLimiter implements UsageLimiter {
  readonly durable = true;
  /** Scopes every subject and Pro day key (#264 N5); validated here so no key is ever built without one. */
  private readonly deployment: Deployment;
  /** Non-production sub-cap (#287 B1); null on Production. */
  private readonly nonprodCap: number | null;

  constructor(
    private readonly config: RedisRestConfig,
    private readonly options: LimiterOptions,
    private readonly fetchImpl: typeof fetch = globalThis.fetch,
    /** Bound on each Upstash call; a timeout is a LimiterStoreError (503 `store`). */
    private readonly timeoutMs: number = UPSTASH_FETCH_TIMEOUT_MS,
  ) {
    if (!isDeployment(options.deployment)) throw new TypeError('invalid deployment');
    this.deployment = options.deployment;
    this.nonprodCap = options.deployment === 'production' ? null : effectiveNonprodCap(options.nonprodDailyCharCap);
  }

  /** The sub-cap key and cap for `day`, or [] on Production (#287 B1). */
  private subCap(day: string): { keys: string[]; args: number[] } {
    const key = envDayKey(this.deployment, day);
    if (key === null || this.nonprodCap === null) return { keys: [], args: [] };
    return { keys: [key], args: [this.nonprodCap] };
  }

  /** One EVAL over Upstash's REST API. Any transport or store error, or a timeout, throws (the handler fails closed). */
  private eval(script: string, keys: string[], args: (string | number)[]): Promise<number> {
    return upstashEval(this.config, this.fetchImpl, this.timeoutMs, script, keys, args);
  }

  async allowRequest(bucket: string, now: number, limit: number = this.options.requestsPerMinute): Promise<boolean> {
    const k = `${KEY_PREFIX}:rate:${bucket}:${utcMinute(now)}`;
    const result = await this.eval(RATE_SCRIPT, [k], [limit, MINUTE_TTL_MS]);
    // RATE_SCRIPT returns only 0 (limited) or 1 (allowed); any other integer is a store fault (503), not 429.
    if (result !== 0 && result !== 1) throw new LimiterStoreError('limiter store error');
    return result === 1;
  }

  async reserve(subject: Subject, chars: number, now: number): Promise<ReserveResult> {
    const day = utcDay(now);
    const bucket = subjectBucket(subject);
    const sub = this.subCap(day);
    const result = await this.eval(RESERVE2_SCRIPT, [...dayKeys(bucket, day, this.deployment), ...sub.keys], [
      chars,
      subjectCap(subject, this.options),
      this.options.dailyCharCap,
      DAY_TTL_SECONDS,
      ...sub.args,
    ]);
    if (result === -1) return { ok: false, reason: subjectReason(subject) };
    // -5: this non-production deployment's sub-cap; on the wire it is the global ceiling.
    // On Production no sub-cap key is sent, so a -5 there is a store fault (503), never a 429.
    if (result === -2 || (result === -5 && this.nonprodCap !== null)) return { ok: false, reason: 'global_daily' };
    if (result < 0) throw new LimiterStoreError('limiter store error');
    // Success is the subject counter after INCRBY chars, so it is at least `chars`; less
    // (0 included) means the store did not apply the reservation.
    if (result < chars) throw new LimiterStoreError('limiter store error');
    return { ok: true, reservation: { rid: newReservationId(), bucket, day, chars } };
  }

  async release(reservation: Reservation): Promise<boolean> {
    const marker = refundMarkerKey(reservation.rid);
    const sub = this.subCap(reservation.day);
    const result = await this.eval(RELEASE2_SCRIPT, [...dayKeys(reservation.bucket, reservation.day, this.deployment), marker, ...sub.keys], [
      reservation.chars,
      REFUND_MARKER_TTL_SECONDS,
    ]);
    if (result !== 0 && result !== 1) throw new LimiterStoreError('limiter store error');
    return result === 1;
  }

  async reservePro(charge: ProCharge, now: number): Promise<ProReserveResult> {
    checkProCharge(charge);
    const day = utcDay(now);
    const sub = this.subCap(day);
    const result = await this.eval(PRO_RESERVE_SCRIPT, [...proDayKeys(charge.bucket, day, this.deployment), ...sub.keys], [
      charge.chars,
      this.options.dailyCharCap,
      effectiveProCharCap(charge.charCap, this.options.dailyCharCap),
      charge.renderAllowance,
      DAY_TTL_SECONDS,
      ...sub.args,
    ]);
    if (result === -2 || (result === -5 && this.nonprodCap !== null)) return { ok: false, reason: 'global_daily' };
    if (result === -4) return { ok: false, reason: 'pro_renders' };
    if (result === -3) return { ok: false, reason: 'pro_chars' };
    // Success is the new render count, 1..allowance; anything else is a store fault (503), never a grant.
    if (result < 1 || result > charge.renderAllowance) throw new LimiterStoreError('limiter store error');
    return { ok: true, reservation: { rid: newReservationId(), bucket: charge.bucket, day, chars: charge.chars } };
  }

  async releasePro(reservation: ProReservation): Promise<boolean> {
    const keys = [...proDayKeys(reservation.bucket, reservation.day, this.deployment), refundMarkerKey(reservation.rid), ...this.subCap(reservation.day).keys];
    const result = await this.eval(PRO_RELEASE_SCRIPT, keys, [reservation.chars, REFUND_MARKER_TTL_SECONDS]);
    if (result !== 0 && result !== 1) throw new LimiterStoreError('limiter store error');
    return result === 1;
  }
}
