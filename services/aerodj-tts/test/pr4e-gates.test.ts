/**
 * PR 4e (stacked on #257), Fry's nits on #256/#257:
 * - The 2 s Upstash default is pinned, and a default-constructed limiter really uses it
 *   (still pending just before 2 s, 503 `store` just after; a 60 s default fails).
 * - A refund lost after an upstream non-2xx emits one structured line with only
 *   `event`, `reason` ('store' | 'timeout') and `chars`.
 */
import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { defaultDeps, handleTts, logRefundLostToConsole, selectLimiter, type Deps, type Env, type RefundLostLog, type TtsRequest, type TtsResponse } from '../src/handler.js';
import { RedisUsageLimiter, type UsageLimiter } from '../src/limiter.js';
import { UPSTASH_FETCH_TIMEOUT_MS } from '../src/upstash.js';

const TOKEN = 'test-owner-token-not-a-real-secret';
const TOKEN_HASH = crypto.createHash('sha256').update(TOKEN).digest('hex');
const VOICE = 'voiceAllowed123';
const STORE = { url: 'https://store.example.upstash.io', token: 'test-store-token-not-real' };
const OPTIONS = { deployment: 'production' as const, dailyCharCap: 9_000, requestsPerMinute: 100 };
const NOON = Date.UTC(2026, 9, 29, 12);
const TEXT = 'Hello from the DJ booth.';
const ENV: Env = { AERODJ_TTS_TOKEN_SHA256: TOKEN_HASH, AERODJ_TTS_VOICE_IDS: VOICE, ELEVENLABS_API_KEY: 'test-elevenlabs-key-not-real' };
const REQ: TtsRequest = { method: 'POST', authorization: `Bearer ${TOKEN}`, body: { upstream: 'elevenlabs', voiceId: VOICE, text: TEXT, format: 'text' } };

function deps(limiter: UsageLimiter, upstreamStatus: number, lost: RefundLostLog[]): Deps {
  return {
    env: ENV,
    fetch: (async () => new Response(Buffer.alloc(44_100, 1), { status: upstreamStatus })) as typeof fetch,
    limiter, log: () => {}, now: () => NOON, timeoutMs: 50, requestId: () => 'req-1',
    logRefundLost: (e) => lost.push(e),
  };
}
/** Rate 1, reserve counter, then `third` for the refund EVAL. */
const thenRefund = (third: (init: RequestInit) => Promise<Response>) => {
  let n = 0;
  return (async (_u: unknown, init: RequestInit) => {
    n++;
    if (n === 1) return Response.json({ result: 1 });
    if (n === 2) return Response.json({ result: TEXT.length });
    return third(init);
  }) as unknown as typeof fetch;
};
const never = (init: RequestInit) => new Promise<Response>((_r, reject) => {
  init.signal?.addEventListener('abort', () => reject(init.signal!.reason), { once: true });
});
async function withKeepAlive<T>(run: () => Promise<T>): Promise<T> {
  const keep = setTimeout(() => {}, 30_000);
  try { return await run(); } finally { clearTimeout(keep); }
}

describe('Upstash timeout default is pinned and used (Fry nit on #256/#257)', () => {
  test('UPSTASH_FETCH_TIMEOUT_MS === 2000', () => {
    assert.equal(UPSTASH_FETCH_TIMEOUT_MS, 2000);
  });

  for (const [name, make] of [
    ['new RedisUsageLimiter(store, options, fetch)', (f: typeof fetch) => new RedisUsageLimiter(STORE, OPTIONS, f)],
    ['selectLimiter(env, fetch)', (f: typeof fetch) => selectLimiter({ KV_REST_API_URL: STORE.url, KV_REST_API_TOKEN: STORE.token, VERCEL_ENV: 'production' }, f)!],
  ] as const) {
    test(`${name}: a stalled EVAL is pending at 1800 ms and 503 store by 2600 ms`, { timeout: 10_000 }, () =>
      withKeepAlive(async () => {
        const limiter = make(((_u: unknown, init: RequestInit) => never(init)) as unknown as typeof fetch);
        assert.ok(limiter instanceof RedisUsageLimiter);
        const box: { r?: TtsResponse } = {};
        const started = Date.now();
        void handleTts(REQ, deps(limiter, 200, [])).then((r) => { box.r = r; });
        await new Promise((r) => setTimeout(r, 1_800));
        assert.ok(box.r === undefined, 'still pending just before the 2 s bound');
        while (!box.r && Date.now() - started < 2_600) await new Promise((r) => setTimeout(r, 20));
        const settled = box.r as TtsResponse | undefined;
        assert.ok(settled, 'settled by 2600 ms');
        assert.equal(settled.status, 503);
        assert.equal(JSON.parse(Buffer.from(settled.body as Buffer).toString('utf8')).reason, 'store');
        assert.ok(Date.now() - started >= 1_950, 'not before the bound');
      }));
  }
});

describe('lost refunds are logged (Fry nit on #257)', () => {
  test('refund store error after upstream 502 → one refund_lost line, reason store', async () => {
    const lost: RefundLostLog[] = [];
    const res = await handleTts(REQ, deps(new RedisUsageLimiter(STORE, OPTIONS, thenRefund(async () => new Response('x', { status: 500 }))), 502, lost));
    assert.equal(res.status, 502);
    assert.deepEqual(lost, [{ event: 'refund_lost', reason: 'store', chars: TEXT.length }]);
    assert.deepEqual(Object.keys(lost[0]!).sort(), ['chars', 'event', 'reason']);
  });

  test('refund timeout after upstream 502 → one refund_lost line, reason timeout', { timeout: 5_000 }, () =>
    withKeepAlive(async () => {
      const lost: RefundLostLog[] = [];
      const res = await handleTts(REQ, deps(new RedisUsageLimiter(STORE, OPTIONS, thenRefund(never), 20), 502, lost));
      assert.equal(res.status, 502);
      assert.deepEqual(lost, [{ event: 'refund_lost', reason: 'timeout', chars: TEXT.length }]);
    }));

  test('successful refund or 200 → no refund_lost line', async () => {
    for (const [status, refund] of [[502, { result: 1 }], [502, { result: 0 }], [200, { result: 1 }]] as const) {
      const lost: RefundLostLog[] = [];
      await handleTts(REQ, deps(new RedisUsageLimiter(STORE, OPTIONS, thenRefund(async () => Response.json(refund))), status, lost));
      assert.deepEqual(lost, [], `${status} ${JSON.stringify(refund)}`);
    }
  });

  test('default sink: one console.log JSON line with exactly event, reason, chars', async () => {
    const lines: string[] = [];
    const orig = console.log;
    console.log = (...a: unknown[]) => { lines.push(a.map(String).join(' ')); };
    try {
      const d = { ...deps(new RedisUsageLimiter(STORE, OPTIONS, thenRefund(async () => new Response('x', { status: 500 }))), 502, []), log: () => {} };
      delete d.logRefundLost;
      await handleTts(REQ, d);
      logRefundLostToConsole({ event: 'refund_lost', reason: 'timeout', chars: 7, extra: 'leak' } as RefundLostLog);
    } finally {
      console.log = orig;
    }
    assert.deepEqual(lines.map((l) => JSON.parse(l)), [
      { event: 'refund_lost', reason: 'store', chars: TEXT.length },
      { event: 'refund_lost', reason: 'timeout', chars: 7 },
    ]);
    for (const l of lines) for (const secret of [TOKEN, STORE.token, TEXT, VOICE, 'leak']) assert.ok(!l.includes(secret));
    assert.equal(typeof defaultDeps({}).logRefundLost, 'undefined');
  });
});
