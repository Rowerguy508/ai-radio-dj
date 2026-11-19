import { test } from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { defaultDeps, handleTts, type Deps, type Env, type LogEntry, type RefundLostLog, type TtsRequest } from '../src/handler.js';
import { InMemoryUsageLimiter } from '../src/limiter.js';

// Sentinel's #364 N1: stitching context (previousText / nextText / previousRequestIds) is the
// neighbouring DJ lines of a break. It is forwarded upstream and never logged or echoed. Every
// log line keeps the fixed minimal shape, whatever the outcome of the request.

const TOKEN = 'test-owner-token-not-a-real-secret';
const TOKEN_HASH = crypto.createHash('sha256').update(TOKEN).digest('hex');
const VOICE = 'voiceAllowed123';
const PREVIOUS = 'Zebra previous line marker, good morning.';
const NEXT = 'Quokka next line marker, nine-forty.';
const REQUEST_IDS = ['ctxReqIdMarker01', 'ctxReqIdMarker02'];
const MARKERS = ['Zebra', 'Quokka', 'ctxReqIdMarker', 'previous line marker', 'next line marker'];
const ALLOWED_KEYS = new Set(['requestId', 'status', 'chars', 'reason', 'upstreamStatus', 'upstreamCode']);
const ALLOWED_REFUND_KEYS = new Set(['event', 'reason', 'chars', 'kind']);

function pcm(): Response {
  return new Response(Buffer.alloc(22_050 * 2, 1), {
    status: 200,
    headers: { 'Content-Type': 'audio/pcm', 'request-id': 'upstreamId123', 'character-cost': '30' },
  });
}

function harness(fetchImpl: () => Promise<Response>, env: Env = {}, extra: Partial<Deps> = {}) {
  const logs: LogEntry[] = [];
  const refunds: RefundLostLog[] = [];
  const deps: Deps = {
    env: { AERODJ_TTS_TOKEN_SHA256: TOKEN_HASH, AERODJ_TTS_VOICE_IDS: VOICE, ELEVENLABS_API_KEY: 'test-key-not-real', ...env },
    fetch: (async () => fetchImpl()) as typeof fetch,
    limiter: new InMemoryUsageLimiter({ deployment: 'production', dailyCharCap: 20_000, requestsPerMinute: 100 }),
    log: (e) => logs.push(e),
    logRefundLost: (e) => refunds.push(e),
    now: () => Date.UTC(2026, 10, 2, 12),
    timeoutMs: 50,
    requestId: () => 'req-1',
    testOnlyAllowNonDurableLimiter: true,
    ...extra,
  };
  return { deps, logs, refunds };
}

function request(extra: Record<string, unknown> = {}): TtsRequest {
  return {
    method: 'POST',
    authorization: `Bearer ${TOKEN}`,
    body: {
      upstream: 'elevenlabs', voiceId: VOICE, text: 'Okay, here comes the next one.', format: 'text',
      previousText: PREVIOUS, nextText: NEXT, previousRequestIds: REQUEST_IDS, ...extra,
    },
  };
}

/** Captures everything written through console.log/info/warn/error/debug while `run` executes. */
async function capturingConsole<T>(run: () => Promise<T>): Promise<{ result: T; lines: string[] }> {
  const lines: string[] = [];
  const methods = ['log', 'info', 'warn', 'error', 'debug'] as const;
  const saved = methods.map((m) => console[m]);
  for (const m of methods) console[m] = (...args: unknown[]) => { lines.push(args.map((a) => (typeof a === 'string' ? a : JSON.stringify(a))).join(' ')); };
  try {
    return { result: await run(), lines };
  } finally {
    methods.forEach((m, i) => { console[m] = saved[i]; });
  }
}

function assertNoContext(label: string, entries: object[], allowed: Set<string>): void {
  for (const entry of entries) {
    for (const key of Object.keys(entry)) assert.ok(allowed.has(key), `${label}: unexpected log key "${key}"`);
    const serialized = JSON.stringify(entry);
    for (const marker of MARKERS) assert.ok(!serialized.includes(marker), `${label}: context "${marker}" reached a log line`);
  }
}

function assertResponseHasNoContext(label: string, res: { headers: Record<string, string>; body: unknown }): void {
  const visible = JSON.stringify(res.headers) + (Buffer.isBuffer(res.body) ? '' : JSON.stringify(res.body ?? ''));
  for (const marker of MARKERS) assert.ok(!visible.includes(marker), `${label}: context "${marker}" echoed in the response`);
}

const outcomes: Array<{ label: string; status: number; fetch: () => Promise<Response>; extra?: Record<string, unknown> }> = [
  { label: '200 ok', status: 200, fetch: async () => pcm() },
  {
    label: '502 upstream error',
    status: 502,
    fetch: async () => new Response(JSON.stringify({ detail: { status: 'quota_exceeded', message: PREVIOUS } }), { status: 401 }),
  },
  { label: '502 network error', status: 502, fetch: async () => { throw new Error(NEXT); } },
  { label: '502 empty audio', status: 502, fetch: async () => new Response(Buffer.alloc(0), { status: 200 }) },
  { label: '400 over-long context', status: 400, fetch: async () => pcm(), extra: { nextText: NEXT + 'x'.repeat(2_500) } },
  { label: '400 bad request ids', status: 400, fetch: async () => pcm(), extra: { previousRequestIds: ['ctxReqIdMarker bad!'] } },
];

for (const o of outcomes) {
  test(`context stays out of every log line and the response: ${o.label}`, async () => {
    const h = harness(o.fetch);
    const { result: res, lines } = await capturingConsole(() => handleTts(request(o.extra), h.deps));
    assert.equal(res.status, o.status);
    assert.ok(h.logs.length >= 1, 'the request is logged');
    assertNoContext(o.label, h.logs, ALLOWED_KEYS);
    assertNoContext(`${o.label} refund_lost`, h.refunds, ALLOWED_REFUND_KEYS);
    for (const line of lines) for (const marker of MARKERS) assert.ok(!line.includes(marker), `${o.label}: console got "${marker}"`);
    assertResponseHasNoContext(o.label, res);
  });
}

test('context stays out of the 200 line exactly: requestId, status and the spoken chars only', async () => {
  const h = harness(async () => pcm());
  assert.equal((await handleTts(request(), h.deps)).status, 200);
  assert.deepEqual(h.logs, [{ requestId: 'req-1', status: 200, chars: 'Okay, here comes the next one.'.length }]);
});

test('context stays out of the logs on an eleven_v3 request (context not forwarded there either)', async () => {
  const h = harness(async () => pcm(), { ELEVENLABS_MODEL_ID: 'eleven_v3' });
  assert.equal((await handleTts(request(), h.deps)).status, 200);
  assertNoContext('v3', h.logs, ALLOWED_KEYS);
});

test('the production console logger writes only the minimal fields, even if handed more', async () => {
  const { lines } = await capturingConsole(async () => {
    const log = defaultDeps({}).log;
    // A future caller that wrongly spreads context into the entry must still not reach the console.
    log({ requestId: 'req-1', status: 200, chars: 5, previousText: PREVIOUS, nextText: NEXT } as unknown as LogEntry);
  });
  assert.equal(lines.length, 1);
  assert.deepEqual(Object.keys(JSON.parse(lines[0])).sort(), ['chars', 'requestId', 'status']);
  for (const marker of MARKERS) assert.ok(!lines[0].includes(marker));
});

test('context stays out of the full console output of a real-logger request', async () => {
  const h = harness(async () => pcm(), {}, { log: defaultDeps({}).log, logRefundLost: undefined });
  const { result, lines } = await capturingConsole(() => handleTts(request(), h.deps));
  assert.equal(result.status, 200);
  assert.ok(lines.length >= 1);
  for (const line of lines) {
    for (const key of Object.keys(JSON.parse(line))) assert.ok(ALLOWED_KEYS.has(key), `unexpected console key "${key}"`);
    for (const marker of MARKERS) assert.ok(!line.includes(marker), `console got "${marker}"`);
  }
});
