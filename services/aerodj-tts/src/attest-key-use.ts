import { STORE_RETRY_AFTER_SECONDS } from './attest-flags.js';
import { AttestStoreError, keyRecordKey, type AttestStore, type Keyspace } from './attest-store.js';

/**
 * One successful use of an attested key (owner decision 2026-10-29: 90-day SLIDING
 * TTL, refreshed on every use, not only on register).
 *
 * The assertion path (PR 4: attested `/api/tts` and `/api/entitlement`) calls this
 * after the assertion has verified against the stored key, before serving. It
 * refreshes the record's TTL to 90 days. A record that is gone (never registered,
 * or unused for 90 days and expired) is 401 `assertion` with detail `unknown_key`;
 * the app re-attests. Any store error or timeout fails closed: 503 `store`,
 * Retry-After 30 (STORE_RETRY_AFTER_SECONDS), and the request is not served.
 */
export type KeyUseResult =
  | { readonly ok: true }
  | { readonly ok: false; readonly status: 401; readonly reason: 'assertion'; readonly detail: 'unknown_key' }
  | { readonly ok: false; readonly status: 503; readonly reason: 'store'; readonly retryAfterSeconds: number };

export async function useAttestKey(store: AttestStore, keyspace: Keyspace, keyId: Buffer): Promise<KeyUseResult> {
  try {
    const outcome = await store.touchKey(keyRecordKey(keyspace, keyId));
    if (outcome === 'refreshed') return { ok: true };
    return { ok: false, status: 401, reason: 'assertion', detail: 'unknown_key' };
  } catch (error) {
    if (error instanceof AttestStoreError) return { ok: false, status: 503, reason: 'store', retryAfterSeconds: STORE_RETRY_AFTER_SECONDS };
    throw error;
  }
}
