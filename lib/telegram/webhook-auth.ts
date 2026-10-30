import { createHash, timingSafeEqual } from 'crypto';
import { TELEGRAM_SECRET_MIN_LENGTH } from '@/lib/auth/route-gate';

/**
 * Fail closed. A missing, blank or short (under 32 chars after trim) expected secret
 * rejects the request, matching the middleware gate. Only the configured value is
 * trimmed; the presented header is compared as sent.
 * Both sides are hashed to a fixed length before the constant-time compare.
 */
export function webhookAuthorized(provided: string | null, rawExpected: string | undefined): boolean {
  const expected = (rawExpected ?? '').trim();
  if (expected.length < TELEGRAM_SECRET_MIN_LENGTH) return false;
  const actual = createHash('sha256').update(provided ?? '', 'utf8').digest();
  const wanted = createHash('sha256').update(expected, 'utf8').digest();
  return timingSafeEqual(actual, wanted);
}
