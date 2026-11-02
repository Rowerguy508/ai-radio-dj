import crypto from 'node:crypto';
import { TESTFLIGHT_VALIDATION_CATEGORY, tokenClientData, verifyAssertion, MAX_ASSERTION_BYTES, type AssertionFailure } from './app-attest-assertion.js';
import { registerConfig } from './attest-config.js';
import {
  attestEnabled,
  DISABLED_RETRY_AFTER_SECONDS,
  MISCONFIG_RETRY_AFTER_SECONDS,
  paidStopped,
  STORE_RETRY_AFTER_SECONDS,
  testerVoiceEnabled,
} from './attest-flags.js';
import {
  attestUsedKey,
  AttestStoreError,
  counterKey,
  keyRecordKey,
  revokedKey,
  selectAttestStore,
  tokenMintKey,
  type AttestStore,
} from './attest-store.js';
import { parseKeyId, verifyChallenge, type ChallengeFailure } from './challenge.js';
import { secondsUntilNextUtcDay, type Env } from './handler.js';
import { isDurable } from './install-quota.js';
import { INSTALL_TOKEN_TTL_SECONDS, installTokenKey, mintInstallToken } from './install-token.js';
import { utcDay } from './limiter.js';
import { BODY_CAPS, parseJsonObject, readRawBody } from './raw-body.js';

/**
 * POST /api/attest/token (#378 design §1.1 step 4, §1.2, §1.3): an attested TestFlight
 * install swaps ONE fresh App Attest assertion over a key-bound `tok` challenge for a
 * 30-minute install token. Headers `X-OnAirly-Key` (standard base64 keyId) and
 * `X-OnAirly-Assertion` (standard base64 CBOR); body `{ challenge }`, at most 1 KiB, read
 * raw from the stream and hashed into clientData:
 *   clientData = "onairly-tok-v1\n" + challenge + "\n" + hex(sha256(rawBody)).
 *
 * Order: PAID_STOP → 405 → AERODJ_TTS_ATTEST_ENABLED → AERODJ_TTS_TESTER_VOICE_ENABLED (both
 * exact `true`, else 503 `disabled` before any store call) → mixed auth (`Authorization` or
 * `X-OnAirly-Install-Token` present: 400 `mixed_auth`; an owner token can never mint) →
 * config (challenge key, dedicated token key, App ID: 500 `misconfig`) → durable store
 * (503 `store`) → body/headers (400/413) → stateless challenge (`tok`, bound to this keyId;
 * 401 `assertion`) → GET key record (missing/revoked: 401 `reattest`) → assertion signature
 * + rpIdHash (401 `assertion`) → TestFlight tier (403 `no_entitlement`) → expired challenge:
 * read-only used probe (401 / 400 `challenge_expired`) → ONE script: single-use mark,
 * record + revocation, counter (> stored, then committed), 96/day mint rate (429 `rate`),
 * 90-day TTL → 200 `{ token, expiresIn: 1800 }`.
 *
 * Minting costs no characters. Logs carry enums only: never the token, keyId, challenge,
 * assertion, header values or body.
 */

export type TokenReason =
  | 'bad_request'
  | 'too_large'
  | 'misconfig'
  | 'store'
  | 'disabled'
  | 'mixed_auth'
  | 'assertion'
  | 'challenge_expired'
  | 'reattest'
  | 'no_entitlement'
  | 'rate';

export type TokenDetail = ChallengeFailure | AssertionFailure | 'reused' | 'counter' | 'revoked' | 'unknown_key' | 'category';

export interface TokenLogEntry {
  requestId: string;
  status: number;
  reason?: TokenReason;
  detail?: TokenDetail;
}

export interface TokenDeps {
  env: Env;
  store: AttestStore | null;
  log: (entry: TokenLogEntry) => void;
  now: () => number;
  requestId: () => string;
  random?: (n: number) => Buffer;
}

const STATUS: Record<TokenReason, number> = {
  bad_request: 400,
  mixed_auth: 400,
  challenge_expired: 400,
  assertion: 401,
  reattest: 401,
  no_entitlement: 403,
  too_large: 413,
  rate: 429,
  misconfig: 500,
  store: 503,
  disabled: 503,
};
const FIXED_RETRY_AFTER: Partial<Record<TokenReason, number>> = {
  misconfig: MISCONFIG_RETRY_AFTER_SECONDS,
  store: STORE_RETRY_AFTER_SECONDS,
  disabled: DISABLED_RETRY_AFTER_SECONDS,
};
const MESSAGES: Record<number, string> = {
  400: 'Bad request',
  401: 'Unauthorized',
  403: 'Forbidden',
  405: 'Method not allowed',
  413: 'Payload too large',
  429: 'Too many requests',
  500: 'Server misconfigured',
  503: 'Service unavailable',
};
const B64 = /^[A-Za-z0-9+/]+={0,2}$/;
const MAX_ASSERTION_B64 = Math.ceil(MAX_ASSERTION_BYTES / 3) * 4;

export function tokenDeps(env: Env = process.env): TokenDeps {
  return {
    env,
    store: selectAttestStore(env),
    log: (e) =>
      console.log(
        JSON.stringify({ requestId: e.requestId, status: e.status, ...(e.reason ? { reason: e.reason } : {}), ...(e.detail ? { detail: e.detail } : {}) }),
      ),
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

function parseAssertionHeader(value: string | null): Buffer | null {
  if (value === null || value.length === 0 || value.length > MAX_ASSERTION_B64 || value.length % 4 !== 0 || !B64.test(value)) return null;
  const bytes = Buffer.from(value, 'base64');
  return bytes.toString('base64') === value ? bytes : null;
}

interface StoredKey {
  pubKeySpki: Buffer;
  tier: 'tester' | undefined;
  revoked: boolean;
}

function parseRecord(raw: string): StoredKey | null {
  try {
    const v = JSON.parse(raw) as Record<string, unknown>;
    if (!v || typeof v !== 'object' || typeof v.pubKeySpki !== 'string') return null;
    return { pubKeySpki: Buffer.from(v.pubKeySpki, 'base64'), tier: v.tier === 'tester' ? 'tester' : undefined, revoked: v.revoked !== false };
  } catch {
    return null;
  }
}

export async function handleToken(request: Request, deps: TokenDeps): Promise<Response> {
  const requestId = deps.requestId();
  const fail = (reason: TokenReason, detail?: TokenDetail, retryAfter?: number): Response => {
    const status = STATUS[reason];
    const retry = retryAfter ?? FIXED_RETRY_AFTER[reason];
    deps.log({ requestId, status, reason, ...(detail ? { detail } : {}) });
    return json(
      status,
      requestId,
      { error: MESSAGES[status], requestId, reason, ...(retry ? { retryAfterSeconds: retry } : {}) },
      retry ? { 'Retry-After': String(retry) } : {},
    );
  };
  const discard = () => request.body?.cancel().catch(() => {});

  if (paidStopped(deps.env)) {
    await discard();
    return fail('disabled');
  }
  if (request.method !== 'POST') {
    deps.log({ requestId, status: 405 });
    await discard();
    return json(405, requestId, { error: MESSAGES[405], requestId }, { Allow: 'POST' });
  }
  // Two independent exact-`true` locks, before any config or store access.
  if (!attestEnabled(deps.env) || !testerVoiceEnabled(deps.env)) {
    await discard();
    return fail('disabled');
  }
  if (request.headers.has('authorization') || request.headers.has('x-onairly-install-token')) {
    await discard();
    return fail('mixed_auth');
  }
  const config = registerConfig(deps.env);
  const tokenKey = installTokenKey(deps.env);
  if (!config || !tokenKey) {
    await discard();
    return fail('misconfig');
  }
  const store = deps.store;
  if (!store || !isDurable(store) || !store.getKey || !store.mintToken) {
    await discard();
    return fail('store');
  }

  const raw = await readRawBody(request, BODY_CAPS.challenge);
  if (!raw.ok) return fail(raw.reason);
  const body = parseJsonObject(raw.bytes);
  if (!body || Object.keys(body).length !== 1 || typeof body.challenge !== 'string') return fail('bad_request');
  const challenge = body.challenge;
  const keyId = parseKeyId(request.headers.get('x-onairly-key'));
  const assertion = parseAssertionHeader(request.headers.get('x-onairly-assertion'));
  if (!keyId || !assertion) return fail('bad_request');

  const now = deps.now();
  const check = verifyChallenge(challenge, { key: config.challengeKey, purpose: 'tok', keyId, now });
  const expired = !check.ok && check.reason === 'expired';
  if (!check.ok && !expired) return fail('assertion', check.reason);

  const keyspace = config.keyspace;
  try {
    const rawRecord = await store.getKey(keyRecordKey(keyspace, keyId));
    if (rawRecord === null) return fail('reattest', 'unknown_key');
    const record = parseRecord(rawRecord);
    if (!record) return fail('store');
    if (record.revoked) return fail('reattest', 'revoked');

    const verified = verifyAssertion({ assertion, clientData: tokenClientData(challenge, raw.bytes), publicKeySpki: record.pubKeySpki, appId: config.policy.appId });
    if (!verified.ok) return fail('assertion', verified.reason);
    // TestFlight only (owner decision 2026-11-02; external testers NOT approved, enforced
    // operationally by not inviting them). The tier is set at register from category 2; an
    // assertion that carries a different category (e.g. the App Store build) is refused too.
    if (record.tier !== 'tester') return fail('no_entitlement');
    if (verified.validationCategory !== undefined && verified.validationCategory !== TESTFLIGHT_VALIDATION_CATEGORY) {
      return fail('no_entitlement', 'category');
    }

    const used = attestUsedKey(keyspace, challenge);
    if (expired) return (await store.isUsed(used)) ? fail('assertion', 'reused') : fail('challenge_expired');

    const outcome = await store.mintToken(
      { used, record: keyRecordKey(keyspace, keyId), counter: counterKey(keyspace, keyId), revoked: revokedKey(keyspace, keyId), mint: tokenMintKey(keyspace, keyId, utcDay(now)) },
      verified.counter,
    );
    switch (outcome) {
      case 'minted': {
        const { token } = mintInstallToken({ key: tokenKey, keyId, env: keyspace, now, random: deps.random });
        deps.log({ requestId, status: 200 });
        return json(200, requestId, { token, expiresIn: INSTALL_TOKEN_TTL_SECONDS });
      }
      case 'reused':
        return fail('assertion', 'reused');
      case 'counter':
        return fail('assertion', 'counter');
      case 'unknown':
        return fail('reattest', 'unknown_key');
      case 'revoked':
        return fail('reattest', 'revoked');
      case 'rate':
        return fail('rate', undefined, secondsUntilNextUtcDay(now));
    }
  } catch (error) {
    if (error instanceof AttestStoreError) return fail('store');
    throw error;
  }
}
