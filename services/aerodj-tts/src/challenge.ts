import crypto from 'node:crypto';

/**
 * Stateless attestation/assertion challenges (#233 note §4.1.1, Sentinel B1).
 *
 * challenge = base64url(v ‖ purpose ‖ flags ‖ ts ‖ rand16 ‖ mac)
 *   v       1 byte, CHALLENGE_VERSION
 *   purpose 1 byte, PURPOSE_CODES
 *   flags   1 byte, bit 0 = bound to an App Attest keyId (Sentinel rec. 6)
 *   ts      8 bytes, big-endian issue time in ms
 *   rand16  16 random bytes
 *   mac     HMAC-SHA256(K, DOMAIN ‖ v ‖ purpose ‖ flags ‖ ts ‖ rand16 [‖ keyId(32)])
 *
 * Issuance and verification touch no store. Single use is enforced only at
 * consumption, after the caller's signature check succeeds (challenge-consume.ts).
 */

export const CHALLENGE_VERSION = 1;
export const CHALLENGE_TTL_MS = 120_000;
/** Tolerated issue-time skew between function instances. */
export const CLOCK_SKEW_MS = 5_000;
export const PURPOSES = ['attest', 'tts', 'ent'] as const;
export type Purpose = (typeof PURPOSES)[number];
const PURPOSE_CODES: Record<Purpose, number> = { attest: 1, tts: 2, ent: 3 };
/** Purposes whose challenge must be bound to the install's keyId. */
export const KEY_BOUND_PURPOSES: ReadonlySet<Purpose> = new Set(['tts', 'ent']);

const DOMAIN = Buffer.from('onairly-challenge-v1\0', 'utf8');
const HEADER_BYTES = 1 + 1 + 1 + 8 + 16;
const MAC_BYTES = 32;
export const CHALLENGE_BYTES = HEADER_BYTES + MAC_BYTES;
const FLAG_KEY_BOUND = 0x01;
const KEY_ID = /^[A-Za-z0-9+/]{43}=$/;
const B64URL = /^[A-Za-z0-9_-]+$/;
const MIN_KEY_BYTES = 32;

export function isPurpose(value: unknown): value is Purpose {
  return typeof value === 'string' && (PURPOSES as readonly string[]).includes(value);
}

/**
 * App Attest keyId: standard base64 of a 32-byte SHA-256 (44 chars). Returns
 * the raw 32 bytes, or null when malformed.
 */
export function parseKeyId(value: unknown): Buffer | null {
  if (typeof value !== 'string' || !KEY_ID.test(value)) return null;
  const raw = Buffer.from(value, 'base64');
  return raw.length === 32 && raw.toString('base64') === value ? raw : null;
}

/**
 * Parses AERODJ_TTS_CHALLENGE_HMAC_KEY (owner-generated; never created by us):
 * 64+ hex chars, or base64/base64url of at least 32 bytes. Null when unset,
 * malformed or short, so the caller fails closed with 500 `misconfig`.
 */
export function parseChallengeKey(value: string | undefined): Buffer | null {
  const v = value?.trim();
  if (!v) return null;
  let key: Buffer | null = null;
  if (/^[0-9a-fA-F]+$/.test(v) && v.length % 2 === 0) key = Buffer.from(v, 'hex');
  else if (/^[A-Za-z0-9+/_-]+={0,2}$/.test(v)) key = Buffer.from(v.replace(/-/g, '+').replace(/_/g, '/'), 'base64');
  return key && key.length >= MIN_KEY_BYTES ? key : null;
}

function mac(key: Buffer, header: Buffer, keyId: Buffer | null): Buffer {
  const h = crypto.createHmac('sha256', key).update(DOMAIN).update(header);
  if (keyId) h.update(keyId);
  return h.digest();
}

export interface IssueOptions {
  key: Buffer;
  purpose: Purpose;
  /** Raw 32-byte keyId; required for `tts`/`ent`, optional for `attest`. */
  keyId: Buffer | null;
  now: number;
  random?: (n: number) => Buffer;
}

export function issueChallenge(opts: IssueOptions): string {
  if (KEY_BOUND_PURPOSES.has(opts.purpose) && !opts.keyId) throw new Error('keyId required for this purpose');
  const header = Buffer.alloc(HEADER_BYTES);
  header[0] = CHALLENGE_VERSION;
  header[1] = PURPOSE_CODES[opts.purpose];
  header[2] = opts.keyId ? FLAG_KEY_BOUND : 0;
  header.writeBigUInt64BE(BigInt(opts.now), 3);
  (opts.random ?? crypto.randomBytes)(16).copy(header, 11);
  return Buffer.concat([header, mac(opts.key, header, opts.keyId)]).toString('base64url');
}

export type ChallengeFailure = 'malformed' | 'version' | 'mac' | 'purpose' | 'expired' | 'future' | 'key_binding';
export type ChallengeCheck = { ok: true; issuedAt: number } | { ok: false; reason: ChallengeFailure };

export interface VerifyOptions {
  key: Buffer;
  /** Purpose the consuming endpoint expects. */
  purpose: Purpose;
  /** Raw keyId presented with the request (from X-OnAirly-Key), or null. */
  keyId: Buffer | null;
  now: number;
}

/** Stateless check: MAC (constant time), version, purpose, age, keyId binding. No store access. */
export function verifyChallenge(challenge: unknown, opts: VerifyOptions): ChallengeCheck {
  if (typeof challenge !== 'string' || challenge.length > 128 || !B64URL.test(challenge)) return { ok: false, reason: 'malformed' };
  const bytes = Buffer.from(challenge, 'base64url');
  if (bytes.length !== CHALLENGE_BYTES || bytes.toString('base64url') !== challenge) return { ok: false, reason: 'malformed' };
  const header = bytes.subarray(0, HEADER_BYTES);
  const presented = bytes.subarray(HEADER_BYTES);
  const flags = header[2];
  if (flags !== 0 && flags !== FLAG_KEY_BOUND) return { ok: false, reason: 'malformed' };
  const bound = flags === FLAG_KEY_BOUND;
  // A key-bound challenge verifies only with the same keyId; an unbound one
  // must not be accepted where binding is required.
  if (bound && !opts.keyId) return { ok: false, reason: 'key_binding' };
  const expected = mac(opts.key, header, bound ? opts.keyId : null);
  if (!crypto.timingSafeEqual(expected, presented)) return { ok: false, reason: 'mac' };
  if (header[0] !== CHALLENGE_VERSION) return { ok: false, reason: 'version' };
  if (header[1] !== PURPOSE_CODES[opts.purpose]) return { ok: false, reason: 'purpose' };
  if (KEY_BOUND_PURPOSES.has(opts.purpose) && !bound) return { ok: false, reason: 'key_binding' };
  const issuedAt = Number(header.readBigUInt64BE(3));
  if (issuedAt > opts.now + CLOCK_SKEW_MS) return { ok: false, reason: 'future' };
  if (opts.now - issuedAt > CHALLENGE_TTL_MS) return { ok: false, reason: 'expired' };
  return { ok: true, issuedAt };
}

/** Store key for single use: `used:{aerodj-tts}:<hex sha256(challenge)>`. */
export function usedKey(challenge: string): string {
  return `used:{aerodj-tts}:${crypto.createHash('sha256').update(challenge, 'utf8').digest('hex')}`;
}
/** Single-use mark lifetime (s): longer than CHALLENGE_TTL_MS + CLOCK_SKEW_MS. */
export const USED_TTL_SECONDS = 300;
