/**
 * Fry's question on #287: with no shared Redis store the proxy used a per-instance
 * in-memory limiter, so a deployment holding ELEVENLABS_API_KEY but no store could spend
 * outside the shared 9,000-char day. Now: upstream key set + no store => every path that
 * could call ElevenLabs (owner, Pro) is 500 `misconfig` before any counter write or upstream
 * call, in every VERCEL_ENV, production included (and AERODJ_TTS_ACCEPT_BEST_EFFORT_LIMITS
 * no longer opens it). No key + no store keeps today's behaviour; key + store is unchanged.
 */
import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { defaultDeps, handleTts, nonDurableOverrideHonoured, selectLimiter, upstreamKeyConfigured, type Deps, type Env, type LogEntry, type ProductionDeps, type TtsRequest } from '../src/handler.js';
import { InMemoryUsageLimiter, RedisUsageLimiter, type UsageLimiter } from '../src/limiter.js';
import { proSubjectFromVerified, type ProSubject } from '../src/pro-allowance.js';
import { fakeUpstash } from './redis-lua.js';
import { verifiedTransaction } from './helpers/verified-tx.js';

const TOKEN = 'test-owner-token-not-a-real-secret';
const TOKEN_HASH = crypto.createHash('sha256').update(TOKEN).digest('hex');
const VOICE = 'voiceAllowed123';
const KEY = 'test-elevenlabs-key-not-real';
const STORE = { url: 'https://store.example.upstash.io', token: 'test-store-token-not-real' };
const NOON = Date.UTC(2026, 9, 29, 12);

/** Every VERCEL_ENV shape: the three real ones, unset, empty and unknown. */
const ENVS: (string | undefined)[] = ['production', 'preview', 'development', undefined, '', 'staging'];
/** Store env that does NOT configure a store (selectLimiter's Redis branch is not taken). */
const NO_STORE: [string, Env][] = [
  ['no store env', {}],
  ['URL without a token', { KV_REST_API_URL: STORE.url }],
  ['token without a URL', { KV_REST_API_TOKEN: STORE.token }],
  ['non-https store URL', { KV_REST_API_URL: 'http://store.example.upstash.io', KV_REST_API_TOKEN: STORE.token }],
  ['blank store env', { UPSTASH_REDIS_REST_URL: ' ', UPSTASH_REDIS_REST_TOKEN: ' ' }],
];

function env(o: Env = {}): Env {
  return {
    AERODJ_TTS_TOKEN_SHA256: TOKEN_HASH,
    AERODJ_TTS_VOICE_IDS: VOICE,
    ELEVENLABS_API_KEY: KEY,
    AERODJ_TTS_RATE_PER_MINUTE: '600',
    AERODJ_TTS_PRO_RATE_PER_MINUTE: '600',
    ...o,
  };
}

function pcm(): Response {
  return new Response(Buffer.alloc(22_050 * 2, 1), { status: 200, headers: { 'Content-Type': 'audio/pcm' } });
}

/** Counts every limiter call (allowRequest, reserve, release, reservePro, releasePro). */
function spy(inner: UsageLimiter) {
  let calls = 0;
  const wrap = <A extends unknown[], R>(f: ((...a: A) => R) | undefined) => (f ? (...a: A) => { calls++; return f.apply(inner, a); } : undefined);
  const l = {
    durable: inner.durable,
    allowRequest: wrap(inner.allowRequest),
    reserve: wrap(inner.reserve),
    release: wrap(inner.release),
    ...(inner.reservePro ? { reservePro: wrap(inner.reservePro), releasePro: wrap(inner.releasePro) } : {}),
  } as unknown as UsageLimiter;
  return { l, calls: () => calls };
}

/** Production-shaped deps: no test-only flag. */
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

const req = (verifiedPro?: ProSubject): TtsRequest => ({
  method: 'POST',
  authorization: `Bearer ${TOKEN}`,
  body: { upstream: 'elevenlabs', voiceId: VOICE, text: 'Hello from the DJ booth.', format: 'text' },
  verifiedPro,
});

function expectNoStore(r: Awaited<ReturnType<typeof handleTts>>, logs: LogEntry[], why: string) {
  assert.equal(r.status, 500, why);
  assert.equal(r.headers['Retry-After'], '3600', why);
  assert.deepEqual(JSON.parse(r.body.toString('utf8')), { error: 'Server misconfigured', requestId: 'req-1', reason: 'misconfig', retryAfterSeconds: 3600 }, why);
  assert.deepEqual(logs, [{ requestId: 'req-1', status: 500, chars: 0, reason: 'no_store' }], `${why}: one enum-only log line`);
}

const subject = async () => proSubjectFromVerified(await verifiedTransaction('2000000123456789'));
const label = (v: string | undefined) => `VERCEL_ENV ${JSON.stringify(v)}`;

describe('Fry on #287: ElevenLabs key set, no shared store -> 500 misconfig, zero fetches, every VERCEL_ENV', () => {
  test('selectLimiter picks no limiter (production with ACCEPT_BEST_EFFORT_LIMITS too)', () => {
    for (const v of ENVS) {
      for (const [name, s] of NO_STORE) {
        for (const accept of [{}, { AERODJ_TTS_ACCEPT_BEST_EFFORT_LIMITS: 'true' }]) {
          let fetches = 0;
          const e = { ...s, ...accept, VERCEL_ENV: v, ELEVENLABS_API_KEY: KEY };
          assert.equal(selectLimiter(e, (async () => { fetches++; return new Response('{}'); }) as typeof fetch), null, `${label(v)}, ${name}, ${JSON.stringify(accept)}`);
          assert.equal(fetches, 0);
        }
      }
    }
  });

  for (const v of ENVS) {
    test(`${label(v)}: owner and Pro through selectLimiter are 500 with zero upstream and zero store calls`, async () => {
      for (const [name, s] of NO_STORE) {
        let storeFetches = 0;
        const e = env({ ...s, VERCEL_ENV: v, AERODJ_TTS_ACCEPT_BEST_EFFORT_LIMITS: 'true' });
        const h = deps(selectLimiter(e, (async () => { storeFetches++; return new Response('{}'); }) as typeof fetch), e);
        expectNoStore(await handleTts(req(), h.d), h.logs.splice(0), `${name}: owner`);
        expectNoStore(await handleTts(req(await subject()), h.d), h.logs.splice(0), `${name}: Pro`);
        assert.equal(h.upstream(), 0, 'no ElevenLabs call');
        assert.equal(storeFetches, 0, 'no store call');
      }
    });

    test(`${label(v)}: a non-durable limiter that reaches the handler is refused before any counter or upstream call`, async () => {
      const s = spy(new InMemoryUsageLimiter({ deployment: 'production', dailyCharCap: 9_000, requestsPerMinute: 600 }));
      const h = deps(s.l, env({ VERCEL_ENV: v }));
      expectNoStore(await handleTts(req(), h.d), h.logs.splice(0), 'owner');
      expectNoStore(await handleTts(req(await subject()), h.d), h.logs.splice(0), 'Pro');
      assert.equal(s.calls(), 0, 'no limiter call (no rate or char counter written)');
      assert.equal(h.upstream(), 0, 'no ElevenLabs call');
    });
  }

  test('the key counts as set only when non-blank; a blank key is today\'s "no key" path', () => {
    assert.equal(upstreamKeyConfigured({ ELEVENLABS_API_KEY: KEY }), true);
    assert.equal(upstreamKeyConfigured({ ELEVENLABS_API_KEY: ` ${KEY} ` }), true);
    for (const k of [undefined, '', '   ']) assert.equal(upstreamKeyConfigured({ ELEVENLABS_API_KEY: k }), false, JSON.stringify(k));
  });
});

describe('no ElevenLabs key, no store: today\'s behaviour', () => {
  test('selectLimiter: in-memory outside production, null on production unless best effort is accepted', () => {
    for (const k of [undefined, '', '   ']) {
      assert.equal(selectLimiter({ ELEVENLABS_API_KEY: k })?.durable, false);
      assert.equal(selectLimiter({ ELEVENLABS_API_KEY: k, VERCEL_ENV: 'preview' })?.durable, false);
      assert.equal(selectLimiter({ ELEVENLABS_API_KEY: k, VERCEL_ENV: 'development' })?.durable, false);
      assert.equal(selectLimiter({ ELEVENLABS_API_KEY: k, VERCEL_ENV: 'production' }), null);
      assert.equal(selectLimiter({ ELEVENLABS_API_KEY: k, VERCEL_ENV: 'production', AERODJ_TTS_ACCEPT_BEST_EFFORT_LIMITS: 'true' })?.durable, false);
    }
  });

  for (const v of ENVS) {
    test(`${label(v)}: the handler is the existing 500 misconfig (log reason misconfig), zero limiter and upstream calls`, async () => {
      const e = env({ VERCEL_ENV: v, ELEVENLABS_API_KEY: undefined });
      const selected = selectLimiter(e);
      const s = selected ? spy(selected) : null;
      const h = deps(s?.l ?? null, e);
      for (const r of [await handleTts(req(), h.d), await handleTts(req(await subject()), h.d)]) {
        assert.equal(r.status, 500);
        assert.equal(JSON.parse(r.body.toString('utf8')).reason, 'misconfig');
      }
      assert.deepEqual(h.logs.map((x) => x.reason), ['misconfig', 'misconfig'], 'not the no-store gate');
      assert.equal(s?.calls() ?? 0, 0);
      assert.equal(h.upstream(), 0);
    });
  }
});

describe('ElevenLabs key and store both set: unchanged', () => {
  for (const v of ['production', 'preview', 'development']) {
    test(`${label(v)}: durable limiter, owner and Pro render (200), store charged`, async () => {
      const store = fakeUpstash();
      const e = env({ VERCEL_ENV: v, KV_REST_API_URL: STORE.url, KV_REST_API_TOKEN: STORE.token });
      const selected = selectLimiter(e, store.fetchImpl);
      assert.ok(selected instanceof RedisUsageLimiter);
      const h = deps(selected, e);
      assert.equal((await handleTts(req(), h.d)).status, 200, 'owner');
      assert.equal((await handleTts(req(await subject()), h.d)).status, 200, 'Pro');
      assert.equal(h.upstream(), 2);
      assert.ok(store.calls.length >= 4, `store charged (${store.calls.length} calls)`);
      assert.ok(h.logs.every((x) => x.reason === undefined), JSON.stringify(h.logs));
    });
  }

  test('a durable limiter injected without store env (unit tests) is not refused', async () => {
    const store = fakeUpstash();
    const h = deps(new RedisUsageLimiter(STORE, { deployment: 'production', dailyCharCap: 9_000, requestsPerMinute: 600 }, store.fetchImpl), env({ VERCEL_ENV: 'production' }));
    assert.equal((await handleTts(req(), h.d)).status, 200);
  });

  test('the test-only flag is the only way a non-durable limiter renders with a key set, and only with no VERCEL_ENV', async () => {
    await withProcessEnv({ VERCEL_ENV: undefined }, async () => {
      const h = deps(new InMemoryUsageLimiter({ deployment: 'production', dailyCharCap: 9_000, requestsPerMinute: 600 }), env({ VERCEL_ENV: undefined }));
      assert.equal((await handleTts(req(), h.d)).status, 500, 'no flag');
      assert.equal((await handleTts(req(), { ...h.d, testOnlyAllowNonDurableLimiter: true })).status, 200, 'flag, off-platform');
      const onVercel = { ...h.d, env: env({ VERCEL_ENV: 'production' }), testOnlyAllowNonDurableLimiter: true as const };
      assert.equal((await handleTts(req(), onVercel)).status, 500, 'flag, VERCEL_ENV production');
    });
  });
});

/** Sets (or, with undefined, deletes) process.env keys for the duration of `fn`, then restores them. */
async function withProcessEnv<T>(patch: Env, fn: () => Promise<T> | T): Promise<T> {
  const saved = new Map<string, string | undefined>();
  for (const [k, v] of Object.entries(patch)) {
    saved.set(k, process.env[k]);
    if (v === undefined) delete process.env[k];
    else process.env[k] = v;
  }
  try {
    return await fn();
  } finally {
    for (const [k, v] of saved) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
  }
}

/** Any VERCEL_ENV value counts as "on Vercel": the three real ones, empty and unknown. */
const ON_VERCEL = ['production', 'preview', 'development', '', 'staging'];

describe("Sentinel's nit on #294: the test-only override can never bypass the no-store gate on Vercel", () => {
  for (const v of ON_VERCEL) {
    test(`${label(v)} in deps.env: override ignored, owner and Pro 500 no_store before any counter or upstream call`, async () => {
      await withProcessEnv({ VERCEL_ENV: undefined }, async () => {
        const s = spy(new InMemoryUsageLimiter({ deployment: 'production', dailyCharCap: 9_000, requestsPerMinute: 600 }));
        const h = deps(s.l, env({ VERCEL_ENV: v }));
        const d: Deps = { ...h.d, testOnlyAllowNonDurableLimiter: true };
        expectNoStore(await handleTts(req(), d), h.logs.splice(0), 'owner');
        expectNoStore(await handleTts(req(await subject()), d), h.logs.splice(0), 'Pro');
        assert.equal(s.calls(), 0, 'no limiter call (no rate or char counter written)');
        assert.equal(h.upstream(), 0, 'no ElevenLabs call');
      });
    });

    test(`${label(v)} only in process.env (deps.env has none): override still ignored, 500 no_store, zero calls`, async () => {
      await withProcessEnv({ VERCEL_ENV: v }, async () => {
        const s = spy(new InMemoryUsageLimiter({ deployment: 'production', dailyCharCap: 9_000, requestsPerMinute: 600 }));
        const h = deps(s.l, env({ VERCEL_ENV: undefined }));
        const d: Deps = { ...h.d, testOnlyAllowNonDurableLimiter: true };
        expectNoStore(await handleTts(req(), d), h.logs.splice(0), 'owner');
        expectNoStore(await handleTts(req(await subject()), d), h.logs.splice(0), 'Pro');
        assert.equal(s.calls(), 0, 'no limiter call');
        assert.equal(h.upstream(), 0, 'no ElevenLabs call');
      });
    });
  }

  test('nonDurableOverrideHonoured: true only for the explicit flag with no VERCEL_ENV in deps.env or the runtime env', () => {
    assert.equal(nonDurableOverrideHonoured({ env: {}, testOnlyAllowNonDurableLimiter: true }, {}), true);
    assert.equal(nonDurableOverrideHonoured({ env: { VERCEL_ENV: undefined }, testOnlyAllowNonDurableLimiter: true }, { VERCEL_ENV: undefined }), true);
    assert.equal(nonDurableOverrideHonoured({ env: {} }, {}), false, 'no flag');
    for (const v of ON_VERCEL) {
      assert.equal(nonDurableOverrideHonoured({ env: { VERCEL_ENV: v }, testOnlyAllowNonDurableLimiter: true }, {}), false, `deps.env ${label(v)}`);
      assert.equal(nonDurableOverrideHonoured({ env: {}, testOnlyAllowNonDurableLimiter: true }, { VERCEL_ENV: v }), false, `runtime ${label(v)}`);
    }
  });

  test('the production Deps factory never sets the override, and its result cannot be given one', () => {
    for (const v of [...ON_VERCEL, undefined]) {
      for (const [name, s] of [...NO_STORE, ['store', { KV_REST_API_URL: STORE.url, KV_REST_API_TOKEN: STORE.token }] as [string, Env]]) {
        const d = defaultDeps(env({ ...s, VERCEL_ENV: v }));
        assert.equal(Object.prototype.hasOwnProperty.call(d, 'testOnlyAllowNonDurableLimiter'), false, `${label(v)}, ${name}`);
        assert.equal(d.testOnlyAllowNonDurableLimiter, undefined);
        assert.ok(Object.isFrozen(d), 'frozen');
        assert.throws(() => { (d as unknown as Deps).testOnlyAllowNonDurableLimiter = true; }, TypeError);
        assert.equal(nonDurableOverrideHonoured(d, {}), false);
      }
    }
    // Type level (checked by `tsc --noEmit`): ProductionDeps cannot carry the flag.
    // @ts-expect-error ProductionDeps has testOnlyAllowNonDurableLimiter?: never
    const typed: ProductionDeps = { ...defaultDeps(env()), testOnlyAllowNonDurableLimiter: true };
    assert.ok(typed);
  });
});
