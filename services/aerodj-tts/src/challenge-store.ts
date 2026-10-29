import { redisRestConfig, type RedisRestConfig } from './limiter.js';
import type { Env } from './handler.js';

/**
 * Single-use marks for challenges. Install-scoped operations need a durable
 * store shared by every instance; there is no in-memory fallback in any
 * environment (note §4.3: `durable !== true` → 503 `store`).
 */
export interface ChallengeStore {
  readonly durable: boolean;
  /** SET key NX EX ttl. True if newly set (first use), false if already used. Throws ChallengeStoreError. */
  markUsed(key: string, ttlSeconds: number): Promise<boolean>;
}

export class ChallengeStoreError extends Error {}

export class RedisChallengeStore implements ChallengeStore {
  readonly durable = true;
  constructor(
    private readonly config: RedisRestConfig,
    private readonly fetchImpl: typeof fetch = globalThis.fetch,
  ) {}

  async markUsed(key: string, ttlSeconds: number): Promise<boolean> {
    let response: Response;
    try {
      response = await this.fetchImpl(this.config.url, {
        method: 'POST',
        headers: { Authorization: `Bearer ${this.config.token}`, 'Content-Type': 'application/json' },
        body: JSON.stringify(['SET', key, '1', 'NX', 'EX', String(ttlSeconds)]),
      });
    } catch {
      throw new ChallengeStoreError('store unreachable');
    }
    if (!response.ok) {
      await response.body?.cancel().catch(() => {});
      throw new ChallengeStoreError('store error');
    }
    const payload = (await response.json().catch(() => null)) as { result?: unknown; error?: unknown } | null;
    if (!payload || typeof payload !== 'object' || 'error' in payload || !('result' in payload)) {
      throw new ChallengeStoreError('store error');
    }
    if (payload.result === 'OK') return true;
    if (payload.result === null) return false;
    throw new ChallengeStoreError('store error');
  }
}

/**
 * Durable store when Upstash REST credentials are present; otherwise null, so
 * install-scoped operations return 503 `store`. Reads config only (no network).
 */
export function selectChallengeStore(env: Env, fetchImpl: typeof fetch = globalThis.fetch): ChallengeStore | null {
  const config = redisRestConfig(env);
  return config ? new RedisChallengeStore(config, fetchImpl) : null;
}
