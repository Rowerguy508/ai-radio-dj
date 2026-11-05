/**
 * #287 N1 (Fry): the per-minute request counters for the owner and for an install are
 * scoped by deployment (`VERCEL_ENV`), like the day counters (#264 N5), so Preview traffic
 * never uses up Production's owner or install rate. Pro rate keys already carried their
 * deployment (B3) and keep their shape. Real Lua (test/redis-lua.ts) throughout.
 */
import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { handleTts, limiterOptions, selectLimiter, type Deps, type Env, type LogEntry, type TtsRequest } from '../src/handler.js';
import {
  DEFAULT_REQUESTS_PER_MINUTE,
  RATE_SCRIPT,
  RedisUsageLimiter,
  isDeployment,
  rateKey,
  subjectBucket,
  utcMinute,
  type Deployment,
  type LimiterOptions,
  type Subject,
  type UsageLimiter,
} from '../src/limiter.js';
import { proBucket, proSubjectFromVerified, type ProSubject } from '../src/pro-allowance.js';
import { FakeRedis, fakeUpstash } from './redis-lua.js';
import { verifiedTransaction } from './helpers/verified-tx.js';

const TOKEN = 'test-owner-token-not-a-real-secret';
const TOKEN_HASH = crypto.createHash('sha256').update(TOKEN).digest('hex');
const VOICE = 'voiceAllowed123';
const STORE = { url: 'https://store.example.upstash.io', token: 'test-store-token-not-real' };
const NOON = Date.UTC(2026, 9, 29, 12);
const MIN = Math.floor(NOON / 60_000);
const A: Subject = { kind: 'install', id: 'install-key-id-A' };
const INSTALL = subjectBucket(A);
const INSTALL_SHA = INSTALL.slice('install:'.length);
const sha = (s: string) => crypto.createHash('sha256').update(s, 'utf8').digest('hex');
const DEPLOYMENTS: Deployment[] = ['production', 'preview', 'development'];
const MINUTE_TTL_MS = 120_000;

const limiter = (redis: FakeRedis, deployment: Deployment, o: Partial<LimiterOptions> = {}) =>
  new RedisUsageLimiter(STORE, { deployment, dailyCharCap: 9_000, requestsPerMinute: 2, ...o }, fakeUpstash({ redis }).fetchImpl);

function env(o: Env = {}): Env {
  return {
    AERODJ_TTS_TOKEN_SHA256: TOKEN_HASH,
    AERODJ_TTS_VOICE_IDS: VOICE,
    ELEVENLABS_API_KEY: 'test-elevenlabs-key-not-real',
    ...o,
  };
}

function pcm(): Response {
  return new Response(Buffer.alloc(22_050 * 2, 1), { status: 200, headers: { 'Content-Type': 'audio/pcm' } });
}

function deps(l: UsageLimiter | null, e: Env) {
  const logs: LogEntry[] = [];
  let upstream = 0;
  const d: Deps = {
    env: e,
    fetch: (async () => { upstream++; return pcm(); }) as typeof fetch,
    limiter: l,
    log: (x) => logs.push(x),
    now: () => NOON,
    timeoutMs: 50,
    requestId: () => 'req-1',
  };
  return { d, logs, upstream: () => upstream };
}

const req = (text: string, verifiedPro?: ProSubject): TtsRequest => ({
  method: 'POST',
  authorization: `Bearer ${TOKEN}`,
  body: { upstream: 'elevenlabs', voiceId: VOICE, text, format: 'text' },
  verifiedPro,
});

describe('#287 N1: rate key shapes', () => {
  test('owner and install minute keys carry the deployment; Pro keys keep their B3 shape', () => {
    for (const d of DEPLOYMENTS) {
      assert.equal(rateKey('owner', MIN, d), `aerodj-tts:rate:owner:${d}:${MIN}`);
      assert.equal(rateKey(INSTALL, MIN, d), `aerodj-tts:rate:install:${d}:${INSTALL_SHA}:${MIN}`);
      const pro = `pro:${d}:${sha('otid')}`;
      assert.equal(rateKey(pro, MIN, d), `aerodj-tts:rate:${pro}:${MIN}`);
    }
  });

  test('no unscoped legacy rate key is ever built', () => {
    for (const d of DEPLOYMENTS) {
      for (const k of [rateKey('owner', MIN, d), rateKey(INSTALL, MIN, d), rateKey(`pro:${d}:${sha('x')}`, MIN, d)]) {
        assert.notEqual(k, `aerodj-tts:rate:owner:${MIN}`);
        assert.notEqual(k, `aerodj-tts:rate:${INSTALL}:${MIN}`);
        assert.match(k, new RegExp(`:${d}:`));
      }
    }
  });

  for (const bad of [undefined, '', 'staging', 'Production', 'production ', 'global'] as unknown[]) {
    test(`deployment ${JSON.stringify(bad)} is refused when a rate key is built`, () => {
      assert.equal(isDeployment(bad), false);
      assert.throws(() => rateKey('owner', MIN, bad as Deployment), TypeError);
      assert.throws(() => rateKey(INSTALL, MIN, bad as Deployment), TypeError);
      assert.throws(() => rateKey(`pro:production:${sha('x')}`, MIN, bad as Deployment), TypeError);
    });
  }

  test('a bucket that is not owner, a hashed install or a Pro bucket is refused', () => {
    for (const b of ['', 'global', 'owner:production', 'install:abc', `install:${'A'.repeat(64)}`, `install:production:${INSTALL_SHA}`, 'pro:production:abc', `pro:staging:${sha('x')}`]) {
      assert.throws(() => rateKey(b, MIN, 'production'), TypeError, b);
    }
  });

  test('a bad minute is refused', () => {
    for (const m of [-1, 1.5, Number.NaN, Number.POSITIVE_INFINITY]) assert.throws(() => rateKey('owner', m, 'production'), TypeError, String(m));
  });

  test('a Pro bucket from another deployment is refused and never reaches the store', async () => {
    assert.throws(() => rateKey(`pro:preview:${sha('x')}`, MIN, 'production'), TypeError);
    const redis = new FakeRedis(() => NOON);
    await assert.rejects(limiter(redis, 'production').allowRequest(`pro:preview:${sha('x')}`, NOON, 5), TypeError);
    await assert.rejects(limiter(redis, 'production').allowRequest('install:abc', NOON), TypeError);
    assert.equal(redis.commands.length, 0);
  });

  test('the limiter sends the scoped key to the store (one EVAL of RATE_SCRIPT)', async () => {
    const store = fakeUpstash();
    const l = new RedisUsageLimiter(STORE, { deployment: 'preview', dailyCharCap: 9_000, requestsPerMinute: 12 }, store.fetchImpl);
    assert.equal(await l.allowRequest('owner', NOON), true);
    assert.equal(await l.allowRequest(INSTALL, NOON), true);
    assert.deepEqual(store.calls.map((c) => c.command.slice(0, 4)), [
      ['EVAL', RATE_SCRIPT, 1, `aerodj-tts:rate:owner:preview:${MIN}`],
      ['EVAL', RATE_SCRIPT, 1, `aerodj-tts:rate:install:preview:${INSTALL_SHA}:${MIN}`],
    ]);
  });
});

describe('#287 N1: preview and production rate counters are independent', () => {
  for (const [name, bucket] of [['owner', 'owner'], ['install', INSTALL]] as const) {
    test(`${name}: a spent preview minute does not touch production (and the reverse)`, async () => {
      const redis = new FakeRedis(() => NOON);
      const prod = limiter(redis, 'production');
      const prev = limiter(redis, 'preview');
      const dev = limiter(redis, 'development');
      assert.deepEqual([await prev.allowRequest(bucket, NOON), await prev.allowRequest(bucket, NOON), await prev.allowRequest(bucket, NOON)], [true, true, false]);
      assert.deepEqual([await prod.allowRequest(bucket, NOON), await prod.allowRequest(bucket, NOON), await prod.allowRequest(bucket, NOON)], [true, true, false]);
      assert.deepEqual([await dev.allowRequest(bucket, NOON), await dev.allowRequest(bucket, NOON), await dev.allowRequest(bucket, NOON)], [true, true, false]);
      for (const d of DEPLOYMENTS) assert.equal(redis.get(rateKey(bucket, MIN, d)), 3, d);
      assert.equal(redis.get(`aerodj-tts:rate:${bucket}:${MIN}`), 0, 'legacy unscoped key untouched');
    });
  }

  test('owner and install never share a bucket within one deployment', async () => {
    const redis = new FakeRedis(() => NOON);
    const l = limiter(redis, 'production');
    assert.deepEqual([await l.allowRequest('owner', NOON), await l.allowRequest('owner', NOON), await l.allowRequest('owner', NOON)], [true, true, false]);
    assert.equal(await l.allowRequest(INSTALL, NOON), true);
  });

  test('end to end: preview owner traffic through selectLimiter never 429s production', async () => {
    const redis = new FakeRedis(() => NOON);
    const store = fakeUpstash({ redis });
    const base = { KV_REST_API_URL: STORE.url, KV_REST_API_TOKEN: STORE.token, AERODJ_TTS_RATE_PER_MINUTE: '2' };
    const prev = deps(selectLimiter({ ...base, VERCEL_ENV: 'preview' }, store.fetchImpl), env({ ...base, VERCEL_ENV: 'preview' }));
    const prod = deps(selectLimiter({ ...base, VERCEL_ENV: 'production' }, store.fetchImpl), env({ ...base, VERCEL_ENV: 'production' }));
    const statuses = async (h: ReturnType<typeof deps>) => [await handleTts(req('hi'), h.d), await handleTts(req('hi'), h.d), await handleTts(req('hi'), h.d)].map((r) => r.status);
    assert.deepEqual(await statuses(prev), [200, 200, 429]);
    assert.deepEqual(await statuses(prod), [200, 200, 429]);
    assert.equal(prev.upstream(), 2);
    assert.equal(prod.upstream(), 2);
    assert.equal(redis.get(`aerodj-tts:rate:owner:preview:${MIN}`), 3);
    assert.equal(redis.get(`aerodj-tts:rate:owner:production:${MIN}`), 3);
  });

  test('end to end: Pro rate keys are unchanged and still per deployment', async () => {
    const redis = new FakeRedis(() => NOON);
    const store = fakeUpstash({ redis });
    const base = { KV_REST_API_URL: STORE.url, KV_REST_API_TOKEN: STORE.token, AERODJ_TTS_PRO_RATE_PER_MINUTE: '1' };
    const subject = proSubjectFromVerified(await verifiedTransaction('2000000123456789'));
    const prev = deps(selectLimiter({ ...base, VERCEL_ENV: 'preview' }, store.fetchImpl), env({ ...base, VERCEL_ENV: 'preview' }));
    const prod = deps(selectLimiter({ ...base, VERCEL_ENV: 'production' }, store.fetchImpl), env({ ...base, VERCEL_ENV: 'production' }));
    assert.deepEqual([(await handleTts(req('hi', subject), prev.d)).status, (await handleTts(req('hi', subject), prev.d)).status], [200, 429]);
    assert.equal((await handleTts(req('hi', subject), prod.d)).status, 200);
    assert.equal(redis.get(`aerodj-tts:rate:${proBucket(subject, 'preview')}:${MIN}`), 2);
    assert.equal(redis.get(`aerodj-tts:rate:${proBucket(subject, 'production')}:${MIN}`), 1);
  });
});

describe('#287 N1: limits and TTL are unchanged within one deployment', () => {
  test('default 12/min, the next minute starts fresh, and the minute TTL is still 120 s', async () => {
    let clock = NOON;
    const redis = new FakeRedis(() => clock);
    const l = new RedisUsageLimiter(STORE, limiterOptions({ VERCEL_ENV: 'production' }), fakeUpstash({ redis }).fetchImpl);
    assert.equal(DEFAULT_REQUESTS_PER_MINUTE, 12);
    for (let i = 0; i < 12; i++) assert.equal(await l.allowRequest('owner', NOON), true, `#${i}`);
    assert.equal(await l.allowRequest('owner', NOON), false);
    clock = NOON + 60_000;
    assert.equal(await l.allowRequest('owner', clock), true);
    assert.equal(utcMinute(NOON), MIN);
    for (const k of [rateKey('owner', MIN, 'production'), rateKey('owner', MIN + 1, 'production')]) {
      assert.ok(redis.expiresAt.has(k), k);
    }
    assert.equal(redis.expiresAt.get(rateKey('owner', MIN, 'production')), NOON + MINUTE_TTL_MS);
    assert.equal(redis.expiresAt.get(rateKey('owner', MIN + 1, 'production')), NOON + 60_000 + MINUTE_TTL_MS);
  });
});

describe('#287 N1: unset or unknown VERCEL_ENV fails closed', () => {
  for (const v of [undefined, '', 'staging', 'Production', 'preview ']) {
    test(`VERCEL_ENV ${JSON.stringify(v)} with a store: no limiter, no rate counter, 500 misconfig, nothing fetched`, async () => {
      let fetches = 0;
      const e = { KV_REST_API_URL: STORE.url, KV_REST_API_TOKEN: STORE.token, VERCEL_ENV: v };
      const l = selectLimiter(e, (async () => { fetches++; return new Response('{}'); }) as typeof fetch);
      assert.equal(l, null);
      const h = deps(l, env(e));
      const r = await handleTts(req('hello'), h.d);
      assert.equal(r.status, 500);
      assert.equal(JSON.parse(r.body.toString('utf8')).reason, 'misconfig');
      assert.equal(fetches, 0);
      assert.equal(h.upstream(), 0);
      assert.throws(() => new RedisUsageLimiter(STORE, { ...limiterOptions(e), dailyCharCap: 9_000, requestsPerMinute: 12 }), TypeError);
    });
  }
});
