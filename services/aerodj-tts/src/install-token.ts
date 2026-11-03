import crypto from 'node:crypto';
import type { Keyspace } from './attest-store.js';
import { parseChallengeKey } from './challenge.js';
import type { Env } from './handler.js';

/**
 * Install token (#378 design §1.3): a short-lived bearer an attested TestFlight install
 * gets from `POST /api/attest/token` by signing a fresh `tok` challenge with its App
 * Attest key. It lets that install spend only from its own daily bucket, inside the
 * tester pool and the global ceiling.
 *
 *   token   = "v1." + b64url(payload) + "." + b64url(HMAC-SHA256(K_tok, DOMAIN ‖ b64url(payload)))
 *   payload = {"aud":"aerodj-tts/tts","sub":<b64url keyId>,"tier":"tester","env":<keyspace>,
 *              "iat":<s>,"exp":<s>,"jti":<b64url 16 random bytes>}
 *
 * Not a JWT: there is no `alg` header to confuse, one fixed MAC. K_tok is a dedicated
 * server-only key (`AERODJ_TTS_INSTALL_TOKEN_HMAC_KEY`, at least 32 bytes, created by the
 * owner) that must differ from the challenge key. Verification is stateless (MAC, aud, env,
 * tier, exp, iat); revocation and the key record are checked inside the reserve script.
 * Callers must never log the token, its payload or the keyId.
 */

export const INSTALL_TOKEN_TTL_SECONDS = 30 * 60;
/** Clock skew allowed on `iat` only (design §1.3); `exp` gets none. */
export const INSTALL_TOKEN_IAT_SKEW_SECONDS = 30;
export const INSTALL_TOKEN_AUDIENCE = 'aerodj-tts/tts';
export const MAX_INSTALL_TOKEN_CHARS = 512;

const DOMAIN = Buffer.from('aerodj-tts/install-token/v1\0', 'utf8');
const SHAPE = /^v1\.([A-Za-z0-9_-]{1,400})\.([A-Za-z0-9_-]{43})$/;
const KEY_ID_B64URL = /^[A-Za-z0-9_-]{43}$/;
const JTI = /^[A-Za-z0-9_-]{22}$/;
const FIELDS = ['aud', 'sub', 'tier', 'env', 'iat', 'exp', 'jti'];

export interface InstallTokenClaims {
  readonly aud: typeof INSTALL_TOKEN_AUDIENCE;
  /** base64url of the raw 32-byte App Attest keyId. */
  readonly sub: string;
  readonly tier: 'tester';
  readonly env: Keyspace;
  readonly iat: number;
  readonly exp: number;
  readonly jti: string;
}

/**
 * Parses AERODJ_TTS_INSTALL_TOKEN_HMAC_KEY by the challenge key's rule (64+ hex chars, or
 * base64/base64url of at least 32 bytes). Null when unset, malformed, short, or equal to
 * the challenge key (a dedicated key is required): the caller fails closed (500 `misconfig`).
 */
export function installTokenKey(env: Env): Buffer | null {
  const key = parseChallengeKey(env.AERODJ_TTS_INSTALL_TOKEN_HMAC_KEY);
  if (!key) return null;
  const challengeKey = parseChallengeKey(env.AERODJ_TTS_CHALLENGE_HMAC_KEY);
  if (challengeKey && challengeKey.length === key.length && crypto.timingSafeEqual(challengeKey, key)) return null;
  return key;
}

function mac(key: Buffer, payloadB64: string): Buffer {
  return crypto.createHmac('sha256', key).update(DOMAIN).update(payloadB64, 'ascii').digest();
}

export interface MintOptions {
  key: Buffer;
  keyId: Buffer;
  env: Keyspace;
  /** ms since epoch. */
  now: number;
  random?: (n: number) => Buffer;
}

export function mintInstallToken(opts: MintOptions): { token: string; claims: InstallTokenClaims } {
  if (!Buffer.isBuffer(opts.keyId) || opts.keyId.length !== 32) throw new TypeError('keyId must be 32 bytes');
  const iat = Math.floor(opts.now / 1000);
  const claims: InstallTokenClaims = {
    aud: INSTALL_TOKEN_AUDIENCE,
    sub: opts.keyId.toString('base64url'),
    tier: 'tester',
    env: opts.env,
    iat,
    exp: iat + INSTALL_TOKEN_TTL_SECONDS,
    jti: (opts.random ?? crypto.randomBytes)(16).toString('base64url'),
  };
  const payload = Buffer.from(JSON.stringify(claims), 'utf8').toString('base64url');
  return { token: `v1.${payload}.${mac(opts.key, payload).toString('base64url')}`, claims };
}

export type TokenFailure = 'malformed' | 'mac' | 'claims' | 'audience' | 'env' | 'expired' | 'future';
export type TokenCheck = { ok: true; claims: InstallTokenClaims } | { ok: false; reason: TokenFailure };

/**
 * Stateless check, in this order: shape → constant-time MAC → strict claims → aud → env
 * (this deployment's keyspace) → exp (no skew) → iat (≤ now + 30 s, and exp − iat ≤ TTL).
 * No store access. Never throws.
 */
export function verifyInstallToken(token: unknown, opts: { key: Buffer; env: Keyspace; now: number }): TokenCheck {
  if (typeof token !== 'string' || token.length > MAX_INSTALL_TOKEN_CHARS) return { ok: false, reason: 'malformed' };
  const m = SHAPE.exec(token);
  if (!m) return { ok: false, reason: 'malformed' };
  const [, payload, sig] = m;
  const presented = Buffer.from(sig, 'base64url');
  if (presented.length !== 32 || presented.toString('base64url') !== sig) return { ok: false, reason: 'malformed' };
  if (!crypto.timingSafeEqual(mac(opts.key, payload), presented)) return { ok: false, reason: 'mac' };
  let claims: Record<string, unknown>;
  try {
    const raw = Buffer.from(payload, 'base64url');
    if (raw.toString('base64url') !== payload) return { ok: false, reason: 'malformed' };
    const value: unknown = JSON.parse(raw.toString('utf8'));
    if (!value || typeof value !== 'object' || Array.isArray(value)) return { ok: false, reason: 'claims' };
    claims = value as Record<string, unknown>;
  } catch {
    return { ok: false, reason: 'claims' };
  }
  const keys = Object.keys(claims);
  if (keys.length !== FIELDS.length || !FIELDS.every((f) => keys.includes(f))) return { ok: false, reason: 'claims' };
  const { aud, sub, tier, env, iat, exp, jti } = claims;
  if (typeof sub !== 'string' || !KEY_ID_B64URL.test(sub) || Buffer.from(sub, 'base64url').length !== 32) return { ok: false, reason: 'claims' };
  if (typeof jti !== 'string' || !JTI.test(jti)) return { ok: false, reason: 'claims' };
  if (tier !== 'tester') return { ok: false, reason: 'claims' };
  if (!Number.isSafeInteger(iat) || !Number.isSafeInteger(exp)) return { ok: false, reason: 'claims' };
  if (aud !== INSTALL_TOKEN_AUDIENCE) return { ok: false, reason: 'audience' };
  if (env !== opts.env) return { ok: false, reason: 'env' };
  const nowS = Math.floor(opts.now / 1000);
  if (nowS >= (exp as number)) return { ok: false, reason: 'expired' };
  if ((iat as number) > nowS + INSTALL_TOKEN_IAT_SKEW_SECONDS) return { ok: false, reason: 'future' };
  if ((exp as number) - (iat as number) > INSTALL_TOKEN_TTL_SECONDS || (exp as number) <= (iat as number)) return { ok: false, reason: 'claims' };
  return { ok: true, claims: claims as unknown as InstallTokenClaims };
}

/** The raw keyId bytes of a verified token's `sub`. */
export function tokenKeyId(claims: InstallTokenClaims): Buffer {
  return Buffer.from(claims.sub, 'base64url');
}
