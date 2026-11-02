/**
 * PR 4f (stacked on #259), Fry's nit on #259 (comment 6512438788): the Upstash time
 * bound covers the response body read too, and a refund whose body read is cut off by
 * it is logged as refund_lost reason `timeout`, the same as a fetch cut off by it.
 * A body that fails on its own (bad JSON, stream error) stays reason `store`.
 */
import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { handleTts, type Deps, type Env, type RefundLostLog, type TtsRequest } from '../src/handler.js';
import { LimiterStoreError, RedisUsageLimiter, type UsageLimiter } from '../src/limiter.js';

const TOKEN = 'test-owner-token-not-a-real-secret';
const TOKEN_HASH = crypto.createHash('sha256').update(TOKEN).digest('hex');
const VOICE = 'voiceAllowed123';
const STORE = { url: 'https://store.example.upstash.io', token: 'test-store-token-not-real' };
const OPTIONS = { deployment: 'production' as const, dailyCharCap: 9_000, requestsPerMinute: 100 };
const NOON = Date.UTC(2026, 9, 29, 12);
const TEXT = 'Hello from the DJ booth.';
const ENV: Env = { AERODJ_TTS_TOKEN_SHA256: TOKEN_HASH, AERODJ_TTS_VOICE_IDS: VOICE, ELEVENLABS_API_KEY: 'test-elevenlabs-key-not-real' };
const REQ: TtsRequest = { method: 'POST', authorization: `Bearer ${TOKEN}`, body: { upstream: 'elevenlabs', voiceId: VOICE, text: TEXT, format: 'text' } };
const BOUND_MS = 30;

function deps(limiter: UsageLimiter, lost: RefundLostLog[]): Deps {
  return {
    env: ENV,
    fetch: (async () => new Response(Buffer.alloc(44_100, 1), { status: 502 })) as typeof fetch,
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
const enc = new TextEncoder();
/** 200 whose body sends a partial JSON prefix and then stalls, ignoring the signal. */
const stalledBody = async () =>
  new Response(new ReadableStream({ start(c) { c.enqueue(enc.encode('{"resu')); } }), { status: 200 });
/** 200 whose body stalls and then errors with the signal's reason, as a real aborted fetch body does. */
const abortedBody = async (init: RequestInit) =>
  new Response(new ReadableStream({
    start(c) {
      c.enqueue(enc.encode('{"resu'));
      init.signal?.addEventListener('abort', () => c.error(init.signal!.reason), { once: true });
    },
  }), { status: 200 });
async function withKeepAlive<T>(run: () => Promise<T>): Promise<T> {
  const keep = setTimeout(() => {}, 30_000);
  try { return await run(); } finally { clearTimeout(keep); }
}
const refundLost = (third: (init: RequestInit) => Promise<Response>) =>
  withKeepAlive(async () => {
    const lost: RefundLostLog[] = [];
    const res = await handleTts(REQ, deps(new RedisUsageLimiter(STORE, OPTIONS, thenRefund(third), BOUND_MS), lost));
    assert.equal(res.status, 502);
    return lost;
  });

describe('refund_lost: a body read cut off by the Upstash bound is a timeout (Fry nit on #259)', () => {
  test('refund 200 whose body stalls (signal ignored) → reason timeout', { timeout: 5_000 }, async () => {
    assert.deepEqual(await refundLost(stalledBody), [{ event: 'refund_lost', reason: 'timeout', chars: TEXT.length }]);
  });

  test('refund 200 whose body errors with the abort reason → reason timeout', { timeout: 5_000 }, async () => {
    assert.deepEqual(await refundLost(abortedBody), [{ event: 'refund_lost', reason: 'timeout', chars: TEXT.length }]);
  });

  test('refund 200 with a malformed body, in time → reason store', { timeout: 5_000 }, async () => {
    assert.deepEqual(await refundLost(async () => new Response('{"result":', { status: 200 })), [
      { event: 'refund_lost', reason: 'store', chars: TEXT.length },
    ]);
  });

  test('refund 200 whose body stream fails on its own, in time → reason store', { timeout: 5_000 }, async () => {
    const broken = async () =>
      new Response(new ReadableStream({ start(c) { c.error(new Error('stream reset')); } }), { status: 200 });
    assert.deepEqual(await refundLost(broken), [{ event: 'refund_lost', reason: 'store', chars: TEXT.length }]);
  });

  test('refund 200 with an error reply, in time → reason store', { timeout: 5_000 }, async () => {
    assert.deepEqual(await refundLost(async () => Response.json({ error: 'ERR' })), [
      { event: 'refund_lost', reason: 'store', chars: TEXT.length },
    ]);
  });
});

describe('limiter: body-read timeout is timedOut, like a fetch timeout', () => {
  test('stalled body: LimiterStoreError with timedOut, settled near the bound', { timeout: 5_000 }, () =>
    withKeepAlive(async () => {
      const limiter = new RedisUsageLimiter(STORE, OPTIONS, stalledBody as unknown as typeof fetch, BOUND_MS);
      const started = Date.now();
      const error = await limiter.allowRequest('owner', NOON).then(() => null, (e: unknown) => e);
      assert.ok(error instanceof LimiterStoreError);
      assert.equal(error.timedOut, true);
      assert.ok(Date.now() - started < 1_000, 'bounded by the time bound, not left hanging');
    }));

  test('malformed body in time: LimiterStoreError, not timedOut', async () => {
    const limiter = new RedisUsageLimiter(STORE, OPTIONS, (async () => new Response('nope', { status: 200 })) as unknown as typeof fetch, BOUND_MS);
    const error = await limiter.allowRequest('owner', NOON).then(() => null, (e: unknown) => e);
    assert.ok(error instanceof LimiterStoreError);
    assert.equal(error.timedOut, false);
  });
});
