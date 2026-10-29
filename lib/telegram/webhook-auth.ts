import { createHash, timingSafeEqual } from 'crypto';

/**
 * Fail closed. A missing expected secret rejects the request.
 * Both sides are hashed to a fixed length before the constant-time compare.
 */
export function webhookAuthorized(provided: string | null, expected: string | undefined): boolean {
  if (!expected) return false;
  const actual = createHash('sha256').update(provided ?? '', 'utf8').digest();
  const wanted = createHash('sha256').update(expected, 'utf8').digest();
  return timingSafeEqual(actual, wanted);
}
