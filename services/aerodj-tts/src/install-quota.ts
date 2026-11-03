import { MISCONFIG_RETRY_AFTER_SECONDS, STORE_RETRY_AFTER_SECONDS } from './attest-flags.js';
import { LimiterStoreError, type InstallCharge, type InstallReserveOutcome, type ReserveResult, type UsageLimiter } from './limiter.js';

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
 * #378: the install-token path on `/api/tts` calls it with a gate (tester reserve).
 * Its tests show 503 `store` without Redis.
 */

/** `Retry-After` for 503 `store` on the attest/install paths (note §4.4 table). */
export const INSTALL_STORE_RETRY_AFTER_SECONDS = STORE_RETRY_AFTER_SECONDS;

export type InstallReserveResult =
  | ReserveResult
  | InstallReserveOutcome
  | { readonly ok: false; readonly status: 503; readonly reason: 'store'; readonly retryAfterSeconds: number }
  | { readonly ok: false; readonly status: 500; readonly reason: 'misconfig'; readonly retryAfterSeconds: number };

const STORE_REFUSAL = Object.freeze({
  ok: false as const,
  status: 503 as const,
  reason: 'store' as const,
  retryAfterSeconds: INSTALL_STORE_RETRY_AFTER_SECONDS,
});

/**
 * Any non-store failure from the limiter (a bug, a bad subject, a broken limiter):
 * 500 `misconfig` with `Retry-After: 3600`, the same contract as every other server
 * misconfiguration (note §4.4; Sentinel's #250 nit, PR 4), instead of an uncaught
 * platform 500. Nothing is reserved on this path, so nothing is spent.
 */
const MISCONFIG_REFUSAL = Object.freeze({
  ok: false as const,
  status: 500 as const,
  reason: 'misconfig' as const,
  retryAfterSeconds: MISCONFIG_RETRY_AFTER_SECONDS,
});

/** True only for a limiter backed by a store shared by every instance. */
export function isDurable(limiter: Pick<UsageLimiter, 'durable'> | null | undefined): boolean {
  return limiter?.durable === true;
}

/**
 * Reserves `chars` for one install (keyId) and the global ceiling, or refuses.
 * No limiter call at all when the limiter is missing or not durable.
 * A store error is 503 `store`; any other throw is 500 `misconfig` (never rethrown).
 */
export async function reserveForInstall(
  limiter: UsageLimiter | null,
  keyId: string,
  chars: number,
  now: number,
  /**
   * #378: the token's attest record + revocation keys. With a gate the reservation is the
   * tester one (`reserveInstall`: record, revocation, global, tester pool, install, one script);
   * a limiter without it is 503 `store`. Without a gate: the pre-#378 two-bucket reserve.
   */
  gate?: Omit<InstallCharge, 'id' | 'chars'>,
): Promise<InstallReserveResult> {
  if (!limiter || !isDurable(limiter)) return STORE_REFUSAL;
  try {
    if (gate) {
      if (!limiter.reserveInstall) return STORE_REFUSAL;
      return await limiter.reserveInstall({ id: keyId, chars, recordKey: gate.recordKey, revokedKey: gate.revokedKey }, now);
    }
    return await limiter.reserve({ kind: 'install', id: keyId }, chars, now);
  } catch (error) {
    if (error instanceof LimiterStoreError) return STORE_REFUSAL;
    return MISCONFIG_REFUSAL;
  }
}
