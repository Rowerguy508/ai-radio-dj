/**
 * Sentinel's N2 on #256/#270: pin the enroll counter TTL as the LITERAL 172800 seconds
 * (2 days). The other suites compare against ENROLL_TTL_SECONDS, so a 3-day constant
 * used to pass them. Sentinel's condition is a TTL of 2 days or less on every
 * day-scoped enroll counter: the global key, the network (device) HMAC key and the
 * install HMAC key. There is no in-memory attest store (no Upstash -> 503 `store`),
 * so the Redis/Upstash path running the real REGISTER_SCRIPT is the only path.
 */
import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { attestClientDataHash } from '../src/app-attest-verify.js';
import { attestUsedKey, ENROLL_TTL_SECONDS, enrollDeviceKey, enrollInstallKey, enrollKey, keyRecordKey, RedisAttestStore, REGISTER_SCRIPT } from '../src/attest-store.js';
import { issueChallenge } from '../src/challenge.js';
import { clientNetwork, deviceBucket } from '../src/enroll-device.js';
import { installBucket } from '../src/enroll-install.js';
import type { Env } from '../src/handler.js';
import { utcDay } from '../src/limiter.js';
import { handleRegister } from '../src/register-handler.js';
import { makeAttestCa, makeAttestation, TEST_APP_ID_PREFIX } from './helpers/fake-appattest.js';
import { FakeRedis, fakeUpstash } from './redis-lua.js';

// Test-only key material, generated here: never an env value, never a real secret.
const KEY = crypto.createHash('sha256').update('aerodj-tts enroll ttl pin test key, not a secret').digest();
const NOW = Date.UTC(2026, 9, 29, 12);
const TWO_DAYS_S = 172_800; // literal on purpose: never derived from ENROLL_TTL_SECONDS
const TWO_DAYS_MS = 172_800_000;
const CA = makeAttestCa();
const IP = '203.0.113.7';
const INSTALL = '3f2b8c1e-9d4a-4e6b-a7c2-5b1d0e9f8a63';
const ENV: Env = Object.freeze({
  AERODJ_TTS_ATTEST_ENABLED: 'true',
  AERODJ_TTS_CHALLENGE_HMAC_KEY: KEY.toString('hex'),
  AERODJ_TTS_APPLE_APP_ID_PREFIX: TEST_APP_ID_PREFIX,
  VERCEL_ENV: 'preview',
});

function world(evict = false) {
  let now = NOW;
  const redis = new FakeRedis(() => now);
  redis.evictExpired = evict;
  const up = fakeUpstash({ redis });
  const store = new RedisAttestStore({ url: 'https://upstash.invalid', token: 't' }, up.fetchImpl);
  return {
    redis,
    calls: up.calls,
    setNow: (t: number) => (now = t),
    async register(opts: { ip?: string; installId?: string } = {}) {
      const t = now;
      const challenge = issueChallenge({ key: KEY, purpose: 'attest', keyId: null, now: t });
      const a = makeAttestation(CA, { clientDataHash: attestClientDataHash(challenge) });
      const body = JSON.stringify({ keyId: a.keyId.toString('base64'), attestationObject: a.attestationObject.toString('base64'), challenge, installId: opts.installId ?? INSTALL });
      const req = new Request('https://proxy.invalid/api/attest/register', {
        method: 'POST',
        body,
        headers: { 'Content-Type': 'application/json', 'x-vercel-forwarded-for': opts.ip ?? IP },
      });
      const res = await handleRegister(req, { env: ENV, store, log: () => {}, now: () => t, requestId: () => 'r', roots: [CA.root] });
      return { res, keyId: a.keyId, challenge };
    },
  };
}
const day = (t = NOW) => utcDay(t);
const globalKey = (t = NOW) => enrollKey('nonprod', day(t));
const devKey = (t = NOW, ip = IP) => enrollDeviceKey('nonprod', day(t), deviceBucket(KEY, day(t), clientNetwork(new Headers({ 'x-vercel-forwarded-for': ip }))!));
const instKey = (t = NOW, id = INSTALL) => enrollInstallKey('nonprod', day(t), installBucket(KEY, day(t), id));
const expireCmds = (r: FakeRedis, from = 0) => r.commands.slice(from).filter((c) => c[0].toUpperCase() === 'EXPIRE');

describe('enroll counters: TTL pinned to the literal 172800 s (Sentinel N2)', () => {
  test('ENROLL_TTL_SECONDS is exactly 172800 (2 days)', () => {
    assert.equal(ENROLL_TTL_SECONDS, 172_800);
    assert.ok(ENROLL_TTL_SECONDS <= 2 * 86_400, "Sentinel's condition: 2 days or less");
  });

  test('register sends 172800 as the enroll TTL argument (ARGV[5]) over the wire', async () => {
    const w = world();
    assert.equal((await w.register()).res.status, 204);
    assert.equal(w.calls.length, 1);
    const [verb, , numKeys, ...rest] = w.calls[0].command as [string, string, number, ...string[]];
    assert.equal(verb, 'EVAL');
    assert.equal(numKeys, 5);
    assert.equal(rest.slice(numKeys)[4], '172800');
  });

  test('a success EXPIREs exactly the three enroll counters, each to 172800, once each', async () => {
    const w = world();
    assert.equal((await w.register()).res.status, 204);
    assert.deepEqual(
      expireCmds(w.redis),
      [
        ['EXPIRE', globalKey(), '172800'],
        ['EXPIRE', devKey(), '172800'],
        ['EXPIRE', instKey(), '172800'],
      ],
    );
  });

  test('each enroll counter expires exactly 172800 s after the write', async () => {
    const w = world();
    const { res, keyId, challenge } = await w.register();
    assert.equal(res.status, 204);
    for (const [name, k] of [['global', globalKey()], ['network', devKey()], ['install', instKey()]] as const) {
      assert.equal(w.redis.data.get(k), '1', name);
      assert.equal(w.redis.expiresAt.get(k), NOW + TWO_DAYS_MS, name);
    }
    // The 2-day TTL lands on the counters only: never on the key record or the used mark.
    assert.notEqual(w.redis.expiresAt.get(keyRecordKey('nonprod', keyId)), NOW + TWO_DAYS_MS);
    assert.notEqual(w.redis.expiresAt.get(attestUsedKey('nonprod', challenge)), NOW + TWO_DAYS_MS);
  });

  test('a later success the same day re-sets each counter to 172800 s from that write', async () => {
    const w = world();
    assert.equal((await w.register()).res.status, 204);
    const later = NOW + 6 * 3_600_000;
    w.setNow(later);
    const before = w.redis.commands.length;
    assert.equal((await w.register({ ip: '198.51.100.9', installId: '9a1c4e2b-7d3f-4b8a-9c6e-1f2a3b4c5d6e' })).res.status, 204);
    assert.equal(w.redis.get(globalKey()), 2);
    assert.equal(w.redis.expiresAt.get(globalKey()), later + TWO_DAYS_MS);
    for (const c of expireCmds(w.redis, before)) assert.equal(c[2], String(TWO_DAYS_S));
    // The first request's network and install counters keep their own 2-day TTL.
    assert.equal(w.redis.expiresAt.get(devKey()), NOW + TWO_DAYS_MS);
    assert.equal(w.redis.expiresAt.get(instKey()), NOW + TWO_DAYS_MS);
  });

  test('a counter written at the last second of its UTC day is gone 172800 s later (lifetime <= day + 2 days)', async () => {
    const w = world(true);
    const last = Date.UTC(2026, 9, 29, 23, 59, 59);
    w.setNow(last);
    assert.equal((await w.register()).res.status, 204);
    const keys = [globalKey(last), devKey(last), instKey(last)];
    const probe = (k: string) => w.redis.eval("if redis.call('GET', KEYS[1]) then return 1 end return 0", [k], []);
    w.setNow(last + TWO_DAYS_MS - 1000);
    for (const k of keys) assert.equal(probe(k), 1, k);
    w.setNow(last + TWO_DAYS_MS);
    for (const k of keys) assert.equal(probe(k), 0, k);
    assert.ok(last + TWO_DAYS_MS <= Date.UTC(2026, 9, 30) + 2 * 86_400_000);
  });

  test('a capped refusal (429) sets no TTL on any key', async () => {
    const w = world();
    for (let i = 0; i < 3; i++) {
      w.setNow(NOW + i);
      assert.equal((await w.register({ installId: crypto.randomUUID() })).res.status, 204);
    }
    const before = w.redis.commands.length;
    const ttls = new Map(w.redis.expiresAt);
    assert.equal((await w.register({ installId: crypto.randomUUID() })).res.status, 429);
    assert.deepEqual(expireCmds(w.redis, before), []);
    assert.deepEqual(w.redis.expiresAt, ttls);
  });

  test('REGISTER_SCRIPT: ARGV[5] is used only by the three enroll-counter EXPIREs', () => {
    const uses = REGISTER_SCRIPT.match(/[^\n]*ARGV\[5\][^\n]*/g) ?? [];
    assert.deepEqual(uses, [
      "redis.call('EXPIRE', KEYS[3], ARGV[5])",
      "redis.call('EXPIRE', KEYS[4], ARGV[5])",
      "redis.call('EXPIRE', KEYS[5], ARGV[5])",
    ]);
  });
});
