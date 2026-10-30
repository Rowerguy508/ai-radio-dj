/**
 * #264 N5 (Fry): every durable day counter is scoped by deployment (`VERCEL_ENV`), like
 * the Pro keys (Sentinel's B3), so Preview and Production never share the global 9k
 * ceiling, the owner budget or an install budget. Real Lua (test/redis-lua.ts) throughout.
 */
import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { handleTts, limiterOptions, selectLimiter, type Deps, type Env, type LogEntry, type TtsRequest } from '../src/handler.js';
import {
  OWNER_SUBJECT,
  RedisUsageLimiter,
  dayKeys,
  globalDayKey,
  isDeployment,
  proDayKeys,
  subjectBucket,
  type Deployment,
  type LimiterOptions,
  type Subject,
  type UsageLimiter,
} from '../src/limiter.js';
import { PRO_DAILY_RENDER_ALLOWANCE, proBucket, proSubjectFromVerified, type ProSubject } from '../src/pro-allowance.js';
import { FakeRedis, fakeUpstash } from './redis-lua.js';
import { verifiedTransaction } from './helpers/verified-tx.js';

const TOKEN = 'test-owner-token-not-a-real-secret';
const TOKEN_HASH = crypto.createHash('sha256').update(TOKEN).digest('hex');
const VOICE = 'voiceAllowed123';
const STORE = { url: 'https://store.example.upstash.io', token: 'test-store-token-not-real' };
const NOON = Date.UTC(2026, 9, 29, 12);
const DAY = '2026-10-29';
const A: Subject = { kind: 'install', id: 'install-key-id-A' };
const sha = (s: string) => crypto.createHash('sha256').update(s, 'utf8').digest('hex');
const DEPLOYMENTS: Deployment[] = ['production', 'preview', 'development'];
const DAY_TTL_S = 2 * 24 * 60 * 60;

const limiter = (redis: FakeRedis, deployment: Deployment, o: Partial<LimiterOptions> = {}) =>
  new RedisUsageLimiter(STORE, { deployment, dailyCharCap: 9_000, requestsPerMinute: 600, ...o }, fakeUpstash({ redis }).fetchImpl);

function env(o: Env = {}): Env {
  return {
    AERODJ_TTS_TOKEN_SHA256: TOKEN_HASH,
    AERODJ_TTS_VOICE_IDS: VOICE,
    ELEVENLABS_API_KEY: 'test-elevenlabs-key-not-real',
    AERODJ_TTS_RATE_PER_MINUTE: '600',
    AERODJ_TTS_PRO_RATE_PER_MINUTE: '600',
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

describe('#264 N5: key shapes', () => {
  test('global, owner and install day keys carry the deployment, like pro:<deployment>:<sha> (B3)', () => {
    const install = subjectBucket(A).slice('install:'.length);
    for (const d of DEPLOYMENTS) {
      assert.equal(globalDayKey(d, DAY), `aerodj-tts:chars:global:${d}:${DAY}`);
      assert.deepEqual(dayKeys('owner', DAY, d), [`aerodj-tts:chars:owner:${d}:${DAY}`, `aerodj-tts:chars:global:${d}:${DAY}`]);
      assert.deepEqual(dayKeys(subjectBucket(A), DAY, d), [`aerodj-tts:chars:install:${d}:${install}:${DAY}`, `aerodj-tts:chars:global:${d}:${DAY}`]);
      const pro = `pro:${d}:${sha('otid')}`;
      assert.deepEqual(proDayKeys(pro, DAY, d), [`aerodj-tts:chars:global:${d}:${DAY}`, `aerodj-tts:chars:${pro}:${DAY}`, `aerodj-tts:renders:${pro}:${DAY}`]);
    }
  });

  test('no unscoped legacy key is ever built', () => {
    for (const d of DEPLOYMENTS) {
      for (const k of [...dayKeys('owner', DAY, d), ...dayKeys(subjectBucket(A), DAY, d), ...proDayKeys(`pro:${d}:${sha('x')}`, DAY, d)]) {
        assert.notEqual(k, `aerodj-tts:chars:global:${DAY}`);
        assert.notEqual(k, `aerodj-tts:chars:owner:${DAY}`);
        assert.match(k, new RegExp(`:${d}:`));
      }
    }
  });

  for (const bad of [undefined, '', 'staging', 'Production', 'production ', 'global'] as unknown[]) {
    test(`deployment ${JSON.stringify(bad)} is refused everywhere a key is built`, () => {
      assert.equal(isDeployment(bad), false);
      assert.throws(() => globalDayKey(bad as Deployment, DAY), TypeError);
      assert.throws(() => dayKeys('owner', DAY, bad as Deployment), TypeError);
      assert.throws(() => proDayKeys(`pro:production:${sha('x')}`, DAY, bad as Deployment), TypeError);
      assert.throws(() => new RedisUsageLimiter(STORE, { deployment: bad as Deployment, dailyCharCap: 9_000, requestsPerMinute: 12 }), TypeError);
    });
  }

  test('a subject bucket that is neither owner nor a hashed install is refused', () => {
    for (const b of ['global', 'owner:production', 'install:abc', `install:${'A'.repeat(64)}`, `pro:production:${sha('x')}`]) {
      assert.throws(() => dayKeys(b, DAY, 'production'), TypeError, b);
    }
  });

  test('a Pro bucket from another deployment never reaches the store', async () => {
    const redis = new FakeRedis(() => NOON);
    const l = limiter(redis, 'production');
    assert.throws(() => proDayKeys(`pro:preview:${sha('x')}`, DAY, 'production'), TypeError);
    await assert.rejects(l.reservePro({ bucket: `pro:preview:${sha('x')}`, chars: 10, charCap: 100, renderAllowance: 160 }, NOON), TypeError);
    assert.equal(redis.commands.length, 0);
  });
});

describe('#264 N5: preview and production counters are independent', () => {
  test('a full preview global ceiling does not touch production (and the reverse)', async () => {
    const redis = new FakeRedis(() => NOON);
    const prod = limiter(redis, 'production');
    const prev = limiter(redis, 'preview');
    for (let i = 0; i < 15; i++) assert.equal((await prev.reserve(OWNER_SUBJECT, 600, NOON)).ok, true, `preview #${i}`);
    assert.deepEqual(await prev.reserve(OWNER_SUBJECT, 1, NOON), { ok: false, reason: 'owner_daily' });
    assert.deepEqual(await prev.reserve(A, 1, NOON), { ok: false, reason: 'global_daily' });
    // Production still has its whole 9,000.
    for (let i = 0; i < 15; i++) assert.equal((await prod.reserve(OWNER_SUBJECT, 600, NOON)).ok, true, `production #${i}`);
    assert.deepEqual(await prod.reserve(A, 1, NOON), { ok: false, reason: 'global_daily' });
    assert.equal(redis.get(globalDayKey('preview', DAY)), 9_000);
    assert.equal(redis.get(globalDayKey('production', DAY)), 9_000);
    assert.equal(redis.get(`aerodj-tts:chars:global:${DAY}`), 0, 'legacy unscoped key untouched');
  });

  test('install budgets are per deployment too', async () => {
    const redis = new FakeRedis(() => NOON);
    const prod = limiter(redis, 'production');
    const prev = limiter(redis, 'preview');
    assert.equal((await prev.reserve(A, 1_500, NOON)).ok, true);
    assert.deepEqual(await prev.reserve(A, 1, NOON), { ok: false, reason: 'install_daily' });
    assert.equal((await prod.reserve(A, 1_500, NOON)).ok, true);
  });

  test('a refund only returns chars to its own deployment', async () => {
    const redis = new FakeRedis(() => NOON);
    const prod = limiter(redis, 'production');
    const prev = limiter(redis, 'preview');
    const p = await prod.reserve(OWNER_SUBJECT, 500, NOON);
    const q = await prev.reserve(OWNER_SUBJECT, 300, NOON);
    assert.ok(p.ok && q.ok);
    assert.equal(await prev.release(q.reservation), true);
    assert.equal(redis.get(globalDayKey('preview', DAY)), 0);
    assert.equal(redis.get(globalDayKey('production', DAY)), 500);
    assert.equal(redis.get(`aerodj-tts:chars:owner:production:${DAY}`), 500);
  });

  test('Pro: a full preview global ceiling never refuses a production Pro render', async () => {
    const redis = new FakeRedis(() => NOON);
    const prev = limiter(redis, 'preview');
    const prod = limiter(redis, 'production');
    const subject = proSubjectFromVerified(await verifiedTransaction('2000000123456789'));
    for (let i = 0; i < 15; i++) assert.equal((await prev.reserve(OWNER_SUBJECT, 600, NOON)).ok, true);
    const charge = (d: Deployment) => ({ bucket: proBucket(subject, d), chars: 50, charCap: 12_000, renderAllowance: PRO_DAILY_RENDER_ALLOWANCE });
    assert.deepEqual(await prev.reservePro(charge('preview'), NOON), { ok: false, reason: 'global_daily' });
    const r = await prod.reservePro(charge('production'), NOON);
    assert.equal(r.ok, true);
    assert.equal(redis.get(globalDayKey('production', DAY)), 50);
    assert.equal(redis.get(globalDayKey('preview', DAY)), 9_000);
  });

  test('Pro: a preview Pro refund returns chars and the render to preview only', async () => {
    const redis = new FakeRedis(() => NOON);
    const prev = limiter(redis, 'preview');
    const prod = limiter(redis, 'production');
    const subject = proSubjectFromVerified(await verifiedTransaction('2000000123456789'));
    const charge = (d: Deployment) => ({ bucket: proBucket(subject, d), chars: 70, charCap: 12_000, renderAllowance: PRO_DAILY_RENDER_ALLOWANCE });
    const p = await prod.reservePro(charge('production'), NOON);
    const q = await prev.reservePro(charge('preview'), NOON);
    assert.ok(p.ok && q.ok);
    assert.equal(await prev.releasePro(q.reservation), true);
    const [g, c, r] = proDayKeys(proBucket(subject, 'preview'), DAY, 'preview');
    assert.deepEqual([redis.get(g), redis.get(c), redis.get(r)], [0, 0, 0]);
    const [pg, pc, pr] = proDayKeys(proBucket(subject, 'production'), DAY, 'production');
    assert.deepEqual([redis.get(pg), redis.get(pc), redis.get(pr)], [70, 70, 1]);
  });

  test('end to end: preview traffic through selectLimiter never spends the production ceiling', async () => {
    const redis = new FakeRedis(() => NOON);
    const store = fakeUpstash({ redis });
    const base = { KV_REST_API_URL: STORE.url, KV_REST_API_TOKEN: STORE.token, AERODJ_TTS_DAILY_CHAR_CAP: '1200' };
    const prev = deps(selectLimiter({ ...base, VERCEL_ENV: 'preview' }, store.fetchImpl), env({ ...base, VERCEL_ENV: 'preview' }));
    const prod = deps(selectLimiter({ ...base, VERCEL_ENV: 'production' }, store.fetchImpl), env({ ...base, VERCEL_ENV: 'production' }));
    const text = 'x'.repeat(600);
    assert.deepEqual([await handleTts(req(text), prev.d), await handleTts(req(text), prev.d), await handleTts(req(text), prev.d)].map((r) => r.status), [200, 200, 429]);
    assert.deepEqual([await handleTts(req(text), prod.d), await handleTts(req(text), prod.d), await handleTts(req(text), prod.d)].map((r) => r.status), [200, 200, 429]);
    assert.equal(redis.get(globalDayKey('preview', DAY)), 1_200);
    assert.equal(redis.get(globalDayKey('production', DAY)), 1_200);
  });
});

describe('#264 N5: existing cap behaviour is unchanged within one deployment', () => {
  test('9,000 global default, owner = global, 1,500 per install; refusal moves no counter; TTL is still 2 days', async () => {
    const redis = new FakeRedis(() => NOON);
    const l = new RedisUsageLimiter(STORE, limiterOptions({ VERCEL_ENV: 'production' }), fakeUpstash({ redis }).fetchImpl);
    assert.equal((await l.reserve(A, 1_500, NOON)).ok, true);
    assert.deepEqual(await l.reserve(A, 1, NOON), { ok: false, reason: 'install_daily' });
    for (let i = 0; i < 12; i++) assert.equal((await l.reserve(OWNER_SUBJECT, 600, NOON)).ok, true, `#${i}`);
    assert.deepEqual(await l.reserve(OWNER_SUBJECT, 301, NOON), { ok: false, reason: 'global_daily' });
    assert.equal(redis.get(globalDayKey('production', DAY)), 8_700);
    assert.equal(redis.get(`aerodj-tts:chars:owner:production:${DAY}`), 7_200);
    assert.equal((await l.reserve(OWNER_SUBJECT, 300, NOON)).ok, true, 'exactly at the ceiling still fits');
    for (const k of [globalDayKey('production', DAY), `aerodj-tts:chars:owner:production:${DAY}`, dayKeys(subjectBucket(A), DAY, 'production')[0]]) {
      assert.equal(redis.expiresAt.get(k), NOON + DAY_TTL_S * 1000, k);
    }
  });

  test('limiterOptions takes the deployment from VERCEL_ENV on the B3 allow-list only', () => {
    for (const d of DEPLOYMENTS) assert.equal(limiterOptions({ VERCEL_ENV: d }).deployment, d);
    for (const v of [undefined, '', 'staging', 'Production', ' preview']) assert.equal(limiterOptions({ VERCEL_ENV: v }).deployment, undefined, String(v));
  });
});

describe('#264 N5: unset or unknown VERCEL_ENV fails closed (as B3)', () => {
  for (const v of [undefined, '', 'staging', 'Production', 'preview ']) {
    test(`VERCEL_ENV ${JSON.stringify(v)} with a store: no limiter, owner and Pro requests are 500 misconfig, no store or upstream call`, async () => {
      let fetches = 0;
      const e = { KV_REST_API_URL: STORE.url, KV_REST_API_TOKEN: STORE.token, VERCEL_ENV: v };
      assert.equal(selectLimiter(e, (async () => { fetches++; return new Response('{}'); }) as typeof fetch), null);
      const h = deps(null, env(e));
      const subject = proSubjectFromVerified(await verifiedTransaction('2000000123456789'));
      for (const r of [await handleTts(req('hello'), h.d), await handleTts(req('hello', subject), h.d)]) {
        assert.equal(r.status, 500);
        assert.equal(JSON.parse(r.body.toString('utf8')).reason, 'misconfig');
      }
      assert.equal(fetches, 0);
      assert.equal(h.upstream(), 0);
    });
  }

  test('control: each allowed VERCEL_ENV with a store selects the durable limiter', () => {
    for (const d of DEPLOYMENTS) assert.equal(selectLimiter({ KV_REST_API_URL: STORE.url, KV_REST_API_TOKEN: STORE.token, VERCEL_ENV: d })?.durable, true, d);
  });

  test('no store: the in-memory paths are unchanged (nothing shared, so nothing to scope)', () => {
    assert.equal(selectLimiter({})?.durable, false);
    assert.equal(selectLimiter({ VERCEL_ENV: 'preview' })?.durable, false);
    assert.equal(selectLimiter({ VERCEL_ENV: 'production' }), null);
  });
});
