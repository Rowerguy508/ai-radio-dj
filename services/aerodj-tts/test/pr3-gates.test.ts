/**
 * #233 PR 3 gates on the existing paths: the `AERODJ_TTS_PAID_STOP` master stop (D1),
 * 500 `misconfig` on every server misconfiguration, and durable-only install reservations
 * (Sentinel B3). The refund marker (D2) is in quota.test.ts; the challenge cap and
 * `challenge_expired` are in challenge.test.ts.
 */
import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { handleTts, type Deps, type Env, type LogEntry, type TtsRequest } from '../src/handler.js';
import { InMemoryUsageLimiter, LimiterStoreError, RedisUsageLimiter, type UsageLimiter } from '../src/limiter.js';
import { paidStopped } from '../src/attest-flags.js';
import { handleChallenge, type AttestLogEntry } from '../src/challenge-handler.js';
import type { ChallengeStore } from '../src/challenge-store.js';
import { INSTALL_STORE_RETRY_AFTER_SECONDS, isDurable, reserveForInstall } from '../src/install-quota.js';
import { fakeUpstash } from './redis-lua.js';

const TOKEN = 'test-owner-token-not-a-real-secret';
const TOKEN_HASH = crypto.createHash('sha256').update(TOKEN).digest('hex');
const VOICE = 'voiceAllowed123';
const STORE = { url: 'https://store.example.upstash.io', token: 'test-store-token-not-real' };
const NOON = Date.UTC(2026, 9, 29, 12);
const KEY_HEX = crypto.createHash('sha256').update('pr3 test challenge key, not a secret').digest('hex');
const KEY_ID = crypto.createHash('sha256').update('install A').digest('base64');

/** Values that must STOP (fail closed: any value except exactly `false`, including empty). */
const STOP_VALUES = ['', 'true', '1', 'yes', 'TRUE', 'False', 'FALSE', 'false ', ' false', ' ', 'no', 'off', '0'];
/** Values that must NOT stop. */
const RUN_VALUES: (string | undefined)[] = [undefined, 'false'];

const env = (o: Env = {}): Env => ({
  AERODJ_TTS_TOKEN_SHA256: TOKEN_HASH,
  AERODJ_TTS_VOICE_IDS: VOICE,
  ELEVENLABS_API_KEY: 'test-elevenlabs-key-not-real',
  ...o,
});

function pcm(): Response {
  return new Response(Buffer.alloc(22_050 * 2, 1), { status: 200, headers: { 'Content-Type': 'audio/pcm' } });
}

/** Limiter spy: counts every call; wraps a real limiter. */
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

function harness(o: { env?: Env; limiter?: UsageLimiter | null } = {}) {
  const logs: LogEntry[] = [];
  let upstream = 0;
  const spy = spyLimiter(new InMemoryUsageLimiter({ dailyCharCap: 9_000, requestsPerMinute: 100 }));
  const deps: Deps = {
    env: o.env ?? env(),
    fetch: (async () => { upstream++; return pcm(); }) as typeof fetch,
    limiter: o.limiter === undefined ? spy.limiter : o.limiter,
    log: (e) => logs.push(e),
    now: () => NOON,
    timeoutMs: 50,
    requestId: () => 'req-1',
  };
  return { deps, logs, upstream: () => upstream, limiterCalls: spy.calls };
}

const req = (o: Partial<TtsRequest> = {}): TtsRequest => ({
  method: 'POST',
  authorization: `Bearer ${TOKEN}`,
  body: { upstream: 'elevenlabs', voiceId: VOICE, text: 'Hello from the DJ booth.', format: 'text' },
  ...o,
});

const body = (res: { body: Buffer }) => JSON.parse(res.body.toString('utf8')) as Record<string, unknown>;

// ---------------------------------------------------------------------------
describe('AERODJ_TTS_PAID_STOP master stop (note §4.7, Fry D1)', () => {
  test('paidStopped: any value except exactly `false` stops (incl. empty); only unset and `false` run (Sentinel)', () => {
    for (const v of STOP_VALUES) assert.equal(paidStopped({ AERODJ_TTS_PAID_STOP: v }), true, JSON.stringify(v));
    for (const v of RUN_VALUES) assert.equal(paidStopped({ AERODJ_TTS_PAID_STOP: v }), false, JSON.stringify(v));
    assert.equal(paidStopped({}), false);
  });

  test('owner /api/tts: 503 disabled, Retry-After 3600, zero limiter and zero ElevenLabs calls', async () => {
    for (const v of STOP_VALUES) {
      const h = harness({ env: env({ AERODJ_TTS_PAID_STOP: v }) });
      const res = await handleTts(req(), h.deps);
      assert.equal(res.status, 503, JSON.stringify(v));
      assert.equal(res.headers['Retry-After'], '3600');
      assert.deepEqual(body(res), { error: 'Service unavailable', requestId: 'req-1', reason: 'disabled', retryAfterSeconds: 3600 });
      assert.equal(h.limiterCalls(), 0, 'no limiter call');
      assert.equal(h.upstream(), 0, 'no ElevenLabs call');
      assert.deepEqual(h.logs, [{ requestId: 'req-1', status: 503, chars: 0, reason: 'disabled' }]);
    }
  });

  test('checked first: before the method, auth, the token hash, the limiter and the API key', async () => {
    const stop = { AERODJ_TTS_PAID_STOP: 'true' };
    const cases: [string, Env, Partial<TtsRequest>, UsageLimiter | null | undefined][] = [
      ['GET', env(stop), { method: 'GET' }, undefined],
      ['no auth', env(stop), { authorization: undefined }, undefined],
      ['wrong token', env(stop), { authorization: 'Bearer nope' }, undefined],
      ['no token hash', { ...env(stop), AERODJ_TTS_TOKEN_SHA256: undefined }, {}, undefined],
      ['no limiter', env(stop), {}, null],
      ['no API key', { ...env(stop), ELEVENLABS_API_KEY: undefined }, {}, undefined],
      ['bad body', env(stop), { body: 'not json' }, undefined],
    ];
    for (const [name, e, r, limiter] of cases) {
      const h = harness({ env: e, limiter });
      const res = await handleTts(req(r), h.deps);
      assert.equal(res.status, 503, name);
      assert.equal(body(res).reason, 'disabled', name);
      assert.equal(h.upstream(), 0, name);
    }
  });

  test('durable Upstash limiter: zero store requests while stopped', async () => {
    const store = fakeUpstash();
    const limiter = new RedisUsageLimiter(STORE, { dailyCharCap: 9_000, requestsPerMinute: 100 }, store.fetchImpl);
    const h = harness({ env: env({ AERODJ_TTS_PAID_STOP: 'true' }), limiter });
    assert.equal((await handleTts(req(), h.deps)).status, 503);
    assert.equal(store.calls.length, 0);
  });

  test('unset or exactly `false`: normal behaviour (200, one render)', async () => {
    for (const v of RUN_VALUES) {
      const h = harness({ env: env({ AERODJ_TTS_PAID_STOP: v }) });
      const res = await handleTts(req(), h.deps);
      assert.equal(res.status, 200, JSON.stringify(v));
      assert.equal(h.upstream(), 1);
    }
  });

  describe('attest endpoint POST /api/attest/challenge', () => {
    class SpyStore implements ChallengeStore {
      durable = true;
      calls = 0;
      async markUsed() { this.calls++; return true; }
      async isUsed() { this.calls++; return false; }
    }
    const ENABLED = { AERODJ_TTS_ATTEST_ENABLED: 'true', AERODJ_TTS_CHALLENGE_HMAC_KEY: KEY_HEX };
    const post = (method = 'POST') =>
      new Request('https://proxy.invalid/api/attest/challenge', {
        method,
        headers: { 'Content-Type': 'application/json' },
        body: method === 'POST' ? JSON.stringify({ purpose: 'tts', keyId: KEY_ID }) : null,
      });
    const run = async (e: Env, method = 'POST', store: ChallengeStore | null = new SpyStore()) => {
      const logs: AttestLogEntry[] = [];
      const res = await handleChallenge(post(method), { env: e, store, log: (l) => logs.push(l), now: () => NOON, requestId: () => 'req-1' });
      return { res, logs, store };
    };

    test('stopped: 503 disabled with Retry-After 3600 even when attest is enabled and fully configured; no store call', async () => {
      for (const v of STOP_VALUES) {
        const { res, logs, store } = await run({ ...ENABLED, AERODJ_TTS_PAID_STOP: v });
        assert.equal(res.status, 503, JSON.stringify(v));
        assert.equal(res.headers.get('retry-after'), '3600');
        assert.deepEqual(await res.json(), { error: 'Service unavailable', requestId: 'req-1', reason: 'disabled', retryAfterSeconds: 3600 });
        assert.equal((store as SpyStore).calls, 0);
        assert.deepEqual(logs, [{ requestId: 'req-1', status: 503, reason: 'disabled' }]);
      }
    });

    test('stopped: checked before the method, the HMAC key and the store', async () => {
      const stop = { AERODJ_TTS_PAID_STOP: 'true' };
      for (const [name, e, method, store] of [
        ['GET', { ...ENABLED, ...stop }, 'GET', new SpyStore()],
        ['no key', { AERODJ_TTS_ATTEST_ENABLED: 'true', ...stop }, 'POST', new SpyStore()],
        ['no store', { ...ENABLED, ...stop }, 'POST', null],
      ] as [string, Env, string, ChallengeStore | null][]) {
        const { res } = await run(e, method, store);
        assert.equal(res.status, 503, name);
        assert.equal(((await res.json()) as { reason: string }).reason, 'disabled', name);
      }
    });

    test('unset or exactly `false`: the challenge is issued as before', async () => {
      for (const v of RUN_VALUES) {
        const { res } = await run({ ...ENABLED, AERODJ_TTS_PAID_STOP: v });
        assert.equal(res.status, 200, JSON.stringify(v));
      }
    });
  });
});

// ---------------------------------------------------------------------------
describe('500 misconfig contract on /api/tts (note §4.4)', () => {
  const expectMisconfig = async (name: string, h: ReturnType<typeof harness>, r: TtsRequest = req()) => {
    const res = await handleTts(r, h.deps);
    assert.equal(res.status, 500, name);
    assert.equal(res.headers['Retry-After'], '3600', name);
    assert.deepEqual(body(res), { error: 'Server misconfigured', requestId: 'req-1', reason: 'misconfig', retryAfterSeconds: 3600 }, name);
    assert.equal(h.upstream(), 0, name);
    assert.deepEqual(h.logs, [{ requestId: 'req-1', status: 500, chars: 0, reason: 'misconfig' }], name);
  };

  test('token hash unset or malformed (before auth, so also unauthenticated)', async () => {
    await expectMisconfig('unset', harness({ env: { ...env(), AERODJ_TTS_TOKEN_SHA256: undefined } }));
    await expectMisconfig('malformed', harness({ env: env({ AERODJ_TTS_TOKEN_SHA256: 'not-hex' }) }));
    await expectMisconfig('unauthenticated', harness({ env: env({ AERODJ_TTS_TOKEN_SHA256: '' }) }), req({ authorization: undefined }));
  });

  test('no acceptable limiter (production without a store)', async () => {
    await expectMisconfig('no limiter', harness({ limiter: null }));
  });

  test('ElevenLabs key unset or blank (authenticated only; zero limiter calls)', async () => {
    for (const k of [undefined, '', '   ']) {
      const h = harness({ env: { ...env(), ELEVENLABS_API_KEY: k } });
      await expectMisconfig(JSON.stringify(k), h);
      assert.equal(h.limiterCalls(), 0);
    }
    // Unauthenticated still gets 401, not a config hint.
    const h = harness({ env: { ...env(), ELEVENLABS_API_KEY: undefined } });
    assert.equal((await handleTts(req({ authorization: 'Bearer nope' }), h.deps)).status, 401);
  });
});

// ---------------------------------------------------------------------------
describe('install reservations require a durable store (note §4.3, Sentinel B3; PR 3 gate b)', () => {
  const STORE_REFUSAL = { ok: false, status: 503, reason: 'store', retryAfterSeconds: 30 };

  test('Retry-After for the install store refusal is 30 s, per the §4.4 table', () => {
    assert.equal(INSTALL_STORE_RETRY_AFTER_SECONDS, 30);
  });

  test('no limiter → 503 store', async () => {
    assert.deepEqual(await reserveForInstall(null, KEY_ID, 100, NOON), STORE_REFUSAL);
  });

  test('in-memory limiter → 503 store with zero limiter calls, in every environment', async () => {
    const spy = spyLimiter(new InMemoryUsageLimiter({ dailyCharCap: 9_000, requestsPerMinute: 100 }));
    assert.deepEqual(await reserveForInstall(spy.limiter, KEY_ID, 100, NOON), STORE_REFUSAL);
    assert.equal(spy.calls(), 0);
  });

  test('a limiter whose durable flag is anything but boolean true → 503 store', async () => {
    for (const durable of [false, 'true', 1, undefined] as unknown[]) {
      const spy = spyLimiter(new InMemoryUsageLimiter({ dailyCharCap: 9_000, requestsPerMinute: 100 }));
      const limiter = { ...spy.limiter, durable } as unknown as UsageLimiter;
      assert.equal(isDurable(limiter), false, String(durable));
      assert.deepEqual(await reserveForInstall(limiter, KEY_ID, 100, NOON), STORE_REFUSAL, String(durable));
      assert.equal(spy.calls(), 0);
    }
  });

  test('durable Upstash limiter → reserves on the install and global buckets', async () => {
    const store = fakeUpstash();
    const limiter = new RedisUsageLimiter(STORE, { dailyCharCap: 9_000, requestsPerMinute: 100 }, store.fetchImpl);
    const r = await reserveForInstall(limiter, KEY_ID, 100, NOON);
    assert.equal(r.ok, true);
    assert.equal(store.calls.length, 1);
    // Install cap still applies through the gate.
    const over = await reserveForInstall(limiter, KEY_ID, 1_500, NOON);
    assert.deepEqual(over, { ok: false, reason: 'install_daily' });
  });

  test('durable limiter whose store is down → 503 store; other errors are 500 misconfig (PR 4), not rethrown', async () => {
    const down = new RedisUsageLimiter(STORE, { dailyCharCap: 9_000, requestsPerMinute: 100 }, fakeUpstash({ status: 500 }).fetchImpl);
    assert.deepEqual(await reserveForInstall(down, KEY_ID, 100, NOON), STORE_REFUSAL);
    const broken: UsageLimiter = {
      durable: true,
      allowRequest: async () => true,
      reserve: async () => { throw new TypeError('bug'); },
      release: async () => true,
    };
    // PR 4 (Sentinel's #250 nit): a non-store throw maps to 500 misconfig instead of a bare platform 500.
    assert.deepEqual(await reserveForInstall(broken, KEY_ID, 100, NOON), { ok: false, status: 500, reason: 'misconfig', retryAfterSeconds: 3600 });
    const storeErr: UsageLimiter = { ...broken, reserve: async () => { throw new LimiterStoreError('x'); } };
    assert.deepEqual(await reserveForInstall(storeErr, KEY_ID, 100, NOON), STORE_REFUSAL);
  });
});
