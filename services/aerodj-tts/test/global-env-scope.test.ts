/**
 * #264 N5 (Fry): the owner, install and Pro day counters are scoped by deployment
 * (`VERCEL_ENV`), like the Pro keys (Sentinel's B3).
 * #287 B1 (Sentinel): the GLOBAL ceiling is one account-wide key shared by every
 * deployment (the pre-#287 name), so Production + Preview + Development together never
 * pass it, and Preview / Development each get a low env-scoped sub-cap (default and max
 * 1,000) charged on top of the shared key. Real Lua (test/redis-lua.ts) throughout.
 */
import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { handleTts, limiterOptions, selectLimiter, type Deps, type Env, type LogEntry, type TtsRequest } from '../src/handler.js';
import {
  DEFAULT_NONPROD_DAILY_CHAR_CAP,
  OWNER_SUBJECT,
  RedisUsageLimiter,
  dayKeys,
  effectiveNonprodCap,
  envDayKey,
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

const LEGACY_GLOBAL = `aerodj-tts:chars:global:${DAY}`;
const PRE_287_GLOBAL = (day: string) => `aerodj-tts:chars:global:${day}`;

describe('#287 B1: key shapes', () => {
  test('the global key is the pre-#287 name, shared by every deployment', () => {
    assert.equal(globalDayKey(DAY), LEGACY_GLOBAL);
    assert.equal(globalDayKey('2026-01-01'), PRE_287_GLOBAL('2026-01-01'));
    for (const d of DEPLOYMENTS) {
      assert.equal(dayKeys('owner', DAY, d)[1], LEGACY_GLOBAL, d);
      assert.equal(dayKeys(subjectBucket(A), DAY, d)[1], LEGACY_GLOBAL, d);
      assert.equal(proDayKeys(`pro:${d}:${sha('otid')}`, DAY, d)[0], LEGACY_GLOBAL, d);
    }
  });

  test('owner, install and Pro day keys carry the deployment (#264 N5)', () => {
    const install = subjectBucket(A).slice('install:'.length);
    for (const d of DEPLOYMENTS) {
      assert.deepEqual(dayKeys('owner', DAY, d), [`aerodj-tts:chars:owner:${d}:${DAY}`, LEGACY_GLOBAL]);
      assert.deepEqual(dayKeys(subjectBucket(A), DAY, d), [`aerodj-tts:chars:install:${d}:${install}:${DAY}`, LEGACY_GLOBAL]);
      const pro = `pro:${d}:${sha('otid')}`;
      assert.deepEqual(proDayKeys(pro, DAY, d), [LEGACY_GLOBAL, `aerodj-tts:chars:${pro}:${DAY}`, `aerodj-tts:renders:${pro}:${DAY}`]);
    }
  });

  test('the non-production sub-cap key is env-scoped; Production has none', () => {
    assert.equal(envDayKey('production', DAY), null);
    assert.equal(envDayKey('preview', DAY), `aerodj-tts:chars:env:preview:${DAY}`);
    assert.equal(envDayKey('development', DAY), `aerodj-tts:chars:env:development:${DAY}`);
  });

  test('the per-env global keys from 271ebe2 are never built', () => {
    for (const d of DEPLOYMENTS) {
      for (const k of [...dayKeys('owner', DAY, d), ...dayKeys(subjectBucket(A), DAY, d), ...proDayKeys(`pro:${d}:${sha('x')}`, DAY, d)]) {
        assert.notEqual(k, `aerodj-tts:chars:global:${d}:${DAY}`);
        assert.notEqual(k, `aerodj-tts:chars:owner:${DAY}`);
      }
    }
  });

  for (const bad of [undefined, '', 'staging', 'Production', 'production ', 'global'] as unknown[]) {
    test(`deployment ${JSON.stringify(bad)} is refused everywhere a key is built`, () => {
      assert.equal(isDeployment(bad), false);
      assert.throws(() => envDayKey(bad as Deployment, DAY), TypeError);
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

describe('#287 B1: the non-production sub-cap is configurable only downward', () => {
  test('effectiveNonprodCap: default 1,000; lower values used; higher or invalid -> 1,000', () => {
    assert.equal(DEFAULT_NONPROD_DAILY_CHAR_CAP, 1_000);
    for (const [v, want] of [[undefined, 1_000], [1, 1], [250, 250], [1_000, 1_000], [1_001, 1_000], [9_000, 1_000], [0, 1_000], [-5, 1_000], [1.5, 1_000], [Number.NaN, 1_000]] as const) {
      assert.equal(effectiveNonprodCap(v), want, String(v));
    }
  });

  test('limiterOptions reads AERODJ_TTS_NONPROD_DAILY_CHAR_CAP on Preview/Development only, clamped to 1,000', () => {
    for (const d of ['preview', 'development'] as const) {
      assert.equal(limiterOptions({ VERCEL_ENV: d }).nonprodDailyCharCap, 1_000, d);
      assert.equal(limiterOptions({ VERCEL_ENV: d, AERODJ_TTS_NONPROD_DAILY_CHAR_CAP: '300' }).nonprodDailyCharCap, 300, d);
      assert.equal(limiterOptions({ VERCEL_ENV: d, AERODJ_TTS_NONPROD_DAILY_CHAR_CAP: '5000' }).nonprodDailyCharCap, 1_000, d);
      for (const bad of ['0', '-1', 'abc', '', '1e3']) assert.equal(limiterOptions({ VERCEL_ENV: d, AERODJ_TTS_NONPROD_DAILY_CHAR_CAP: bad }).nonprodDailyCharCap, 1_000, `${d} ${bad}`);
    }
    assert.equal(limiterOptions({ VERCEL_ENV: 'production', AERODJ_TTS_NONPROD_DAILY_CHAR_CAP: '300' }).nonprodDailyCharCap, undefined);
  });

  test('a RedisUsageLimiter built with a higher sub-cap still stops at 1,000', async () => {
    const redis = new FakeRedis(() => NOON);
    const prev = limiter(redis, 'preview', { nonprodDailyCharCap: 50_000 });
    assert.equal((await prev.reserve(OWNER_SUBJECT, 600, NOON)).ok, true);
    assert.equal((await prev.reserve(OWNER_SUBJECT, 400, NOON)).ok, true);
    const before = [...redis.data.entries()];
    assert.deepEqual(await prev.reserve(OWNER_SUBJECT, 1, NOON), { ok: false, reason: 'global_daily' });
    assert.deepEqual([...redis.data.entries()], before, 'sub-cap refusal moves no counter (shared key included)');
    assert.equal(redis.get(LEGACY_GLOBAL), 1_000);
  });
});

describe('#287 B1: every deployment together never passes the global ceiling', () => {
  test('production + preview + development combined stop at 9,000 on the one shared key', async () => {
    const redis = new FakeRedis(() => NOON);
    const prod = limiter(redis, 'production');
    const prev = limiter(redis, 'preview');
    const dev = limiter(redis, 'development');
    let granted = 0;
    // Round-robin until every deployment is refused.
    for (let i = 0; i < 60; i++) {
      for (const l of [prod, prev, dev]) {
        const r = await l.reserve(i % 2 ? A : OWNER_SUBJECT, 300, NOON);
        if (r.ok) granted += 300;
      }
    }
    assert.ok(granted <= 9_000, `granted ${granted}`);
    assert.equal(granted, 9_000);
    assert.equal(redis.get(LEGACY_GLOBAL), 9_000);
    assert.ok(redis.get(envDayKey('preview', DAY)!) <= 1_000);
    assert.ok(redis.get(envDayKey('development', DAY)!) <= 1_000);
    assert.equal(redis.get(`aerodj-tts:chars:global:production:${DAY}`), 0, 'no per-env global key');
  });

  test('non-production spend counts against the shared key: production gets what is left', async () => {
    const redis = new FakeRedis(() => NOON);
    const prod = limiter(redis, 'production');
    const prev = limiter(redis, 'preview');
    const dev = limiter(redis, 'development');
    assert.equal((await prev.reserve(OWNER_SUBJECT, 1_000, NOON)).ok, true);
    assert.equal((await dev.reserve(OWNER_SUBJECT, 1_000, NOON)).ok, true);
    assert.equal(redis.get(LEGACY_GLOBAL), 2_000);
    for (let i = 0; i < 11; i++) assert.equal((await prod.reserve(OWNER_SUBJECT, 600, NOON)).ok, true, `#${i}`);
    assert.equal((await prod.reserve(OWNER_SUBJECT, 400, NOON)).ok, true);
    assert.deepEqual(await prod.reserve(OWNER_SUBJECT, 1, NOON), { ok: false, reason: 'global_daily' });
    assert.equal(redis.get(LEGACY_GLOBAL), 9_000);
  });

  test('production spend counts for non-production too: a full global key refuses preview', async () => {
    const redis = new FakeRedis(() => NOON);
    const prod = limiter(redis, 'production');
    const prev = limiter(redis, 'preview');
    for (let i = 0; i < 15; i++) assert.equal((await prod.reserve(OWNER_SUBJECT, 600, NOON)).ok, true);
    const before = [...redis.data.entries()];
    assert.deepEqual(await prev.reserve(OWNER_SUBJECT, 1, NOON), { ok: false, reason: 'global_daily' });
    assert.deepEqual([...redis.data.entries()], before, 'refusal moves no counter');
  });

  test('Pro on preview is charged to the shared key and the sub-cap too', async () => {
    const redis = new FakeRedis(() => NOON);
    const prev = limiter(redis, 'preview');
    const prod = limiter(redis, 'production');
    const subject = proSubjectFromVerified(await verifiedTransaction('2000000123456789'));
    const charge = (d: Deployment, chars: number) => ({ bucket: proBucket(subject, d), chars, charCap: 12_000, renderAllowance: PRO_DAILY_RENDER_ALLOWANCE });
    assert.equal((await prev.reservePro(charge('preview', 600), NOON)).ok, true);
    assert.equal((await prev.reservePro(charge('preview', 400), NOON)).ok, true);
    const before = [...redis.data.entries()];
    assert.deepEqual(await prev.reservePro(charge('preview', 1), NOON), { ok: false, reason: 'global_daily' });
    assert.deepEqual([...redis.data.entries()], before, 'sub-cap refusal moves no counter (renders included)');
    assert.equal(redis.get(LEGACY_GLOBAL), 1_000);
    assert.equal(redis.get(envDayKey('preview', DAY)!), 1_000);
    // Production Pro sees the 1,000 already on the shared key.
    for (let i = 0; i < 13; i++) assert.equal((await prod.reservePro(charge('production', 600), NOON)).ok, true, `#${i}`);
    assert.deepEqual(await prod.reservePro(charge('production', 201), NOON), { ok: false, reason: 'global_daily' });
    assert.equal(redis.get(LEGACY_GLOBAL), 8_800);
  });

  test('end to end through selectLimiter: three deployments on one store never pass 9,000', async () => {
    const redis = new FakeRedis(() => NOON);
    const store = fakeUpstash({ redis });
    const base = { KV_REST_API_URL: STORE.url, KV_REST_API_TOKEN: STORE.token, AERODJ_TTS_RATE_PER_MINUTE: '600' };
    const hs = DEPLOYMENTS.map((d) => deps(selectLimiter({ ...base, VERCEL_ENV: d }, store.fetchImpl), env({ ...base, VERCEL_ENV: d })));
    const text = 'x'.repeat(600);
    const ok: number[] = [0, 0, 0];
    for (let i = 0; i < 20; i++) for (const [j, h] of hs.entries()) if ((await handleTts(req(text), h.d)).status === 200) ok[j]++;
    assert.deepEqual(ok, [13, 1, 1], 'production 13 x 600 = 7,800; preview and development 1 x 600 each (sub-cap 1,000)');
    assert.equal(ok.reduce((a, b) => a + b) * 600, 9_000);
    assert.equal(redis.get(LEGACY_GLOBAL), 9_000);
    assert.equal(hs.reduce((n, h) => n + h.upstream(), 0), 15);
  });
});

describe('#287 B1: refunds return chars to the shared key and to the sub-cap', () => {
  test('a preview refund restores the shared key and the preview sub-cap, not production', async () => {
    const redis = new FakeRedis(() => NOON);
    const prod = limiter(redis, 'production');
    const prev = limiter(redis, 'preview');
    const p = await prod.reserve(OWNER_SUBJECT, 500, NOON);
    const q = await prev.reserve(OWNER_SUBJECT, 300, NOON);
    assert.ok(p.ok && q.ok);
    assert.equal(await prev.release(q.reservation), true);
    assert.equal(await prev.release(q.reservation), false, 'once only');
    assert.equal(redis.get(LEGACY_GLOBAL), 500);
    assert.equal(redis.get(envDayKey('preview', DAY)!), 0);
    assert.equal(redis.get(`aerodj-tts:chars:owner:production:${DAY}`), 500);
    assert.equal(redis.get(`aerodj-tts:chars:owner:preview:${DAY}`), 0);
  });

  test('a preview Pro refund restores chars and the render on preview only', async () => {
    const redis = new FakeRedis(() => NOON);
    const prev = limiter(redis, 'preview');
    const prod = limiter(redis, 'production');
    const subject = proSubjectFromVerified(await verifiedTransaction('2000000123456789'));
    const charge = (d: Deployment) => ({ bucket: proBucket(subject, d), chars: 70, charCap: 12_000, renderAllowance: PRO_DAILY_RENDER_ALLOWANCE });
    const p = await prod.reservePro(charge('production'), NOON);
    const q = await prev.reservePro(charge('preview'), NOON);
    assert.ok(p.ok && q.ok);
    assert.equal(await prev.releasePro(q.reservation), true);
    const [, c, r] = proDayKeys(proBucket(subject, 'preview'), DAY, 'preview');
    assert.deepEqual([redis.get(c), redis.get(r), redis.get(envDayKey('preview', DAY)!)], [0, 0, 0]);
    const [, pc, pr] = proDayKeys(proBucket(subject, 'production'), DAY, 'production');
    assert.deepEqual([redis.get(LEGACY_GLOBAL), redis.get(pc), redis.get(pr)], [70, 70, 1]);
  });
});

describe('#264 N5 / #287 B1: owner, install and Pro budgets stay per deployment', () => {
  test('install budgets are per deployment', async () => {
    const redis = new FakeRedis(() => NOON);
    const prod = limiter(redis, 'production');
    const dev = limiter(redis, 'development', { installDailyCharCap: 500 });
    assert.equal((await dev.reserve(A, 500, NOON)).ok, true);
    assert.deepEqual(await dev.reserve(A, 1, NOON), { ok: false, reason: 'install_daily' });
    assert.equal((await prod.reserve(A, 1_500, NOON)).ok, true, 'production install budget untouched');
  });

  test('owner budgets are per deployment', async () => {
    const redis = new FakeRedis(() => NOON);
    const prod = limiter(redis, 'production', { ownerDailyCharCap: 700 });
    const prev = limiter(redis, 'preview', { ownerDailyCharCap: 700 });
    assert.equal((await prev.reserve(OWNER_SUBJECT, 700, NOON)).ok, true);
    assert.deepEqual(await prev.reserve(OWNER_SUBJECT, 1, NOON), { ok: false, reason: 'owner_daily' });
    assert.equal((await prod.reserve(OWNER_SUBJECT, 700, NOON)).ok, true);
  });
});

describe('#287 B1: Production behaviour is the pre-#287 behaviour', () => {
  test('9,000 global default, owner = global, 1,500 per install; refusal moves no counter; TTL is still 2 days', async () => {
    const redis = new FakeRedis(() => NOON);
    const l = new RedisUsageLimiter(STORE, limiterOptions({ VERCEL_ENV: 'production' }), fakeUpstash({ redis }).fetchImpl);
    assert.equal((await l.reserve(A, 1_500, NOON)).ok, true);
    assert.deepEqual(await l.reserve(A, 1, NOON), { ok: false, reason: 'install_daily' });
    for (let i = 0; i < 12; i++) assert.equal((await l.reserve(OWNER_SUBJECT, 600, NOON)).ok, true, `#${i}`);
    assert.deepEqual(await l.reserve(OWNER_SUBJECT, 301, NOON), { ok: false, reason: 'global_daily' });
    assert.equal(redis.get(LEGACY_GLOBAL), 8_700);
    assert.equal(redis.get(`aerodj-tts:chars:owner:production:${DAY}`), 7_200);
    assert.equal((await l.reserve(OWNER_SUBJECT, 300, NOON)).ok, true, 'exactly at the ceiling still fits');
    for (const k of [LEGACY_GLOBAL, `aerodj-tts:chars:owner:production:${DAY}`, dayKeys(subjectBucket(A), DAY, 'production')[0]]) {
      assert.equal(redis.expiresAt.get(k), NOON + DAY_TTL_S * 1000, k);
    }
    assert.ok(![...redis.data.keys()].some((k) => k.includes(':env:')), 'production writes no sub-cap key');
  });

  test('deploy day: production keeps the pre-#287 global count (no reset, no doubling)', async () => {
    const redis = new FakeRedis(() => NOON);
    redis.data.set(PRE_287_GLOBAL(DAY), '8500'); // spent today before the deploy
    const l = new RedisUsageLimiter(STORE, limiterOptions({ VERCEL_ENV: 'production' }), fakeUpstash({ redis }).fetchImpl);
    assert.equal((await l.reserve(OWNER_SUBJECT, 500, NOON)).ok, true);
    assert.deepEqual(await l.reserve(OWNER_SUBJECT, 1, NOON), { ok: false, reason: 'global_daily' });
    assert.equal(redis.get(PRE_287_GLOBAL(DAY)), 9_000);
  });

  test('the sub-cap TTL is the same 2 days', async () => {
    const redis = new FakeRedis(() => NOON);
    const prev = limiter(redis, 'preview');
    assert.equal((await prev.reserve(OWNER_SUBJECT, 10, NOON)).ok, true);
    assert.equal(redis.expiresAt.get(envDayKey('preview', DAY)!), NOON + DAY_TTL_S * 1000);
  });

  test('on Production a -5 store reply is a store fault, never a refusal', async () => {
    const fetchImpl = (async () => new Response(JSON.stringify({ result: -5 }), { status: 200 })) as typeof fetch;
    const l = new RedisUsageLimiter(STORE, { deployment: 'production', dailyCharCap: 9_000, requestsPerMinute: 12 }, fetchImpl);
    await assert.rejects(l.reserve(OWNER_SUBJECT, 1, NOON), (e: Error) => e.name === 'LimiterStoreError' || /store/.test(e.message));
    const p = new RedisUsageLimiter(STORE, { deployment: 'preview', dailyCharCap: 9_000, requestsPerMinute: 12 }, fetchImpl);
    assert.deepEqual(await p.reserve(OWNER_SUBJECT, 1, NOON), { ok: false, reason: 'global_daily' });
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
