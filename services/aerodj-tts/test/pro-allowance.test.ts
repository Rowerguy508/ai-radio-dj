/**
 * Pro daily allowance (owner: "Pro gets 40 premium breaks a day"; src/pro-allowance.ts).
 * The proxy counts renders: 40 breaks x 4 max cloud renders per break = 160 per Pro
 * purchase per UTC day. Redis tests run the REAL Lua scripts (test/redis-lua.ts).
 */
import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { handleTts, secondsUntilNextUtcDay, type Deps, type Env, type LogEntry, type TtsRequest } from '../src/handler.js';
import { InMemoryUsageLimiter, type UsageLimiter } from '../src/limiter.js';
import {
  InMemoryProAllowance,
  MAX_CLOUD_RENDERS_PER_BREAK,
  PRO_DAILY_BREAKS,
  PRO_DAILY_RENDER_ALLOWANCE,
  PRO_RESERVE_SCRIPT,
  RedisProAllowance,
  isVerifiedProSubject,
  proDayKey,
  proSubjectFromVerified,
  type ProAllowanceStore,
  type ProSubject,
} from '../src/pro-allowance.js';
import { FakeRedis, fakeUpstash } from './redis-lua.js';

const TOKEN = 'test-owner-token-not-a-real-secret';
const TOKEN_HASH = crypto.createHash('sha256').update(TOKEN).digest('hex');
const VOICE = 'voiceAllowed123';
const STORE = { url: 'https://store.example.upstash.io', token: 'test-store-token-not-real' };
const NOON = Date.UTC(2026, 9, 29, 12);
const DAY = '2026-10-29';
const OTID_A = '2000000123456789';
const OTID_B = '2000000987654321';
const ENV: Env = { AERODJ_TTS_TOKEN_SHA256: TOKEN_HASH, AERODJ_TTS_VOICE_IDS: VOICE, ELEVENLABS_API_KEY: 'test-elevenlabs-key-not-real' };
const TEXT = 'Next up, a little something for the drive home.';
const sha = (s: string) => crypto.createHash('sha256').update(s, 'utf8').digest('hex');

const pcm = () => new Response(Buffer.alloc(22_050 * 2, 1), { status: 200, headers: { 'Content-Type': 'audio/pcm' } });
const body = (r: { body: Buffer }) => JSON.parse(r.body.toString('utf8')) as Record<string, unknown>;

function req(pro: ProSubject | undefined, text = TEXT): TtsRequest {
  return { method: 'POST', authorization: `Bearer ${TOKEN}`, body: { upstream: 'elevenlabs', voiceId: VOICE, text, format: 'text' }, verifiedPro: pro };
}

function harness(o: { store?: ProAllowanceStore | null; limiter?: UsageLimiter; upstream?: () => Promise<Response>; now?: () => number } = {}) {
  let clock = NOON;
  const up = fakeUpstash({ redis: new FakeRedis(() => clock) });
  const store = o.store === undefined ? new RedisProAllowance(STORE, PRO_DAILY_RENDER_ALLOWANCE, up.fetchImpl) : o.store;
  const logs: LogEntry[] = [];
  let upstreamCalls = 0;
  const d: Deps = {
    env: ENV,
    fetch: (async () => {
      upstreamCalls++;
      return (o.upstream ?? pcm)();
    }) as typeof fetch,
    limiter: o.limiter ?? new InMemoryUsageLimiter({ dailyCharCap: 10_000_000, requestsPerMinute: 600 }),
    proAllowance: store,
    log: (e) => logs.push(e),
    now: o.now ?? (() => clock),
    timeoutMs: 50,
    requestId: () => 'req-1',
    logRefundLost: () => {},
  };
  return { d, logs, redis: up.redis, calls: up.calls, upstream: () => upstreamCalls, setNow: (t: number) => { clock = t; } };
}

async function run(h: ReturnType<typeof harness>, pro: ProSubject | undefined, n: number, text = TEXT) {
  const statuses: number[] = [];
  for (let i = 0; i < n; i++) statuses.push((await handleTts(req(pro, text), h.d)).status);
  return statuses;
}

describe('Pro allowance: sizing', () => {
  test('40 breaks x 4 max cloud renders per break = 160 renders per day', () => {
    assert.equal(PRO_DAILY_BREAKS, 40);
    assert.equal(MAX_CLOUD_RENDERS_PER_BREAK, 4);
    assert.equal(PRO_DAILY_RENDER_ALLOWANCE, 160);
  });
});

describe('Pro allowance: handler (redis, real Lua)', () => {
  test('40 full breaks (160 renders) all succeed; the next render gets 429 daily_allowance before any upstream call', async () => {
    const h = harness();
    const A = proSubjectFromVerified({ originalTransactionId: OTID_A });
    for (let brk = 0; brk < PRO_DAILY_BREAKS; brk++) {
      assert.deepEqual(await run(h, A, MAX_CLOUD_RENDERS_PER_BREAK), [200, 200, 200, 200], `break ${brk + 1}`);
    }
    assert.equal(h.upstream(), 160);
    const over = await handleTts(req(A), h.d);
    assert.equal(over.status, 429);
    assert.equal(h.upstream(), 160, 'no upstream call once the allowance is used up');
    assert.equal(over.headers['Retry-After'], String(secondsUntilNextUtcDay(NOON)));
    assert.equal(over.headers['Retry-After'], '43200');
    assert.deepEqual(body(over), { error: 'Too many requests', requestId: 'req-1', reason: 'daily_allowance', retryAfterSeconds: 43200 });
    assert.equal(h.redis.get(proDayKey(A.bucket, DAY)), 160, 'a refusal changes no counter');
    assert.deepEqual(h.logs.at(-1), { requestId: 'req-1', status: 429, chars: TEXT.length, reason: 'daily_allowance' });
  });

  test('another Pro purchase is unaffected', async () => {
    const h = harness();
    const A = proSubjectFromVerified({ originalTransactionId: OTID_A });
    const B = proSubjectFromVerified({ originalTransactionId: OTID_B });
    await run(h, A, 160);
    assert.equal((await handleTts(req(A), h.d)).status, 429);
    assert.equal((await handleTts(req(B), h.d)).status, 200);
    assert.equal(h.redis.get(proDayKey(B.bucket, DAY)), 1);
  });

  test('the same purchase verified twice shares one bucket', async () => {
    const h = harness();
    await run(h, proSubjectFromVerified({ originalTransactionId: OTID_A }), 160);
    assert.equal((await handleTts(req(proSubjectFromVerified({ originalTransactionId: OTID_A })), h.d)).status, 429);
  });

  test('resets at 00:00 UTC; Retry-After counts down to it; counter TTL is 2 days', async () => {
    const h = harness();
    const A = proSubjectFromVerified({ originalTransactionId: OTID_A });
    const lastSecond = Date.UTC(2026, 9, 29, 23, 59, 59);
    h.setNow(lastSecond);
    await run(h, A, 160);
    const over = await handleTts(req(A), h.d);
    assert.equal(over.status, 429);
    assert.equal(over.headers['Retry-After'], '1');
    h.setNow(Date.UTC(2026, 9, 30, 0, 0, 0));
    assert.equal((await handleTts(req(A), h.d)).status, 200);
    assert.equal(h.redis.get(proDayKey(A.bucket, '2026-10-30')), 1);
    const key = proDayKey(A.bucket, DAY);
    assert.equal(h.redis.expiresAt.get(key), lastSecond + 172_800_000);
  });

  test('keys hold only the SHA-256 of the transaction id; no raw id in any key, command or log', async () => {
    const h = harness();
    const A = proSubjectFromVerified({ originalTransactionId: OTID_A });
    await run(h, A, 2);
    assert.equal(A.bucket, `pro:${sha(OTID_A)}`);
    assert.ok(h.redis.data.has(`aerodj-tts:renders:pro:${sha(OTID_A)}:${DAY}`));
    const everything = JSON.stringify([...h.redis.data.keys(), h.calls.map((c) => c.command.slice(2)), h.logs]);
    assert.ok(!everything.includes(OTID_A));
  });

  test('an upstream non-2xx refunds the render, so failed renders never burn allowance', async () => {
    let fail = true;
    const h = harness({ upstream: async () => (fail ? new Response('{"detail":{"status":"busy"}}', { status: 503 }) : pcm()) });
    const A = proSubjectFromVerified({ originalTransactionId: OTID_A });
    assert.deepEqual(await run(h, A, 5), [502, 502, 502, 502, 502]);
    assert.equal(h.redis.get(proDayKey(A.bucket, DAY)), 0);
    fail = false;
    assert.ok((await run(h, A, 160)).every((s) => s === 200));
    assert.equal((await handleTts(req(A), h.d)).status, 429);
  });

  test('a char-budget refusal returns the render (nothing was rendered)', async () => {
    const limiter = new InMemoryUsageLimiter({ dailyCharCap: TEXT.length, requestsPerMinute: 600 });
    const h = harness({ limiter });
    const A = proSubjectFromVerified({ originalTransactionId: OTID_A });
    assert.equal((await handleTts(req(A), h.d)).status, 200);
    const r = await handleTts(req(A), h.d);
    assert.equal(r.status, 429);
    assert.equal(body(r).reason, 'owner_daily');
    assert.equal(h.redis.get(proDayKey(A.bucket, DAY)), 1);
  });

  test('the 600-char per-request cap still applies to Pro, and a refused request counts nothing', async () => {
    const h = harness();
    const A = proSubjectFromVerified({ originalTransactionId: OTID_A });
    assert.equal((await handleTts(req(A, 'x'.repeat(601)), h.d)).status, 400);
    assert.equal((await handleTts(req(A, 'x'.repeat(600)), h.d)).status, 200);
    assert.equal(h.redis.get(proDayKey(A.bucket, DAY)), 1);
  });

  test('owner path (no verifiedPro) never touches the allowance and is not capped by it', async () => {
    let storeCalls = 0;
    const spy: ProAllowanceStore = {
      durable: true,
      reserve: async () => { storeCalls++; return { ok: false }; },
      release: async () => { storeCalls++; return true; },
    };
    const h = harness({ store: spy });
    assert.ok((await run(h, undefined, 170)).every((s) => s === 200));
    assert.equal(storeCalls, 0);
  });

  test('a hand-built Pro subject (not minted from a verified transaction) is refused: 500 misconfig, no store or upstream call', async () => {
    const h = harness();
    const forged = Object.freeze({ kind: 'pro', bucket: `pro:${sha(OTID_A)}` }) as ProSubject;
    assert.equal(isVerifiedProSubject(forged), false);
    const r = await handleTts(req(forged), h.d);
    assert.equal(r.status, 500);
    assert.equal(body(r).reason, 'misconfig');
    assert.equal(h.calls.length, 0);
    assert.equal(h.upstream(), 0);
  });
});

describe('Pro allowance: store errors fail closed (503 store, Retry-After 30), never 429', () => {
  const A = () => proSubjectFromVerified({ originalTransactionId: OTID_A });
  const expectStore = async (h: ReturnType<typeof harness>) => {
    const r = await handleTts(req(A()), h.d);
    assert.equal(r.status, 503);
    assert.equal(r.headers['Retry-After'], '30');
    assert.equal(body(r).reason, 'store');
    assert.equal(h.upstream(), 0);
  };
  test('store HTTP 500', async () => {
    const up = fakeUpstash({ status: 500 });
    await expectStore(harness({ store: new RedisProAllowance(STORE, 160, up.fetchImpl) }));
  });
  test('store timeout (2 s bound, here 20 ms)', async () => {
    const stalled = (() => new Promise<Response>(() => {})) as unknown as typeof fetch;
    const keep = setTimeout(() => {}, 5_000);
    try {
      await expectStore(harness({ store: new RedisProAllowance(STORE, 160, stalled, 20) }));
    } finally {
      clearTimeout(keep);
    }
  });
  for (const result of [null, true, '1', 1.5, 0, 161, -2]) {
    test(`non-grant reply ${JSON.stringify(result)}`, async () => {
      const f = (async () => Response.json({ result })) as unknown as typeof fetch;
      await expectStore(harness({ store: new RedisProAllowance(STORE, 160, f) }));
    });
  }
  test('no store, or a non-durable store', async () => {
    await expectStore(harness({ store: null }));
    await expectStore(harness({ store: new InMemoryProAllowance() }));
  });
});

describe('Pro allowance: scripts and stores', () => {
  test('PRO_RESERVE_SCRIPT: 159 -> 160 granted; at 160 refused with no change', () => {
    const redis = new FakeRedis(() => NOON);
    const key = proDayKey(`pro:${sha(OTID_A)}`, DAY);
    redis.data.set(key, '159');
    assert.equal(redis.eval(PRO_RESERVE_SCRIPT, [key], ['160', '172800']), 160);
    assert.equal(redis.eval(PRO_RESERVE_SCRIPT, [key], ['160', '172800']), -1);
    assert.equal(redis.get(key), 160);
  });
  for (const [name, make] of [
    ['redis', () => new RedisProAllowance(STORE, 3, fakeUpstash().fetchImpl)],
    ['in-memory', () => new InMemoryProAllowance(3)],
  ] as const) {
    test(`${name}: exact allowance, per-subject scope, once-only release`, async () => {
      const s = make();
      const A = proSubjectFromVerified({ originalTransactionId: OTID_A });
      const B = proSubjectFromVerified({ originalTransactionId: OTID_B });
      const got = [];
      for (let i = 0; i < 4; i++) got.push(await s.reserve(A, NOON));
      assert.deepEqual(got.map((g) => g.ok), [true, true, true, false]);
      assert.equal((await s.reserve(B, NOON)).ok, true);
      const first = got[0];
      assert.ok(first.ok);
      assert.equal(await s.release(first.reservation), true);
      assert.equal(await s.release(first.reservation), false);
      assert.equal((await s.reserve(A, NOON)).ok, true);
      assert.equal((await s.reserve(A, NOON)).ok, false);
      assert.equal((await s.reserve(A, NOON + 12 * 3_600_000)).ok, true, 'next UTC day');
    });
  }
  test('proSubjectFromVerified refuses an empty or oversized id', () => {
    assert.throws(() => proSubjectFromVerified({ originalTransactionId: '' }));
    assert.throws(() => proSubjectFromVerified({ originalTransactionId: 'x'.repeat(257) }));
  });
});
