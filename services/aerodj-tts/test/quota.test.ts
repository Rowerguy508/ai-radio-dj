/**
 * Per-install + global daily quotas and the 429 / 503 `reason` + Retry-After contract
 * (design note #233, PR 1). Redis tests run the limiter's REAL Lua scripts (test/redis-lua.ts).
 */
import { test, mock } from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { handleTts, limiterOptions, parseCharCap, parseRatePerMinute, secondsUntilNextUtcDay, type Deps, type Env, type LogEntry } from '../src/handler.js';
import {
  DEFAULT_GLOBAL_DAILY_CHAR_CAP,
  DEFAULT_INSTALL_DAILY_CHAR_CAP,
  InMemoryUsageLimiter,
  MAX_CONFIGURED_CHAR_CAP,
  MAX_CONFIGURED_REQUESTS_PER_MINUTE,
  OWNER_SUBJECT,
  RedisUsageLimiter,
  RATE_SCRIPT,
  RELEASE2_SCRIPT,
  RESERVE2_SCRIPT,
  refundMarkerKey,
  subjectBucket,
  type LimiterOptions,
  type Subject,
  type UsageLimiter,
} from '../src/limiter.js';
import { FakeRedis, fakeUpstash } from './redis-lua.js';

const TOKEN = 'test-owner-token-not-a-real-secret';
const TOKEN_HASH = crypto.createHash('sha256').update(TOKEN).digest('hex');
const VOICE = 'voiceAllowed123';
const STORE = { url: 'https://store.example.upstash.io', token: 'test-store-token-not-real' };
const NOON = Date.UTC(2026, 9, 28, 12);
const DAY = '2026-10-28';
const A: Subject = { kind: 'install', id: 'install-key-id-A' };
const B: Subject = { kind: 'install', id: 'install-key-id-B' };

const env = (o: Env = {}): Env => ({
  AERODJ_TTS_TOKEN_SHA256: TOKEN_HASH,
  AERODJ_TTS_VOICE_IDS: VOICE,
  ELEVENLABS_API_KEY: 'test-elevenlabs-key-not-real',
  ...o,
});

function pcm(): Response {
  return new Response(Buffer.alloc(22_050 * 2, 1), { status: 200, headers: { 'Content-Type': 'audio/pcm' } });
}

function deps(limiter: UsageLimiter, o: { fetch?: () => Promise<Response>; now?: number } = {}) {
  const logs: LogEntry[] = [];
  let upstreamCalls = 0;
  const d: Deps = {
    env: env(),
    fetch: (async () => {
      upstreamCalls++;
      return (o.fetch ?? (async () => pcm()))();
    }) as typeof fetch,
    limiter,
    log: (e) => logs.push(e),
    now: () => o.now ?? NOON,
    timeoutMs: 50,
    requestId: () => 'req-1',
  };
  return { d, logs, upstream: () => upstreamCalls };
}

const req = (text: string, extra: Record<string, unknown> = {}) => ({
  method: 'POST',
  authorization: `Bearer ${TOKEN}`,
  body: { upstream: 'elevenlabs', voiceId: VOICE, text, format: 'text', ...extra },
});

const body = (r: { body: Buffer }) => JSON.parse(r.body.toString('utf8')) as Record<string, unknown>;

/** Both limiter implementations, with the same options. */
function limiters(options: LimiterOptions): [string, UsageLimiter, FakeRedis | null][] {
  const store = fakeUpstash();
  return [
    ['in-memory', new InMemoryUsageLimiter(options), null],
    ['redis (real Lua)', new RedisUsageLimiter(STORE, options, store.fetchImpl), store.redis],
  ];
}

const ownerKey = `aerodj-tts:chars:owner:production:${DAY}`;
const globalKey = `aerodj-tts:chars:global:production:${DAY}`;
const installKey = (s: Subject) => `aerodj-tts:chars:${subjectBucket(s).replace(/^install:/, 'install:production:')}:${DAY}`;
const isRefundMarker = (key: string | undefined) => typeof key === 'string' && key.startsWith('refund:{aerodj-tts}:');
const counterSets = (redis: FakeRedis) => redis.commands.filter((c) => c[0] === 'SET' && !isRefundMarker(c[1]));
const markerSets = (redis: FakeRedis) => redis.commands.filter((c) => c[0] === 'SET' && isRefundMarker(c[1]));

// --- Per-install and global buckets ---

test('one install exhausting its cap does not block another install', async () => {
  for (const [name, limiter] of limiters({ deployment: 'production' as const, dailyCharCap: 9_000, installDailyCharCap: 1_500, requestsPerMinute: 100 })) {
    assert.equal((await limiter.reserve(A, 1_500, NOON)).ok, true, name);
    assert.deepEqual(await limiter.reserve(A, 1, NOON), { ok: false, reason: 'install_daily' }, name);
    assert.equal((await limiter.reserve(B, 1_500, NOON)).ok, true, `${name}: B unaffected`);
  }
});

test('the global ceiling blocks every caller, owner included, with reason global_daily', async () => {
  for (const [name, limiter] of limiters({ deployment: 'production' as const, dailyCharCap: 3_000, installDailyCharCap: 1_500, requestsPerMinute: 100 })) {
    assert.equal((await limiter.reserve(A, 1_500, NOON)).ok, true);
    assert.equal((await limiter.reserve(B, 1_000, NOON)).ok, true);
    assert.equal((await limiter.reserve(OWNER_SUBJECT, 500, NOON)).ok, true, `${name}: owner counts in global`);
    const fresh: Subject = { kind: 'install', id: 'install-key-id-C' };
    assert.deepEqual(await limiter.reserve(fresh, 1, NOON), { ok: false, reason: 'global_daily' }, name);
    assert.deepEqual(await limiter.reserve(OWNER_SUBJECT, 1, NOON), { ok: false, reason: 'global_daily' }, name);
    assert.deepEqual(await limiter.reserve(B, 1, NOON), { ok: false, reason: 'global_daily' }, name);
  }
});

test('owner has its own cap bucket, still counted in the global ceiling', async () => {
  for (const [name, limiter, redis] of limiters({ deployment: 'production' as const, dailyCharCap: 9_000, ownerDailyCharCap: 1_000, requestsPerMinute: 100 })) {
    assert.equal((await limiter.reserve(OWNER_SUBJECT, 1_000, NOON)).ok, true);
    assert.deepEqual(await limiter.reserve(OWNER_SUBJECT, 1, NOON), { ok: false, reason: 'owner_daily' }, name);
    assert.equal((await limiter.reserve(A, 1_500, NOON)).ok, true, `${name}: installs unaffected by the owner cap`);
    if (redis) {
      assert.equal(redis.get(ownerKey), 1_000);
      assert.equal(redis.get(globalKey), 2_500);
    } else {
      const mem = limiter as InMemoryUsageLimiter;
      assert.equal(mem.used('owner', NOON), 1_000);
      assert.equal(mem.used('global', NOON), 2_500);
    }
  }
});

test('owner default stays today\'s behaviour: one 9,000/day budget, and installs share the same ceiling', async () => {
  for (const [name, limiter] of limiters(limiterOptions({ AERODJ_TTS_DAILY_CHAR_CAP: '9000', VERCEL_ENV: 'production' }))) {
    for (let i = 0; i < 15; i++) assert.equal((await limiter.reserve(OWNER_SUBJECT, 600, NOON)).ok, true, `${name} #${i}`);
    assert.deepEqual(await limiter.reserve(OWNER_SUBJECT, 1, NOON), { ok: false, reason: 'owner_daily' }, name);
    assert.deepEqual(await limiter.reserve(A, 1, NOON), { ok: false, reason: 'global_daily' }, name);
  }
});

// --- All-or-nothing ---

test('all-or-nothing: a refusal on either bucket changes neither counter (real Lua)', async () => {
  const store = fakeUpstash();
  const limiter = new RedisUsageLimiter(STORE, { deployment: 'production' as const, dailyCharCap: 2_000, installDailyCharCap: 1_500, requestsPerMinute: 100 }, store.fetchImpl);
  assert.equal((await limiter.reserve(A, 1_400, NOON)).ok, true);
  // Install cap refuses: global must not move.
  assert.deepEqual(await limiter.reserve(A, 200, NOON), { ok: false, reason: 'install_daily' });
  assert.equal(store.redis.get(globalKey), 1_400);
  assert.equal(store.redis.get(installKey(A)), 1_400);
  // Global refuses: B's own bucket must not move.
  assert.deepEqual(await limiter.reserve(B, 700, NOON), { ok: false, reason: 'global_daily' });
  assert.equal(store.redis.get(installKey(B)), 0);
  assert.equal(store.redis.get(globalKey), 1_400);
  // Exactly at the edge still fits.
  assert.equal((await limiter.reserve(B, 600, NOON)).ok, true);
  assert.equal(store.redis.get(globalKey), 2_000);
});

test('all-or-nothing: the in-memory limiter matches', async () => {
  const limiter = new InMemoryUsageLimiter({ deployment: 'production' as const, dailyCharCap: 2_000, installDailyCharCap: 1_500, requestsPerMinute: 100 });
  assert.equal((await limiter.reserve(A, 1_400, NOON)).ok, true);
  assert.equal((await limiter.reserve(A, 200, NOON)).ok, false);
  assert.equal(limiter.used('global', NOON), 1_400);
  assert.equal((await limiter.reserve(B, 700, NOON)).ok, false);
  assert.equal(limiter.used(subjectBucket(B), NOON), 0);
});

test('concurrent reservations from two instances on the shared store never exceed the global ceiling', async () => {
  const store = fakeUpstash();
  const options = { deployment: 'production' as const, dailyCharCap: 1_000, installDailyCharCap: 1_000, requestsPerMinute: 100 };
  const one = new RedisUsageLimiter(STORE, options, store.fetchImpl);
  const two = new RedisUsageLimiter(STORE, options, store.fetchImpl);
  const subjects: Subject[] = Array.from({ length: 8 }, (_, i) => ({ kind: 'install', id: `install-key-id-${i}` }));
  const results = await Promise.all(subjects.map((s, i) => (i % 2 ? one : two).reserve(s, 300, NOON)));
  assert.equal(results.filter((r) => r.ok).length, 3);
  assert.ok(results.filter((r) => !r.ok).every((r) => !r.ok && r.reason === 'global_daily'));
  assert.equal(store.redis.get(globalKey), 900);
  const perInstall = subjects.reduce((sum, s) => sum + store.redis.get(installKey(s)), 0);
  assert.equal(perInstall, 900, 'refused installs were not charged');
});

test('Lua and in-memory limiters agree on a random reserve/release sequence', async () => {
  const options = { deployment: 'production' as const, dailyCharCap: 5_000, installDailyCharCap: 1_500, ownerDailyCharCap: 2_500, requestsPerMinute: 100 };
  const [[, mem], [, redis]] = limiters(options);
  const subjects: Subject[] = [OWNER_SUBJECT, A, B, { kind: 'install', id: 'install-key-id-C' }];
  let seed = 7;
  const rand = (n: number) => ((seed = (seed * 1_103_515_245 + 12_345) % 2 ** 31) % n);
  const heldMem: Parameters<UsageLimiter['release']>[0][] = [];
  const heldRedis: Parameters<UsageLimiter['release']>[0][] = [];
  for (let i = 0; i < 300; i++) {
    if (rand(4) === 0 && heldMem.length) {
      const k = rand(heldMem.length);
      await mem.release(heldMem.splice(k, 1)[0]);
      await redis.release(heldRedis.splice(k, 1)[0]);
      continue;
    }
    const s = subjects[rand(subjects.length)];
    const chars = 1 + rand(600);
    const m = await mem.reserve(s, chars, NOON);
    const r = await redis.reserve(s, chars, NOON);
    assert.deepEqual(r.ok ? 'ok' : r.reason, m.ok ? 'ok' : m.reason, `step ${i}`);
    if (m.ok && r.ok) {
      heldMem.push(m.reservation);
      heldRedis.push(r.reservation);
    }
  }
});

// --- Refund and UTC reset ---

test('upstream non-2xx refunds both the owner bucket and the global ceiling (real Lua)', async () => {
  const store = fakeUpstash();
  const limiter = new RedisUsageLimiter(STORE, limiterOptions({ VERCEL_ENV: 'production' }), store.fetchImpl);
  const h = deps(limiter, { fetch: async () => new Response('nope', { status: 500 }) });
  assert.equal((await handleTts(req('x'.repeat(600)), h.d)).status, 502);
  assert.equal(store.redis.get(ownerKey), 0);
  assert.equal(store.redis.get(globalKey), 0);
  const ok = deps(limiter);
  assert.equal((await handleTts(req('x'.repeat(600)), ok.d)).status, 200);
  assert.equal(store.redis.get(ownerKey), 600);
  assert.equal(store.redis.get(globalKey), 600);
});

test('refund on an install reservation releases both buckets, floored at zero, keeping TTLs', async () => {
  for (const [name, limiter, redis] of limiters({ deployment: 'production' as const, dailyCharCap: 9_000, requestsPerMinute: 100 })) {
    const r = await limiter.reserve(A, 500, NOON);
    assert.ok(r.ok);
    await limiter.release(r.reservation);
    await limiter.release(r.reservation); // double release never goes negative
    if (redis) {
      assert.equal(redis.get(installKey(A)), 0, name);
      assert.equal(redis.get(globalKey), 0, name);
      assert.ok(redis.expiresAt.has(installKey(A)) && redis.expiresAt.has(globalKey), 'KEEPTTL');
    } else {
      const mem = limiter as InMemoryUsageLimiter;
      assert.equal(mem.used(subjectBucket(A), NOON), 0);
      assert.equal(mem.used('global', NOON), 0);
    }
  }
});

test('refund floor: a counter above 0 but below the refund amount clamps to 0, never negative (real Lua)', async () => {
  const store = fakeUpstash();
  const limiter = new RedisUsageLimiter(STORE, { deployment: 'production' as const, dailyCharCap: 9_000, requestsPerMinute: 100 }, store.fetchImpl);
  const r = await limiter.reserve(A, 500, NOON);
  assert.ok(r.ok);
  // The counters dropped below this reservation after it was taken (e.g. the store was
  // reset or the key expired and was recreated): 0 < counter < refund amount.
  store.redis.data.set(installKey(A), '200');
  store.redis.data.set(globalKey, '100');
  await limiter.release(r.reservation);
  assert.equal(store.redis.data.get(installKey(A)), '0');
  assert.equal(store.redis.data.get(globalKey), '0');
  assert.ok(store.redis.expiresAt.has(installKey(A)) && store.redis.expiresAt.has(globalKey), 'KEEPTTL');
});

test('refund that would go below zero: an absent or zero counter is left untouched (real Lua)', async () => {
  const store = fakeUpstash();
  const limiter = new RedisUsageLimiter(STORE, { deployment: 'production' as const, dailyCharCap: 9_000, requestsPerMinute: 100 }, store.fetchImpl);
  // A reservation for a day whose counters no longer exist (expired, or never written).
  await limiter.release({ rid: crypto.randomUUID(), bucket: subjectBucket(A), day: DAY, chars: 500 });
  assert.equal(store.redis.data.has(installKey(A)), false, 'no counter is created');
  assert.equal(store.redis.data.has(globalKey), false, 'no counter is created');
  assert.equal(counterSets(store.redis).length, 0, 'no counter key is written');
  // The only key written is the per-charge refund marker (PR 3), and it carries a TTL.
  const markers = markerSets(store.redis);
  assert.equal(markers.length, 1);
  assert.ok(store.redis.expiresAt.has(markers[0][1]), 'refund marker has a TTL');
  // Counters at exactly 0 stay 0.
  store.redis.data.set(installKey(A), '0');
  store.redis.data.set(globalKey, '0');
  await limiter.release({ rid: crypto.randomUUID(), bucket: subjectBucket(A), day: DAY, chars: 500 });
  assert.equal(store.redis.data.get(installKey(A)), '0');
  assert.equal(store.redis.data.get(globalKey), '0');
});

test('double refund: a non-2xx request releases its charge exactly once, so other callers stay counted', async () => {
  for (const [name, limiter, redis] of limiters({ deployment: 'production' as const, dailyCharCap: 9_000, requestsPerMinute: 100 })) {
    // Another caller already holds 300 of the global ceiling.
    assert.ok((await limiter.reserve(B, 300, NOON)).ok);
    const releases: unknown[] = [];
    const counting: UsageLimiter = {
      durable: limiter.durable,
      allowRequest: (b, n) => limiter.allowRequest(b, n),
      reserve: (s, c, n) => limiter.reserve(s, c, n),
      release: (r) => {
        releases.push(r);
        return limiter.release(r);
      },
    };
    const h = deps(counting, { fetch: async () => new Response('nope', { status: 500 }) });
    assert.equal((await handleTts(req('x'.repeat(500)), h.d)).status, 502, name);
    assert.equal(releases.length, 1, `${name}: one release per charge`);
    if (redis) {
      assert.equal(redis.get(ownerKey), 0, name);
      assert.equal(redis.get(globalKey), 300, `${name}: B's 300 is still counted`);
      assert.equal(counterSets(redis).length, 2, `${name}: one RELEASE2 (2 counter SETs)`);
      assert.equal(markerSets(redis).length, 1, `${name}: one refund marker`);
    } else {
      const mem = limiter as InMemoryUsageLimiter;
      assert.equal(mem.used('owner', NOON), 0);
      assert.equal(mem.used('global', NOON), 300, `${name}: B's 300 is still counted`);
    }
  }
});

// Per-charge refund marker (Fry D2, note §4.3, PR 3 gate). Replaces #241's `todo`, split into
// one test per limiter so a failure in one cannot hide the other (the old loop stopped at the
// in-memory limiter and never reached the Redis script).
test('double refund of the same reservation applies once: in-memory limiter (per-charge marker, PR 3 gate)', async () => {
  const limiter = new InMemoryUsageLimiter({ deployment: 'production' as const, dailyCharCap: 9_000, requestsPerMinute: 100 });
  assert.ok((await limiter.reserve(B, 300, NOON)).ok);
  const r = await limiter.reserve(A, 500, NOON);
  assert.ok(r.ok);
  assert.equal(await limiter.release(r.reservation), true, 'first release applies');
  assert.equal(await limiter.release(r.reservation), false, 'second release is a no-op');
  assert.equal(await limiter.release({ ...r.reservation }), false, 'a copy of the same reservation is still the same charge');
  assert.equal(limiter.used('global', NOON), 300, "B's 300 must still be counted");
  assert.equal(limiter.used(subjectBucket(B), NOON), 300);
  assert.equal(limiter.used(subjectBucket(A), NOON), 0);
});

test('double refund of the same reservation applies once: Upstash limiter, real RELEASE2 Lua (per-charge marker, PR 3 gate)', async () => {
  const store = fakeUpstash();
  const limiter = new RedisUsageLimiter(STORE, { deployment: 'production' as const, dailyCharCap: 9_000, requestsPerMinute: 100 }, store.fetchImpl);
  assert.ok((await limiter.reserve(B, 300, NOON)).ok);
  const r = await limiter.reserve(A, 500, NOON);
  assert.ok(r.ok);
  assert.equal(await limiter.release(r.reservation), true, 'first release applies');
  assert.equal(await limiter.release(r.reservation), false, 'second release is a no-op');
  assert.equal(store.redis.get(globalKey), 300, "B's 300 must still be counted");
  assert.equal(store.redis.get(installKey(B)), 300);
  assert.equal(store.redis.get(installKey(A)), 0);
  assert.equal(counterSets(store.redis).length, 2, 'only the first release touched the counters');
  const marker = `refund:{aerodj-tts}:${r.reservation.rid}`;
  assert.equal(store.redis.data.get(marker), '1');
  assert.equal(store.redis.expiresAt.get(marker), NOON + 172_800 * 1000, 'marker lives 2 days, like the day counters');
});

test('refund marker is per charge: two reservations of the same size each refund once', async () => {
  for (const make of [
    () => ({ limiter: new InMemoryUsageLimiter({ deployment: 'production' as const, dailyCharCap: 9_000, requestsPerMinute: 100 }) as UsageLimiter, read: (l: UsageLimiter) => (l as InMemoryUsageLimiter).used('global', NOON) }),
    () => {
      const store = fakeUpstash();
      return { limiter: new RedisUsageLimiter(STORE, { deployment: 'production' as const, dailyCharCap: 9_000, requestsPerMinute: 100 }, store.fetchImpl) as UsageLimiter, read: () => store.redis.get(globalKey) };
    },
  ]) {
    const { limiter, read } = make();
    const r1 = await limiter.reserve(A, 500, NOON);
    const r2 = await limiter.reserve(A, 500, NOON);
    assert.ok(r1.ok && r2.ok);
    assert.notEqual(r1.reservation.rid, r2.reservation.rid, 'server-generated rid is unique per charge');
    assert.equal(await limiter.release(r1.reservation), true);
    assert.equal(read(limiter), 500);
    assert.equal(await limiter.release(r2.reservation), true);
    assert.equal(read(limiter), 0);
  }
});

test('refund marker key: only a server-generated UUID rid is accepted, so no client value can address another key', async () => {
  const rid = crypto.randomUUID();
  assert.equal(refundMarkerKey(rid), `refund:{aerodj-tts}:${rid}`);
  for (const bad of ['', 'x', `${rid}:x`, `${rid}*`, rid.toUpperCase(), 'refund:{aerodj-tts}:*']) {
    assert.throws(() => refundMarkerKey(bad), TypeError, bad);
  }
  const store = fakeUpstash();
  const limiter = new RedisUsageLimiter(STORE, { deployment: 'production' as const, dailyCharCap: 9_000, requestsPerMinute: 100 }, store.fetchImpl);
  await assert.rejects(limiter.release({ rid: '*', bucket: subjectBucket(A), day: DAY, chars: 1 }), TypeError);
  assert.equal(store.calls.length, 0, 'nothing reaches the store');
});

test('RELEASE2 script runs the SET NX marker before touching any counter', () => {
  const marker = RELEASE2_SCRIPT.indexOf("'NX'");
  assert.ok(marker >= 0 && marker < RELEASE2_SCRIPT.indexOf('KEYS[i]'));
});

test('both buckets reset at 00:00 UTC; day keys carry a 2-day TTL', async () => {
  const late = Date.UTC(2026, 9, 28, 23, 59, 30);
  const next = Date.UTC(2026, 9, 29, 0, 0, 1);
  for (const [name, limiter, redis] of limiters({ deployment: 'production' as const, dailyCharCap: 1_000, installDailyCharCap: 600, requestsPerMinute: 100 })) {
    assert.equal((await limiter.reserve(A, 600, late)).ok, true);
    assert.equal((await limiter.reserve(B, 400, late)).ok, true);
    assert.equal((await limiter.reserve(A, 1, late)).ok, false);
    assert.equal((await limiter.reserve(A, 600, next)).ok, true, `${name}: install resets`);
    assert.equal((await limiter.reserve(B, 400, next)).ok, true, `${name}: global resets`);
    if (redis) {
      assert.equal(redis.get(`aerodj-tts:chars:global:production:2026-10-29`), 1_000);
      for (const cmd of redis.commands.filter((c) => c[0] === 'EXPIRE')) assert.equal(cmd[2], '172800');
    }
  }
});

// --- 429 / 503 contract ---

const CONTRACT_KEYS = ['error', 'reason', 'requestId', 'retryAfterSeconds'];

test('daily 429: Retry-After = seconds to next UTC midnight, enum reason, numbers only', async () => {
  const at = Date.UTC(2026, 9, 28, 23, 59, 30, 250);
  const limiter = new InMemoryUsageLimiter({ deployment: 'production' as const, dailyCharCap: 10, requestsPerMinute: 100 });
  const h = deps(limiter, { now: at });
  const res = await handleTts(req('x'.repeat(11)), h.d);
  assert.equal(res.status, 429);
  assert.equal(res.headers['Retry-After'], '30');
  const b = body(res);
  assert.deepEqual(Object.keys(b).sort(), CONTRACT_KEYS);
  assert.deepEqual(b, { error: 'Too many requests', requestId: 'req-1', reason: 'owner_daily', retryAfterSeconds: 30 });
  assert.equal(h.upstream(), 0);
  assert.equal(secondsUntilNextUtcDay(NOON), 12 * 3600);
  assert.equal(secondsUntilNextUtcDay(Date.UTC(2026, 9, 28, 23, 59, 59, 999)), 1, 'never 0');
  assert.equal(secondsUntilNextUtcDay(Date.UTC(2026, 9, 29)), 24 * 3600);
});

test('global 429 through the handler: reason global_daily when installs already filled the ceiling', async () => {
  const limiter = new InMemoryUsageLimiter({ deployment: 'production' as const, dailyCharCap: 1_000, ownerDailyCharCap: 1_000, requestsPerMinute: 100 });
  assert.equal((await limiter.reserve(A, 900, NOON)).ok, true);
  const h = deps(limiter);
  const res = await handleTts(req('x'.repeat(200)), h.d);
  assert.equal(res.status, 429);
  assert.equal(body(res).reason, 'global_daily');
  assert.equal(res.headers['Retry-After'], String(12 * 3600));
  assert.equal(h.upstream(), 0);
});

test('rate 429 and store 503 carry reason and Retry-After 60 (rate) and 30 (store, note §4.4)', async () => {
  const rate = deps(new InMemoryUsageLimiter({ deployment: 'production' as const, dailyCharCap: 9_000, requestsPerMinute: 1 }));
  assert.equal((await handleTts(req('hi'), rate.d)).status, 200);
  const limited = await handleTts(req('hi'), rate.d);
  assert.equal(limited.status, 429);
  assert.equal(limited.headers['Retry-After'], '60');
  assert.deepEqual(body(limited), { error: 'Too many requests', requestId: 'req-1', reason: 'rate', retryAfterSeconds: 60 });

  const down = fakeUpstash({ status: 500 });
  const store = deps(new RedisUsageLimiter(STORE, limiterOptions({ VERCEL_ENV: 'production' }), down.fetchImpl));
  const res = await handleTts(req('hi'), store.d);
  assert.equal(res.status, 503);
  assert.equal(res.headers['Retry-After'], '30');
  assert.deepEqual(body(res), { error: 'Service unavailable', requestId: 'req-1', reason: 'store', retryAfterSeconds: 30 });
  assert.equal(store.upstream(), 0);
});

test('a store error at reserve (after the rate check passed) fails closed: 503 store, no upstream call', async () => {
  const failures: [string, (() => Promise<Response>)][] = [
    ['HTTP 500', async () => new Response('{"error":"down"}', { status: 500 })],
    ['network error', async () => { throw new TypeError('fetch failed'); }],
    ['error payload', async () => new Response('{"error":"ERR script"}', { status: 200 })],
    ['non-numeric result', async () => new Response('{"result":"OK"}', { status: 200 })],
    ['unknown negative result', async () => new Response('{"result":-3}', { status: 200 })],
  ];
  for (const [name, fail] of failures) {
    const store = fakeUpstash();
    let reserveCalls = 0;
    const fetchImpl = (async (url: string, init: RequestInit) => {
      const command = JSON.parse(String(init.body)) as unknown[];
      if (command[1] === RESERVE2_SCRIPT) {
        reserveCalls++;
        return fail();
      }
      assert.equal(command[1], RATE_SCRIPT, `${name}: only the rate check reaches the store`);
      return store.fetchImpl(url, init);
    }) as typeof fetch;
    const h = deps(new RedisUsageLimiter(STORE, limiterOptions({ VERCEL_ENV: 'production' }), fetchImpl));
    const res = await handleTts(req('hi'), h.d);
    assert.equal(reserveCalls, 1, `${name}: the rate check passed and reserve was attempted`);
    assert.equal(res.status, 503, name);
    assert.deepEqual(body(res), { error: 'Service unavailable', requestId: 'req-1', reason: 'store', retryAfterSeconds: 30 }, name);
    assert.equal(h.upstream(), 0, `${name}: upstream never called`);
    assert.equal(store.redis.commands.some((c) => c[0] === 'INCRBY'), false, `${name}: nothing reserved`);
  }
});

test('other errors keep the old body shape (no reason, no Retry-After)', async () => {
  const h = deps(new InMemoryUsageLimiter({ deployment: 'production' as const, dailyCharCap: 9_000, requestsPerMinute: 100 }));
  const unauth = await handleTts({ ...req('hi'), authorization: 'Bearer wrong' }, h.d);
  assert.equal(unauth.status, 401);
  assert.deepEqual(Object.keys(body(unauth)).sort(), ['error', 'requestId']);
  assert.equal(unauth.headers['Retry-After'], undefined);
});

test('429/503 log lines carry only requestId, status, chars and the enum reason', async () => {
  const lines: string[] = [];
  const spy = mock.method(console, 'log', (...a: unknown[]) => lines.push(a.map(String).join(' ')));
  try {
    const { defaultDeps } = await import('../src/handler.js');
    const base = defaultDeps(env());
    const limiter = new InMemoryUsageLimiter({ deployment: 'production' as const, dailyCharCap: 5, requestsPerMinute: 100 });
    await handleTts(req('secret listening note'), { ...base, limiter, fetch: (async () => pcm()) as typeof fetch });
  } finally {
    spy.mock.restore();
  }
  assert.equal(lines.length, 1);
  const parsed = JSON.parse(lines[0]);
  assert.deepEqual(Object.keys(parsed).sort(), ['chars', 'reason', 'requestId', 'status']);
  assert.equal(parsed.reason, 'owner_daily');
  for (const s of ['secret listening note', TOKEN, TOKEN_HASH, VOICE]) assert.ok(!lines[0].includes(s));
});

// --- Bucket selection: nothing in the request picks it ---

test('the handler always charges the owner bucket; body fields cannot select an install bucket', async () => {
  const store = fakeUpstash();
  const h = deps(new RedisUsageLimiter(STORE, limiterOptions({ VERCEL_ENV: 'production' }), store.fetchImpl));
  const res = await handleTts(req('hello', { installId: 'install-key-id-A', keyId: 'install-key-id-A', stationId: 'install-key-id-A' }), h.d);
  assert.equal(res.status, 200);
  const keys = store.calls.flatMap((c) => c.command.slice(3, 3 + Number(c.command[2])) as string[]);
  assert.ok(keys.every((k) => k.includes(':owner:') || k.includes(':global:')), JSON.stringify(keys));
  assert.equal(store.redis.get(installKey(A)), 0);
  assert.equal(store.calls[1].command[1], RESERVE2_SCRIPT);
});

test('install ids are hashed into store keys and invalid ids are rejected', () => {
  const bucket = subjectBucket({ kind: 'install', id: 'a:b*{c}' });
  assert.match(bucket, /^install:[0-9a-f]{64}$/);
  assert.ok(!bucket.includes('a:b'));
  assert.notEqual(subjectBucket(A), subjectBucket(B));
  assert.throws(() => subjectBucket({ kind: 'install', id: '' }));
  assert.throws(() => subjectBucket({ kind: 'install', id: 'x'.repeat(257) }));
  assert.equal(subjectBucket(OWNER_SUBJECT), 'owner');
});

// --- Env parsing ---

test('parseCharCap: only plain integers in [1, max]; everything else falls back (never unlimited)', () => {
  for (const ok of [['1', 1], ['9000', 9_000], [' 1500 ', 1_500], [String(MAX_CONFIGURED_CHAR_CAP), MAX_CONFIGURED_CHAR_CAP]] as const) {
    assert.equal(parseCharCap(ok[0]), ok[1], ok[0]);
  }
  for (const bad of [undefined, '', '  ', '0', '-1', '-9000', '1.5', '1e4', '0x10', 'Infinity', 'NaN', 'abc', '9000abc',
    '+9000', String(MAX_CONFIGURED_CHAR_CAP + 1), '9999999999', '1,000']) {
    assert.equal(parseCharCap(bad), null, String(bad));
  }
});

test('limiterOptions: defaults 9,000 global / 1,500 install, legacy cap honoured, owner defaults to global', () => {
  assert.deepEqual(limiterOptions({}), {
    dailyCharCap: DEFAULT_GLOBAL_DAILY_CHAR_CAP,
    ownerDailyCharCap: DEFAULT_GLOBAL_DAILY_CHAR_CAP,
    installDailyCharCap: DEFAULT_INSTALL_DAILY_CHAR_CAP,
    requestsPerMinute: 12,
  });
  assert.equal(DEFAULT_GLOBAL_DAILY_CHAR_CAP, 9_000);
  assert.equal(DEFAULT_INSTALL_DAILY_CHAR_CAP, 1_500);
  // Today's deployment sets only the legacy single-bucket cap.
  assert.equal(limiterOptions({ AERODJ_TTS_DAILY_CHAR_CAP: '9000' }).dailyCharCap, 9_000);
  assert.equal(limiterOptions({ AERODJ_TTS_DAILY_CHAR_CAP: '4000' }).ownerDailyCharCap, 4_000);
  // The new global name wins over the legacy one.
  assert.equal(limiterOptions({ AERODJ_TTS_GLOBAL_DAILY_CHAR_CAP: '5000', AERODJ_TTS_DAILY_CHAR_CAP: '9000' }).dailyCharCap, 5_000);
  // Garbage falls back down the chain, never to unlimited.
  const garbage = limiterOptions({
    AERODJ_TTS_GLOBAL_DAILY_CHAR_CAP: '-1',
    AERODJ_TTS_DAILY_CHAR_CAP: 'unlimited',
    AERODJ_TTS_OWNER_DAILY_CHAR_CAP: 'Infinity',
    AERODJ_TTS_INSTALL_DAILY_CHAR_CAP: '0',
  });
  assert.deepEqual(
    [garbage.dailyCharCap, garbage.ownerDailyCharCap, garbage.installDailyCharCap],
    [9_000, 9_000, 1_500],
  );
  assert.equal(limiterOptions({ AERODJ_TTS_OWNER_DAILY_CHAR_CAP: '2000' }).ownerDailyCharCap, 2_000);
  assert.equal(limiterOptions({ AERODJ_TTS_INSTALL_DAILY_CHAR_CAP: '800' }).installDailyCharCap, 800);
});

test('parseRatePerMinute: same rule as the caps, plain integers in [1, 600]; 1e9 and friends fall back', () => {
  assert.equal(MAX_CONFIGURED_REQUESTS_PER_MINUTE, 600);
  for (const ok of [['1', 1], ['12', 12], [' 100 ', 100], ['600', 600]] as const) {
    assert.equal(parseRatePerMinute(ok[0]), ok[1], ok[0]);
  }
  for (const bad of [undefined, '', '  ', '0', '-1', '1.5', '1e9', '1e2', '0x10', 'Infinity', 'NaN', 'abc', '12abc',
    '+12', '601', '1000000000', '99999999', '1,000']) {
    assert.equal(parseRatePerMinute(bad), null, String(bad));
  }
});

test('limiterOptions: AERODJ_TTS_RATE_PER_MINUTE out of range or malformed uses the default 12, never unlimited', () => {
  assert.equal(limiterOptions({ AERODJ_TTS_RATE_PER_MINUTE: '30' }).requestsPerMinute, 30);
  assert.equal(limiterOptions({ AERODJ_TTS_RATE_PER_MINUTE: '600' }).requestsPerMinute, 600);
  for (const bad of ['1e9', '601', '1000000000', 'Infinity', '0', '-5', '2.5']) {
    assert.equal(limiterOptions({ AERODJ_TTS_RATE_PER_MINUTE: bad }).requestsPerMinute, 12, bad);
  }
});
