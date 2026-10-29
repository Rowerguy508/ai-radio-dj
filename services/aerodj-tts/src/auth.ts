import crypto from 'node:crypto';

const HEX_SHA256 = /^[0-9a-f]{64}$/i;

/** Parses the configured SHA-256 hex digest. Returns null when unset or malformed. */
export function parseTokenHash(hex: string | undefined): Buffer | null {
  const trimmed = hex?.trim();
  if (!trimmed || !HEX_SHA256.test(trimmed)) return null;
  return Buffer.from(trimmed, 'hex');
}

/** Extracts the bearer token from an Authorization header value. */
export function bearerToken(header: string | undefined): string | null {
  if (!header) return null;
  const match = /^Bearer[ ]+(\S+)\s*$/i.exec(header);
  return match ? match[1] : null;
}

/**
 * Hashes the presented token and compares it with the stored digest in constant
 * time. Both sides are always 32 bytes, so timingSafeEqual never throws on length.
 */
export function tokenMatches(token: string, expectedHash: Buffer): boolean {
  const presented = crypto.createHash('sha256').update(token, 'utf8').digest();
  return crypto.timingSafeEqual(presented, expectedHash);
}
