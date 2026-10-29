import { LimiterStoreError, type ReserveResult, type UsageLimiter } from './limiter.js';

/**
 * Durable-only rule for per-install state (note §4.3, Sentinel B3; PR 3 gate (b)).
 *
 * Every per-install reservation goes through `reserveForInstall`. Without a
 * durable store shared by every instance (`limiter.durable === true`, i.e. the
 * Upstash limiter) it refuses with 503 `store` and `Retry-After`, in EVERY
 * environment: there is no in-memory fallback for install quotas, and
 * `AERODJ_TTS_ACCEPT_BEST_EFFORT_LIMITS` does not apply here. The in-memory
 * limiter remains only for the legacy owner path's local dev tests.
 *
 * Nothing calls this from a request yet: PR 4 (`RESERVE2` on the attested
 * `/api/tts`) and the PR 3b `register` endpoint use it; PR 6 and PR 7 inherit
 * the same rule. Their own tests must show 503 `store` without Redis.
 */

/** `Retry-After` for 503 `store` on the attest/install paths (note §4.4 table). */
export const INSTALL_STORE_RETRY_AFTER_SECONDS = 30;

export type InstallReserveResult =
  | ReserveResult
  | { readonly ok: false; readonly status: 503; readonly reason: 'store'; readonly retryAfterSeconds: number };

const STORE_REFUSAL = Object.freeze({
  ok: false as const,
  status: 503 as const,
  reason: 'store' as const,
  retryAfterSeconds: INSTALL_STORE_RETRY_AFTER_SECONDS,
});

/** True only for a limiter backed by a store shared by every instance. */
export function isDurable(limiter: Pick<UsageLimiter, 'durable'> | null | undefined): boolean {
  return limiter?.durable === true;
}

/**
 * Reserves `chars` for one install (keyId) and the global ceiling, or refuses.
 * No limiter call at all when the limiter is missing or not durable.
 */
export async function reserveForInstall(
  limiter: UsageLimiter | null,
  keyId: string,
  chars: number,
  now: number,
): Promise<InstallReserveResult> {
  if (!limiter || !isDurable(limiter)) return STORE_REFUSAL;
  try {
    return await limiter.reserve({ kind: 'install', id: keyId }, chars, now);
  } catch (error) {
    if (error instanceof LimiterStoreError) return STORE_REFUSAL;
    throw error;
  }
}
