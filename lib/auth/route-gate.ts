// Fail-closed gate for every legacy ray-do API route (#174 §6).
// Edge-safe: Web Crypto only, so middleware and route handlers share it.

export const ADMIN_TOKEN_ENV = 'RAY_DO_ADMIN_TOKEN';
export const TELEGRAM_SECRET_ENV = 'TELEGRAM_WEBHOOK_SECRET';
export const ADMIN_TOKEN_MIN_LENGTH = 32;
export const TELEGRAM_SECRET_MIN_LENGTH = 32;

/** Paths that are gone for every caller, authenticated or not. */
export const REMOVED_API_PATHS: readonly string[] = ['/api/telegram/set-webhook'];

/** Telegram's inbound receivers. Telegram can only send its secret-token header. */
export const TELEGRAM_WEBHOOK_PATHS: readonly string[] = ['/api/telegram', '/api/webhooks/telegram'];

export type GateDecision =
  | { allow: true }
  | { allow: false; status: 401 | 410 | 503; error: 'unauthorized' | 'gone' | 'misconfig' };

const encoder = new TextEncoder();

async function sha256(value: string): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest('SHA-256', encoder.encode(value)));
}

/** Constant-time compare of fixed-length digests. An empty expected value never matches. */
export async function secretMatches(provided: string | null, expected: string): Promise<boolean> {
  if (expected.length === 0) return false;
  const [actual, wanted] = await Promise.all([sha256(provided ?? ''), sha256(expected)]);
  let diff = 0;
  for (let i = 0; i < wanted.length; i++) diff |= actual[i] ^ wanted[i];
  return diff === 0;
}

function bearer(header: string | null): string | null {
  if (!header) return null;
  const match = /^Bearer[ ]+(\S+)[ ]*$/i.exec(header);
  return match ? match[1] : null;
}

function normalize(pathname: string): string {
  const trimmed = pathname.replace(/\/+$/, '');
  return trimmed === '' ? '/' : trimmed;
}

/**
 * The configured secret with surrounding whitespace trimmed, or null when it is unset,
 * blank after trimming, or shorter than `minLength` after trimming (a misconfig).
 *
 * Only the configured value is trimmed: a stray newline pasted into an env var must not
 * become part of the secret. The presented credential is never trimmed; it is compared
 * as sent against the trimmed value, in constant time, so " <token>" or "<token>\n" in a
 * header does not match.
 */
export function configuredSecret(name: string, minLength: number): string | null {
  const value = (process.env[name] ?? '').trim();
  return value.length >= minLength ? value : null;
}

/** Requires `Authorization: Bearer <RAY_DO_ADMIN_TOKEN>`. Unset, blank or short (after trim) is a misconfig. */
export async function adminDecision(headers: Headers): Promise<GateDecision> {
  const expected = configuredSecret(ADMIN_TOKEN_ENV, ADMIN_TOKEN_MIN_LENGTH);
  if (expected === null) {
    return { allow: false, status: 503, error: 'misconfig' };
  }
  if (!(await secretMatches(bearer(headers.get('authorization')), expected))) {
    return { allow: false, status: 401, error: 'unauthorized' };
  }
  return { allow: true };
}

/** Requires Telegram's X-Telegram-Bot-Api-Secret-Token. Unset, blank or short (after trim) is a misconfig. */
export async function telegramDecision(headers: Headers): Promise<GateDecision> {
  const expected = configuredSecret(TELEGRAM_SECRET_ENV, TELEGRAM_SECRET_MIN_LENGTH);
  if (expected === null) {
    return { allow: false, status: 503, error: 'misconfig' };
  }
  if (!(await secretMatches(headers.get('x-telegram-bot-api-secret-token'), expected))) {
    return { allow: false, status: 401, error: 'unauthorized' };
  }
  return { allow: true };
}

/** One decision per /api path. Anything not listed needs the admin token. */
export async function apiDecision(pathname: string, headers: Headers): Promise<GateDecision> {
  const path = normalize(pathname);
  if (REMOVED_API_PATHS.includes(path)) {
    return { allow: false, status: 410, error: 'gone' };
  }
  if (TELEGRAM_WEBHOOK_PATHS.includes(path)) {
    return telegramDecision(headers);
  }
  return adminDecision(headers);
}
