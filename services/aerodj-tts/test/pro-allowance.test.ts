/**
 * Pro daily allowance (owner: "Pro gets 40 premium breaks a day"; src/pro-allowance.ts).
 * The proxy counts renders: 40 breaks x 4 max cloud renders per break = 160 per Pro
 * purchase per UTC day. Redis tests run the REAL Lua scripts (test/redis-lua.ts), and
 * every Pro subject is minted from a REAL verified transaction (test/helpers/verified-tx.ts).
 */
import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { readFileSync } from 'node:fs';
import { handleTts, secondsUntilNextUtcDay, DEFAULT_PRO_REQUESTS_PER_MINUTE, type Deps, type Env, type LogEntry, type RefundLostLog, type TtsRequest } from '../src/handler.js';
import {
  InMemoryUsageLimiter,
  LimiterStoreError,
  PRO_RELEASE_SCRIPT,
  PRO_RESERVE_SCRIPT,
  RESERVE2_SCRIPT,
  RedisUsageLimiter,
  isDeployment,
  proDayKeys,
  type LimiterOptions,
  type UsageLimiter,
} from '../src/limiter.js';
import {
  MAX_CLOUD_RENDERS_PER_BREAK,
  PRO_DAILY_BREAKS,
  PRO_DAILY_RENDER_ALLOWANCE,
  isVerifiedProSubject,
  proBucket,
  proDeployment,
  proSubjectFromVerified,
  type ProSubject,
} from '../src/pro-allowance.js';
import { isVerifiedTransaction, type VerifiedTransaction } from '../src/storekit-verify.js';
import { FakeRedis, fakeUpstash } from './redis-lua.js';
import { verifiedTransaction } from './helpers/verified-tx.js';

const TOKEN = 'test-owner-token-not-a-real-secret';
const TOKEN_HASH = crypto.createHash('sha256').update(TOKEN).digest('hex');
const VOICE = 'voiceAllowed123';
const STORE = { url: 'https://store.example.upstash.io', token: 'test-store-token-not-real' };
const NOON = Date.UTC(2026, 9, 29, 12);
const DAY = '2026-10-29';
const OTID_A = '2000000123456789';
const OTID_B = '2000000987654321';
const BIG = 10_000_000;
// Pro rate raised for the 160-render runs (fixed clock); the default is pinned separately.
const ENV: Env = {
  AERODJ_TTS_TOKEN_SHA256: TOKEN_HASH,
  AERODJ_TTS_VOICE_IDS: VOICE,
  ELEVENLABS_API_KEY: 'test-elevenlabs-key-not-real',
  VERCEL_ENV: 'production',
  AERODJ_TTS_PRO_RATE_PER_MINUTE: '600',
};
const TEXT = 'Next up, a little something for the drive home.';
const sha = (s: string) => crypto.createHash('sha256').update(s, 'utf8').digest('hex');
const PRO_A = `pro:production:${sha(OTID_A)}`;
const PRO_B = `pro:production:${sha(OTID_B)}`;
const keys = (bucket: string, day = DAY) => {
  const [global, chars, renders] = proDayKeys(bucket, day, deploymentOf(bucket.split(':')[1]));
  return { global, chars, renders };
};
const OWNER_KEY = `aerodj-tts:chars:owner:production:${DAY}`;

const pcm = () => new Response(Buffer.alloc(22_050 * 2, 1), { status: 200, headers: { 'Content-Type': 'audio/pcm' } });
const body = (r: { body: Buffer }) => JSON.parse(r.body.toString('utf8')) as Record<string, unknown>;
const subject = async (otid = OTID_A) => proSubjectFromVerified(await verifiedTransaction(otid));

function req(pro: ProSubject | undefined, text = TEXT, extra: Record<string, unknown> = {}): TtsRequest {
  return { method: 'POST', authorization: `Bearer ${TOKEN}`, body: { upstream: 'elevenlabs', voiceId: VOICE, text, format: 'text', ...extra }, verifiedPro: pro };
}

/** The limiter's deployment follows the harness env (as `selectLimiter` does); default production. */
const deploymentOf = (v: string | undefined) => (isDeployment(v) ? v : 'production');

function harness(o: { limiter?: UsageLimiter; options?: Partial<LimiterOptions>; upstream?: (url?: unknown, init?: RequestInit) => Promise<Response>; env?: Env; lost?: RefundLostLog[]; redis?: FakeRedis } = {}) {
  let clock = NOON;
  const up = fakeUpstash({ redis: o.redis ?? new FakeRedis(() => clock) });
  const limiter = o.limiter ?? new RedisUsageLimiter(STORE, { deployment: deploymentOf(o.env?.VERCEL_ENV), dailyCharCap: BIG, requestsPerMinute: 600, ...o.options }, up.fetchImpl);
  const logs: LogEntry[] = [];
  let upstreamCalls = 0;
  const d: Deps = {
    env: { ...ENV, ...o.env },
    fetch: (async (url: unknown, init?: RequestInit) => {
      upstreamCalls++;
      return (o.upstream ?? pcm)(url, init);
    }) as typeof fetch,
    limiter,
    log: (e) => logs.push(e),
    now: () => clock,
    timeoutMs: 50,
    requestId: () => 'req-1',
    // Test-only: these harnesses drive the handler with an in-memory/spy limiter (Fry on #287 gate).
    testOnlyAllowNonDurableLimiter: true,
    logRefundLost: (e) => o.lost?.push(e),
  };
  const proCalls = () => up.calls.filter((c) => c.command[1] === PRO_RESERVE_SCRIPT || c.command[1] === PRO_RELEASE_SCRIPT).length;
  return { d, logs, redis: up.redis, calls: up.calls, proCalls, upstream: () => upstreamCalls, setNow: (t: number) => { clock = t; } };
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
    const A = await subject();
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
    const k = keys(PRO_A);
    assert.equal(h.redis.get(k.renders), 160, 'a refusal changes no counter');
    assert.equal(h.redis.get(k.chars), 160 * TEXT.length, 'the render-allowance 429 comes before (and without) any char charge');
    assert.equal(h.redis.get(k.global), 160 * TEXT.length);
    assert.deepEqual(h.logs.at(-1), { requestId: 'req-1', status: 429, chars: TEXT.length, reason: 'daily_allowance' });
  });

  test('another Pro purchase is unaffected', async () => {
    const h = harness();
    const A = await subject();
    const B = await subject(OTID_B);
    await run(h, A, 160);
    assert.equal((await handleTts(req(A), h.d)).status, 429);
    assert.equal((await handleTts(req(B), h.d)).status, 200);
    assert.equal(h.redis.get(keys(PRO_B).renders), 1);
  });

  test('the same purchase verified twice shares one bucket', async () => {
    const h = harness();
    await run(h, await subject(), 160);
    assert.equal((await handleTts(req(await subject()), h.d)).status, 429);
  });

  test('resets at 00:00 UTC; Retry-After counts down to it; counter TTL is 2 days', async () => {
    const h = harness();
    const A = await subject();
    const lastSecond = Date.UTC(2026, 9, 29, 23, 59, 59);
    h.setNow(lastSecond);
    await run(h, A, 160);
    const over = await handleTts(req(A), h.d);
    assert.equal(over.status, 429);
    assert.equal(over.headers['Retry-After'], '1');
    h.setNow(Date.UTC(2026, 9, 30, 0, 0, 0));
    assert.equal((await handleTts(req(A), h.d)).status, 200);
    assert.equal(h.redis.get(keys(PRO_A, '2026-10-30').renders), 1);
    for (const key of [keys(PRO_A).renders, keys(PRO_A).chars]) assert.equal(h.redis.expiresAt.get(key), lastSecond + 172_800_000);
  });

  test('keys hold only the SHA-256 of the transaction id, scoped to the deployment; no raw id in any key, command or log', async () => {
    const h = harness();
    const A = await subject();
    await run(h, A, 2);
    assert.equal(proBucket(A, 'production'), PRO_A);
    assert.ok(h.redis.data.has(`aerodj-tts:renders:pro:production:${sha(OTID_A)}:${DAY}`));
    assert.ok(h.redis.data.has(`aerodj-tts:chars:pro:production:${sha(OTID_A)}:${DAY}`));
    assert.ok([...h.redis.data.keys()].some((k) => k.startsWith(`aerodj-tts:rate:pro:production:${sha(OTID_A)}:`)));
    const everything = JSON.stringify([...h.redis.data.keys(), h.calls.map((c) => c.command.slice(2)), h.logs]);
    assert.ok(!everything.includes(OTID_A));
  });

  test('an upstream non-2xx refunds the render and its chars, so failed renders never burn allowance', async () => {
    let fail = true;
    const h = harness({ upstream: async () => (fail ? new Response('{"detail":{"status":"busy"}}', { status: 503 }) : pcm()) });
    const A = await subject();
    assert.deepEqual(await run(h, A, 5), [502, 502, 502, 502, 502]);
    const k = keys(PRO_A);
    assert.deepEqual([h.redis.get(k.renders), h.redis.get(k.chars), h.redis.get(k.global)], [0, 0, 0]);
    fail = false;
    assert.ok((await run(h, A, 160)).every((s) => s === 200));
    assert.equal((await handleTts(req(A), h.d)).status, 429);
  });

  test('the 600-char per-request cap still applies to Pro, and a refused request counts nothing', async () => {
    const h = harness();
    const A = await subject();
    assert.equal((await handleTts(req(A, 'x'.repeat(601)), h.d)).status, 400);
    assert.equal(h.proCalls(), 0);
    assert.equal((await handleTts(req(A, 'x'.repeat(600)), h.d)).status, 200);
    assert.equal(h.redis.get(keys(PRO_A).renders), 1);
  });

  test('owner path (no verifiedPro) never touches Pro counters and is not capped by the allowance', async () => {
    const h = harness();
    assert.ok((await run(h, undefined, 170)).every((s) => s === 200));
    assert.equal(h.proCalls(), 0);
    assert.ok(![...h.redis.data.keys()].some((k) => k.includes(':pro:')));
  });

  test('a hand-built Pro subject (not minted from a verified transaction) is refused: 500 misconfig, no store or upstream call', async () => {
    const h = harness();
    const forged = Object.freeze({ kind: 'pro', hash: sha(OTID_A) }) as ProSubject;
    assert.equal(isVerifiedProSubject(forged), false);
    const r = await handleTts(req(forged), h.d);
    assert.equal(r.status, 500);
    assert.equal(body(r).reason, 'misconfig');
    assert.equal(h.calls.length, 0);
    assert.equal(h.upstream(), 0);
  });
});

describe('Pro: the global ceiling is checked BEFORE the Pro reserve (Sentinel)', () => {
  test('global at its limit: a verified Pro request gets 429 global_daily and no Pro counter changes', async () => {
    const h = harness({ options: { deployment: 'production' as const, dailyCharCap: TEXT.length } });
    assert.equal((await run(h, undefined, 1))[0], 200, 'the owner fills the global ceiling');
    const A = await subject();
    const r = await handleTts(req(A), h.d);
    assert.equal(r.status, 429);
    assert.equal(body(r).reason, 'global_daily');
    const k = keys(PRO_A);
    assert.equal(h.redis.data.has(k.renders), false, 'no Pro render counted');
    assert.equal(h.redis.data.has(k.chars), false, 'no Pro chars counted');
    assert.equal(h.redis.get(k.global), TEXT.length);
    assert.equal(h.upstream(), 1);
  });

  test('global full AND the render allowance used up: the refusal is global_daily (global is checked first)', async () => {
    const h = harness();
    const A = await subject();
    await run(h, A, 160);
    const k = keys(PRO_A);
    h.redis.data.set(k.global, String(BIG));
    const r = await handleTts(req(A), h.d);
    assert.equal(body(r).reason, 'global_daily');
    assert.deepEqual([h.redis.get(k.renders), h.redis.get(k.chars)], [160, 160 * TEXT.length]);
  });

  test('render allowance used up AND char cap full: the refusal logs daily_allowance (renders before chars), no counter changes', async () => {
    const h = harness({ env: { AERODJ_TTS_PRO_DAILY_CHARS: String(160 * TEXT.length) } });
    const A = await subject();
    await run(h, A, 160);
    const r = await handleTts(req(A), h.d);
    assert.equal(body(r).reason, 'daily_allowance');
    assert.equal(h.logs.at(-1)?.reason, 'daily_allowance');
  });

  test('the Pro path never calls the owner/install char reserve (no RESERVE2 for a Pro request)', async () => {
    const h = harness();
    const A = await subject();
    await run(h, A, 3);
    assert.equal(h.calls.filter((c) => c.command[1] === RESERVE2_SCRIPT).length, 0);
    assert.equal(h.redis.data.has(OWNER_KEY), false);
  });
});

describe('Pro: identity never comes from a body field or header', () => {
  test('Pro-looking body fields leave the request on the owner bucket and its cap (owner_daily), never Pro', async () => {
    const h = harness({ options: { ownerDailyCharCap: TEXT.length } });
    const fake = { verifiedPro: { kind: 'pro', hash: sha(OTID_A) }, originalTransactionId: OTID_A, signedTransaction: 'x.y.z', pro: true };
    assert.equal((await handleTts(req(undefined, TEXT, fake), h.d)).status, 200);
    const r = await handleTts(req(undefined, TEXT, fake), h.d);
    assert.equal(r.status, 429);
    assert.equal(body(r).reason, 'owner_daily');
    assert.equal(h.proCalls(), 0);
    assert.ok(![...h.redis.data.keys()].some((k) => k.includes(':pro:')));
  });

  test('api/tts.ts passes only method, authorization and body (never verifiedPro, never another header)', () => {
    const src = readFileSync(new URL('../api/tts.ts', import.meta.url), 'utf8');
    assert.ok(!src.includes('verifiedPro'));
    assert.deepEqual(src.match(/req\.headers\.[a-z-]+/g), ['req.headers.authorization']);
  });
});

describe("Pro: Sentinel's B2 (branded verified transactions only)", () => {
  test('a verified transaction is frozen and branded; a hand-built or copied one is not, and minting from it throws', async () => {
    const tx = await verifiedTransaction(OTID_A);
    assert.equal(isVerifiedTransaction(tx), true);
    assert.ok(Object.isFrozen(tx));
    assert.throws(() => { (tx as { originalTransactionId: string }).originalTransactionId = OTID_B; });
    const handBuilt = { originalTransactionId: OTID_A } as VerifiedTransaction;
    const copy = { ...tx };
    for (const t of [handBuilt, copy]) {
      assert.equal(isVerifiedTransaction(t), false);
      assert.throws(() => proSubjectFromVerified(t), /unverified transaction/);
    }
    const A = proSubjectFromVerified(tx);
    assert.ok(isVerifiedProSubject(A));
    assert.ok(Object.isFrozen(A));
    assert.equal(A.hash, sha(OTID_A));
    assert.equal(isVerifiedProSubject({ ...A }), false);
  });
});

describe("Pro: Sentinel's B3 (deployment-scoped keys)", () => {
  test('VERCEL_ENV allow-list: production | preview | development only', () => {
    for (const v of ['production', 'preview', 'development'] as const) assert.equal(proDeployment({ VERCEL_ENV: v }), v);
    for (const v of [undefined, '', 'Production', 'staging', ' production', 'test']) assert.equal(proDeployment({ VERCEL_ENV: v }), null);
  });

  test('the same purchase gets distinct render, char and rate keys per deployment', async () => {
    const redis = new FakeRedis(() => NOON);
    const A = await subject();
    for (const env of ['production', 'preview', 'development']) {
      const h = harness({ redis, env: { VERCEL_ENV: env } });
      assert.equal((await handleTts(req(A), h.d)).status, 200);
    }
    for (const env of ['production', 'preview', 'development']) {
      const k = keys(`pro:${env}:${sha(OTID_A)}`);
      assert.equal(redis.get(k.renders), 1, env);
      assert.equal(redis.get(k.chars), TEXT.length, env);
      assert.ok([...redis.data.keys()].some((key) => key.startsWith(`aerodj-tts:rate:pro:${env}:`)), env);
    }
  });

  for (const v of [undefined, 'staging', 'Production']) {
    test(`VERCEL_ENV ${JSON.stringify(v)}: a Pro request is 500 misconfig before any store or upstream call; the owner path is unaffected`, async () => {
      const h = harness({ env: { VERCEL_ENV: v } });
      const r = await handleTts(req(await subject()), h.d);
      assert.equal(r.status, 500);
      assert.equal(body(r).reason, 'misconfig');
      assert.equal(h.calls.length, 0);
      assert.equal((await handleTts(req(undefined), h.d)).status, 200);
    });
  }
});

describe("Pro: Sentinel's B1 (Pro's own rate bucket, never the owner's)", () => {
  test('default Pro rate is 12/min (a break is at most 4 renders)', () => {
    assert.equal(DEFAULT_PRO_REQUESTS_PER_MINUTE, 12);
  });

  test('default 12/min applies when unset: the 13th Pro request in a minute gets 429 rate', async () => {
    const h = harness({ env: { AERODJ_TTS_PRO_RATE_PER_MINUTE: undefined } });
    const A = await subject();
    const s = await run(h, A, 13);
    assert.deepEqual(s.slice(0, 12), Array(12).fill(200));
    assert.equal(s[12], 429);
    assert.equal(h.logs.at(-1)?.reason, 'rate');
  });

  test('the owner rate exhausted does not block Pro; the Pro rate exhausted does not block the owner or another purchase', async () => {
    const h = harness({ options: { requestsPerMinute: 1 }, env: { AERODJ_TTS_PRO_RATE_PER_MINUTE: '2' } });
    const A = await subject();
    assert.deepEqual(await run(h, undefined, 2), [200, 429]);
    assert.deepEqual(await run(h, A, 3), [200, 200, 429]);
    assert.deepEqual(await run(h, await subject(OTID_B), 1), [200]);
  });

  for (const bad of ['0', '601', 'abc', '1.5', '', '-1']) {
    test(`AERODJ_TTS_PRO_RATE_PER_MINUTE=${JSON.stringify(bad)}: Pro is 500 misconfig, owner unaffected`, async () => {
      const h = harness({ env: { AERODJ_TTS_PRO_RATE_PER_MINUTE: bad } });
      const r = await handleTts(req(await subject()), h.d);
      assert.equal(r.status, 500);
      assert.equal(body(r).reason, 'misconfig');
      assert.equal(h.calls.length, 0);
      assert.equal((await handleTts(req(undefined), h.d)).status, 200);
    });
  }

  test('Pro chars never touch the owner bucket, and a low owner cap never limits Pro', async () => {
    const h = harness({ options: { ownerDailyCharCap: TEXT.length } });
    assert.ok((await run(h, await subject(), 20)).every((s) => s === 200));
    assert.equal(h.redis.data.has(OWNER_KEY), false);
    assert.equal(h.redis.get(keys(PRO_A).chars), 20 * TEXT.length);
  });
});

describe('Pro allowance: store errors fail closed (503 store, Retry-After 30), never 429', () => {
  const expectStore = async (h: ReturnType<typeof harness>) => {
    const r = await handleTts(req(await subject()), h.d);
    assert.equal(r.status, 503);
    assert.equal(r.headers['Retry-After'], '30');
    assert.equal(body(r).reason, 'store');
    assert.equal(h.upstream(), 0);
  };
  const opts: LimiterOptions = { deployment: 'production' as const, dailyCharCap: BIG, requestsPerMinute: 600 };
  test('store HTTP 500', async () => {
    await expectStore(harness({ limiter: new RedisUsageLimiter(STORE, opts, fakeUpstash({ status: 500 }).fetchImpl) }));
  });
  test('store timeout (2 s bound, here 20 ms) on the Pro reserve', async () => {
    const up = fakeUpstash();
    const stalled = (async (url: string, init: RequestInit) => {
      if (String(init.body).includes('INCR\', KEYS[3]')) return new Promise<Response>(() => {});
      return up.fetchImpl(url, init);
    }) as unknown as typeof fetch;
    const keep = setTimeout(() => {}, 5_000);
    try {
      await expectStore(harness({ limiter: new RedisUsageLimiter(STORE, opts, stalled, 20) }));
    } finally {
      clearTimeout(keep);
    }
  });
  for (const result of [null, true, '1', 1.5, 0, 161, -1, -5]) {
    test(`non-grant Pro reserve reply ${JSON.stringify(result)}`, async () => {
      const up = fakeUpstash();
      const f = (async (url: string, init: RequestInit) =>
        String(init.body).includes('INCR\', KEYS[3]') ? Response.json({ result }) : up.fetchImpl(url, init)) as unknown as typeof fetch;
      await expectStore(harness({ limiter: new RedisUsageLimiter(STORE, opts, f) }));
    });
  }
  test('a non-durable limiter is refused even earlier: 500 no_store (the test-only override is ignored with VERCEL_ENV set)', async () => {
    // Sentinel's nit on #294: with VERCEL_ENV set the override no longer lets a non-durable
    // limiter past the no-store gate, so it never reaches the Pro reserve. Zero upstream calls.
    const h = harness({ limiter: new InMemoryUsageLimiter(opts) });
    const r = await handleTts(req(await subject()), h.d);
    assert.equal(r.status, 500);
    assert.equal(body(r).reason, 'misconfig');
    assert.deepEqual(h.logs.map((x) => x.reason), ['no_store']);
    assert.equal(h.upstream(), 0);
  });
  test('a durable limiter without reservePro', async () => {
    const inner = new RedisUsageLimiter(STORE, opts, fakeUpstash().fetchImpl);
    const bare: UsageLimiter = { durable: true, allowRequest: (b, n, l) => inner.allowRequest(b, n, l), reserve: (s, c, n) => inner.reserve(s, c, n), release: (r) => inner.release(r) };
    await expectStore(harness({ limiter: bare }));
  });
});

describe('Pro allowance: scripts and limiters', () => {
  const args = (chars: number, global: number, proCap: number, renders: number) => [String(chars), String(global), String(proCap), String(renders), '172800'];
  test('PRO_RESERVE_SCRIPT: order global (-2), renders (-4), chars (-3); a refusal changes nothing; 159 -> 160 granted', () => {
    const redis = new FakeRedis(() => NOON);
    const k = keys(PRO_A);
    const K = [k.global, k.chars, k.renders];
    const snapshot = () => K.map((key) => redis.get(key));
    redis.data.set(k.renders, '159');
    assert.equal(redis.eval(PRO_RESERVE_SCRIPT, K, args(10, 100, 100, 160)), 160);
    assert.deepEqual(snapshot(), [10, 10, 160]);
    assert.equal(redis.eval(PRO_RESERVE_SCRIPT, K, args(91, 100, 1000, 160)), -2, 'global first');
    assert.equal(redis.eval(PRO_RESERVE_SCRIPT, K, args(1, 100, 5, 160)), -4, 'renders before chars');
    redis.data.set(k.renders, '0');
    assert.equal(redis.eval(PRO_RESERVE_SCRIPT, K, args(1, 100, 10, 160)), -3);
    assert.equal(redis.eval(PRO_RESERVE_SCRIPT, K, args(90, 100, 100, 160)), 1, 'exactly at both caps is granted');
    assert.deepEqual(snapshot(), [100, 100, 1]);
  });

  for (const [name, make] of [
    ['redis', () => new RedisUsageLimiter(STORE, { deployment: 'production' as const, dailyCharCap: 1_000, requestsPerMinute: 600 }, fakeUpstash().fetchImpl)],
    ['in-memory', () => new InMemoryUsageLimiter({ deployment: 'production' as const, dailyCharCap: 1_000, requestsPerMinute: 600 })],
  ] as const) {
    test(`${name}: exact render allowance, per-purchase scope, once-only release, next UTC day`, async () => {
      const l = make();
      const charge = (bucket: string) => ({ bucket, chars: 10, charCap: 1_000, renderAllowance: 3 });
      const got = [];
      for (let i = 0; i < 4; i++) got.push(await l.reservePro(charge(PRO_A), NOON));
      assert.deepEqual(got.map((g) => (g.ok ? 'ok' : g.reason)), ['ok', 'ok', 'ok', 'pro_renders']);
      assert.equal((await l.reservePro(charge(PRO_B), NOON)).ok, true);
      const first = got[0];
      assert.ok(first.ok);
      assert.equal(await l.releasePro(first.reservation), true);
      assert.equal(await l.releasePro(first.reservation), false);
      assert.equal((await l.reservePro(charge(PRO_A), NOON)).ok, true);
      assert.equal((await l.reservePro(charge(PRO_A), NOON)).ok, false);
      assert.equal((await l.reservePro(charge(PRO_A), NOON + 12 * 3_600_000)).ok, true, 'next UTC day');
    });
    test(`${name}: global refusal first, then the clamped char cap`, async () => {
      const l = make();
      assert.deepEqual(await l.reservePro({ bucket: PRO_A, chars: 1_001, charCap: 5_000, renderAllowance: 3 }, NOON), { ok: false, reason: 'global_daily' });
      assert.deepEqual(await l.reservePro({ bucket: PRO_A, chars: 501, charCap: 500, renderAllowance: 3 }, NOON), { ok: false, reason: 'pro_chars' });
      assert.equal((await l.reservePro({ bucket: PRO_A, chars: 500, charCap: 500, renderAllowance: 3 }, NOON)).ok, true);
    });
    test(`${name}: global is checked before the render allowance (both exhausted: global_daily, nothing changes)`, async () => {
      const l = make();
      assert.equal((await l.reservePro({ bucket: PRO_A, chars: 10, charCap: 1_000, renderAllowance: 1 }, NOON)).ok, true);
      assert.deepEqual(await l.reservePro({ bucket: PRO_A, chars: 991, charCap: 1_000, renderAllowance: 1 }, NOON), { ok: false, reason: 'global_daily' });
      assert.deepEqual(await l.reservePro({ bucket: PRO_A, chars: 990, charCap: 1_000, renderAllowance: 1 }, NOON), { ok: false, reason: 'pro_renders' });
    });
    test(`${name}: rejects a bucket that is not pro:<deployment>:<sha256>`, async () => {
      const l = make();
      for (const bucket of ['owner', `pro:${sha(OTID_A)}`, `pro:staging:${sha(OTID_A)}`, `pro:production:${OTID_A}`]) {
        await assert.rejects(l.reservePro({ bucket, chars: 1, charCap: 10, renderAllowance: 3 }, NOON), TypeError);
      }
    });
  }
});

describe("Pro allowance: Fry's nits on #264", () => {
  // N2: a render that may have been billed stays counted (render and chars).
  const hang = (_u?: unknown, init?: RequestInit) =>
    new Promise<Response>((_, reject) => init?.signal?.addEventListener('abort', () => reject(new Error('aborted')), { once: true }));
  for (const [name, upstream, status] of [
    ['upstream timeout', hang, 504],
    ['network error', async () => { throw new TypeError('fetch failed'); }, 502],
    ['bad audio after a 2xx', async () => new Response(Buffer.alloc(0), { status: 200 }), 502],
  ] as const) {
    test(`N2: ${name} keeps the render and its chars counted (no refund)`, async () => {
      const lost: RefundLostLog[] = [];
      const h = harness({ upstream, lost });
      assert.equal((await handleTts(req(await subject()), h.d)).status, status);
      const k = keys(PRO_A);
      assert.deepEqual([h.redis.get(k.renders), h.redis.get(k.chars)], [1, TEXT.length]);
      assert.equal(h.calls.filter((c) => c.command[1] === PRO_RELEASE_SCRIPT).length, 0);
      assert.deepEqual(lost, []);
    });
  }

  // N1: a failed Pro refund logs one enum-only refund_lost line.
  for (const [name, error, reason] of [
    ['store error', new LimiterStoreError('x'), 'store'],
    ['timeout', new LimiterStoreError('x', true), 'timeout'],
  ] as const) {
    test(`N1: a failed Pro refund (${name}) logs refund_lost reason ${reason}, kind pro_render, no ids`, async () => {
      const lost: RefundLostLog[] = [];
      const inner = new RedisUsageLimiter(STORE, { deployment: 'production' as const, dailyCharCap: BIG, requestsPerMinute: 600 }, fakeUpstash().fetchImpl);
      const limiter: UsageLimiter = {
        durable: true,
        allowRequest: (b, n, l) => inner.allowRequest(b, n, l),
        reserve: (s, c, n) => inner.reserve(s, c, n),
        release: (r) => inner.release(r),
        reservePro: (c, n) => inner.reservePro(c, n),
        releasePro: async () => { throw error; },
      };
      const h = harness({ limiter, lost, upstream: async () => new Response('{}', { status: 500 }) });
      assert.equal((await handleTts(req(await subject()), h.d)).status, 502);
      assert.deepEqual(lost, [{ event: 'refund_lost', reason, chars: TEXT.length, kind: 'pro_render' }]);
      assert.ok(!JSON.stringify(lost).includes(sha(OTID_A)));
    });
  }

  // N3: concurrency through the real Lua with interleaved fetches.
  test('N3: 200 concurrent renders on one purchase: exactly 160 succeed, 40 get 429 daily_allowance', async () => {
    const h = harness();
    const a = await subject();
    const results = await Promise.all(Array.from({ length: 200 }, () => handleTts(req(a), h.d)));
    assert.equal(results.filter((r) => r.status === 200).length, 160);
    const refused = results.filter((r) => r.status === 429);
    assert.equal(refused.length, 40);
    assert.ok(refused.every((r) => body(r).reason === 'daily_allowance'));
    assert.equal(h.upstream(), 160);
    assert.equal(h.redis.get(keys(PRO_A).renders), 160);
    assert.equal(h.redis.get(keys(PRO_A).chars), 160 * TEXT.length);
  });

  test('N4: on a 502 one store call refunds the render, its chars and the global chars together', async () => {
    const h = harness({ upstream: async () => new Response('{}', { status: 500 }) });
    const before = h.calls.length;
    assert.equal((await handleTts(req(await subject()), h.d)).status, 502);
    const after = h.calls.slice(before).map((c) => c.command[1]);
    assert.equal(after.filter((s) => s === PRO_RELEASE_SCRIPT).length, 1);
    assert.equal(after.at(-1), PRO_RELEASE_SCRIPT);
  });
});
