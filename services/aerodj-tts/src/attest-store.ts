import { usedKey } from './challenge.js';
import type { Env } from './handler.js';
import { redisRestConfig, type RedisRestConfig } from './limiter.js';

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

/** The challenge's single-use mark (`used:{aerodj-tts}:<sha256>` from #246), in this keyspace. */
export function attestUsedKey(keyspace: Keyspace, challenge: string): string {
  return `${prefix(keyspace)}${usedKey(challenge)}`;
}

/** 90-day sliding TTL (note §4.1.2); PR 4 refreshes it on each verified assertion. */
export const KEY_RECORD_TTL_SECONDS = 90 * 86_400;
/** The enroll counter outlives its UTC day. */
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
}

export type RegisterOutcome = 'registered' | 'reused' | 'duplicate' | 'enroll_cap';

export interface AttestStore {
  readonly durable: boolean;
  /** Read-only: is the challenge's single-use mark present? Throws AttestStoreError. */
  isUsed(usedKey: string): Promise<boolean>;
  /** The one §4.1.2 step-4 script. Throws AttestStoreError. */
  register(keys: RegisterKeys, record: KeyRecord, options: { usedTtlSeconds: number; enrollCap: number }): Promise<RegisterOutcome>;
}

export class AttestStoreError extends Error {}

/** GET only, so a probe of the mark writes nothing. */
export const IS_USED_SCRIPT = `if redis.call('GET', KEYS[1]) then return 1 end
return 0`;

/**
 * KEYS: used mark, key record, enroll counter.
 * ARGV: used TTL, record JSON, record TTL, enroll cap, enroll TTL.
 * 1 registered; -1 challenge already used (nothing written); -3 enroll cap
 * reached (checked BEFORE any write: nothing written, challenge not consumed);
 * -2 keyId already registered (record untouched, counter untouched, challenge
 * consumed so the same request cannot be replayed).
 */
export const REGISTER_SCRIPT = `if redis.call('GET', KEYS[1]) then return -1 end
local n = tonumber(redis.call('GET', KEYS[3]) or '0')
if n >= tonumber(ARGV[4]) then return -3 end
if not redis.call('SET', KEYS[2], ARGV[2], 'NX', 'EX', ARGV[3]) then
  redis.call('SET', KEYS[1], '1', 'EX', ARGV[1])
  return -2
end
redis.call('SET', KEYS[1], '1', 'EX', ARGV[1])
redis.call('INCR', KEYS[3])
redis.call('EXPIRE', KEYS[3], ARGV[5])
return 1`;

export class RedisAttestStore implements AttestStore {
  readonly durable = true;
  constructor(
    private readonly config: RedisRestConfig,
    private readonly fetchImpl: typeof fetch = globalThis.fetch,
  ) {}

  private async eval(script: string, keys: string[], args: (string | number)[]): Promise<number> {
    let response: Response;
    try {
      response = await this.fetchImpl(this.config.url, {
        method: 'POST',
        headers: { Authorization: `Bearer ${this.config.token}`, 'Content-Type': 'application/json' },
        body: JSON.stringify(['EVAL', script, keys.length, ...keys, ...args.map(String)]),
      });
    } catch {
      throw new AttestStoreError('store unreachable');
    }
    if (!response.ok) {
      await response.body?.cancel().catch(() => {});
      throw new AttestStoreError('store error');
    }
    const payload = (await response.json().catch(() => null)) as { result?: unknown } | null;
    if (!payload || typeof payload !== 'object' || 'error' in payload || typeof payload.result !== 'number') {
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

  async register(keys: RegisterKeys, record: KeyRecord, options: { usedTtlSeconds: number; enrollCap: number }): Promise<RegisterOutcome> {
    const result = await this.eval(REGISTER_SCRIPT, [keys.used, keys.record, keys.enroll], [
      options.usedTtlSeconds,
      JSON.stringify(record),
      KEY_RECORD_TTL_SECONDS,
      options.enrollCap,
      ENROLL_TTL_SECONDS,
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
