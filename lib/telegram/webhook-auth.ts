import { createHash, timingSafeEqual } from 'crypto';
import { TELEGRAM_SECRET_MIN_LENGTH } from '@/lib/auth/route-gate';

/**
 * Fail closed. A missing, blank or short (under 32 chars after trim) expected secret
 * rejects the request, matching the middleware gate. Only the configured value is
 * trimmed; the presented header is compared as sent.
 * Both sides are hashed to a fixed length before the constant-time compare.
 *
 * Why 401 here when the middleware gate returns 503 for the same misconfig: the gate
 * (lib/auth/route-gate.ts, via middleware.ts) runs first on every /api path and is the
 * authoritative 503 `misconfig`. This handler-side check is defense in depth only. If it
 * is ever reached with a missing/short secret, it fails closed with the handlers' existing
 * 401, so it never reveals to a caller that the secret is misconfigured. The 401 is
 * deliberate; do not "align" it to 503.
 */
export function webhookAuthorized(provided: string | null, rawExpected: string | undefined): boolean {
  const expected = (rawExpected ?? '').trim();
  if (expected.length < TELEGRAM_SECRET_MIN_LENGTH) return false;
  const actual = createHash('sha256').update(provided ?? '', 'utf8').digest();
  const wanted = createHash('sha256').update(expected, 'utf8').digest();
  return timingSafeEqual(actual, wanted);
}
