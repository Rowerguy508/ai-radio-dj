/**
 * Per-subscriber daily CHAR cap for verified Pro (Sentinel on #264): env
 * `AERODJ_TTS_PRO_DAILY_CHARS`, default 12,000 (owner-confirmed), effective value clamped
 * to the global ceiling (Orion), charged to the Pro purchase's own bucket in the same atomic
 * step as the render allowance and the global ceiling. A verified Pro subject skips the
 * per-install 1,500/day cap (Orion and Nigel); the global ceiling still applies to everyone.
 * Real Lua via test/redis-lua.ts; real verified transactions via test/helpers/verified-tx.ts.
 */
import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { DEFAULT_PRO_DAILY_CHARS, MIN_PRO_DAILY_CHARS, handleTts, proDailyChars, secondsUntilNextUtcDay, type Deps, type Env, type LogEntry, type TtsRequest } from '../src/handler.js';
import {
  DEFAULT_GLOBAL_DAILY_CHAR_CAP,
  DEFAULT_INSTALL_DAILY_CHAR_CAP,
  PRO_RESERVE_SCRIPT,
  RedisUsageLimiter,
  effectiveProCharCap,
  proDayKeys,
  type LimiterOptions,
} from '../src/limiter.js';
import { proSubjectFromVerified, type ProSubject } from '../src/pro-allowance.js';
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
const ENV: Env = {
  AERODJ_TTS_TOKEN_SHA256: TOKEN_HASH,
  AERODJ_TTS_VOICE_IDS: VOICE,
  ELEVENLABS_API_KEY: 'test-elevenlabs-key-not-real',
  VERCEL_ENV: 'production',
  AERODJ_TTS_PRO_RATE_PER_MINUTE: '600',
};
const sha = (s: string) => crypto.createHash('sha256').update(s, 'utf8').digest('hex');
const keys = (otid: string) => {
  const [global, chars, renders] = proDayKeys(`pro:production:${sha(otid)}`, DAY);
  return { global, chars, renders };
};
const pcm = () => new Response(Buffer.alloc(22_050 * 2, 1), { status: 200, headers: { 'Content-Type': 'audio/pcm' } });
const body = (r: { body: Buffer }) => JSON.parse(r.body.toString('utf8')) as Record<string, unknown>;
const subject = async (otid = OTID_A) => proSubjectFromVerified(await verifiedTransaction(otid));
const req = (pro: ProSubject | undefined, n: number): TtsRequest => ({
  method: 'POST',
  authorization: `Bearer ${TOKEN}`,
  body: { upstream: 'elevenlabs', voiceId: VOICE, text: 'x'.repeat(n), format: 'text' },
  verifiedPro: pro,
});

function harness(o: { options?: Partial<LimiterOptions>; env?: Env; upstream?: () => Promise<Response> } = {}) {
  const up = fakeUpstash({ redis: new FakeRedis(() => NOON) });
  const logs: LogEntry[] = [];
  let upstreamCalls = 0;
  const d: Deps = {
    env: { ...ENV, ...o.env },
    fetch: (async () => { upstreamCalls++; return (o.upstream ?? pcm)(); }) as typeof fetch,
    limiter: new RedisUsageLimiter(STORE, { dailyCharCap: BIG, requestsPerMinute: 600, ...o.options }, up.fetchImpl),
    log: (e) => logs.push(e),
    now: () => NOON,
    timeoutMs: 50,
    requestId: () => 'req-1',
  };
  return { d, logs, redis: up.redis, calls: up.calls, upstream: () => upstreamCalls };
}

/** Spends `total` chars for `pro` in 600-char requests (the per-request cap) plus a remainder. */
async function spend(h: ReturnType<typeof harness>, pro: ProSubject | undefined, total: number) {
  for (let left = total; left > 0; left -= 600) {
    const r = await handleTts(req(pro, Math.min(600, left)), h.d);
    assert.equal(r.status, 200, `spending at ${total - left}`);
  }
}

describe('Pro char cap: configuration', () => {
  test('default 12,000 (owner-confirmed); unset uses it; floor is one full request (600)', () => {
    assert.equal(DEFAULT_PRO_DAILY_CHARS, 12_000);
    assert.equal(MIN_PRO_DAILY_CHARS, 600);
    assert.equal(proDailyChars({}), 12_000);
    assert.equal(proDailyChars({ AERODJ_TTS_PRO_DAILY_CHARS: '600' }), 600);
    assert.equal(proDailyChars({ AERODJ_TTS_PRO_DAILY_CHARS: '20000' }), 20_000);
  });

  for (const bad of ['', 'abc', '0', '599', '-1', '12000.5', '1e4', '0x2ee0', '10000001', 'Infinity']) {
    test(`AERODJ_TTS_PRO_DAILY_CHARS=${JSON.stringify(bad)}: Pro is 500 misconfig before any store or upstream call; owner unaffected`, async () => {
      assert.equal(proDailyChars({ AERODJ_TTS_PRO_DAILY_CHARS: bad }), null);
      const h = harness({ env: { AERODJ_TTS_PRO_DAILY_CHARS: bad } });
      const r = await handleTts(req(await subject(), 10), h.d);
      assert.equal(r.status, 500);
      assert.equal(body(r).reason, 'misconfig');
      assert.equal(h.calls.length, 0);
      assert.equal(h.upstream(), 0);
      assert.equal((await handleTts(req(undefined, 10), h.d)).status, 200);
    });
  }
});

describe('Pro char cap: clamp to the global ceiling (Orion)', () => {
  test('effective = min(configured, global): 12,000 with 9,000 global is 9,000; a lower value wins', () => {
    assert.equal(DEFAULT_GLOBAL_DAILY_CHAR_CAP, 9_000);
    assert.equal(effectiveProCharCap(12_000, 9_000), 9_000);
    assert.equal(effectiveProCharCap(1_200, 9_000), 1_200);
    assert.equal(effectiveProCharCap(9_000, 9_000), 9_000);
  });

  test('12,000 configured with 9,000 global: the script is handed 9,000; 9,000 succeed, the next char is refused', async () => {
    const h = harness({ options: { dailyCharCap: 9_000 } });
    const A = await subject();
    await spend(h, A, 9_000);
    const proArgs = h.calls.find((c) => c.command[1] === PRO_RESERVE_SCRIPT)?.command;
    // EVAL, script, numKeys=3, 3 keys, then chars, global cap, effective Pro cap, renders, ttl.
    assert.equal(proArgs?.[2], 3);
    assert.equal(String(proArgs?.[8]), '9000');
    assert.equal(String(proArgs?.[7]), '9000');
    const r = await handleTts(req(A, 1), h.d);
    assert.equal(r.status, 429);
    assert.equal(h.redis.get(keys(OTID_A).chars), 9_000);
  });

  test('a lower per-subscriber value wins over the global ceiling', async () => {
    const h = harness({ env: { AERODJ_TTS_PRO_DAILY_CHARS: '1200' } });
    const A = await subject();
    await spend(h, A, 1_200);
    const r = await handleTts(req(A, 1), h.d);
    assert.equal(r.status, 429);
    assert.equal(body(r).reason, 'daily_allowance');
    assert.equal(h.logs.at(-1)?.reason, 'pro_chars');
  });
});

describe('Pro char cap: enforcement (default 12,000, global raised so the cap itself is visible)', () => {
  test('exactly at the cap succeeds; +1 char is 429 daily_allowance (log pro_chars) before any upstream call; nothing else changes', async () => {
    const h = harness();
    const A = await subject();
    await spend(h, A, 12_000);
    const k = keys(OTID_A);
    const before = { renders: h.redis.get(k.renders), chars: h.redis.get(k.chars), global: h.redis.get(k.global), up: h.upstream() };
    assert.deepEqual(before, { renders: 20, chars: 12_000, global: 12_000, up: 20 });
    const r = await handleTts(req(A, 1), h.d);
    assert.equal(r.status, 429);
    assert.equal(r.headers['Retry-After'], String(secondsUntilNextUtcDay(NOON)));
    assert.deepEqual(body(r), { error: 'Too many requests', requestId: 'req-1', reason: 'daily_allowance', retryAfterSeconds: 43200 });
    assert.deepEqual(h.logs.at(-1), { requestId: 'req-1', status: 429, chars: 1, reason: 'pro_chars' });
    assert.deepEqual({ renders: h.redis.get(k.renders), chars: h.redis.get(k.chars), global: h.redis.get(k.global), up: h.upstream() }, before);
  });

  test('another subscriber is unaffected', async () => {
    const h = harness();
    await spend(h, await subject(), 12_000);
    assert.equal((await handleTts(req(await subject(OTID_A), 1), h.d)).status, 429);
    assert.equal((await handleTts(req(await subject(OTID_B), 600), h.d)).status, 200);
    assert.equal(h.redis.get(keys(OTID_B).chars), 600);
  });

  test('a refund (upstream non-2xx) restores the chars', async () => {
    let fail = false;
    const h = harness({ upstream: async () => (fail ? new Response('{}', { status: 500 }) : pcm()) });
    const A = await subject();
    await spend(h, A, 11_400);
    fail = true;
    assert.equal((await handleTts(req(A, 600), h.d)).status, 502);
    assert.equal(h.redis.get(keys(OTID_A).chars), 11_400);
    fail = false;
    assert.equal((await handleTts(req(A, 600), h.d)).status, 200);
    assert.equal(h.redis.get(keys(OTID_A).chars), 12_000);
  });

  test('store error on the Pro reserve: 503 store, Retry-After 30, no upstream call', async () => {
    const up = fakeUpstash({ status: 500 });
    const h = harness();
    h.d.limiter = new RedisUsageLimiter(STORE, { dailyCharCap: BIG, requestsPerMinute: 600 }, up.fetchImpl);
    const r = await handleTts(req(await subject(), 10), h.d);
    assert.equal(r.status, 503);
    assert.equal(r.headers['Retry-After'], '30');
    assert.equal(body(r).reason, 'store');
    assert.equal(h.upstream(), 0);
  });
});

describe('Per-install bypass: verified Pro only (Orion, Nigel; Sentinel conditions)', () => {
  test('a verified Pro subject goes past the 1,500/day install cap, up to its own cap', async () => {
    const h = harness({ options: { installDailyCharCap: DEFAULT_INSTALL_DAILY_CHAR_CAP } });
    assert.equal(DEFAULT_INSTALL_DAILY_CHAR_CAP, 1_500);
    const A = await subject();
    await spend(h, A, 3_000);
    assert.equal(h.redis.get(keys(OTID_A).chars), 3_000);
    assert.ok(![...h.redis.data.keys()].some((k) => k.includes(':install:')));
  });

  test('an unverified install is still capped at 1,500 (limiter level; PR 6 picks install vs Pro)', async () => {
    const limiter = new RedisUsageLimiter(STORE, { dailyCharCap: BIG, requestsPerMinute: 600 }, fakeUpstash().fetchImpl);
    const install = { kind: 'install' as const, id: 'a'.repeat(64) };
    assert.equal((await limiter.reserve(install, 1_500, NOON)).ok, true);
    assert.deepEqual(await limiter.reserve(install, 1, NOON), { ok: false, reason: 'install_daily' });
  });

  test('an unverified request with a fake Pro-looking body field stays on its own (non-Pro) cap', async () => {
    const h = harness({ options: { ownerDailyCharCap: 1_500 } });
    const fake = (n: number): TtsRequest => ({ ...req(undefined, n), body: { ...(req(undefined, n).body as object), verifiedPro: { kind: 'pro', hash: sha(OTID_A) }, originalTransactionId: OTID_A } });
    for (let i = 0; i < 3; i++) assert.equal((await handleTts(fake(500), h.d)).status, 200);
    const r = await handleTts(fake(1), h.d);
    assert.equal(r.status, 429);
    assert.equal(body(r).reason, 'owner_daily');
    assert.ok(![...h.redis.data.keys()].some((k) => k.includes(':pro:')));
  });

  test('the global ceiling still stops a verified Pro subject (429 global_daily, no Pro counter moves)', async () => {
    const h = harness({ options: { dailyCharCap: 2_000 } });
    await spend(h, undefined, 1_800);
    const A = await subject();
    const r = await handleTts(req(A, 300), h.d);
    assert.equal(r.status, 429);
    assert.equal(body(r).reason, 'global_daily');
    assert.equal(h.redis.data.has(keys(OTID_A).chars), false);
    assert.equal(h.redis.data.has(keys(OTID_A).renders), false);
    assert.equal((await handleTts(req(A, 200), h.d)).status, 200, 'what is left of the global ceiling is still usable');
  });
});
