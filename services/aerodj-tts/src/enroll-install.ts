import crypto from 'node:crypto';

/**
 * Per-install enrollment sub-cap key (Orion and Sentinel on #256, 2026-10-29: keep
 * the network key and add the install ID as a second 3/day check, so a register
 * must pass the network 3/day, the install 3/day and the global 20/day).
 *
 * Contract (Fry): the app sends `installId` in the /api/attest/register body only:
 * a random UUID v4 kept in the device Keychain, lowercase, 36 characters, carrying
 * no device data. It is client-chosen, so on its own it caps nothing (a client can
 * rotate it freely); that is why the network cap stays alongside it. Together they
 * give the owner's "3 per device" for an honest app and still cap abuse.
 *
 * Privacy: the install ID is never stored, logged or returned. The counter key holds
 * only HMAC-SHA256(K, domain ‖ day ‖ installId), K being the server's challenge HMAC
 * key, under a domain distinct from the network bucket's, so the two buckets never
 * collide or link. The day is inside the MAC, so one install maps to unrelated keys
 * on different days, and each counter expires with the enroll counters (2 days).
 */

export const DEFAULT_ENROLL_INSTALL_DAILY_CAP = 3;
export const MAX_ENROLL_INSTALL_DAILY_CAP = 1_000;

const DOMAIN = Buffer.from('onairly-enroll-install-v1\0', 'utf8');
/** Lowercase UUID v4: version nibble 4, variant nibble 8, 9, a or b. */
const INSTALL_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

/** The install ID if it is exactly a lowercase UUID v4 string, else null (the caller fails closed). */
export function parseInstallId(value: unknown): string | null {
  return typeof value === 'string' && value.length === 36 && INSTALL_ID.test(value) ? value : null;
}

/** Hex HMAC-SHA256(key, DOMAIN ‖ day ‖ 0x00 ‖ installId). Never the install ID itself. */
export function installBucket(key: Buffer, day: string, installId: string): string {
  return crypto.createHmac('sha256', key).update(DOMAIN).update(day, 'utf8').update('\0').update(installId, 'utf8').digest('hex');
}
