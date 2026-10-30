import { usedKey } from './challenge.js';
import type { Env } from './handler.js';
import { redisRestConfig, type RedisRestConfig } from './limiter.js';
import { UPSTASH_FETCH_TIMEOUT_MS, untilAborted } from './upstash.js';

/**
 * Durable App Attest key store (note §4.1.2 step 4, §4.3). Upstash only: there
 * is no in-memory store in any environment (`selectAttestStore` returns null
 * without Redis and the register endpoint answers 503 `store`).
 *
 * Keyspace separation (PR 3b): a Preview or Development deployment must never
 * write a record that Production would trust, even if it shares the Upstash
 * database. Only `VERCEL_ENV === 'production'` exactly uses the production
 * names; anything else (preview, development, unset, a typo) prefixes every
 * key with `nonprod:`. Both choices fail closed: an unset VERCEL_ENV gets
 * Production's strict verification policy (`deploymentFromEnv`) AND the
 * non-production keyspace. All names keep the `{aerodj-tts}` hash tag so one
 * script touches one slot.
 */
export type Keyspace = 'production' | 'nonprod';

export function keyspaceFromEnv(env: Readonly<Record<string, string | undefined>>): Keyspace {
  return env.VERCEL_ENV === 'production' ? 'production' : 'nonprod';
}

const prefix = (keyspace: Keyspace): string => (keyspace === 'production' ? '' : 'nonprod:');

/** `key:{aerodj-tts}:<base64url keyId>`, the record PR 4's assertion path reads. */
export function keyRecordKey(keyspace: Keyspace, keyId: Buffer): string {
  return `${prefix(keyspace)}key:{aerodj-tts}:${keyId.toString('base64url')}`;
}

/** `enroll:{aerodj-tts}:<UTC day>`: verified enrollments per day. */
export function enrollKey(keyspace: Keyspace, day: string): string {
  return `${prefix(keyspace)}enroll:{aerodj-tts}:${day}`;
}

/**
 * `enrolldev:{aerodj-tts}:<UTC day>:<hex HMAC>`: verified enrollments per day from one
 * client network (enroll-device.ts). The bucket is a keyed hash, never an address.
 * Same `{aerodj-tts}` hash tag, so the register script still touches one slot.
 */
export function enrollDeviceKey(keyspace: Keyspace, day: string, bucket: string): string {
  if (!/^[0-9a-f]{64}$/.test(bucket)) throw new Error('enroll device bucket must be a hex SHA-256');
  return `${prefix(keyspace)}enrolldev:{aerodj-tts}:${day}:${bucket}`;
}

/** The challenge's single-use mark (`used:{aerodj-tts}:<sha256>` from #246), in this keyspace. */
export function attestUsedKey(keyspace: Keyspace, challenge: string): string {
  return `${prefix(keyspace)}${usedKey(challenge)}`;
}

/**
 * 90-day sliding TTL (note §4.1.2; owner decision 2026-10-29): set on register and
 * refreshed on every successful use of the key (`touchKey`, called by the assertion
 * path after the assertion verifies), not only on register. A key unused for 90 days
 * expires and its next assertion fails as an unknown key.
 */
export const KEY_RECORD_TTL_SECONDS = 90 * 86_400;
/** The enroll counters (global and per device) outlive their UTC day. */
export const ENROLL_TTL_SECONDS = 2 * 86_400;

export interface KeyRecord {
  pubKeySpki: string; // base64 DER SPKI
  counter: 0;
  env: 'production' | 'development';
  createdDay: string;
  revoked: false;
}

export interface RegisterKeys {
  used: string;
  record: string;
  enroll: string;
  /** Per-device (client network) enroll counter for the same day. */
  enrollDevice: string;
}

export interface RegisterOptions {
  usedTtlSeconds: number;
  /** Global verified enrollments per UTC day. */
  enrollCap: number;
  /** Verified enrollments per UTC day per device bucket. */
  enrollDeviceCap: number;
}

/** `touchKey`: the record existed and its TTL is back to 90 days, or no such key (never registered, or expired). */
export type TouchOutcome = 'refreshed' | 'unknown';

export type RegisterOutcome = 'registered' | 'reused' | 'duplicate' | 'enroll_cap' | 'enroll_device_cap';

export interface AttestStore {
  readonly durable: boolean;
  /** Read-only: is the challenge's single-use mark present? Throws AttestStoreError. */
  isUsed(usedKey: string): Promise<boolean>;
  /**
   * Sliding TTL on use: `EXPIRE` the key record to KEY_RECORD_TTL_SECONDS if it
   * exists. Writes nothing for a missing key. Throws AttestStoreError.
   */
  touchKey(recordKey: string): Promise<TouchOutcome>;
  /** The one §4.1.2 step-4 script. Throws AttestStoreError. */
  register(keys: RegisterKeys, record: KeyRecord, options: RegisterOptions): Promise<RegisterOutcome>;
}

export class AttestStoreError extends Error {}

/** GET only, so a probe of the mark writes nothing. */
export const IS_USED_SCRIPT = `if redis.call('GET', KEYS[1]) then return 1 end
return 0`;

/**
 * KEYS: key record. ARGV: record TTL (seconds). 1 refreshed; 0 no such key (nothing
 * written: EXPIRE on a missing key is a no-op in Redis).
 */
export const TOUCH_KEY_SCRIPT = `if redis.call('EXPIRE', KEYS[1], ARGV[1]) == 1 then return 1 end
return 0`;

/**
 * KEYS: used mark, key record, global enroll counter, per-device enroll counter.
 * ARGV: used TTL, record JSON, record TTL, global cap, enroll TTL, device cap.
 * 1 registered; -1 challenge already used (nothing written); -4 per-device cap
 * reached and -3 global cap reached (both checked BEFORE any write: nothing
 * written, neither counter moves, challenge not consumed; the device cap is
 * checked first, so a device-capped request never spends global budget and
 * reports the narrower reason); -2 keyId already registered (record and both
 * counters untouched, challenge consumed so the same request cannot be replayed).
 * A success increments both counters and (re)sets both TTLs.
 */
export const REGISTER_SCRIPT = `if redis.call('GET', KEYS[1]) then return -1 end
local d = tonumber(redis.call('GET', KEYS[4]) or '0')
if d >= tonumber(ARGV[6]) then return -4 end
local n = tonumber(redis.call('GET', KEYS[3]) or '0')
if n >= tonumber(ARGV[4]) then return -3 end
if not redis.call('SET', KEYS[2], ARGV[2], 'NX', 'EX', ARGV[3]) then
  redis.call('SET', KEYS[1], '1', 'EX', ARGV[1])
  return -2
end
redis.call('SET', KEYS[1], '1', 'EX', ARGV[1])
redis.call('INCR', KEYS[3])
redis.call('EXPIRE', KEYS[3], ARGV[5])
redis.call('INCR', KEYS[4])
redis.call('EXPIRE', KEYS[4], ARGV[5])
return 1`;

export class RedisAttestStore implements AttestStore {
  readonly durable = true;
  constructor(
    private readonly config: RedisRestConfig,
    private readonly fetchImpl: typeof fetch = globalThis.fetch,
    /** Bound on each Upstash call; a timeout is a store error (503 `store`). */
    private readonly timeoutMs: number = UPSTASH_FETCH_TIMEOUT_MS,
  ) {}

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
      throw new AttestStoreError('store unreachable');
    }
    if (!response.ok) {
      await response.body?.cancel().catch(() => {});
      throw new AttestStoreError('store error');
    }
    const payload = (await untilAborted(response.json(), signal).catch(() => null)) as { result?: unknown } | null;
    // Strict integer replies only (as in the limiter): a float, string or huge number is a store error.
    if (!payload || typeof payload !== 'object' || 'error' in payload || typeof payload.result !== 'number' || !Number.isSafeInteger(payload.result)) {
      throw new AttestStoreError('store error');
    }
    return payload.result;
  }

  async isUsed(key: string): Promise<boolean> {
    const result = await this.eval(IS_USED_SCRIPT, [key], []);
    if (result === 1) return true;
    if (result === 0) return false;
    throw new AttestStoreError('store error');
  }

  async touchKey(recordKey: string): Promise<TouchOutcome> {
    const result = await this.eval(TOUCH_KEY_SCRIPT, [recordKey], [KEY_RECORD_TTL_SECONDS]);
    if (result === 1) return 'refreshed';
    if (result === 0) return 'unknown';
    throw new AttestStoreError('store error');
  }

  async register(keys: RegisterKeys, record: KeyRecord, options: RegisterOptions): Promise<RegisterOutcome> {
    const result = await this.eval(REGISTER_SCRIPT, [keys.used, keys.record, keys.enroll, keys.enrollDevice], [
      options.usedTtlSeconds,
      JSON.stringify(record),
      KEY_RECORD_TTL_SECONDS,
      options.enrollCap,
      ENROLL_TTL_SECONDS,
      options.enrollDeviceCap,
    ]);
    switch (result) {
      case 1:
        return 'registered';
      case -1:
        return 'reused';
      case -2:
        return 'duplicate';
      case -3:
        return 'enroll_cap';
      case -4:
        return 'enroll_device_cap';
      default:
        throw new AttestStoreError('store error');
    }
  }
}

/** Durable store when Upstash REST credentials are present; otherwise null (503 `store`). No network here. */
export function selectAttestStore(env: Env, fetchImpl: typeof fetch = globalThis.fetch): AttestStore | null {
  const config = redisRestConfig(env);
  return config ? new RedisAttestStore(config, fetchImpl) : null;
}
