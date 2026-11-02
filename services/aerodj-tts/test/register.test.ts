import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { readFileSync } from 'node:fs';
import { attestClientDataHash } from '../src/app-attest-verify.js';
import { DEFAULT_ENROLL_DAILY_CAP, registerConfig } from '../src/attest-config.js';
import {
  attestUsedKey,
  ENROLL_TTL_SECONDS,
  enrollKey,
  KEY_RECORD_TTL_SECONDS,
  keyRecordKey,
  keyspaceFromEnv,
  RedisAttestStore,
  REGISTER_SCRIPT,
  selectAttestStore,
  type AttestStore,
} from '../src/attest-store.js';
import { CHALLENGE_TTL_MS, issueChallenge, usedKey, USED_TTL_SECONDS } from '../src/challenge.js';
import { secondsUntilNextUtcDay, type Env } from '../src/handler.js';
import { utcDay } from '../src/limiter.js';
import { handleRegister, type RegisterDeps, type RegisterLogEntry } from '../src/register-handler.js';
import { UPSTASH_FETCH_TIMEOUT_MS } from '../src/upstash.js';
import registerEndpoint from '../api/attest/register.js';
import { AAGUID_DEV, makeAttestCa, makeAttestation, TEST_APP_ID_PREFIX, type AttestOptions } from './helpers/fake-appattest.js';
import { FakeRedis, fakeUpstash } from './redis-lua.js';

// Test-only key material, generated here: never an env value, never a real secret.
const KEY = crypto.createHash('sha256').update('aerodj-tts register test key, not a secret').digest();
const OTHER_KEY = crypto.createHash('sha256').update('another register test key').digest();
const NOW = Date.UTC(2026, 9, 29, 12);
const CA = makeAttestCa();
const OTHER_CA = makeAttestCa('Other');
const URL_ = 'https://proxy.invalid/api/attest/register';

const BASE_ENV: Env = Object.freeze({
  AERODJ_TTS_ATTEST_ENABLED: 'true',
  AERODJ_TTS_CHALLENGE_HMAC_KEY: KEY.toString('hex'),
  AERODJ_TTS_APPLE_APP_ID_PREFIX: TEST_APP_ID_PREFIX,
  VERCEL_ENV: 'preview',
});

interface Harness {
  redis: FakeRedis;
  calls: unknown[];
  logs: RegisterLogEntry[];
  deps: RegisterDeps;
}
function harness(env: Env = {}, over: Partial<RegisterDeps> = {}, redis = new FakeRedis(() => NOW)): Harness {
  const up = fakeUpstash({ redis });
  const logs: RegisterLogEntry[] = [];
  const mergedEnv = { ...BASE_ENV, ...env };
  for (const [k, v] of Object.entries(env)) if (v === undefined) delete mergedEnv[k];
  return {
    redis,
    calls: up.calls,
    logs,
    deps: {
      env: mergedEnv,
      store: new RedisAttestStore({ url: 'https://upstash.invalid', token: 'test-token' }, up.fetchImpl),
      log: (e) => logs.push(e),
      now: () => NOW,
      requestId: () => 'req-1',
      roots: [CA.root],
      ...over,
    },
  };
}

function challengeFor(opts: { keyId?: Buffer | null; now?: number; purpose?: 'attest' | 'tts' | 'ent'; key?: Buffer } = {}) {
  return issueChallenge({ key: opts.key ?? KEY, purpose: opts.purpose ?? 'attest', keyId: opts.keyId ?? null, now: opts.now ?? NOW });
}
function attest(challenge: string, o: Partial<AttestOptions> = {}) {
  return makeAttestation(CA, { clientDataHash: attestClientDataHash(challenge), ...o });
}
function bodyOf(a: { keyId: Buffer; attestationObject: Buffer }, challenge: string, extra: Record<string, unknown> = {}) {
  // installId: Fry's contract (lowercase UUID v4); a fresh one per body, so the per-install cap never binds here.
  return JSON.stringify({ keyId: a.keyId.toString('base64'), attestationObject: a.attestationObject.toString('base64'), challenge, installId: crypto.randomUUID(), ...extra });
}
// Vercel's edge always sets x-vercel-forwarded-for; register refuses a request without
// it (400 `network`, enroll-caps.test.ts), so every request here carries one.
const post = (body: string, headers: Record<string, string> = {}) =>
  new Request(URL_, { method: 'POST', body, headers: { 'Content-Type': 'application/json', 'x-vercel-forwarded-for': '203.0.113.50', ...headers } });
async function reasonOf(res: Response): Promise<string | undefined> {
  return ((await res.json()) as { reason?: string }).reason;
}
function fresh(o: Partial<AttestOptions> = {}) {
  const challenge = challengeFor();
  const a = attest(challenge, o);
  return { challenge, a, body: bodyOf(a, challenge) };
}

describe('POST /api/attest/register: success (note §4.1.2)', () => {
  test('204; one script writes the key record, the used mark and all three enroll counters', async () => {
    const h = harness();
    const { a, challenge, body } = fresh();
    const res = await handleRegister(post(body), h.deps);
    assert.equal(res.status, 204);
    assert.equal(await res.text(), '');
    assert.equal(res.headers.get('cache-control'), 'no-store');
    assert.equal(h.calls.length, 1, 'exactly one store round trip');
    const record = JSON.parse(h.redis.data.get(keyRecordKey('nonprod', a.keyId))!);
    assert.deepEqual(record, {
      pubKeySpki: (a.credKey.publicKey.export({ format: 'der', type: 'spki' }) as Buffer).toString('base64'),
      counter: 0,
      env: 'production',
      createdDay: utcDay(NOW),
      revoked: false,
    });
    assert.equal(h.redis.expiresAt.get(keyRecordKey('nonprod', a.keyId)), NOW + KEY_RECORD_TTL_SECONDS * 1000);
    assert.equal(h.redis.data.get(enrollKey('nonprod', utcDay(NOW))), '1');
    assert.equal(h.redis.expiresAt.get(enrollKey('nonprod', utcDay(NOW))), NOW + ENROLL_TTL_SECONDS * 1000);
    assert.equal(h.redis.data.get(attestUsedKey('nonprod', challenge)), '1');
    assert.equal(h.redis.expiresAt.get(attestUsedKey('nonprod', challenge)), NOW + USED_TTL_SECONDS * 1000);
    // The per-device enroll counter (#256 owner decision) is the fourth and last key.
    const deviceKeys = [...h.redis.data.keys()].filter((k) => k.startsWith('nonprod:enrolldev:{aerodj-tts}:'));
    assert.equal(deviceKeys.length, 1);
    assert.equal(h.redis.data.get(deviceKeys[0]), '1');
    assert.equal(h.redis.expiresAt.get(deviceKeys[0]), NOW + ENROLL_TTL_SECONDS * 1000);
    // The per-install enroll counter (stacked on #256) is the fifth key.
    const installKeys = [...h.redis.data.keys()].filter((k) => k.startsWith('nonprod:enrollinst:{aerodj-tts}:'));
    assert.equal(installKeys.length, 1);
    assert.equal(h.redis.data.get(installKeys[0]), '1');
    assert.equal(h.redis.expiresAt.get(installKeys[0]), NOW + ENROLL_TTL_SECONDS * 1000);
    // Changed expected value: 4 keys at #256 (used, record, enroll, enrolldev); the install counter makes 5.
    assert.equal(h.redis.data.size, 5);
    assert.deepEqual(h.logs, [{ requestId: 'req-1', status: 204 }]);
  });
  test('a challenge bound to the same keyId is accepted', async () => {
    const h = harness();
    const credKey = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
    const probe = attest('x', { credKey });
    const challenge = challengeFor({ keyId: probe.keyId });
    const a = attest(challenge, { credKey });
    assert.equal((await handleRegister(post(bodyOf(a, challenge)), h.deps)).status, 204);
  });
  test('development aaguid only with AERODJ_TTS_APP_ATTEST_ENV=development on Preview without an ElevenLabs key', async () => {
    const dev = harness({ AERODJ_TTS_APP_ATTEST_ENV: 'development' });
    const d = fresh({ aaguid: AAGUID_DEV });
    assert.equal((await handleRegister(post(d.body), dev.deps)).status, 204);
    assert.equal(JSON.parse(dev.redis.data.get(keyRecordKey('nonprod', d.a.keyId))!).env, 'development');

    const prod = harness();
    const p = fresh({ aaguid: AAGUID_DEV });
    const res = await handleRegister(post(p.body), prod.deps);
    assert.equal(res.status, 401);
    assert.equal(prod.logs[0].detail, 'aaguid');
    assert.equal(prod.calls.length, 0);
  });
});

describe('register: single use, duplicates and the enroll cap', () => {
  test('replaying the same request: 401 assertion (reused), nothing new written', async () => {
    const h = harness();
    const { body } = fresh();
    assert.equal((await handleRegister(post(body), h.deps)).status, 204);
    const before = new Map(h.redis.data);
    const res = await handleRegister(post(body), h.deps);
    assert.equal(res.status, 401);
    assert.equal(await reasonOf(res), 'assertion');
    assert.equal(h.logs[1].detail, 'reused');
    assert.deepEqual(h.redis.data, before);
  });
  test('an already-registered keyId: 401 (duplicate), record and counter untouched, challenge consumed', async () => {
    const h = harness();
    const credKey = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
    const first = fresh({ credKey });
    assert.equal((await handleRegister(post(first.body), h.deps)).status, 204);
    const record = h.redis.data.get(keyRecordKey('nonprod', first.a.keyId));
    const second = fresh({ credKey });
    const res = await handleRegister(post(second.body), h.deps);
    assert.equal(res.status, 401);
    assert.equal(h.logs[1].detail, 'duplicate');
    assert.equal(h.redis.data.get(keyRecordKey('nonprod', first.a.keyId)), record);
    assert.equal(h.redis.data.get(enrollKey('nonprod', utcDay(NOW))), '1');
    assert.equal(h.redis.data.get(attestUsedKey('nonprod', second.challenge)), '1');
  });
  test('enroll cap reached: 429 enroll, Retry-After to UTC midnight, nothing written (cap checked before INCR)', async () => {
    const h = harness({ AERODJ_TTS_ENROLL_DAILY_CAP: '1' });
    assert.equal((await handleRegister(post(fresh().body), h.deps)).status, 204);
    const before = new Map(h.redis.data);
    const second = fresh();
    const res = await handleRegister(post(second.body), h.deps);
    assert.equal(res.status, 429);
    assert.equal(await reasonOf(res), 'enroll');
    assert.equal(res.headers.get('retry-after'), String(secondsUntilNextUtcDay(NOW)));
    assert.deepEqual(h.redis.data, before, 'no record, no counter increment, challenge not consumed');
    assert.equal(h.redis.data.has(keyRecordKey('nonprod', second.a.keyId)), false);
    // A new UTC day has a fresh budget.
    const tomorrow = NOW + 86_400_000;
    const t = harness({ AERODJ_TTS_ENROLL_DAILY_CAP: '1' }, { now: () => tomorrow }, h.redis);
    const c = challengeFor({ now: tomorrow });
    assert.equal((await handleRegister(post(bodyOf(attest(c), c)), t.deps)).status, 204);
  });
  test('the enroll cap default and bounds', () => {
    const cap = (v: string | undefined) => registerConfig({ ...BASE_ENV, AERODJ_TTS_ENROLL_DAILY_CAP: v })!.enrollCap;
    assert.equal(cap(undefined), DEFAULT_ENROLL_DAILY_CAP);
    for (const v of ['', '0', '-1', '1.5', '1e3', '0x10', 'abc', '100001', 'Infinity']) assert.equal(cap(v), DEFAULT_ENROLL_DAILY_CAP, v);
    assert.equal(cap('7'), 7);
    assert.equal(cap('100000'), 100_000);
  });
  test('the script is the only writer and runs as one EVAL', () => {
    assert.match(REGISTER_SCRIPT, /SET', KEYS\[2\], ARGV\[2\], 'NX'/);
    assert.ok(REGISTER_SCRIPT.indexOf('return -3') < REGISTER_SCRIPT.indexOf("'SET'"), 'cap check before any write');
  });
});

describe('register: challenge binding (#246, #250 semantics)', () => {
  test('wrong purpose, forged MAC, other key binding, malformed: 401 assertion, zero store calls', async () => {
    const credKey = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
    const probe = attest('x', { credKey });
    const otherId = crypto.createHash('sha256').update('other install').digest();
    const cases: [string, string][] = [
      [challengeFor({ purpose: 'tts', keyId: probe.keyId }), 'purpose'],
      [challengeFor({ key: OTHER_KEY }), 'mac'],
      [challengeFor({ keyId: otherId }), 'mac'],
      [challengeFor({ now: NOW + 60_000 }), 'future'],
      ['not-a-challenge', 'malformed'],
    ];
    for (const [challenge, detail] of cases) {
      const h = harness();
      const a = attest(challenge, { credKey });
      const res = await handleRegister(post(bodyOf(a, challenge)), h.deps);
      assert.equal(res.status, 401, detail);
      assert.equal(await reasonOf(res), 'assertion');
      assert.equal(h.logs[0].detail, detail);
      assert.equal(h.calls.length, 0, detail);
    }
  });
  test('the attestation must be over THIS challenge (nonce binds it)', async () => {
    const h = harness();
    const c1 = challengeFor();
    const c2 = challengeFor({ now: NOW - 1000 });
    const a = attest(c1);
    const res = await handleRegister(post(bodyOf(a, c2)), h.deps);
    assert.equal(res.status, 401);
    assert.equal(h.logs[0].detail, 'nonce');
    assert.equal(h.calls.length, 0);
  });
  test('expired but otherwise valid: 400 challenge_expired after verification, read-only probe, nothing written', async () => {
    const h = harness();
    const old = challengeFor({ now: NOW - CHALLENGE_TTL_MS - 1 });
    const a = attest(old);
    const res = await handleRegister(post(bodyOf(a, old)), h.deps);
    assert.equal(res.status, 400);
    assert.equal(await reasonOf(res), 'challenge_expired');
    assert.equal(h.redis.data.size, 0);
    assert.deepEqual(h.redis.commands.map((c) => c[0]), ['GET']);
  });
  test('expired and already used: 401 (reused)', async () => {
    const h = harness();
    const old = challengeFor({ now: NOW - CHALLENGE_TTL_MS - 1 });
    h.redis.data.set(attestUsedKey('nonprod', old), '1');
    const res = await handleRegister(post(bodyOf(attest(old), old)), h.deps);
    assert.equal(res.status, 401);
    assert.equal(h.logs[0].detail, 'reused');
  });
  test('expired with a bad attestation: 401, no store call', async () => {
    const h = harness();
    const old = challengeFor({ now: NOW - CHALLENGE_TTL_MS - 1 });
    const res = await handleRegister(post(bodyOf(attest(old, { counter: 1 }), old)), h.deps);
    assert.equal(res.status, 401);
    assert.equal(h.logs[0].detail, 'counter');
    assert.equal(h.calls.length, 0);
  });
});

describe('register: attestation failures write nothing', () => {
  const cases: [string, Partial<AttestOptions>][] = [
    ['rp_id', { appId: 'ZZZZZ12345.com.aerodj.app' }],
    ['rp_id', { appId: `${TEST_APP_ID_PREFIX}.com.example.other` }],
    ['counter', { counter: 1 }],
    ['flags', { flags: 0 }],
    ['nonce', { nonce: Buffer.alloc(32) }],
    ['format', { fmt: 'packed' }],
    ['chain', { credIssuerKey: OTHER_CA.intermediateKey }],
  ];
  for (const [detail, o] of cases) {
    test(`${detail}: 401 assertion, zero store calls`, async () => {
      const h = harness();
      const res = await handleRegister(post(fresh(o).body), h.deps);
      assert.equal(res.status, 401);
      assert.equal(await reasonOf(res), 'assertion');
      assert.equal(h.logs[0].detail, detail);
      assert.equal(h.calls.length, 0);
    });
  }
  test('fake roots are not trusted without injection: pinned Apple root applies', async () => {
    const h = harness({}, { roots: undefined });
    const res = await handleRegister(post(fresh().body), h.deps);
    assert.equal(res.status, 401);
    assert.equal(h.logs[0].detail, 'chain');
  });
  test('the 401 body names no check (no oracle)', async () => {
    const h = harness();
    const res = await handleRegister(post(fresh({ counter: 1 }).body), h.deps);
    const body = (await res.json()) as Record<string, unknown>;
    assert.deepEqual(Object.keys(body).sort(), ['error', 'reason', 'requestId']);
  });
});

describe('register: gates, config and store (note §4.4, §4.7, §12)', () => {
  test('PAID_STOP wins over the method, the flag, config and store', async () => {
    for (const method of ['POST', 'GET']) {
      const h = harness({ AERODJ_TTS_PAID_STOP: 'true', AERODJ_TTS_APPLE_APP_ID_PREFIX: undefined }, { store: null });
      const res = await handleRegister(new Request(URL_, method === 'POST' ? { method, body: fresh().body } : { method }), h.deps);
      assert.equal(res.status, 503);
      assert.equal(await reasonOf(res), 'disabled');
      assert.equal(res.headers.get('retry-after'), '3600');
    }
  });
  test('405 for non-POST', async () => {
    const h = harness();
    const res = await handleRegister(new Request(URL_, { method: 'GET' }), h.deps);
    assert.equal(res.status, 405);
    assert.equal(res.headers.get('allow'), 'POST');
  });
  test('off unless AERODJ_TTS_ATTEST_ENABLED is exactly "true"', async () => {
    for (const v of [undefined, '', 'TRUE', 'True', '1', 'yes', ' true', 'true ']) {
      const h = harness({ AERODJ_TTS_ATTEST_ENABLED: v });
      const res = await handleRegister(post(fresh().body), h.deps);
      assert.equal(res.status, 503, String(v));
      assert.equal(await reasonOf(res), 'disabled');
      assert.equal(h.calls.length, 0);
    }
  });
  test('500 misconfig (Retry-After 3600) for each invalid setting, before the store check', async () => {
    const bad: Env[] = [
      { AERODJ_TTS_CHALLENGE_HMAC_KEY: undefined },
      { AERODJ_TTS_APPLE_APP_ID_PREFIX: undefined },
      { AERODJ_TTS_APPLE_APP_ID_PREFIX: '' },
      { AERODJ_TTS_APPLE_APP_ID_PREFIX: 'abcde12345' },
      { AERODJ_TTS_APPLE_APP_ID_PREFIX: 'ABCDE1234' },
      { AERODJ_TTS_APPLE_APP_ID_PREFIX: 'ABCDE12345.com.aerodj.app' },
      { AERODJ_TTS_BUNDLE_ID: 'com.example.myapp' },
      { AERODJ_TTS_BUNDLE_ID: '' },
      { AERODJ_TTS_APP_ATTEST_ENV: 'sandbox' },
      { AERODJ_TTS_APP_ATTEST_ENV: '' },
      { AERODJ_TTS_APP_ATTEST_ENV: 'Development' },
      { AERODJ_TTS_APP_ATTEST_ENV: 'development', ELEVENLABS_API_KEY: 'sk-test-not-real' },
      { AERODJ_TTS_APP_ATTEST_ENV: 'development', VERCEL_ENV: 'production' },
      { AERODJ_TTS_APP_ATTEST_ENV: 'development', VERCEL_ENV: undefined },
      // Injected test roots outside Preview/Development fail closed.
      { VERCEL_ENV: 'production' },
      { VERCEL_ENV: undefined },
      { VERCEL_ENV: 'staging' },
    ];
    for (const env of bad) {
      const h = harness(env, { store: null });
      const res = await handleRegister(post(fresh().body), h.deps);
      assert.equal(res.status, 500, JSON.stringify(env));
      assert.equal(await reasonOf(res), 'misconfig');
      assert.equal(res.headers.get('retry-after'), '3600');
    }
    // Development aaguid is never allowed on Production, even with no ElevenLabs key and no test roots.
    for (const VERCEL_ENV of ['production', undefined, 'staging']) {
      assert.equal(registerConfig({ ...BASE_ENV, AERODJ_TTS_APP_ATTEST_ENV: 'development', VERCEL_ENV }), null, String(VERCEL_ENV));
    }
    assert.equal(registerConfig({ ...BASE_ENV, AERODJ_TTS_APP_ATTEST_ENV: 'development' })!.policy.allowDevelopment, true);
    // The configured bundle is accepted.
    assert.ok(registerConfig({ ...BASE_ENV, AERODJ_TTS_BUNDLE_ID: 'com.aerodj.app' }));
    assert.ok(registerConfig({ ...BASE_ENV, AERODJ_TTS_APP_ATTEST_ENV: 'production' }));
    assert.equal(registerConfig({ ...BASE_ENV, VERCEL_ENV: 'production' })!.policy.deployment, 'production');
    assert.equal(registerConfig({ ...BASE_ENV, VERCEL_ENV: 'production' })!.policy.allowDevelopment, false);
    assert.equal(registerConfig({ ...BASE_ENV, VERCEL_ENV: 'development' }, [CA.root])!.policy.roots?.length, 1);
  });
  test('503 store (Retry-After 30) without a durable store; nothing else runs', async () => {
    const nonDurable: AttestStore = { durable: false, isUsed: async () => false, touchKey: async () => 'refreshed', register: async () => 'registered' };
    for (const store of [null, nonDurable]) {
      const h = harness({}, { store });
      const res = await handleRegister(post(fresh().body), h.deps);
      assert.equal(res.status, 503);
      assert.equal(await reasonOf(res), 'store');
      assert.equal(res.headers.get('retry-after'), '30');
    }
    assert.equal(selectAttestStore({}), null);
    assert.equal(selectAttestStore({ KV_REST_API_URL: 'http://plain.invalid', KV_REST_API_TOKEN: 't' }), null);
    assert.ok(selectAttestStore({ KV_REST_API_URL: 'https://x.invalid', KV_REST_API_TOKEN: 't' })?.durable);
  });
  test('store failures during the script or the expired probe: 503 store', async () => {
    for (const status of [500, 401]) {
      const up = fakeUpstash({ status });
      const h = harness({}, { store: new RedisAttestStore({ url: 'https://u.invalid', token: 't' }, up.fetchImpl) });
      const res = await handleRegister(post(fresh().body), h.deps);
      assert.equal(res.status, 503);
      assert.equal(await reasonOf(res), 'store');
      const old = challengeFor({ now: NOW - CHALLENGE_TTL_MS - 1 });
      const r2 = await handleRegister(post(bodyOf(attest(old), old)), h.deps);
      assert.equal(r2.status, 503);
    }
    const throwing = (async () => {
      throw new TypeError('network');
    }) as unknown as typeof fetch;
    const h = harness({}, { store: new RedisAttestStore({ url: 'https://u.invalid', token: 't' }, throwing) });
    assert.equal((await handleRegister(post(fresh().body), h.deps)).status, 503);
    const odd = (async () => new Response(JSON.stringify({ result: 7 }))) as unknown as typeof fetch;
    const h2 = harness({}, { store: new RedisAttestStore({ url: 'https://u.invalid', token: 't' }, odd) });
    assert.equal((await handleRegister(post(fresh().body), h2.deps)).status, 503);
  });
  test('an Upstash call that never finishes times out: 503 store (Retry-After 30)', { timeout: 5_000 }, async () => {
    // AbortSignal.timeout's timer does not hold the event loop open; this does, for the test only.
    const keepAlive = setTimeout(() => {}, 10_000);
    try {
      const TIMEOUT_MS = 20;
      const signals: (AbortSignal | null | undefined)[] = [];
      // Like real fetch: never answers, rejects when its signal aborts.
      const honoring = ((_url: string, init: RequestInit) => {
        signals.push(init.signal);
        return new Promise<Response>((_resolve, reject) => {
          init.signal?.addEventListener('abort', () => reject(init.signal!.reason), { once: true });
        });
      }) as unknown as typeof fetch;
      // Never answers and ignores the signal.
      const ignoring = (() => new Promise<Response>(() => {})) as unknown as typeof fetch;
      // Headers arrive, the body never does.
      const stalledBody = (async () =>
        new Response(new ReadableStream({ start() {} }), { status: 200 })) as unknown as typeof fetch;
      for (const [name, fetchImpl] of [['honoring', honoring], ['ignoring', ignoring], ['stalledBody', stalledBody]] as const) {
        const h = harness({}, { store: new RedisAttestStore({ url: 'https://u.invalid', token: 't' }, fetchImpl, TIMEOUT_MS) });
        const started = Date.now();
        const res = await handleRegister(post(fresh().body), h.deps);
        assert.equal(res.status, 503, name);
        assert.equal(await reasonOf(res), 'store', name);
        assert.equal(res.headers.get('retry-after'), '30', name);
        assert.ok(Date.now() - started < 1_000, name);
      }
      assert.equal(signals.length, 1);
      assert.ok(signals[0] instanceof AbortSignal);
      assert.equal(signals[0]!.aborted, true);
    } finally {
      clearTimeout(keepAlive);
    }
  });
  test('the default Upstash timeout is UPSTASH_FETCH_TIMEOUT_MS (2 s)', () => {
    assert.equal(UPSTASH_FETCH_TIMEOUT_MS, 2_000);
  });
});

describe('register: raw body and fields (note §4.1.4)', () => {
  test('16 KiB cap on raw bytes: 413 too_large by Content-Length and by stream', async () => {
    const h = harness();
    const big = 'x'.repeat(16 * 1024 + 1);
    const r1 = await handleRegister(post(big), h.deps);
    assert.equal(r1.status, 413);
    const stream = new ReadableStream({
      start(c) {
        c.enqueue(new TextEncoder().encode(big));
        c.close();
      },
    });
    const r2 = await handleRegister(new Request(URL_, { method: 'POST', body: stream, duplex: 'half' } as RequestInit), h.deps);
    assert.equal(r2.status, 413);
    assert.equal(h.calls.length, 0);
  });
  test('400 bad_request for anything but { keyId, attestationObject, challenge } (+ installId) with strict encodings', async () => {
    const { a, challenge } = fresh();
    const good = JSON.parse(bodyOf(a, challenge)) as Record<string, unknown>;
    const b64 = good.attestationObject as string;
    const bodies: string[] = [
      '',
      'not json',
      '[]',
      JSON.stringify({ ...good, extra: 1 }),
      JSON.stringify({ keyId: good.keyId, challenge }),
      JSON.stringify({ ...good, keyId: a.keyId.toString('base64url') }),
      JSON.stringify({ ...good, keyId: a.keyId.subarray(1).toString('base64') }),
      JSON.stringify({ ...good, attestationObject: b64.replace(/=+$/, '') + (b64.endsWith('=') ? '' : 'A') }),
      JSON.stringify({ ...good, attestationObject: a.attestationObject.toString('base64url') }),
      JSON.stringify({ ...good, attestationObject: ' ' + b64 }),
      JSON.stringify({ ...good, attestationObject: '' }),
      // Non-canonical: the unused low bits of the last character are set ('AA==' is canonical).
      JSON.stringify({ ...good, attestationObject: 'AB==' }),
      JSON.stringify({ ...good, attestationObject: 5 }),
      JSON.stringify({ ...good, challenge: 5 }),
    ];
    for (const body of bodies) {
      const h = harness();
      const res = await handleRegister(post(body), h.deps);
      assert.equal(res.status, 400, body.slice(0, 60));
      assert.equal(await reasonOf(res), 'bad_request');
      assert.equal(h.calls.length, 0);
    }
  });
  test('handler source never uses req.body or for-await', () => {
    for (const file of ['../src/register-handler.ts', '../api/attest/register.ts', '../src/app-attest-verify.ts', '../src/cbor.ts']) {
      // Code only: comments may name the helper they avoid.
      const code = readFileSync(new URL(file, import.meta.url), 'utf8').replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/.*$/gm, '');
      assert.doesNotMatch(code, /\.body\b(?!\?\.cancel)|for\s+await|getReader/, file);
    }
  });
});

describe('register: Preview never writes records Production trusts', () => {
  test('keyspace: only VERCEL_ENV=production exactly uses production names', () => {
    assert.equal(keyspaceFromEnv({ VERCEL_ENV: 'production' }), 'production');
    for (const v of [undefined, '', 'preview', 'development', 'Production', 'production ']) {
      assert.equal(keyspaceFromEnv({ VERCEL_ENV: v }), 'nonprod', String(v));
    }
    const id = Buffer.alloc(32, 1);
    assert.equal(keyRecordKey('production', id), `key:{aerodj-tts}:${id.toString('base64url')}`);
    assert.equal(keyRecordKey('nonprod', id), `nonprod:key:{aerodj-tts}:${id.toString('base64url')}`);
    assert.equal(enrollKey('production', '2026-10-29'), 'enroll:{aerodj-tts}:2026-10-29');
    assert.equal(enrollKey('nonprod', '2026-10-29'), 'nonprod:enroll:{aerodj-tts}:2026-10-29');
    assert.equal(attestUsedKey('production', 'c'), usedKey('c'));
    assert.equal(attestUsedKey('nonprod', 'c'), `nonprod:${usedKey('c')}`);
  });
  for (const vercelEnv of ['preview', 'development']) {
    test(`a ${vercelEnv} registration on a shared Upstash leaves every production key untouched`, async () => {
      const shared = new FakeRedis(() => NOW);
      const h = harness({ VERCEL_ENV: vercelEnv }, {}, shared);
      const { a, challenge, body } = fresh();
      assert.equal((await handleRegister(post(body), h.deps)).status, 204);
      const prodKeys = [keyRecordKey('production', a.keyId), enrollKey('production', utcDay(NOW)), attestUsedKey('production', challenge)];
      for (const k of prodKeys) assert.equal(shared.data.has(k), false, k);
      for (const k of shared.data.keys()) assert.ok(k.startsWith('nonprod:'), k);
      // And Production's own register path reads the production names: the preview
      // used mark does not make a production replay look "used" or vice versa.
      const prodCfg = registerConfig({ ...BASE_ENV, VERCEL_ENV: 'production' })!;
      assert.equal(prodCfg.keyspace, 'production');
      const prodStore = new RedisAttestStore({ url: 'https://u.invalid', token: 't' }, fakeUpstash({ redis: shared }).fetchImpl);
      assert.equal(await prodStore.isUsed(attestUsedKey(prodCfg.keyspace, challenge)), false);
    });
  }
});

describe('register: logs carry enums only', () => {
  test('no keyId, challenge, attestation or header value appears in any log line', async () => {
    const h = harness({ AERODJ_TTS_ENROLL_DAILY_CAP: '1' });
    const secrets: string[] = [];
    const record = (a: { keyId: Buffer; attestationObject: Buffer }, c: string) =>
      secrets.push(a.keyId.toString('base64'), a.keyId.toString('base64url'), a.keyId.toString('hex'), c, a.attestationObject.toString('base64').slice(0, 40));
    const ok = fresh();
    record(ok.a, ok.challenge);
    await handleRegister(post(ok.body, { 'X-OnAirly-Key': ok.a.keyId.toString('base64') }), h.deps);
    await handleRegister(post(ok.body), h.deps); // reused
    const capped = fresh();
    record(capped.a, capped.challenge);
    await handleRegister(post(capped.body), h.deps); // enroll
    const bad = fresh({ counter: 1 });
    record(bad.a, bad.challenge);
    await handleRegister(post(bad.body), h.deps);
    const old = challengeFor({ now: NOW - CHALLENGE_TTL_MS - 1 });
    const oa = attest(old);
    record(oa, old);
    await handleRegister(post(bodyOf(oa, old)), h.deps);
    const text = JSON.stringify(h.logs);
    for (const s of secrets) assert.equal(text.includes(s), false);
    for (const e of h.logs) {
      assert.deepEqual(Object.keys(e).filter((k) => !['requestId', 'status', 'reason', 'detail'].includes(k)), []);
      if (e.detail) assert.match(e.detail, /^[a-z_]+$/);
    }
    assert.deepEqual(h.logs.map((e) => e.status), [204, 401, 429, 401, 400]);
  });
});

describe('api/attest/register.ts', () => {
  test('exports a Web fetch handler that is off by default', async () => {
    assert.equal(typeof registerEndpoint.fetch, 'function');
    const saved = process.env.AERODJ_TTS_ATTEST_ENABLED;
    delete process.env.AERODJ_TTS_ATTEST_ENABLED;
    try {
      const res = await registerEndpoint.fetch(post(fresh().body));
      assert.equal(res.status, 503);
      assert.equal(await reasonOf(res), 'disabled');
    } finally {
      if (saved !== undefined) process.env.AERODJ_TTS_ATTEST_ENABLED = saved;
    }
  });
});
