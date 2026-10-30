/**
 * Stacked on #256 (Orion and Sentinel, 2026-10-29): keep the network key and add the
 * install ID as a second 3/day cap. A register must pass the network 3/day, the
 * install 3/day and the global 20/day. Contract (Fry): `installId`, register only,
 * lowercase UUID v4.
 */
import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { attestClientDataHash } from '../src/app-attest-verify.js';
import { registerConfig } from '../src/attest-config.js';
import { ENROLL_TTL_SECONDS, enrollDeviceKey, enrollInstallKey, enrollKey, RedisAttestStore, REGISTER_SCRIPT } from '../src/attest-store.js';
import { issueChallenge } from '../src/challenge.js';
import { clientNetwork, deviceBucket } from '../src/enroll-device.js';
import { DEFAULT_ENROLL_INSTALL_DAILY_CAP, installBucket, parseInstallId } from '../src/enroll-install.js';
import { secondsUntilNextUtcDay, type Env } from '../src/handler.js';
import { utcDay } from '../src/limiter.js';
import { handleRegister, type RegisterDeps, type RegisterLogEntry } from '../src/register-handler.js';
import { makeAttestCa, makeAttestation, TEST_APP_ID_PREFIX } from './helpers/fake-appattest.js';
import { FakeRedis, fakeUpstash } from './redis-lua.js';

// Test-only key material, generated here: never an env value, never a real secret.
const KEY = crypto.createHash('sha256').update('aerodj-tts enroll install test key, not a secret').digest();
const NOW = Date.UTC(2026, 9, 29, 12);
const DAY = utcDay(NOW);
const CA = makeAttestCa();
const URL_ = 'https://proxy.invalid/api/attest/register';
const INSTALL = '3f2b8c1e-9d4a-4e6b-a7c2-5b1d0e9f8a63';
const BASE_ENV: Env = Object.freeze({
  AERODJ_TTS_ATTEST_ENABLED: 'true',
  AERODJ_TTS_CHALLENGE_HMAC_KEY: KEY.toString('hex'),
  AERODJ_TTS_APPLE_APP_ID_PREFIX: TEST_APP_ID_PREFIX,
  VERCEL_ENV: 'preview',
});

function harness(opts: { env?: Env; now?: number } = {}) {
  const now = opts.now ?? NOW;
  const redis = new FakeRedis(() => now);
  const up = fakeUpstash({ redis });
  const logs: RegisterLogEntry[] = [];
  const deps: RegisterDeps = {
    env: { ...BASE_ENV, ...(opts.env ?? {}) },
    store: new RedisAttestStore({ url: 'https://upstash.invalid', token: 't' }, up.fetchImpl),
    log: (e) => logs.push(e),
    now: () => now,
    requestId: () => 'req-1',
    roots: [CA.root],
  };
  return { redis, calls: up.calls, logs, deps };
}

/** `installId: undefined` omits the field; any other value is sent as is. */
function request(opts: { ip?: string; installId?: unknown; omit?: boolean; now?: number } = {}) {
  const now = opts.now ?? NOW;
  const challenge = issueChallenge({ key: KEY, purpose: 'attest', keyId: null, now });
  const a = makeAttestation(CA, { clientDataHash: attestClientDataHash(challenge) });
  const fields: Record<string, unknown> = { keyId: a.keyId.toString('base64'), attestationObject: a.attestationObject.toString('base64'), challenge };
  if (!opts.omit) fields.installId = 'installId' in opts ? opts.installId : INSTALL;
  const body = JSON.stringify(fields);
  const mk = (ip = opts.ip ?? '203.0.113.7') =>
    new Request(URL_, { method: 'POST', body, headers: { 'Content-Type': 'application/json', 'x-vercel-forwarded-for': ip } });
  return { req: mk(), mk, challenge, fields };
}
const reasonOf = async (res: Response) => ((await res.json()) as { reason?: string }).reason;
const instKey = (id: string, day = DAY) => enrollInstallKey('nonprod', day, installBucket(KEY, day, id));
const devKey = (ip: string, day = DAY) => enrollDeviceKey('nonprod', day, deviceBucket(KEY, day, clientNetwork(new Headers({ 'x-vercel-forwarded-for': ip }))!));

describe('installId validation (Fry contract: lowercase UUID v4, 36 chars)', () => {
  test('parseInstallId accepts only lowercase v4 with variant 8, 9, a or b', () => {
    assert.equal(parseInstallId(INSTALL), INSTALL);
    for (const v of '89ab') assert.ok(parseInstallId(`3f2b8c1e-9d4a-4e6b-${v}7c2-5b1d0e9f8a63`), v);
    assert.ok(parseInstallId(crypto.randomUUID()));
    const bad: unknown[] = [
      undefined, null, 5, true, {}, [INSTALL], '',
      INSTALL.toUpperCase(),
      '3F2b8c1e-9d4a-4e6b-a7c2-5b1d0e9f8a63', // one uppercase nibble
      '3f2b8c1e-9d4a-1e6b-a7c2-5b1d0e9f8a63', // version 1
      '3f2b8c1e-9d4a-5e6b-a7c2-5b1d0e9f8a63', // version 5
      '3f2b8c1e-9d4a-4e6b-c7c2-5b1d0e9f8a63', // variant c
      '3f2b8c1e-9d4a-4e6b-77c2-5b1d0e9f8a63', // variant 7
      '3f2b8c1e9d4a4e6ba7c25b1d0e9f8a63', // no hyphens
      `{${INSTALL}}`,
      ` ${INSTALL}`,
      `${INSTALL}\n`,
      `${INSTALL}0`,
      INSTALL.slice(1),
      '3f2b8c1e-9d4a-4e6b-a7c2-5b1d0e9f8a6g',
      '00000000-0000-0000-0000-000000000000',
    ];
    for (const v of bad) assert.equal(parseInstallId(v), null, JSON.stringify(v));
  });
  test('missing or invalid installId: 400 install, no Retry-After, no store call, challenge not consumed', async () => {
    const h = harness();
    const cases: { omit?: boolean; installId?: unknown }[] = [{ omit: true }, { installId: null }, { installId: 5 }, { installId: INSTALL.toUpperCase() }, { installId: '3f2b8c1e-9d4a-1e6b-a7c2-5b1d0e9f8a63' }, { installId: '' }];
    for (const [i, c] of cases.entries()) {
      const r = request(c);
      const res = await handleRegister(r.req, h.deps);
      const label = JSON.stringify(c);
      assert.equal(res.status, 400, label);
      assert.deepEqual(await res.json(), { error: 'Bad request', requestId: 'req-1', reason: 'install' }, label);
      assert.equal(res.headers.get('retry-after'), null, label);
      assert.equal(h.calls.length, 0, `${label}: no Upstash command`);
      assert.deepEqual(h.logs.at(-1), { requestId: 'req-1', status: 400, reason: 'install' }, label);
      // Not consumed: the same challenge and attestation enroll once a valid installId is sent.
      const fixed = JSON.stringify({ ...r.fields, installId: crypto.randomUUID() });
      const retryHarness = harness();
      const ok = await handleRegister(new Request(URL_, { method: 'POST', body: fixed, headers: { 'x-vercel-forwarded-for': `198.51.100.${i + 1}` } }), retryHarness.deps);
      assert.equal(ok.status, 204, `${label}: challenge unconsumed`);
    }
  });
  test('an expired challenge with no installId is refused before the used-mark probe', async () => {
    const h = harness();
    const r = request({ omit: true, now: NOW - 121_000 });
    const res = await handleRegister(r.req, h.deps);
    assert.equal(res.status, 400);
    assert.equal(await reasonOf(res), 'install');
    assert.equal(h.calls.length, 0);
  });
  test('the network check comes first: no edge header and no installId is 400 network', async () => {
    const h = harness();
    const r = request({ omit: true });
    const res = await handleRegister(new Request(URL_, { method: 'POST', body: JSON.stringify(r.fields) }), h.deps);
    assert.equal(await reasonOf(res), 'network');
  });
  test('unknown fields beside installId are still 400 bad_request', async () => {
    const h = harness();
    const r = request();
    const res = await handleRegister(new Request(URL_, { method: 'POST', body: JSON.stringify({ ...r.fields, deviceId: 'x' }), headers: { 'x-vercel-forwarded-for': '203.0.113.7' } }), h.deps);
    assert.equal(res.status, 400);
    assert.equal(await reasonOf(res), 'bad_request');
  });
});

describe('per-install cap: 3/day alongside the network 3/day and the global 20/day', () => {
  test('defaults and AERODJ_TTS_ENROLL_INSTALL_DAILY_CAP parsing (same as the device cap)', () => {
    assert.equal(DEFAULT_ENROLL_INSTALL_DAILY_CAP, 3);
    assert.equal(registerConfig(BASE_ENV)!.enrollInstallCap, 3);
    const cap = (v: string | undefined) => registerConfig({ ...BASE_ENV, AERODJ_TTS_ENROLL_INSTALL_DAILY_CAP: v })!.enrollInstallCap;
    for (const v of [undefined, '', '0', '-1', '2.5', '1e2', '0x3', 'abc', '1001', 'Infinity']) assert.equal(cap(v), 3, String(v));
    assert.equal(cap('1'), 1);
    assert.equal(cap('1000'), 1000);
    assert.equal(registerConfig({ ...BASE_ENV, AERODJ_TTS_ENROLL_INSTALL_DAILY_CAP: '7' })!.enrollDeviceCap, 3, 'independent of the device cap');
  });
  test('one install across networks: 3 succeed, the 4th is 429 enroll (install_cap), nothing written', async () => {
    const h = harness();
    for (let i = 1; i <= 3; i++) assert.equal((await handleRegister(request({ ip: `192.0.2.${i}` }).req, h.deps)).status, 204, `#${i}`);
    assert.equal(h.redis.data.get(instKey(INSTALL)), '3');
    const before = new Map(h.redis.data);
    const res = await handleRegister(request({ ip: '192.0.2.4' }).req, h.deps);
    assert.equal(res.status, 429);
    assert.equal(await reasonOf(res), 'enroll');
    assert.equal(res.headers.get('retry-after'), String(secondsUntilNextUtcDay(NOW)));
    assert.deepEqual(h.redis.data, before, 'no record, no counter moves, challenge not consumed');
    assert.equal(h.redis.data.has(devKey('192.0.2.4')), false, 'the fresh network got no counter');
    assert.equal(h.redis.data.get(enrollKey('nonprod', DAY)), '3', 'no global budget spent');
    assert.deepEqual(h.logs.at(-1), { requestId: 'req-1', status: 429, reason: 'enroll', detail: 'install_cap' });
  });
  test('rotating installId on one network still hits the network cap (why both checks)', async () => {
    const h = harness();
    for (let i = 0; i < 3; i++) assert.equal((await handleRegister(request({ installId: crypto.randomUUID() }).req, h.deps)).status, 204);
    const res = await handleRegister(request({ installId: crypto.randomUUID() }).req, h.deps);
    assert.equal(res.status, 429);
    assert.equal(h.logs.at(-1)!.detail, 'device_cap');
  });
  test('all three 429s answer the same body and Retry-After (no oracle)', async () => {
    const bodies: unknown[] = [];
    const retries: (string | null)[] = [];
    const scenarios: [Env, (i: number) => { ip?: string; installId?: unknown }][] = [
      [{ AERODJ_TTS_ENROLL_DEVICE_DAILY_CAP: '1' }, () => ({ installId: crypto.randomUUID() })],
      [{ AERODJ_TTS_ENROLL_INSTALL_DAILY_CAP: '1' }, (i) => ({ ip: `192.0.2.${i + 1}` })],
      [{ AERODJ_TTS_ENROLL_DAILY_CAP: '1' }, (i) => ({ ip: `192.0.2.${i + 1}`, installId: crypto.randomUUID() })],
    ];
    const details: unknown[] = [];
    for (const [env, opt] of scenarios) {
      const h = harness({ env });
      await handleRegister(request(opt(0)).req, h.deps);
      const res = await handleRegister(request(opt(1)).req, h.deps);
      assert.equal(res.status, 429);
      bodies.push(await res.json());
      retries.push(res.headers.get('retry-after'));
      details.push(h.logs.at(-1)!.detail);
    }
    assert.deepEqual(bodies[0], bodies[1]);
    assert.deepEqual(bodies[1], bodies[2]);
    assert.equal(new Set(retries).size, 1);
    assert.deepEqual(details, ['device_cap', 'install_cap', undefined]);
  });
  test('order in the script: network (-4), then install (-5), then global (-3), all before any write', () => {
    const at = (s: string) => REGISTER_SCRIPT.indexOf(s);
    assert.ok(at('return -4') > 0 && at('return -4') < at('return -5') && at('return -5') < at('return -3') && at('return -3') < at("'SET'"));
    assert.match(REGISTER_SCRIPT, /'INCR', KEYS\[5\]/);
    assert.match(REGISTER_SCRIPT, /'EXPIRE', KEYS\[5\], ARGV\[5\]/);
  });
  test('network and install both full: device_cap is reported, nothing written', async () => {
    const h = harness();
    for (let i = 0; i < 3; i++) await handleRegister(request().req, h.deps);
    const before = new Map(h.redis.data);
    await handleRegister(request().req, h.deps);
    assert.equal(h.logs.at(-1)!.detail, 'device_cap');
    assert.deepEqual(h.redis.data, before);
  });
  test('the global 20 still holds across many installs and networks', async () => {
    const h = harness();
    for (let i = 1; i <= 20; i++) assert.equal((await handleRegister(request({ ip: `192.0.2.${i}`, installId: crypto.randomUUID() }).req, h.deps)).status, 204);
    const id = crypto.randomUUID();
    const res = await handleRegister(request({ ip: '192.0.2.21', installId: id }).req, h.deps);
    assert.equal(res.status, 429);
    assert.equal(h.logs.at(-1)!.detail, undefined);
    assert.equal(h.redis.data.has(instKey(id)), false);
  });
  test('a duplicate keyId spends no install budget', async () => {
    const h = harness();
    const credKey = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
    for (let i = 0; i < 2; i++) {
      const challenge = issueChallenge({ key: KEY, purpose: 'attest', keyId: null, now: NOW });
      const a = makeAttestation(CA, { clientDataHash: attestClientDataHash(challenge), credKey });
      const body = JSON.stringify({ keyId: a.keyId.toString('base64'), attestationObject: a.attestationObject.toString('base64'), challenge, installId: INSTALL });
      await handleRegister(new Request(URL_, { method: 'POST', body, headers: { 'x-vercel-forwarded-for': `203.0.113.${i + 1}` } }), h.deps);
    }
    assert.equal(h.logs.at(-1)!.detail, 'duplicate');
    assert.equal(h.redis.data.get(instKey(INSTALL)), '1');
  });
  test('the install counter carries the 2-day TTL; the next UTC day is a fresh, unlinkable bucket', async () => {
    const h = harness();
    await handleRegister(request().req, h.deps);
    assert.equal(h.redis.expiresAt.get(instKey(INSTALL)), NOW + ENROLL_TTL_SECONDS * 1000);
    const tomorrow = utcDay(NOW + 86_400_000);
    assert.notEqual(instKey(INSTALL).split(':').at(-1), instKey(INSTALL, tomorrow).split(':').at(-1));
  });
});

describe('per-install key: privacy and layout', () => {
  test('the raw installId is in no key, value, Upstash command or log line', async () => {
    const h = harness();
    const ids = [INSTALL, crypto.randomUUID(), crypto.randomUUID()];
    for (const [n, id] of ids.entries()) for (let i = 0; i < 4; i++) await handleRegister(request({ ip: `198.51.100.${n * 10 + i}`, installId: id }).req, h.deps);
    // The Upstash EVAL args carry the key names only; the request body is not forwarded.
    const everything = JSON.stringify([...h.redis.data.keys(), ...h.redis.data.values(), h.calls.map((c) => c.command), h.logs]);
    for (const id of ids) {
      assert.equal(everything.includes(id), false, id);
      assert.equal(everything.includes(id.replace(/-/g, '')), false, `${id} without hyphens`);
    }
    for (const k of h.redis.data.keys()) if (k.includes('enrollinst')) assert.match(k, /^nonprod:enrollinst:\{aerodj-tts\}:\d{4}-\d{2}-\d{2}:[0-9a-f]{64}$/);
    for (const e of h.logs) assert.deepEqual(Object.keys(e).filter((k) => !['requestId', 'status', 'reason', 'detail'].includes(k)), []);
  });
  test('layout: production has no prefix; bucket must be hex SHA-256', () => {
    const b = 'b'.repeat(64);
    assert.equal(enrollInstallKey('production', '2026-10-29', b), `enrollinst:{aerodj-tts}:2026-10-29:${b}`);
    assert.equal(enrollInstallKey('nonprod', '2026-10-29', b), `nonprod:enrollinst:{aerodj-tts}:2026-10-29:${b}`);
    for (const bad of [INSTALL, 'B'.repeat(64), 'b'.repeat(63)]) assert.throws(() => enrollInstallKey('nonprod', '2026-10-29', bad), bad);
  });
  test('the bucket is keyed, day-scoped, and in a domain distinct from the network bucket', () => {
    const other = crypto.createHash('sha256').update('other').digest();
    assert.notEqual(installBucket(KEY, DAY, INSTALL), installBucket(other, DAY, INSTALL));
    assert.notEqual(installBucket(KEY, DAY, INSTALL), installBucket(KEY, '2026-10-30', INSTALL));
    assert.notEqual(installBucket(KEY, DAY, INSTALL), deviceBucket(KEY, DAY, INSTALL), 'distinct domain from enroll-device');
    assert.notEqual(installBucket(KEY, DAY, INSTALL), crypto.createHash('sha256').update(INSTALL).digest('hex'));
    assert.equal(
      installBucket(KEY, DAY, INSTALL),
      crypto.createHmac('sha256', KEY).update('onairly-enroll-install-v1\0').update(DAY).update('\0').update(INSTALL).digest('hex'),
    );
  });
});
