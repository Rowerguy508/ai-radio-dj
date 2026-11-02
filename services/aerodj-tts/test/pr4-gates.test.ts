/**
 * #233 PR 4 gates, from the #250 reviews:
 * - Sentinel (6511622448): install reservations return 503 `store` without Redis, shown
 *   through the real `selectLimiter` and a real `RedisUsageLimiter` whose store is down.
 * - Fry N2 (6511617659): the Redis refund result is checked: any EVAL result other than
 *   0 or 1 rejects with `LimiterStoreError`, 1 is `true`, 0 is `false`.
 * - Sentinel's nit: a non-store throw from `reserve` is 500 `misconfig` with
 *   `Retry-After: 3600` (install gate and owner `/api/tts`), never a bare platform 500.
 */
import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { handleTts, selectLimiter, type Deps, type Env, type LogEntry, type TtsRequest } from '../src/handler.js';
import {
  InMemoryUsageLimiter,
  LimiterStoreError,
  RedisUsageLimiter,
  subjectBucket,
  type Reservation,
  type UsageLimiter,
} from '../src/limiter.js';
import { reserveForInstall } from '../src/install-quota.js';
import { fakeUpstash } from './redis-lua.js';
import { UPSTASH_FETCH_TIMEOUT_MS } from '../src/upstash.js';

const TOKEN = 'test-owner-token-not-a-real-secret';
const TOKEN_HASH = crypto.createHash('sha256').update(TOKEN).digest('hex');
const VOICE = 'voiceAllowed123';
const STORE = { url: 'https://store.example.upstash.io', token: 'test-store-token-not-real' };
const OPTIONS = { deployment: 'production' as const, dailyCharCap: 9_000, requestsPerMinute: 100 };
const NOON = Date.UTC(2026, 9, 29, 12);
const DAY = '2026-10-29';
const KEY_ID = crypto.createHash('sha256').update('install A').digest('base64');

const STORE_REFUSAL = { ok: false, status: 503, reason: 'store', retryAfterSeconds: 30 };
const MISCONFIG_REFUSAL = { ok: false, status: 500, reason: 'misconfig', retryAfterSeconds: 3600 };

/** Counts every limiter call; wraps a real limiter. */
function spyLimiter(inner: UsageLimiter) {
  let calls = 0;
  const limiter: UsageLimiter = {
    durable: inner.durable,
    allowRequest: (b, n) => { calls++; return inner.allowRequest(b, n); },
    reserve: (s, c, n) => { calls++; return inner.reserve(s, c, n); },
    release: (r) => { calls++; return inner.release(r); },
  };
  return { limiter, calls: () => calls };
}

/** A fetch that answers every Upstash EVAL with `payload` (HTTP 200) and counts calls. */
function evalReturning(payload: unknown) {
  let calls = 0;
  const fetchImpl = (async () => {
    calls++;
    return new Response(JSON.stringify(payload), { status: 200, headers: { 'Content-Type': 'application/json' } });
  }) as typeof fetch;
  return { fetchImpl, calls: () => calls };
}

const reservation = (): Reservation => ({ rid: crypto.randomUUID(), bucket: subjectBucket({ kind: 'install', id: KEY_ID }), day: DAY, chars: 100 });

// ---------------------------------------------------------------------------
describe('install reserve without Redis → 503 store (Sentinel, #250)', () => {
  const NO_REDIS_ENVS: [string, Env][] = [
    ['no store env, local dev', {}],
    ['no store env, preview', { VERCEL_ENV: 'preview' }],
    ['no store env, production', { VERCEL_ENV: 'production' }],
    ['no store env, production with ACCEPT_BEST_EFFORT=true', { VERCEL_ENV: 'production', AERODJ_TTS_ACCEPT_BEST_EFFORT_LIMITS: 'true' }],
    ['URL without a token', { KV_REST_API_URL: STORE.url }],
    ['token without a URL', { KV_REST_API_TOKEN: STORE.token }],
    ['non-https store URL', { KV_REST_API_URL: 'http://store.example.upstash.io', KV_REST_API_TOKEN: STORE.token }],
    ['blank store env', { UPSTASH_REDIS_REST_URL: ' ', UPSTASH_REDIS_REST_TOKEN: ' ' }],
  ];

  for (const [name, e] of NO_REDIS_ENVS) {
    test(`selectLimiter: ${name} → reserveForInstall is 503 store with zero limiter and zero store calls`, async () => {
      let fetches = 0;
      const selected = selectLimiter(e, (async () => { fetches++; return new Response('{}'); }) as typeof fetch);
      assert.ok(!(selected instanceof RedisUsageLimiter), 'no Redis configured');
      const spy = selected ? spyLimiter(selected) : null;
      assert.deepEqual(await reserveForInstall(spy?.limiter ?? null, KEY_ID, 100, NOON), STORE_REFUSAL);
      assert.equal(spy?.calls() ?? 0, 0, 'no limiter call');
      assert.equal(fetches, 0, 'no store call');
    });
  }

  test('control: a configured store selects the durable limiter and the same gate reserves', async () => {
    const store = fakeUpstash();
    const selected = selectLimiter({ KV_REST_API_URL: STORE.url, KV_REST_API_TOKEN: STORE.token, VERCEL_ENV: 'production' }, store.fetchImpl);
    assert.ok(selected instanceof RedisUsageLimiter);
    const r = await reserveForInstall(selected, KEY_ID, 100, NOON);
    assert.equal(r.ok, true);
    assert.equal(store.calls.length, 1);
  });

  test('Redis configured but unreachable (fetch throws) → 503 store', async () => {
    const limiter = new RedisUsageLimiter(STORE, OPTIONS, (async () => { throw new Error('ECONNREFUSED'); }) as typeof fetch);
    assert.deepEqual(await reserveForInstall(limiter, KEY_ID, 100, NOON), STORE_REFUSAL);
  });

  for (const status of [401, 429, 500, 502, 503]) {
    test(`Redis answers HTTP ${status} → 503 store`, async () => {
      const limiter = new RedisUsageLimiter(STORE, OPTIONS, fakeUpstash({ status }).fetchImpl);
      assert.deepEqual(await reserveForInstall(limiter, KEY_ID, 100, NOON), STORE_REFUSAL);
    });
  }

  for (const [name, payload] of [
    ['an error payload', { error: 'ERR script' }],
    ['an error payload that also carries a numeric result', { error: 'ERR script', result: 1 }],
    ['no result', {}],
    ['a non-numeric result', { result: 'x' }],
    ['a null body', null],
    ['an unknown negative RESERVE2 result', { result: -3 }],
  ] as [string, unknown][]) {
    test(`Redis returns ${name} for RESERVE2 → 503 store`, async () => {
      const limiter = new RedisUsageLimiter(STORE, OPTIONS, evalReturning(payload).fetchImpl);
      assert.deepEqual(await reserveForInstall(limiter, KEY_ID, 100, NOON), STORE_REFUSAL);
    });
  }
});

// ---------------------------------------------------------------------------
describe('Redis refund result is checked (Fry N2, #250)', () => {
  test('EVAL 1 → true (refund applied), EVAL 0 → false (already refunded)', async () => {
    assert.equal(await new RedisUsageLimiter(STORE, OPTIONS, evalReturning({ result: 1 }).fetchImpl).release(reservation()), true);
    assert.equal(await new RedisUsageLimiter(STORE, OPTIONS, evalReturning({ result: 0 }).fetchImpl).release(reservation()), false);
  });

  for (const result of [2, -1, 0.5, '2', 'x', -0.5, 1e9]) {
    test(`EVAL ${JSON.stringify(result)} → release rejects with LimiterStoreError (not "already refunded")`, async () => {
      const store = evalReturning({ result });
      const limiter = new RedisUsageLimiter(STORE, OPTIONS, store.fetchImpl);
      await assert.rejects(limiter.release(reservation()), LimiterStoreError);
      assert.equal(store.calls(), 1);
    });
  }

  test('an error payload that also carries result 1 → release rejects (never read as "refund applied")', async () => {
    const limiter = new RedisUsageLimiter(STORE, OPTIONS, evalReturning({ error: 'ERR script', result: 1 }).fetchImpl);
    await assert.rejects(limiter.release(reservation()), LimiterStoreError);
  });

  test('refund sequence on the real RELEASE2 Lua: true, then false, never anything else', async () => {
    const store = fakeUpstash();
    const limiter = new RedisUsageLimiter(STORE, OPTIONS, store.fetchImpl);
    const r = await limiter.reserve({ kind: 'install', id: KEY_ID }, 100, NOON);
    assert.ok(r.ok);
    assert.strictEqual(await limiter.release(r.reservation), true);
    assert.strictEqual(await limiter.release(r.reservation), false);
  });
});

// ---------------------------------------------------------------------------
describe('non-store reserve throw → 500 misconfig, Retry-After 3600 (Sentinel nit, #250)', () => {
  const throwing = (thrown: unknown): UsageLimiter => ({
    durable: true,
    allowRequest: async () => true,
    reserve: async () => { throw thrown; },
    release: async () => true,
  });
  class SubclassedStoreError extends LimiterStoreError {}

  const NON_STORE: [string, unknown][] = [
    ['TypeError', new TypeError('bug')],
    ['RangeError', new RangeError('bug')],
    ['plain Error', new Error('bug')],
    ['a thrown string', 'bug'],
    ['a thrown undefined', undefined],
  ];

  for (const [name, thrown] of NON_STORE) {
    test(`install gate: ${name} → 500 misconfig, never rethrown`, async () => {
      assert.deepEqual(await reserveForInstall(throwing(thrown), KEY_ID, 100, NOON), MISCONFIG_REFUSAL);
    });
  }

  test('install gate: LimiterStoreError (and a subclass) stays 503 store', async () => {
    assert.deepEqual(await reserveForInstall(throwing(new LimiterStoreError('x')), KEY_ID, 100, NOON), STORE_REFUSAL);
    assert.deepEqual(await reserveForInstall(throwing(new SubclassedStoreError('x')), KEY_ID, 100, NOON), STORE_REFUSAL);
  });

  test('install gate, real Redis limiter: an invalid install id → 500 misconfig with zero store calls', async () => {
    const store = fakeUpstash();
    const limiter = new RedisUsageLimiter(STORE, OPTIONS, store.fetchImpl);
    for (const bad of ['', 'x'.repeat(257)]) {
      assert.deepEqual(await reserveForInstall(limiter, bad, 100, NOON), MISCONFIG_REFUSAL, `len ${bad.length}`);
    }
    assert.equal(store.calls.length, 0);
  });

  // Owner /api/tts reserve (handler.ts): the same mapping, before any ElevenLabs call.
  const env: Env = { AERODJ_TTS_TOKEN_SHA256: TOKEN_HASH, AERODJ_TTS_VOICE_IDS: VOICE, ELEVENLABS_API_KEY: 'test-elevenlabs-key-not-real' };
  const req: TtsRequest = {
    method: 'POST',
    authorization: `Bearer ${TOKEN}`,
    body: { upstream: 'elevenlabs', voiceId: VOICE, text: 'Hello from the DJ booth.', format: 'text' },
  };
  const run = async (limiter: UsageLimiter) => {
    const logs: LogEntry[] = [];
    let upstream = 0;
    const deps: Deps = {
      env,
      fetch: (async () => { upstream++; return new Response(Buffer.alloc(44_100, 1), { status: 200 }); }) as typeof fetch,
      limiter,
      log: (e) => logs.push(e),
      now: () => NOON,
      timeoutMs: 50,
      requestId: () => 'req-1',
      // Test-only: these harnesses drive the handler with an in-memory/spy limiter (Fry on #287 gate).
      testOnlyAllowNonDurableLimiter: true,
    };
    const res = await handleTts(req, deps);
    return { res, logs, upstream };
  };
  const chars = 'Hello from the DJ booth.'.length;

  for (const [name, thrown] of NON_STORE) {
    test(`owner /api/tts: reserve throws ${name} → 500 misconfig, Retry-After 3600, enum-only body and log, zero ElevenLabs calls`, async () => {
      const { res, logs, upstream } = await run(throwing(thrown));
      assert.equal(res.status, 500);
      assert.equal(res.headers['Retry-After'], '3600');
      assert.deepEqual(JSON.parse(res.body.toString('utf8')), { error: 'Server misconfigured', requestId: 'req-1', reason: 'misconfig', retryAfterSeconds: 3600 });
      assert.deepEqual(logs, [{ requestId: 'req-1', status: 500, chars, reason: 'misconfig' }]);
      assert.equal(upstream, 0);
    });
  }

  test('owner /api/tts: reserve throws LimiterStoreError → still 503 store (Retry-After 30, note §4.4), zero ElevenLabs calls', async () => {
    const { res, upstream } = await run(throwing(new LimiterStoreError('x')));
    assert.equal(res.status, 503);
    assert.equal(res.headers['Retry-After'], '30');
    assert.deepEqual(JSON.parse(res.body.toString('utf8')).retryAfterSeconds, 30);
    assert.equal(JSON.parse(res.body.toString('utf8')).reason, 'store');
    assert.equal(upstream, 0);
  });

  test('control: a working reserve still renders (200)', async () => {
    const { res, upstream } = await run(new InMemoryUsageLimiter(OPTIONS));
    assert.equal(res.status, 200);
    assert.equal(upstream, 1);
  });
});

const TTS_CHARS = 'Hello from the DJ booth.'.length;
// Module-level owner /api/tts runner for the strict-integer table (upstream status configurable).
async function runTts(limiter: UsageLimiter, upstreamStatus = 200) {
  const env: Env = { AERODJ_TTS_TOKEN_SHA256: TOKEN_HASH, AERODJ_TTS_VOICE_IDS: VOICE, ELEVENLABS_API_KEY: 'test-elevenlabs-key-not-real' };
  const req: TtsRequest = { method: 'POST', authorization: `Bearer ${TOKEN}`, body: { upstream: 'elevenlabs', voiceId: VOICE, text: 'Hello from the DJ booth.', format: 'text' } };
  let upstream = 0;
  const deps: Deps = {
    env,
    fetch: (async () => { upstream++; return new Response(Buffer.alloc(44_100, 1), { status: upstreamStatus }); }) as typeof fetch,
    limiter, log: () => {}, now: () => NOON, timeoutMs: 50, requestId: () => 'req-1',
  };
  const res = await handleTts(req, deps);
  return { res, upstream };
}

// ---------------------------------------------------------------------------
describe('strict integer Redis replies (Fry N2 on #252): no Number() coercion', () => {
  const BAD: [string, unknown][] = [
    ['null', null], ['true', true], ['false', false], ["'1'", '1'], ["'1.0'", '1.0'],
    ['0.5', 0.5], ['NaN', Number.NaN], ['{}', {}], ['missing', undefined],
  ];
  // NaN serialises to null over JSON, so it exercises the same nil path a real REST reply would.
  const fetchFor = (result: unknown) => evalReturning(result === undefined ? {} : { result });

  for (const [name, result] of BAD) {
    test(`RESERVE2 reply ${name} → install gate 503 store`, async () => {
      const store = fetchFor(result);
      assert.deepEqual(await reserveForInstall(new RedisUsageLimiter(STORE, OPTIONS, store.fetchImpl), KEY_ID, 100, NOON), STORE_REFUSAL);
    });
    test(`RELEASE2 reply ${name} → release rejects with LimiterStoreError`, async () => {
      const store = fetchFor(result);
      await assert.rejects(new RedisUsageLimiter(STORE, OPTIONS, store.fetchImpl).release(reservation()), LimiterStoreError);
      assert.equal(store.calls(), 1);
    });
    test(`owner /api/tts: reserve reply ${name} → 503 store, zero ElevenLabs calls`, async () => {
      let n = 0;
      const fetchImpl = (async (_u: unknown, init?: RequestInit) => {
        n++;
        void init; // first EVAL is the rate check (real 1), the next is RESERVE2 with the bad reply
        return n === 1 ? Response.json({ result: 1 }) : Response.json(result === undefined ? {} : { result });
      }) as typeof fetch;
      const { res, upstream } = await runTts(new RedisUsageLimiter(STORE, OPTIONS, fetchImpl));
      assert.equal(res.status, 503);
      assert.equal(JSON.parse(res.body.toString('utf8')).reason, 'store');
      assert.equal(upstream, 0);
    });
    test(`owner /api/tts: refund reply ${name} after an upstream failure → no extra ElevenLabs call, still fails closed`, async () => {
      let n = 0;
      const fetchImpl = (async () => { n++; return n <= 2 ? Response.json({ result: n === 1 ? 1 : TTS_CHARS }) : Response.json(result === undefined ? {} : { result }); }) as typeof fetch;
      const { res, upstream } = await runTts(new RedisUsageLimiter(STORE, OPTIONS, fetchImpl), 502);
      assert.equal(n, 3, 'rate, reserve, then the refund EVAL ran');
      assert.equal(res.status, 502);
      // N3: the refund failure is swallowed (reservation kept, cap errs low), so the
      // response is exactly the upstream 502: no reason, no Retry-After.
      assert.deepEqual(JSON.parse(res.body.toString('utf8')), { error: 'Upstream error', requestId: 'req-1' });
      assert.equal(res.headers['Retry-After'], undefined);
      assert.equal(upstream, 1);
    });
  }

  test('controls: refund 0/1, reserve counter ≥ chars and -2 still parse', async () => {
    assert.equal(await new RedisUsageLimiter(STORE, OPTIONS, evalReturning({ result: 1 }).fetchImpl).release(reservation()), true);
    assert.equal(await new RedisUsageLimiter(STORE, OPTIONS, evalReturning({ result: 0 }).fetchImpl).release(reservation()), false);
    const r = await new RedisUsageLimiter(STORE, OPTIONS, evalReturning({ result: 100 }).fetchImpl).reserve({ kind: 'install', id: KEY_ID }, 100, NOON);
    assert.ok(r.ok);
    const q = await new RedisUsageLimiter(STORE, OPTIONS, evalReturning({ result: -2 }).fetchImpl).reserve({ kind: 'install', id: KEY_ID }, 100, NOON);
    assert.deepEqual(q, { ok: false, reason: 'global_daily' });
  });
});

// ---------------------------------------------------------------------------
describe('#254 review delta: rate replies and the reserve counter (Fry B1, N1, N2)', () => {
  /** Rate EVAL answers `rate`; any later EVAL answers a valid reserve. Counts EVALs. */
  const rateReplying = (rate: unknown) => {
    let n = 0;
    const fetchImpl = (async () => { n++; return Response.json(n === 1 ? (rate === undefined ? {} : { result: rate }) : { result: TTS_CHARS }); }) as typeof fetch;
    return { fetchImpl, evals: () => n };
  };
  const expectStore = async (fetchImpl: typeof fetch) => {
    const { res, upstream } = await runTts(new RedisUsageLimiter(STORE, OPTIONS, fetchImpl));
    assert.equal(res.status, 503);
    assert.equal(res.headers['Retry-After'], '30');
    assert.equal(JSON.parse(res.body.toString('utf8')).reason, 'store');
    assert.equal(upstream, 0, 'zero ElevenLabs calls');
  };

  // B1. The install path (reserveForInstall) has no rate check, so only /api/tts applies.
  for (const [name, rate] of [['null', null], ['true', true], ["'1'", '1'], ['0.5', 0.5], ['{}', {}]] as [string, unknown][]) {
    test(`B1: rate reply ${name} → /api/tts 503 store, zero ElevenLabs calls, reserve never reached`, async () => {
      const s = rateReplying(rate);
      await expectStore(s.fetchImpl);
      assert.equal(s.evals(), 1);
      await assert.rejects(new RedisUsageLimiter(STORE, OPTIONS, rateReplying(rate).fetchImpl).allowRequest('owner', NOON), LimiterStoreError);
    });
  }

  // N2. An integer outside {0, 1} is a store fault, not a 429.
  for (const rate of [2, -1]) {
    test(`N2: rate reply ${rate} → 503 store (not 429), zero ElevenLabs calls`, async () => {
      await expectStore(rateReplying(rate).fetchImpl);
    });
  }
  test('N2 controls: rate 1 renders (200), rate 0 is 429 rate', async () => {
    assert.equal((await runTts(new RedisUsageLimiter(STORE, OPTIONS, rateReplying(1).fetchImpl))).res.status, 200);
    const limited = await runTts(new RedisUsageLimiter(STORE, OPTIONS, rateReplying(0).fetchImpl));
    assert.equal(limited.res.status, 429);
    assert.equal(limited.upstream, 0);
  });

  // N1. Reserve success is the subject counter after INCRBY chars, so it must be ≥ chars.
  for (const counter of [0, 1, 99, -3]) {
    test(`N1: reserve counter ${counter} < chars 100 → install 503 store; /api/tts 503 store, zero ElevenLabs calls`, async () => {
      assert.deepEqual(await reserveForInstall(new RedisUsageLimiter(STORE, OPTIONS, evalReturning({ result: counter }).fetchImpl), KEY_ID, 100, NOON), STORE_REFUSAL);
      let n = 0;
      const ttsCounter = counter === 99 ? TTS_CHARS - 1 : counter;
      await expectStore((async () => { n++; return Response.json({ result: n === 1 ? 1 : ttsCounter }); }) as typeof fetch);
    });
  }
  test('N1 controls: counter == chars and > chars both succeed', async () => {
    for (const counter of [100, 5_000]) {
      const r = await new RedisUsageLimiter(STORE, OPTIONS, evalReturning({ result: counter }).fetchImpl).reserve({ kind: 'install', id: KEY_ID }, 100, NOON);
      assert.ok(r.ok, `counter ${counter}`);
    }
  });
});

// ---------------------------------------------------------------------------
describe('Upstash fetch timeout in the limiter (Sentinel N2 on #256)', () => {
  const TIMEOUT_MS = 20;
  // Like real fetch: never answers, rejects when its signal aborts. Records the signal.
  const honoring = (signals: (AbortSignal | null | undefined)[]) =>
    ((_url: string, init: RequestInit) => {
      signals.push(init.signal);
      return new Promise<Response>((_resolve, reject) => {
        init.signal?.addEventListener('abort', () => reject(init.signal!.reason), { once: true });
      });
    }) as unknown as typeof fetch;
  // Never answers and ignores the signal.
  const ignoring = (() => new Promise<Response>(() => {})) as unknown as typeof fetch;
  // Headers arrive, the body never does.
  const stalledBody = (async () => new Response(new ReadableStream({ start() {} }), { status: 200 })) as unknown as typeof fetch;
  /** The first `ok` EVALs answer a valid reply (rate 1, then the reserve counter); later ones go to `stall`. */
  const stallAfter = (ok: number, stall: typeof fetch) => {
    let n = 0;
    return (async (url: string, init: RequestInit) => {
      n++;
      if (n <= ok) return Response.json({ result: n === 1 ? 1 : TTS_CHARS });
      return stall(url, init);
    }) as unknown as typeof fetch;
  };
  /** AbortSignal.timeout's timer does not hold the event loop open; this does, for the test only. */
  async function withKeepAlive(run: () => Promise<void>) {
    const keepAlive = setTimeout(() => {}, 10_000);
    try {
      await run();
    } finally {
      clearTimeout(keepAlive);
    }
  }

  for (const [stage, ok] of [['rate check', 0], ['reserve', 1]] as const) {
    test(`owner /api/tts: ${stage} EVAL never finishes → 503 store, Retry-After 30, zero ElevenLabs calls`, { timeout: 5_000 }, () =>
      withKeepAlive(async () => {
        const signals: (AbortSignal | null | undefined)[] = [];
        for (const [name, stall] of [['honoring', honoring(signals)], ['ignoring', ignoring], ['stalledBody', stalledBody]] as const) {
          const started = Date.now();
          const { res, upstream } = await runTts(new RedisUsageLimiter(STORE, OPTIONS, stallAfter(ok, stall), TIMEOUT_MS));
          assert.equal(res.status, 503, name);
          assert.equal(res.headers['Retry-After'], '30', name);
          assert.equal(JSON.parse(res.body.toString('utf8')).reason, 'store', name);
          assert.equal(upstream, 0, `${name}: zero ElevenLabs calls`);
          assert.ok(Date.now() - started < 1_000, name);
        }
        assert.equal(signals.length, 1);
        assert.ok(signals[0] instanceof AbortSignal);
        assert.equal(signals[0]!.aborted, true);
      }));
  }

  test('install reserve EVAL never finishes → 503 store', { timeout: 5_000 }, () =>
    withKeepAlive(async () => {
      for (const stall of [honoring([]), ignoring, stalledBody]) {
        assert.deepEqual(await reserveForInstall(new RedisUsageLimiter(STORE, OPTIONS, stall, TIMEOUT_MS), KEY_ID, 100, NOON), STORE_REFUSAL);
      }
    }));

  test('a refund EVAL that never finishes rejects with LimiterStoreError', { timeout: 5_000 }, () =>
    withKeepAlive(async () => {
      for (const stall of [honoring([]), ignoring, stalledBody]) {
        await assert.rejects(new RedisUsageLimiter(STORE, OPTIONS, stall, TIMEOUT_MS).release(reservation()), LimiterStoreError);
      }
    }));

  test('the default Upstash timeout is UPSTASH_FETCH_TIMEOUT_MS (2 s)', () => {
    assert.equal(UPSTASH_FETCH_TIMEOUT_MS, 2_000);
  });
});
