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
  /**
   * EXISTS key: true if the single-use mark is present. Read-only. Used only to tell a
   * reused challenge (401 `assertion`) from an expired one (400 `challenge_expired`)
   * after the MAC and signature have verified. Throws ChallengeStoreError.
   */
  isUsed(key: string): Promise<boolean>;
}

export class ChallengeStoreError extends Error {}

export class RedisChallengeStore implements ChallengeStore {
  readonly durable = true;
  constructor(
    private readonly config: RedisRestConfig,
    private readonly fetchImpl: typeof fetch = globalThis.fetch,
  ) {}

  /** One Upstash REST command; returns `result`. Any transport or store error throws ChallengeStoreError. */
  private async command(args: string[]): Promise<unknown> {
    let response: Response;
    try {
      response = await this.fetchImpl(this.config.url, {
        method: 'POST',
        headers: { Authorization: `Bearer ${this.config.token}`, 'Content-Type': 'application/json' },
        body: JSON.stringify(args),
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
    return payload.result;
  }

  async markUsed(key: string, ttlSeconds: number): Promise<boolean> {
    const result = await this.command(['SET', key, '1', 'NX', 'EX', String(ttlSeconds)]);
    if (result === 'OK') return true;
    if (result === null) return false;
    throw new ChallengeStoreError('store error');
  }

  async isUsed(key: string): Promise<boolean> {
    const result = await this.command(['EXISTS', key]);
    if (result === 1) return true;
    if (result === 0) return false;
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
