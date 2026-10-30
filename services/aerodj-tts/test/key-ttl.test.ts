/**
 * Owner decision (2026-10-29): attest key records get a 90-day SLIDING TTL, set on
 * register and refreshed on each successful use (useAttestKey / touchKey), not only
 * on register. FakeRedis runs with lazy expiry so an unused key really disappears.
 */
import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { attestClientDataHash } from '../src/app-attest-verify.js';
import { STORE_RETRY_AFTER_SECONDS } from '../src/attest-flags.js';
import { useAttestKey } from '../src/attest-key-use.js';
import { KEY_RECORD_TTL_SECONDS, keyRecordKey, RedisAttestStore, TOUCH_KEY_SCRIPT } from '../src/attest-store.js';
import { issueChallenge } from '../src/challenge.js';
import type { Env } from '../src/handler.js';
import { handleRegister } from '../src/register-handler.js';
import { makeAttestCa, makeAttestation, TEST_APP_ID_PREFIX } from './helpers/fake-appattest.js';
import { FakeRedis, fakeUpstash } from './redis-lua.js';

// Test-only key material, generated here: never an env value, never a real secret.
const KEY = crypto.createHash('sha256').update('aerodj-tts key ttl test key, not a secret').digest();
const T0 = Date.UTC(2026, 9, 29, 12);
const DAY_MS = 86_400_000;
const TTL_MS = 90 * DAY_MS;
const CA = makeAttestCa();
const ENV: Env = Object.freeze({
  AERODJ_TTS_ATTEST_ENABLED: 'true',
  AERODJ_TTS_CHALLENGE_HMAC_KEY: KEY.toString('hex'),
  AERODJ_TTS_APPLE_APP_ID_PREFIX: TEST_APP_ID_PREFIX,
  VERCEL_ENV: 'preview',
});

function world() {
  let now = T0;
  const redis = new FakeRedis(() => now);
  redis.evictExpired = true;
  const up = fakeUpstash({ redis });
  const store = new RedisAttestStore({ url: 'https://upstash.invalid', token: 't' }, up.fetchImpl);
  return {
    redis,
    store,
    setNow: (t: number) => (now = t),
    async register(): Promise<Buffer> {
      const challenge = issueChallenge({ key: KEY, purpose: 'attest', keyId: null, now });
      const a = makeAttestation(CA, { clientDataHash: attestClientDataHash(challenge) });
      const body = JSON.stringify({ keyId: a.keyId.toString('base64'), attestationObject: a.attestationObject.toString('base64'), challenge });
      const t = now;
      const res = await handleRegister(new Request('https://proxy.invalid/api/attest/register', { method: 'POST', body, headers: { 'x-vercel-forwarded-for': '203.0.113.7' } }), {
        env: ENV,
        store,
        log: () => {},
        now: () => t,
        requestId: () => 'r',
        roots: [CA.root],
      });
      assert.equal(res.status, 204);
      return a.keyId;
    },
  };
}

describe('attest key records: 90-day sliding TTL', () => {
  test('the TTL is exactly 90 days, in seconds', () => {
    assert.equal(KEY_RECORD_TTL_SECONDS, 7_776_000);
  });
  test('register sets the record TTL to 90 days', async () => {
    const w = world();
    const keyId = await w.register();
    assert.equal(w.redis.expiresAt.get(keyRecordKey('nonprod', keyId)), T0 + TTL_MS);
  });
  test('each successful use refreshes the TTL to 90 days from the use', async () => {
    const w = world();
    const keyId = await w.register();
    const rk = keyRecordKey('nonprod', keyId);
    const record = w.redis.data.get(rk);
    for (const day of [1, 45, 89]) {
      const t = T0 + day * DAY_MS;
      w.setNow(t);
      assert.deepEqual(await useAttestKey(w.store, 'nonprod', keyId), { ok: true }, `day ${day}`);
      assert.equal(w.redis.expiresAt.get(rk), t + TTL_MS, `day ${day}`);
    }
    assert.equal(w.redis.data.get(rk), record, 'refresh never rewrites the record');
    const expires = w.redis.commands.filter((c) => c[0] === 'EXPIRE' && c[1] === rk);
    assert.deepEqual(expires.map((c) => c[2]), ['7776000', '7776000', '7776000']);
  });
  test('a used key outlives its register-time expiry; it lapses 90 days after the LAST use', async () => {
    const w = world();
    const keyId = await w.register();
    w.setNow(T0 + 60 * DAY_MS);
    assert.equal((await useAttestKey(w.store, 'nonprod', keyId)).ok, true);
    w.setNow(T0 + 100 * DAY_MS); // past the register-time expiry (day 90)
    assert.equal((await useAttestKey(w.store, 'nonprod', keyId)).ok, true);
    w.setNow(T0 + 190 * DAY_MS - 1);
    assert.equal((await useAttestKey(w.store, 'nonprod', keyId)).ok, true);
    w.setNow(T0 + 190 * DAY_MS - 1 + TTL_MS);
    assert.deepEqual(await useAttestKey(w.store, 'nonprod', keyId), { ok: false, status: 401, reason: 'assertion', detail: 'unknown_key' });
  });
  test('an unused key expires at 90 days and its assertion then fails as an unknown key; nothing is recreated', async () => {
    const w = world();
    const keyId = await w.register();
    const rk = keyRecordKey('nonprod', keyId);
    w.setNow(T0 + TTL_MS - 1000);
    assert.equal(w.redis.data.has(rk), true);
    w.setNow(T0 + TTL_MS);
    assert.deepEqual(await useAttestKey(w.store, 'nonprod', keyId), { ok: false, status: 401, reason: 'assertion', detail: 'unknown_key' });
    assert.equal(w.redis.data.has(rk), false);
    assert.equal(w.redis.expiresAt.has(rk), false);
  });
  test('a never-registered key: unknown_key, nothing written', async () => {
    const w = world();
    const before = new Map(w.redis.data);
    assert.equal((await useAttestKey(w.store, 'nonprod', crypto.randomBytes(32))).ok, false);
    assert.deepEqual(w.redis.data, before);
  });
  test('keyspace: a preview use never refreshes the production record', async () => {
    const w = world();
    const keyId = crypto.randomBytes(32);
    w.redis.data.set(keyRecordKey('production', keyId), '{}');
    w.redis.expiresAt.set(keyRecordKey('production', keyId), T0 + DAY_MS);
    assert.equal((await useAttestKey(w.store, 'nonprod', keyId)).ok, false);
    assert.equal(w.redis.expiresAt.get(keyRecordKey('production', keyId)), T0 + DAY_MS);
  });
  test('a TTL refresh store error or timeout fails closed: 503 store, Retry-After 30', { timeout: 5_000 }, async () => {
    const keepAlive = setTimeout(() => {}, 10_000);
    try {
      const replies = [{ result: 1.5 }, { result: '1' }, { result: 2 }, { result: -1 }, { result: null }, { error: 'ERR' }];
      const impls: [string, typeof fetch][] = replies.map((r) => [JSON.stringify(r), (async () => new Response(JSON.stringify(r))) as unknown as typeof fetch]);
      impls.push(['500', (async () => new Response('x', { status: 500 })) as unknown as typeof fetch]);
      impls.push(['throws', (async () => { throw new TypeError('net'); }) as unknown as typeof fetch]);
      impls.push(['hangs', (() => new Promise<Response>(() => {})) as unknown as typeof fetch]);
      for (const [name, fetchImpl] of impls) {
        const store = new RedisAttestStore({ url: 'https://u.invalid', token: 't' }, fetchImpl, 20);
        const started = Date.now();
        assert.deepEqual(
          await useAttestKey(store, 'nonprod', crypto.randomBytes(32)),
          { ok: false, status: 503, reason: 'store', retryAfterSeconds: STORE_RETRY_AFTER_SECONDS },
          name,
        );
        assert.ok(Date.now() - started < 1_000, name);
      }
      assert.equal(STORE_RETRY_AFTER_SECONDS, 30);
    } finally {
      clearTimeout(keepAlive);
    }
  });
  test('the refresh is a single EXPIRE (no GET-then-SET, never rewrites the record)', () => {
    assert.match(TOUCH_KEY_SCRIPT, /redis\.call\('EXPIRE', KEYS\[1\], ARGV\[1\]\)/);
    assert.doesNotMatch(TOUCH_KEY_SCRIPT, /'SET'/);
  });
});
