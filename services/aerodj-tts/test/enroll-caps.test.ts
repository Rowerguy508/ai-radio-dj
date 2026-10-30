/**
 * #256 owner decision (2026-10-29): "Keep 20 a day overall and 3 per device for now."
 * Global cap 20/day (final) plus a per-device sub-cap of 3/day keyed on a keyed hash
 * of the client network (src/enroll-device.ts explains why and its limits).
 */
import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { attestClientDataHash } from '../src/app-attest-verify.js';
import { DEFAULT_ENROLL_DAILY_CAP, registerConfig } from '../src/attest-config.js';
import { STORE_RETRY_AFTER_SECONDS } from '../src/attest-flags.js';
import { ENROLL_TTL_SECONDS, enrollDeviceKey, enrollKey, RedisAttestStore, REGISTER_SCRIPT } from '../src/attest-store.js';
import { issueChallenge } from '../src/challenge.js';
import { clientNetwork, DEFAULT_ENROLL_DEVICE_DAILY_CAP, deviceBucket } from '../src/enroll-device.js';
import { secondsUntilNextUtcDay, type Env } from '../src/handler.js';
import { utcDay } from '../src/limiter.js';
import { handleRegister, type RegisterDeps, type RegisterLogEntry } from '../src/register-handler.js';
import { makeAttestCa, makeAttestation, TEST_APP_ID_PREFIX } from './helpers/fake-appattest.js';
import { FakeRedis, fakeUpstash } from './redis-lua.js';

// Test-only key material, generated here: never an env value, never a real secret.
const KEY = crypto.createHash('sha256').update('aerodj-tts enroll caps test key, not a secret').digest();
const NOW = Date.UTC(2026, 9, 29, 12);
const DAY = utcDay(NOW);
const CA = makeAttestCa();
const URL_ = 'https://proxy.invalid/api/attest/register';
const BASE_ENV: Env = Object.freeze({
  AERODJ_TTS_ATTEST_ENABLED: 'true',
  AERODJ_TTS_CHALLENGE_HMAC_KEY: KEY.toString('hex'),
  AERODJ_TTS_APPLE_APP_ID_PREFIX: TEST_APP_ID_PREFIX,
  VERCEL_ENV: 'preview',
});

function harness(opts: { env?: Env; now?: number; redis?: FakeRedis; fetchImpl?: typeof fetch; timeoutMs?: number } = {}) {
  const redis = opts.redis ?? new FakeRedis(() => opts.now ?? NOW);
  const up = fakeUpstash({ redis });
  const logs: RegisterLogEntry[] = [];
  const now = opts.now ?? NOW;
  const deps: RegisterDeps = {
    env: { ...BASE_ENV, ...(opts.env ?? {}) },
    store: new RedisAttestStore({ url: 'https://upstash.invalid', token: 't' }, opts.fetchImpl ?? up.fetchImpl, opts.timeoutMs),
    log: (e) => logs.push(e),
    now: () => now,
    requestId: () => 'req-1',
    roots: [CA.root],
  };
  return { redis, calls: up.calls, logs, deps, now };
}

function request(ip: string | null, now = NOW, header = 'x-vercel-forwarded-for') {
  const challenge = issueChallenge({ key: KEY, purpose: 'attest', keyId: null, now });
  const a = makeAttestation(CA, { clientDataHash: attestClientDataHash(challenge) });
  const body = JSON.stringify({ keyId: a.keyId.toString('base64'), attestationObject: a.attestationObject.toString('base64'), challenge, installId: crypto.randomUUID() });
  const headers: Record<string, string> = { 'Content-Type': 'application/json' };
  if (ip !== null) headers[header] = ip;
  return { req: new Request(URL_, { method: 'POST', body, headers }), a, challenge, body };
}
/** Headers with no usable edge address: absent, spoofable-only, or not an IP. */
const JUNK: Record<string, string>[] = [
  {},
  { 'x-real-ip': '203.0.113.7' },
  { 'x-forwarded-for': '203.0.113.7' },
  { 'x-vercel-forwarded-for': 'not-an-ip' },
  { 'x-vercel-forwarded-for': '203.0.113.256' },
  { 'x-vercel-forwarded-for': 'fe80::1%en0' },
  { 'x-vercel-forwarded-for': '' },
  { 'x-vercel-forwarded-for': ', 203.0.113.7' },
];
const reasonOf = async (res: Response) => ((await res.json()) as { reason?: string }).reason;
const devKey = (ip: string, day = DAY) =>
  enrollDeviceKey('nonprod', day, deviceBucket(KEY, day, clientNetwork(new Headers({ 'x-vercel-forwarded-for': ip }))!));

describe('enroll caps: owner decision 20/day overall, 3/day per device', () => {
  test('defaults are final: 20 global, 3 per device', () => {
    assert.equal(DEFAULT_ENROLL_DAILY_CAP, 20);
    assert.equal(DEFAULT_ENROLL_DEVICE_DAILY_CAP, 3);
    const cfg = registerConfig(BASE_ENV)!;
    assert.equal(cfg.enrollCap, 20);
    assert.equal(cfg.enrollDeviceCap, 3);
  });
  test('AERODJ_TTS_ENROLL_DEVICE_DAILY_CAP: plain integer 1-1000, anything else uses 3', () => {
    const cap = (v: string | undefined) => registerConfig({ ...BASE_ENV, AERODJ_TTS_ENROLL_DEVICE_DAILY_CAP: v })!.enrollDeviceCap;
    for (const v of [undefined, '', '0', '-1', '2.5', '1e2', '0x3', 'abc', '1001', 'Infinity']) assert.equal(cap(v), 3, String(v));
    assert.equal(cap('1'), 1);
    assert.equal(cap('1000'), 1000);
  });

  test('exactly 3 per device succeed; the 4th is 429 enroll with the global-cap conventions and writes nothing', async () => {
    const h = harness();
    for (let i = 0; i < 3; i++) assert.equal((await handleRegister(request('203.0.113.7').req, h.deps)).status, 204, `#${i + 1}`);
    assert.equal(h.redis.data.get(devKey('203.0.113.7')), '3');
    const before = new Map(h.redis.data);
    const fourth = request('203.0.113.7');
    const res = await handleRegister(fourth.req, h.deps);
    assert.equal(res.status, 429);
    assert.equal(await reasonOf(res), 'enroll');
    assert.equal(res.headers.get('retry-after'), String(secondsUntilNextUtcDay(NOW)));
    assert.deepEqual(h.redis.data, before, 'no record, no counter moves, challenge not consumed');
    assert.equal(h.redis.data.get(enrollKey('nonprod', DAY)), '3', 'a device-capped request spends no global budget');
    assert.deepEqual(h.logs.at(-1), { requestId: 'req-1', status: 429, reason: 'enroll', detail: 'device_cap' });
  });
  test('the device-cap 429 body is identical in shape to the global-cap 429 (no oracle)', async () => {
    const d = harness({ env: { AERODJ_TTS_ENROLL_DEVICE_DAILY_CAP: '1' } });
    await handleRegister(request('198.51.100.1').req, d.deps);
    const dr = await handleRegister(request('198.51.100.1').req, d.deps);
    const g = harness({ env: { AERODJ_TTS_ENROLL_DAILY_CAP: '1' } });
    await handleRegister(request('198.51.100.1').req, g.deps);
    const gr = await handleRegister(request('198.51.100.2').req, g.deps);
    assert.equal(dr.status, gr.status);
    assert.deepEqual(await dr.json(), await gr.json());
    assert.equal(dr.headers.get('retry-after'), gr.headers.get('retry-after'));
    assert.equal(g.logs.at(-1)!.detail, undefined, 'global-cap 429 log unchanged');
  });
  test('a different device is unaffected', async () => {
    const h = harness();
    for (let i = 0; i < 4; i++) await handleRegister(request('203.0.113.7').req, h.deps);
    assert.equal((await handleRegister(request('203.0.113.8').req, h.deps)).status, 204);
    assert.equal((await handleRegister(request('2001:db8:1:2::1').req, h.deps)).status, 204);
    assert.equal(h.redis.data.get(enrollKey('nonprod', DAY)), '5');
  });
  test('the global 20 cap still holds across many devices; the refused device gets no counter', async () => {
    const h = harness();
    for (let i = 1; i <= 20; i++) assert.equal((await handleRegister(request(`192.0.2.${i}`).req, h.deps)).status, 204, `#${i}`);
    const before = new Map(h.redis.data);
    const res = await handleRegister(request('192.0.2.21').req, h.deps);
    assert.equal(res.status, 429);
    assert.equal(await reasonOf(res), 'enroll');
    assert.equal(h.logs.at(-1)!.detail, undefined);
    assert.deepEqual(h.redis.data, before);
    assert.equal(h.redis.data.has(devKey('192.0.2.21')), false);
    assert.equal(h.redis.data.get(enrollKey('nonprod', DAY)), '20');
  });
  test('both caps full: the device cap is checked first (device_cap), nothing written', async () => {
    const h = harness({ env: { AERODJ_TTS_ENROLL_DAILY_CAP: '3' } });
    for (let i = 0; i < 3; i++) await handleRegister(request('203.0.113.9').req, h.deps);
    const before = new Map(h.redis.data);
    await handleRegister(request('203.0.113.9').req, h.deps);
    assert.equal(h.logs.at(-1)!.detail, 'device_cap');
    assert.deepEqual(h.redis.data, before);
    const i4 = REGISTER_SCRIPT.indexOf('return -4');
    assert.ok(i4 > 0 && i4 < REGISTER_SCRIPT.indexOf('return -3') && REGISTER_SCRIPT.indexOf('return -3') < REGISTER_SCRIPT.indexOf("'SET'"));
  });
  test('a duplicate keyId does not spend device budget', async () => {
    const h = harness();
    const credKey = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
    for (let i = 0; i < 2; i++) {
      const challenge = issueChallenge({ key: KEY, purpose: 'attest', keyId: null, now: NOW });
      const a = makeAttestation(CA, { clientDataHash: attestClientDataHash(challenge), credKey });
      const body = JSON.stringify({ keyId: a.keyId.toString('base64'), attestationObject: a.attestationObject.toString('base64'), challenge, installId: crypto.randomUUID() });
      await handleRegister(new Request(URL_, { method: 'POST', body, headers: { 'x-vercel-forwarded-for': '203.0.113.10' } }), h.deps);
    }
    assert.equal(h.logs.at(-1)!.detail, 'duplicate');
    assert.equal(h.redis.data.get(devKey('203.0.113.10')), '1');
  });

  test('day rollover: the next UTC day has a fresh 3, under a new unlinkable key; counters carry the 2-day TTL', async () => {
    const shared = new FakeRedis(() => NOW);
    const h = harness({ redis: shared });
    for (let i = 0; i < 4; i++) await handleRegister(request('203.0.113.7').req, h.deps);
    assert.equal(h.logs.at(-1)!.status, 429);
    assert.equal(shared.expiresAt.get(devKey('203.0.113.7')), NOW + ENROLL_TTL_SECONDS * 1000);
    const tomorrow = NOW + 86_400_000;
    shared.now = () => tomorrow;
    const t = harness({ redis: shared, now: tomorrow });
    for (let i = 0; i < 3; i++) assert.equal((await handleRegister(request('203.0.113.7', tomorrow).req, t.deps)).status, 204);
    assert.equal((await handleRegister(request('203.0.113.7', tomorrow).req, t.deps)).status, 429);
    const k1 = devKey('203.0.113.7');
    const k2 = devKey('203.0.113.7', utcDay(tomorrow));
    assert.notEqual(k1.split(':').at(-1), k2.split(':').at(-1), 'same network, unrelated buckets on different days');
    assert.equal(shared.data.get(k2), '3');
    // Last second of the day is still today; Retry-After points at midnight.
    const late = Date.UTC(2026, 9, 29, 23, 59, 59);
    const l = harness({ redis: shared, now: late });
    const res = await handleRegister(request('203.0.113.7', late).req, l.deps);
    assert.equal(res.status, 429);
    assert.equal(res.headers.get('retry-after'), '1');
  });

  test('store errors and timeouts fail closed: 503 store, Retry-After 30 (shared constant)', { timeout: 5_000 }, async () => {
    assert.equal(STORE_RETRY_AFTER_SECONDS, 30);
    const keepAlive = setTimeout(() => {}, 10_000);
    try {
      // Changed expected value: -5 was an unknown reply at #256; it is now the per-install
      // cap (enroll-install.test.ts), so the first unknown code is -6.
      const replies = [{ result: -4.5 }, { result: '-4' }, { result: -6 }, { result: '-5' }, { result: 2 ** 60 }, { error: 'ERR' }, {}];
      const impls: [string, typeof fetch][] = replies.map((r) => [JSON.stringify(r), (async () => new Response(JSON.stringify(r))) as unknown as typeof fetch]);
      impls.push(['500', (async () => new Response('x', { status: 500 })) as unknown as typeof fetch]);
      impls.push(['throws', (async () => { throw new TypeError('net'); }) as unknown as typeof fetch]);
      impls.push(['hangs', (() => new Promise<Response>(() => {})) as unknown as typeof fetch]);
      for (const [name, fetchImpl] of impls) {
        const h = harness({ fetchImpl, timeoutMs: 20 });
        const res = await handleRegister(request('203.0.113.7').req, h.deps);
        assert.equal(res.status, 503, name);
        assert.equal(await reasonOf(res), 'store', name);
        assert.equal(res.headers.get('retry-after'), String(STORE_RETRY_AFTER_SECONDS), name);
      }
    } finally {
      clearTimeout(keepAlive);
    }
  });
});

describe('enroll caps: the device key (privacy and layout)', () => {
  test('no raw address in any key, any Upstash command, any log line', async () => {
    const h = harness();
    const ips = ['203.0.113.77', '2001:db8:abcd:12::99', '::ffff:198.51.100.44'];
    for (const ip of ips) for (let i = 0; i < 4; i++) await handleRegister(request(ip).req, h.deps);
    const forms = ['203.0.113.77', '2001:db8:abcd:12', '2001:0db8', '198.51.100.44', 'cb00:714d', 'c633:642c', '2001:db8:abcd:12::99'];
    const everything = JSON.stringify([...h.redis.data.keys(), ...h.redis.data.values(), h.calls.map((c) => c.command), h.logs]);
    for (const f of forms) assert.equal(everything.includes(f), false, f);
    for (const k of h.redis.data.keys()) if (k.includes('enrolldev')) assert.match(k, /^nonprod:enrolldev:\{aerodj-tts\}:\d{4}-\d{2}-\d{2}:[0-9a-f]{64}$/);
    for (const e of h.logs) assert.deepEqual(Object.keys(e).filter((k) => !['requestId', 'status', 'reason', 'detail'].includes(k)), []);
  });
  test('key layout: same {aerodj-tts} slot as every other register key; production has no prefix; bucket must be hex SHA-256', () => {
    const b = 'a'.repeat(64);
    assert.equal(enrollDeviceKey('production', '2026-10-29', b), `enrolldev:{aerodj-tts}:2026-10-29:${b}`);
    assert.equal(enrollDeviceKey('nonprod', '2026-10-29', b), `nonprod:enrolldev:{aerodj-tts}:2026-10-29:${b}`);
    for (const bad of ['203.0.113.7', 'v4:203.0.113.7', 'A'.repeat(64), 'a'.repeat(63)]) assert.throws(() => enrollDeviceKey('nonprod', '2026-10-29', bad), bad);
  });
  test('the bucket is keyed: another HMAC key gives another bucket; day and network both matter', () => {
    const other = crypto.createHash('sha256').update('other').digest();
    const n = 'v4:203.0.113.7';
    assert.notEqual(deviceBucket(KEY, DAY, n), deviceBucket(other, DAY, n));
    assert.notEqual(deviceBucket(KEY, DAY, n), deviceBucket(KEY, '2026-10-30', n));
    assert.notEqual(deviceBucket(KEY, DAY, n), deviceBucket(KEY, DAY, 'v4:203.0.113.8'));
    assert.notEqual(deviceBucket(KEY, DAY, n), crypto.createHash('sha256').update(n).digest('hex'));
  });
  test('clientNetwork: IPv4, IPv6 /64, mapped IPv4, first entry only, x-vercel-forwarded-for only, else null', () => {
    const net = (h: Record<string, string>) => clientNetwork(new Headers(h));
    assert.equal(net({ 'x-vercel-forwarded-for': '203.0.113.7' }), 'v4:203.0.113.7');
    assert.equal(net({ 'x-vercel-forwarded-for': ' 203.0.113.7 , 10.0.0.1' }), 'v4:203.0.113.7');
    // Changed expected value (Sentinel's #256 condition: the edge header only): x-real-ip
    // alone was 'v4:203.0.113.7' at 1f07f7a; it is no longer read, so it is null.
    assert.equal(net({ 'x-real-ip': '203.0.113.7' }), null);
    assert.equal(net({ 'x-vercel-forwarded-for': '203.0.113.7', 'x-real-ip': '198.51.100.1' }), 'v4:203.0.113.7');
    assert.equal(net({ 'x-vercel-forwarded-for': '::ffff:203.0.113.7' }), 'v4:203.0.113.7');
    assert.equal(net({ 'x-vercel-forwarded-for': '2001:db8:1:2:aaaa:bbbb:cccc:dddd' }), 'v6:2001:db8:1:2');
    assert.equal(net({ 'x-vercel-forwarded-for': '2001:0db8:0001:0002::1' }), 'v6:2001:db8:1:2');
    assert.equal(net({ 'x-vercel-forwarded-for': '2001:db8::' }), 'v6:2001:db8:0:0');
    assert.equal(net({ 'x-vercel-forwarded-for': '::1' }), 'v6:0:0:0:0');
    assert.equal(net({ 'x-vercel-forwarded-for': '64:ff9b::203.0.113.7' }), 'v6:64:ff9b:0:0');
    // Changed expected value: absent, spoofable or junk headers were the shared 'unknown'
    // bucket at 1f07f7a; now null, and register refuses them (400 network) instead.
    for (const h of JUNK) assert.equal(net(h), null, JSON.stringify(h));
  });
  test('rotating IPv6 interface ids inside one /64 does not escape the cap', async () => {
    const h = harness();
    for (let i = 1; i <= 3; i++) assert.equal((await handleRegister(request(`2001:db8:5:6::${i}`).req, h.deps)).status, 204);
    assert.equal((await handleRegister(request('2001:db8:5:6:ffff::4').req, h.deps)).status, 429);
    assert.equal((await handleRegister(request('2001:db8:5:7::1').req, h.deps)).status, 204, 'another /64 is another bucket');
  });
  // Replaces "no address header: one shared unknown bucket, capped at 3" (1f07f7a):
  // Sentinel's condition is that a missing edge header fails closed, with no shared bucket.
  test('no usable x-vercel-forwarded-for: 400 network, no Retry-After, no store call, challenge not consumed', async () => {
    const h = harness();
    for (const [i, hdrs] of JUNK.entries()) {
      const { body } = request(null);
      const callsBefore = h.calls.length;
      const dataBefore = new Map(h.redis.data);
      const res = await handleRegister(new Request(URL_, { method: 'POST', body, headers: { 'Content-Type': 'application/json', ...hdrs } }), h.deps);
      const label = JSON.stringify(hdrs);
      assert.equal(res.status, 400, label);
      assert.deepEqual(await res.json(), { error: 'Bad request', requestId: 'req-1', reason: 'network' }, label);
      assert.equal(res.headers.get('retry-after'), null, label);
      assert.equal(h.calls.length, callsBefore, `${label}: no Upstash command at all`);
      assert.deepEqual(h.redis.data, dataBefore, `${label}: nothing written`);
      assert.deepEqual(h.logs.at(-1), { requestId: 'req-1', status: 400, reason: 'network' }, label);
      // The same challenge still enrolls once the edge header is present: it was not consumed.
      const retry = await handleRegister(new Request(URL_, { method: 'POST', body, headers: { 'x-vercel-forwarded-for': `203.0.113.${60 + i}` } }), h.deps);
      assert.equal(retry.status, 204, `${label}: challenge unconsumed`);
    }
    assert.equal(h.redis.data.get(enrollKey('nonprod', DAY)), String(JUNK.length), 'only the retries counted');
  });
  test('x-real-ip alone is not an address: 400 network even when it is a valid IP', async () => {
    const h = harness();
    const res = await handleRegister(request('203.0.113.7', NOW, 'x-real-ip').req, h.deps);
    assert.equal(res.status, 400);
    assert.equal(await reasonOf(res), 'network');
    assert.equal(h.calls.length, 0);
  });
  test('an expired challenge without the edge header is refused before the used-mark probe', async () => {
    const h = harness();
    const old = NOW - 121_000;
    const { body } = request(null, old);
    const res = await handleRegister(new Request(URL_, { method: 'POST', body }), h.deps);
    assert.equal(res.status, 400);
    assert.equal(await reasonOf(res), 'network');
    assert.equal(h.calls.length, 0, 'no isUsed read either');
  });
  test('IPv4, IPv6 /64 and mapped IPv4 each enroll and count in their own bucket; mapped v4 shares the v4 bucket', async () => {
    const h = harness();
    assert.equal((await handleRegister(request('198.51.100.9').req, h.deps)).status, 204);
    assert.equal((await handleRegister(request('::ffff:198.51.100.9').req, h.deps)).status, 204);
    assert.equal(h.redis.data.get(devKey('198.51.100.9')), '2', 'mapped IPv4 is the same network');
    assert.equal((await handleRegister(request('2001:db8:9:9::1').req, h.deps)).status, 204);
    assert.equal((await handleRegister(request('2001:db8:9:9:abcd::2').req, h.deps)).status, 204);
    assert.equal(h.redis.data.get(devKey('2001:db8:9:9::77')), '2', 'same /64');
  });
});
