import crypto from 'node:crypto';
import { attestEnabled, paidStopped } from './attest-flags.js';
import { CHALLENGE_TTL_MS, KEY_BOUND_PURPOSES, isPurpose, issueChallenge, parseChallengeKey, parseKeyId } from './challenge.js';
import { selectChallengeStore, type ChallengeStore } from './challenge-store.js';
import type { Env } from './handler.js';
import { BODY_CAPS, parseJsonObject, readRawBody } from './raw-body.js';

export type AttestReason = 'bad_request' | 'too_large' | 'misconfig' | 'store' | 'disabled';

export interface AttestLogEntry {
  requestId: string;
  status: number;
  reason?: AttestReason;
}

export interface ChallengeDeps {
  env: Env;
  /** Durable single-use store for later consumption; null = not configured (503 `store`). Never called here. */
  store: ChallengeStore | null;
  log: (entry: AttestLogEntry) => void;
  now: () => number;
  requestId: () => string;
  random?: (n: number) => Buffer;
}

/** `Retry-After` per the §4.4 table; every 429/503 carries one. */
const RETRY_AFTER: Partial<Record<AttestReason, number>> = { misconfig: 3600, store: 30, disabled: 3600 };
const STATUS: Record<AttestReason, number> = { bad_request: 400, too_large: 413, misconfig: 500, store: 503, disabled: 503 };
const MESSAGES: Record<number, string> = {
  400: 'Bad request',
  405: 'Method not allowed',
  413: 'Payload too large',
  500: 'Server misconfigured',
  503: 'Service unavailable',
};
const ALLOWED_FIELDS = new Set(['purpose', 'keyId']);

export function challengeDeps(env: Env = process.env): ChallengeDeps {
  return {
    env,
    store: selectChallengeStore(env),
    log: (e) => console.log(JSON.stringify({ requestId: e.requestId, status: e.status, ...(e.reason ? { reason: e.reason } : {}) })),
    now: Date.now,
    requestId: () => crypto.randomUUID(),
  };
}

function json(status: number, requestId: string, body: unknown, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store', 'X-Request-Id': requestId, ...extra },
  });
}

/**
 * POST /api/attest/challenge (note §4.1.1). Body `{ purpose, keyId? }`;
 * `keyId` is required for `tts`/`ent` (bound into the MAC). Returns
 * `{ challenge, expiresIn: 120 }`. Performs **no store read or write**: the
 * store is only checked for being configured, so a deployment that could
 * not consume a challenge does not hand one out.
 */
export async function handleChallenge(request: Request, deps: ChallengeDeps): Promise<Response> {
  const requestId = deps.requestId();
  const fail = (reason: AttestReason): Response => {
    const status = STATUS[reason];
    const retry = RETRY_AFTER[reason];
    deps.log({ requestId, status, reason });
    return json(
      status,
      requestId,
      { error: MESSAGES[status], requestId, reason, ...(retry ? { retryAfterSeconds: retry } : {}) },
      retry ? { 'Retry-After': String(retry) } : {},
    );
  };

  // Master stop (note §4.7, D1; PR 3): first, before the method, the attest flag, the key and the store.
  if (paidStopped(deps.env)) {
    await request.body?.cancel().catch(() => {});
    return fail('disabled');
  }
  if (request.method !== 'POST') {
    deps.log({ requestId, status: 405 });
    await request.body?.cancel().catch(() => {});
    return json(405, requestId, { error: MESSAGES[405], requestId }, { Allow: 'POST' });
  }
  if (!attestEnabled(deps.env)) {
    await request.body?.cancel().catch(() => {});
    return fail('disabled');
  }
  const key = parseChallengeKey(deps.env.AERODJ_TTS_CHALLENGE_HMAC_KEY);
  if (!key) return fail('misconfig');
  if (!deps.store || deps.store.durable !== true) return fail('store');

  const raw = await readRawBody(request, BODY_CAPS.challenge);
  if (!raw.ok) return fail(raw.reason);
  const body = parseJsonObject(raw.bytes);
  if (!body || Object.keys(body).some((k) => !ALLOWED_FIELDS.has(k))) return fail('bad_request');
  const purpose = body.purpose;
  if (!isPurpose(purpose)) return fail('bad_request');
  let keyId: Buffer | null = null;
  if (body.keyId !== undefined) {
    keyId = parseKeyId(body.keyId);
    if (!keyId) return fail('bad_request');
  }
  if (KEY_BOUND_PURPOSES.has(purpose) && !keyId) return fail('bad_request');

  const challenge = issueChallenge({ key, purpose, keyId, now: deps.now(), random: deps.random });
  deps.log({ requestId, status: 200 });
  return json(200, requestId, { challenge, expiresIn: CHALLENGE_TTL_MS / 1000 });
}
