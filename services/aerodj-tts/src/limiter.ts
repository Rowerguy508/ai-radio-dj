/**
 * Usage limiter: per-minute request rate plus an atomic daily character budget.
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
export interface Reservation {
  readonly key: string;
  /** UTC day (YYYY-MM-DD) the characters were reserved against. */
  readonly day: string;
  readonly chars: number;
}

export interface UsageLimiter {
  /** True when backed by a store shared by every instance. */
  readonly durable: boolean;
  /** Counts one request for `key`; false if over the per-minute rate. */
  allowRequest(key: string, now: number): Promise<boolean>;
  /** Atomically reserves `chars` of today's (UTC) cap for `key`; null if they do not fit. */
  reserve(key: string, chars: number, now: number): Promise<Reservation | null>;
  /** Returns a reservation's characters to its day's budget (never below zero). */
  release(reservation: Reservation): Promise<void>;
}

export interface LimiterOptions {
  dailyCharCap: number;
  requestsPerMinute: number;
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

  async allowRequest(key: string, now: number): Promise<boolean> {
    const recent = (this.windows.get(key) ?? []).filter((t) => now - t < 60_000);
    if (recent.length >= this.options.requestsPerMinute) {
      this.windows.set(key, recent);
      return false;
    }
    recent.push(now);
    this.windows.set(key, recent);
    return true;
  }

  async reserve(key: string, chars: number, now: number): Promise<Reservation | null> {
    const day = utcDay(now);
    const entry = this.spend.get(key);
    const used = entry && entry.day === day ? entry.chars : 0;
    if (used + chars > this.options.dailyCharCap) return null;
    this.spend.set(key, { day, chars: used + chars });
    return { key, day, chars };
  }

  async release(reservation: Reservation): Promise<void> {
    const entry = this.spend.get(reservation.key);
    if (!entry || entry.day !== reservation.day) return;
    entry.chars = Math.max(0, entry.chars - reservation.chars);
  }

  /** Test/diagnostic helper: characters currently counted for `key` today. */
  used(key: string, now: number): number {
    const entry = this.spend.get(key);
    return entry && entry.day === utcDay(now) ? entry.chars : 0;
  }
}

// --- Durable: Upstash Redis (REST) ------------------------------------------------

/** KEYS[1] = minute counter; ARGV = limit, ttl ms. Returns 1 if allowed, 0 if not. */
export const RATE_SCRIPT = `local n = redis.call('INCR', KEYS[1])
if n == 1 then redis.call('PEXPIRE', KEYS[1], ARGV[2]) end
if n > tonumber(ARGV[1]) then return 0 end
return 1`;

/** KEYS[1] = day counter; ARGV = chars, cap, ttl s. Returns the new total, or -1 if over cap. */
export const RESERVE_SCRIPT = `local used = tonumber(redis.call('GET', KEYS[1]) or '0')
local c = tonumber(ARGV[1])
if used + c > tonumber(ARGV[2]) then return -1 end
local n = redis.call('INCRBY', KEYS[1], c)
redis.call('EXPIRE', KEYS[1], ARGV[3])
return n`;

/** KEYS[1] = day counter; ARGV = chars. Decrements, floored at zero, keeping the TTL. */
export const RELEASE_SCRIPT = `local used = tonumber(redis.call('GET', KEYS[1]) or '0')
if used <= 0 then return 0 end
local n = used - tonumber(ARGV[1])
if n < 0 then n = 0 end
redis.call('SET', KEYS[1], n, 'KEEPTTL')
return n`;

const KEY_PREFIX = 'aerodj-tts';
const DAY_TTL_SECONDS = 2 * 24 * 60 * 60;
const MINUTE_TTL_MS = 120_000;

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
  private async eval(script: string, key: string, args: (string | number)[]): Promise<number> {
    let response: Response;
    try {
      response = await this.fetchImpl(this.config.url, {
        method: 'POST',
        headers: { Authorization: `Bearer ${this.config.token}`, 'Content-Type': 'application/json' },
        body: JSON.stringify(['EVAL', script, 1, key, ...args.map(String)]),
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

  async allowRequest(key: string, now: number): Promise<boolean> {
    const k = `${KEY_PREFIX}:rate:${key}:${utcMinute(now)}`;
    return (await this.eval(RATE_SCRIPT, k, [this.options.requestsPerMinute, MINUTE_TTL_MS])) === 1;
  }

  async reserve(key: string, chars: number, now: number): Promise<Reservation | null> {
    const day = utcDay(now);
    const k = `${KEY_PREFIX}:chars:${key}:${day}`;
    const result = await this.eval(RESERVE_SCRIPT, k, [chars, this.options.dailyCharCap, DAY_TTL_SECONDS]);
    return result < 0 ? null : { key, day, chars };
  }

  async release(reservation: Reservation): Promise<void> {
    const k = `${KEY_PREFIX}:chars:${reservation.key}:${reservation.day}`;
    await this.eval(RELEASE_SCRIPT, k, [reservation.chars]);
  }
}
