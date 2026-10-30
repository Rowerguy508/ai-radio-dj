import crypto, { type X509Certificate } from 'node:crypto';
import { attestClientDataHash, MAX_ATTESTATION_BYTES, verifyAttestation, type AttestationFailure } from './app-attest-verify.js';
import { registerConfig } from './attest-config.js';
import {
  attestEnabled,
  DISABLED_RETRY_AFTER_SECONDS,
  MISCONFIG_RETRY_AFTER_SECONDS,
  paidStopped,
  STORE_RETRY_AFTER_SECONDS,
} from './attest-flags.js';
import {
  attestUsedKey,
  AttestStoreError,
  enrollDeviceKey,
  enrollKey,
  keyRecordKey,
  selectAttestStore,
  type AttestStore,
} from './attest-store.js';
import { parseKeyId, USED_TTL_SECONDS, verifyChallenge, type ChallengeFailure } from './challenge.js';
import { clientNetwork, deviceBucket } from './enroll-device.js';
import { secondsUntilNextUtcDay, type Env } from './handler.js';
import { isDurable } from './install-quota.js';
import { utcDay } from './limiter.js';
import { BODY_CAPS, parseJsonObject, readRawBody } from './raw-body.js';

export type RegisterReason =
  | 'bad_request'
  | 'too_large'
  | 'misconfig'
  | 'store'
  | 'disabled'
  | 'assertion'
  | 'challenge_expired'
  | 'enroll';

/**
 * Why a 401 happened, or `device_cap` for a 429 refused by the per-device sub-cap
 * (a global-cap 429 carries no detail). For logs only (an enum; never sent to the
 * client: both 429s answer the same `enroll` body).
 */
export type RegisterDetail = ChallengeFailure | AttestationFailure | 'reused' | 'duplicate' | 'device_cap';

export interface RegisterLogEntry {
  requestId: string;
  status: number;
  reason?: RegisterReason;
  detail?: RegisterDetail;
}

export interface RegisterDeps {
  env: Env;
  /** Durable key store; null or non-durable → 503 `store`. */
  store: AttestStore | null;
  log: (entry: RegisterLogEntry) => void;
  now: () => number;
  requestId: () => string;
  /**
   * Test roots instead of the pinned Apple App Attestation Root CA. Refused
   * (500 `misconfig`) unless VERCEL_ENV is `preview` or `development`.
   */
  roots?: readonly X509Certificate[];
}

const STATUS: Record<RegisterReason, number> = {
  bad_request: 400,
  challenge_expired: 400,
  assertion: 401,
  too_large: 413,
  enroll: 429,
  misconfig: 500,
  store: 503,
  disabled: 503,
};
const FIXED_RETRY_AFTER: Partial<Record<RegisterReason, number>> = {
  misconfig: MISCONFIG_RETRY_AFTER_SECONDS,
  store: STORE_RETRY_AFTER_SECONDS,
  disabled: DISABLED_RETRY_AFTER_SECONDS,
};
const MESSAGES: Record<number, string> = {
  400: 'Bad request',
  401: 'Unauthorized',
  405: 'Method not allowed',
  413: 'Payload too large',
  429: 'Too many requests',
  500: 'Server misconfigured',
  503: 'Service unavailable',
};
const FIELDS = ['keyId', 'attestationObject', 'challenge'] as const;
const B64 = /^[A-Za-z0-9+/]+={0,2}$/;
const MAX_ATTESTATION_B64 = Math.ceil(MAX_ATTESTATION_BYTES / 3) * 4;

export function registerDeps(env: Env = process.env): RegisterDeps {
  return {
    env,
    store: selectAttestStore(env),
    log: (e) =>
      console.log(
        JSON.stringify({
          requestId: e.requestId,
          status: e.status,
          ...(e.reason ? { reason: e.reason } : {}),
          ...(e.detail ? { detail: e.detail } : {}),
        }),
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

/** Strict standard base64 (padded, canonical), at most MAX_ATTESTATION_BYTES decoded. */
function parseAttestationObject(value: unknown): Buffer | null {
  if (typeof value !== 'string' || value.length === 0 || value.length > MAX_ATTESTATION_B64) return null;
  if (value.length % 4 !== 0 || !B64.test(value)) return null;
  const bytes = Buffer.from(value, 'base64');
  return bytes.toString('base64') === value ? bytes : null;
}

/**
 * POST /api/attest/register (note §4.1.2). Body `{ keyId, attestationObject, challenge }`,
 * `keyId` standard base64 (44 chars), `attestationObject` standard base64 CBOR.
 *
 * Order: PAID_STOP → 405 → attest flag → config (500 `misconfig`) → durable
 * store (503 `store`) → raw body ≤ 16 KiB (413) → exact fields (400) →
 * stateless challenge, purpose `attest` (401; an otherwise-valid expired one
 * continues) → full attestation verification (401) → expired: read-only
 * used-mark probe (401 reused, else 400 `challenge_expired`, nothing written)
 * → one script: used mark + key `SET NX` + global and per-device enroll
 * counters, both caps checked before any write, the per-device cap first
 * (either 429 `enroll` writes nothing, so a device-capped request spends no
 * global budget) → 204.
 *
 * Caps (owner, 2026-10-29): 20 verified enrollments a day overall, 3 a day per
 * device bucket. The bucket is a keyed hash of the client network (see
 * enroll-device.ts for why, and its limits); the address is never stored or logged.
 *
 * A failed check writes nothing. Logs carry enums only: never the keyId,
 * challenge, attestation, header values, client address or body.
 */
export async function handleRegister(request: Request, deps: RegisterDeps): Promise<Response> {
  const requestId = deps.requestId();
  const fail = (reason: RegisterReason, detail?: RegisterDetail, retryAfter?: number): Response => {
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
  if (!attestEnabled(deps.env)) {
    await discard();
    return fail('disabled');
  }
  const config = registerConfig(deps.env, deps.roots);
  if (!config) {
    await discard();
    return fail('misconfig');
  }
  const store = deps.store;
  if (!store || !isDurable(store)) {
    await discard();
    return fail('store');
  }

  const raw = await readRawBody(request, BODY_CAPS.register);
  if (!raw.ok) return fail(raw.reason);
  const body = parseJsonObject(raw.bytes);
  if (!body) return fail('bad_request');
  const keys = Object.keys(body);
  if (keys.length !== FIELDS.length || !FIELDS.every((f) => keys.includes(f))) return fail('bad_request');
  const keyId = parseKeyId(body.keyId);
  const attestationObject = parseAttestationObject(body.attestationObject);
  const challenge = body.challenge;
  if (!keyId || !attestationObject || typeof challenge !== 'string') return fail('bad_request');

  const now = deps.now();
  const check = verifyChallenge(challenge, { key: config.challengeKey, purpose: 'attest', keyId, now });
  const expired = !check.ok && check.reason === 'expired';
  if (!check.ok && !expired) return fail('assertion', check.reason);

  const verified = verifyAttestation(
    { keyId, attestationObject, clientDataHash: attestClientDataHash(challenge) },
    { ...config.policy, now },
  );
  if (!verified.ok) return fail(verified.reason === 'config' ? 'misconfig' : 'assertion', verified.reason === 'config' ? undefined : verified.reason);

  const used = attestUsedKey(config.keyspace, challenge);
  try {
    if (expired) {
      return (await store.isUsed(used)) ? fail('assertion', 'reused') : fail('challenge_expired');
    }
    const day = utcDay(now);
    const enrollDevice = enrollDeviceKey(config.keyspace, day, deviceBucket(config.challengeKey, day, clientNetwork(request.headers)));
    const outcome = await store.register(
      { used, record: keyRecordKey(config.keyspace, keyId), enroll: enrollKey(config.keyspace, day), enrollDevice },
      {
        pubKeySpki: verified.attestation.publicKeySpki.toString('base64'),
        counter: 0,
        env: verified.attestation.environment,
        createdDay: day,
        revoked: false,
      },
      { usedTtlSeconds: USED_TTL_SECONDS, enrollCap: config.enrollCap, enrollDeviceCap: config.enrollDeviceCap },
    );
    switch (outcome) {
      case 'registered':
        deps.log({ requestId, status: 204 });
        return new Response(null, { status: 204, headers: { 'Cache-Control': 'no-store', 'X-Request-Id': requestId } });
      case 'reused':
        return fail('assertion', 'reused');
      case 'duplicate':
        return fail('assertion', 'duplicate');
      case 'enroll_cap':
        return fail('enroll', undefined, secondsUntilNextUtcDay(now));
      case 'enroll_device_cap':
        // Same status, reason and Retry-After as the global cap: no oracle for which one.
        return fail('enroll', 'device_cap', secondsUntilNextUtcDay(now));
    }
  } catch (error) {
    if (error instanceof AttestStoreError) return fail('store');
    throw error;
  }
}
