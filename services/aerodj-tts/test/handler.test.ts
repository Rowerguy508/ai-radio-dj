import { test, mock } from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { defaultDeps, handleTts, selectLimiter, type Deps, type Env, type LogEntry, type TtsRequest } from '../src/handler.js';
import {
  InMemoryUsageLimiter,
  RATE_SCRIPT,
  RedisUsageLimiter,
  RELEASE_SCRIPT,
  RESERVE_SCRIPT,
  type UsageLimiter,
} from '../src/limiter.js';
import { ssmlToPlainText } from '../src/ssml.js';
import apiHandler from '../api/tts.js';

const TOKEN = 'test-owner-token-not-a-real-secret';
const TOKEN_HASH = crypto.createHash('sha256').update(TOKEN).digest('hex');
const VOICE = 'voiceAllowed123';
const API_KEY = 'test-elevenlabs-key-not-real';
const SECRET_TEXT = 'Up next on AeroDJ, a very private listening note';

function baseEnv(overrides: Env = {}): Env {
  return {
    AERODJ_TTS_TOKEN_SHA256: TOKEN_HASH,
    AERODJ_TTS_VOICE_IDS: `${VOICE},otherVoice`,
    ELEVENLABS_API_KEY: API_KEY,
    ...overrides,
  };
}

function pcmResponse(samples: number, headers: Record<string, string> = {}): Response {
  const pcm = Buffer.alloc(samples * 2);
  for (let i = 0; i < samples; i++) pcm.writeInt16LE((i % 200) - 100, i * 2);
  return new Response(pcm, { status: 200, headers: { 'Content-Type': 'audio/pcm', ...headers } });
}

interface Harness {
  deps: Deps;
  logs: LogEntry[];
  calls: { url: string; init: RequestInit }[];
}

function harness(
  opts: { env?: Env; fetch?: (url: string, init: RequestInit) => Promise<Response>; cap?: number; rate?: number; limiter?: UsageLimiter | null } = {},
): Harness {
  const logs: LogEntry[] = [];
  const calls: { url: string; init: RequestInit }[] = [];
  const fetchImpl = opts.fetch ?? (async () => pcmResponse(22_050));
  const deps: Deps = {
    env: opts.env ?? baseEnv(),
    fetch: (async (url: string, init: RequestInit) => {
      calls.push({ url: String(url), init });
      return fetchImpl(String(url), init);
    }) as typeof fetch,
    limiter:
      opts.limiter !== undefined
        ? opts.limiter
        : new InMemoryUsageLimiter({ dailyCharCap: opts.cap ?? 20_000, requestsPerMinute: opts.rate ?? 100 }),
    log: (e) => logs.push(e),
    now: () => Date.UTC(2026, 9, 28, 12),
    timeoutMs: 50,
    requestId: () => 'req-1',
  };
  return { deps, logs, calls };
}

function request(body: unknown = {}, auth: string | null = `Bearer ${TOKEN}`, method = 'POST'): TtsRequest {
  return {
    method,
    authorization: auth ?? undefined,
    body: { upstream: 'elevenlabs', voiceId: VOICE, text: 'Hello from the DJ booth.', format: 'text', stationId: 's1', ...(body as object) },
  };
}

function errorBody(res: { body: Buffer }): Record<string, unknown> {
  return JSON.parse(res.body.toString('utf8'));
}

// --- Method ---
test('non-POST returns 405 with Allow header', async () => {
  const h = harness();
  const res = await handleTts(request({}, `Bearer ${TOKEN}`, 'GET'), h.deps);
  assert.equal(res.status, 405);
  assert.equal(res.headers.Allow, 'POST');
  assert.equal(h.calls.length, 0);
});

// --- Auth ---
test('missing Authorization returns 401', async () => {
  const h = harness();
  const res = await handleTts(request({}, null), h.deps);
  assert.equal(res.status, 401);
  assert.equal(h.calls.length, 0);
});

test('non-Bearer scheme returns 401', async () => {
  const res = await handleTts(request({}, `Basic ${TOKEN}`), harness().deps);
  assert.equal(res.status, 401);
});

test('wrong token returns 401 and never calls upstream', async () => {
  const h = harness();
  const res = await handleTts(request({}, 'Bearer wrong-token'), h.deps);
  assert.equal(res.status, 401);
  assert.equal(h.calls.length, 0);
});

test('token comparison goes through crypto.timingSafeEqual on 32-byte digests', async () => {
  const spy = mock.method(crypto, 'timingSafeEqual');
  try {
    const bad = await handleTts(request({}, 'Bearer nope'), harness().deps);
    assert.equal(bad.status, 401);
    const good = await handleTts(request(), harness().deps);
    assert.equal(good.status, 200);
    assert.equal(spy.mock.callCount(), 2);
    for (const call of spy.mock.calls) {
      const [a, b] = call.arguments as unknown as [Buffer, Buffer];
      assert.equal(a.length, 32);
      assert.equal(b.length, 32);
    }
  } finally {
    spy.mock.restore();
  }
});

test('unset token hash env returns generic 500', async () => {
  const env = baseEnv();
  delete env.AERODJ_TTS_TOKEN_SHA256;
  const res = await handleTts(request(), harness({ env }).deps);
  assert.equal(res.status, 500);
  assert.equal(errorBody(res).error, 'Server misconfigured');
});

test('malformed token hash env returns generic 500', async () => {
  const res = await handleTts(request(), harness({ env: baseEnv({ AERODJ_TTS_TOKEN_SHA256: 'not-hex' }) }).deps);
  assert.equal(res.status, 500);
});

// --- Validation ---
test('wrong upstream returns 400', async () => {
  const res = await handleTts(request({ upstream: 'cartesia' }), harness().deps);
  assert.equal(res.status, 400);
});

test('voice not in allowlist returns 400 and is not echoed', async () => {
  const res = await handleTts(request({ voiceId: 'evilVoice' }), harness().deps);
  assert.equal(res.status, 400);
  assert.ok(!res.body.toString().includes('evilVoice'));
});

test('empty voice allowlist rejects everything', async () => {
  const res = await handleTts(request(), harness({ env: baseEnv({ AERODJ_TTS_VOICE_IDS: '' }) }).deps);
  assert.equal(res.status, 400);
});

test('empty, whitespace and non-string text return 400', async () => {
  for (const text of ['', '   ', 42, null]) {
    const res = await handleTts(request({ text }), harness().deps);
    assert.equal(res.status, 400, `text=${JSON.stringify(text)}`);
  }
});

test('text over 600 chars returns 400; env override applies', async () => {
  assert.equal((await handleTts(request({ text: 'a'.repeat(601) }), harness().deps)).status, 400);
  assert.equal((await handleTts(request({ text: 'a'.repeat(600) }), harness().deps)).status, 200);
  const h = harness({ env: baseEnv({ AERODJ_TTS_MAX_TEXT_CHARS: '10' }) });
  assert.equal((await handleTts(request({ text: 'a'.repeat(11) }), h.deps)).status, 400);
});

test('invalid JSON / unknown format return 400', async () => {
  const h = harness();
  assert.equal((await handleTts({ method: 'POST', authorization: `Bearer ${TOKEN}`, body: '{nope' }, h.deps)).status, 400);
  assert.equal((await handleTts(request({ format: 'html' }), h.deps)).status, 400);
});

test('raw JSON string and Buffer bodies are accepted', async () => {
  const json = JSON.stringify({ upstream: 'elevenlabs', voiceId: VOICE, text: 'hi', format: 'text' });
  assert.equal((await handleTts({ method: 'POST', authorization: `Bearer ${TOKEN}`, body: json }, harness().deps)).status, 200);
  assert.equal((await handleTts({ method: 'POST', authorization: `Bearer ${TOKEN}`, body: Buffer.from(json) }, harness().deps)).status, 200);
});

test('ssml is stripped to plain text before upstream', async () => {
  assert.equal(ssmlToPlainText('<speak>Hi <break time="1s"/> there &amp; you</speak>'), 'Hi there & you');
  const h = harness();
  const res = await handleTts(request({ text: '<speak>Next up, <emphasis>Daft Punk</emphasis>.</speak>', format: 'ssml' }), h.deps);
  assert.equal(res.status, 200);
  const sent = JSON.parse(String(h.calls[0].init.body));
  assert.equal(sent.text, 'Next up, Daft Punk .');
  assert.ok(!sent.text.includes('<'));
});

test('ssml with only tags returns 400', async () => {
  const res = await handleTts(request({ text: '<speak><break time="1s"/></speak>', format: 'ssml' }), harness().deps);
  assert.equal(res.status, 400);
});

// --- Caps ---
test('daily character cap returns 429 once exhausted', async () => {
  const h = harness({ cap: 50 });
  const text = 'x'.repeat(30);
  assert.equal((await handleTts(request({ text }), h.deps)).status, 200);
  const res = await handleTts(request({ text }), h.deps);
  assert.equal(res.status, 429);
  assert.equal(h.calls.length, 1);
});

test('daily cap resets on the next UTC day', async () => {
  const limiter = new InMemoryUsageLimiter({ dailyCharCap: 10, requestsPerMinute: 100 });
  const day1 = Date.UTC(2026, 9, 28, 23, 59);
  assert.ok(await limiter.reserve('k', 10, day1));
  assert.equal(await limiter.reserve('k', 1, day1), null);
  assert.ok(await limiter.reserve('k', 1, day1 + 2 * 60_000));
});

test('rate limit returns 429 with Retry-After', async () => {
  const h = harness({ rate: 2 });
  assert.equal((await handleTts(request(), h.deps)).status, 200);
  assert.equal((await handleTts(request(), h.deps)).status, 200);
  const res = await handleTts(request(), h.deps);
  assert.equal(res.status, 429);
  assert.equal(res.headers['Retry-After'], '60');
  assert.equal(h.calls.length, 2);
});

// --- Upstream ---
test('missing ElevenLabs key returns generic 500 without calling upstream', async () => {
  const env = baseEnv();
  delete env.ELEVENLABS_API_KEY;
  const h = harness({ env });
  const res = await handleTts(request(), h.deps);
  assert.equal(res.status, 500);
  assert.deepEqual(Object.keys(errorBody(res)).sort(), ['error', 'requestId']);
  assert.equal(h.calls.length, 0);
});

test('upstream non-2xx returns 502 and never leaks the upstream body', async () => {
  const h = harness({
    fetch: async () => new Response('{"detail":"quota_exceeded LEAKY-UPSTREAM-DETAIL"}', { status: 401 }),
  });
  const res = await handleTts(request(), h.deps);
  assert.equal(res.status, 502);
  assert.ok(!res.body.toString().includes('LEAKY'));
  assert.equal(errorBody(res).error, 'Upstream error');
});

test('upstream network error returns 502', async () => {
  const res = await handleTts(request(), harness({ fetch: async () => { throw new Error('ECONNRESET secret'); } }).deps);
  assert.equal(res.status, 502);
  assert.ok(!res.body.toString().includes('secret'));
});

test('upstream timeout aborts and returns 504', async () => {
  let aborted = false;
  const h = harness({
    fetch: (_url, init) =>
      new Promise<Response>((_resolve, reject) => {
        init.signal?.addEventListener('abort', () => {
          aborted = true;
          reject(new DOMException('aborted', 'AbortError'));
        });
      }),
  });
  const res = await handleTts(request(), h.deps);
  assert.equal(res.status, 504);
  assert.ok(aborted);
});

test('empty upstream audio returns 502', async () => {
  const res = await handleTts(request(), harness({ fetch: async () => new Response(new Uint8Array(0), { status: 200 }) }).deps);
  assert.equal(res.status, 502);
});

test('oversized audio (>5MB WAV) returns 502', async () => {
  const res = await handleTts(request(), harness({ fetch: async () => pcmResponse(2_600_000) }).deps);
  assert.equal(res.status, 502);
});

test('success: upstream request shape is correct', async () => {
  const h = harness({ env: baseEnv({ ELEVENLABS_MODEL_ID: 'eleven_multilingual_v2' }) });
  await handleTts(request(), h.deps);
  assert.equal(h.calls.length, 1);
  const { url, init } = h.calls[0];
  assert.equal(url, `https://api.elevenlabs.io/v1/text-to-speech/${VOICE}?output_format=pcm_22050`);
  assert.equal(init.method, 'POST');
  assert.equal((init.headers as Record<string, string>)['xi-api-key'], API_KEY);
  assert.deepEqual(JSON.parse(String(init.body)), { text: 'Hello from the DJ booth.', model_id: 'eleven_multilingual_v2' });
});

test('success: default model is eleven_flash_v2_5', async () => {
  const h = harness();
  await handleTts(request(), h.deps);
  assert.equal(JSON.parse(String(h.calls[0].init.body)).model_id, 'eleven_flash_v2_5');
});

test('success: valid WAV, sample count, duration and billed chars match the client contract', async () => {
  const samples = 33_075; // 1.5 s
  const h = harness({ fetch: async () => pcmResponse(samples) });
  const text = 'Hello from the DJ booth.';
  const res = await handleTts(request({ text }), h.deps);
  assert.equal(res.status, 200);
  assert.ok(res.headers['Content-Type'].startsWith('audio/'));
  assert.equal(res.headers['Content-Type'], 'audio/wav');
  const wav = res.body;
  assert.ok(wav.length > 0 && wav.length <= 5_000_000);
  assert.equal(wav.toString('ascii', 0, 4), 'RIFF');
  assert.equal(wav.readUInt32LE(4), wav.length - 8);
  assert.equal(wav.toString('ascii', 8, 12), 'WAVE');
  assert.equal(wav.toString('ascii', 12, 16), 'fmt ');
  assert.equal(wav.readUInt32LE(16), 16);
  assert.equal(wav.readUInt16LE(20), 1); // PCM
  assert.equal(wav.readUInt16LE(22), 1); // mono
  assert.equal(wav.readUInt32LE(24), 22_050);
  assert.equal(wav.readUInt32LE(28), 44_100);
  assert.equal(wav.readUInt16LE(32), 2);
  assert.equal(wav.readUInt16LE(34), 16);
  assert.equal(wav.toString('ascii', 36, 40), 'data');
  const dataBytes = wav.readUInt32LE(40);
  assert.equal(dataBytes / 2, samples);
  assert.equal(wav.length, 44 + dataBytes);
  const duration = Number(res.headers['X-Audio-Duration']);
  assert.ok(Number.isFinite(duration) && duration > 0 && duration <= 600);
  assert.equal(duration, samples / 22_050);
  assert.equal(res.headers['X-Billed-Characters'], String(text.length));
  assert.equal(res.headers['Content-Length'], String(wav.length));
});

test('success: odd trailing PCM byte is dropped', async () => {
  const h = harness({ fetch: async () => new Response(Buffer.alloc(22_051), { status: 200 }) });
  const res = await handleTts(request(), h.deps);
  assert.equal(res.status, 200);
  assert.equal(res.body.readUInt32LE(40), 22_050);
  assert.equal(Number(res.headers['X-Audio-Duration']), 11_025 / 22_050);
});

test('success: upstream character-cost header is used for X-Billed-Characters', async () => {
  const h = harness({ fetch: async () => pcmResponse(22_050, { 'character-cost': '12' }) });
  const res = await handleTts(request(), h.deps);
  assert.equal(res.headers['X-Billed-Characters'], '12');
  const bad = await handleTts(request(), harness({ fetch: async () => pcmResponse(22_050, { 'character-cost': 'abc' }) }).deps);
  assert.equal(bad.headers['X-Billed-Characters'], String('Hello from the DJ booth.'.length));
});

// --- Logging / privacy ---
test('logs contain only requestId, status and chars; never text, token, key or voiceId', async () => {
  const lines: string[] = [];
  const spies = (['log', 'info', 'warn', 'error', 'debug'] as const).map((m) =>
    mock.method(console, m, (...args: unknown[]) => lines.push(args.map(String).join(' '))),
  );
  try {
    const deps = { ...defaultDeps(baseEnv()), limiter: new InMemoryUsageLimiter({ dailyCharCap: 1e6, requestsPerMinute: 1e6 }) };
    const ok = { ...deps, fetch: (async () => pcmResponse(22_050)) as typeof fetch };
    await handleTts(request({ text: SECRET_TEXT }), ok);
    await handleTts(request({ text: SECRET_TEXT }, 'Bearer wrong-secret-token'), ok);
    await handleTts(request({ text: SECRET_TEXT, voiceId: 'evilVoice' }), ok);
    const upstreamFail = { ...deps, fetch: (async () => new Response('UPSTREAM-SECRET', { status: 500 })) as typeof fetch };
    await handleTts(request({ text: SECRET_TEXT }), upstreamFail);
  } finally {
    spies.forEach((s) => s.mock.restore());
  }
  assert.equal(lines.length, 4);
  const all = lines.join('\n');
  for (const secret of [SECRET_TEXT, TOKEN, TOKEN_HASH, 'wrong-secret-token', API_KEY, VOICE, 'evilVoice', 'UPSTREAM-SECRET', 'Bearer']) {
    assert.ok(!all.includes(secret), `log leaked ${secret}`);
  }
  for (const line of lines.slice(0, 3)) {
    const parsed = JSON.parse(line);
    assert.deepEqual(Object.keys(parsed).sort(), ['chars', 'requestId', 'status']);
  }
  // The upstream non-2xx line adds exactly upstreamStatus and upstreamCode.
  assert.deepEqual(Object.keys(JSON.parse(lines[3])).sort(), ['chars', 'requestId', 'status', 'upstreamCode', 'upstreamStatus']);
  assert.deepEqual(lines.map((l) => JSON.parse(l).status), [200, 401, 400, 502]);
});

test('error bodies never echo user input', async () => {
  const res = await handleTts(request({ text: SECRET_TEXT, upstream: 'nope' }), harness().deps);
  assert.ok(!res.body.toString().includes(SECRET_TEXT));
  assert.ok(!res.body.toString().includes('nope'));
});

// --- Vercel adapter ---
test('api/tts adapter maps the handler result onto the Node response', async () => {
  const saved = { ...process.env };
  Object.assign(process.env, baseEnv());
  const logSpy = mock.method(console, 'log', () => {});
  try {
    const headers: Record<string, string> = {};
    let ended: Buffer | undefined;
    const res = {
      statusCode: 0,
      setHeader: (k: string, v: string) => { headers[k] = v; },
      end: (b: Buffer) => { ended = b; },
    };
    await apiHandler({ method: 'GET', headers: {} } as never, res as never);
    assert.equal(res.statusCode, 405);
    assert.equal(headers.Allow, 'POST');
    assert.ok(ended && ended.length > 0);
    await apiHandler({ method: 'POST', headers: {}, body: {} } as never, res as never);
    assert.equal(res.statusCode, 401);
  } finally {
    logSpy.mock.restore();
    process.env = saved;
  }
});

// --- Atomic daily cap under concurrency (reserve before render, refund on non-2xx) ---

function deferred(): { promise: Promise<void>; resolve: () => void } {
  let resolve!: () => void;
  const promise = new Promise<void>((r) => { resolve = r; });
  return { promise, resolve };
}

/**
 * Minimal Upstash REST stand-in. Each EVAL runs to completion in one synchronous step,
 * like a Lua script in single-threaded Redis, after yielding so requests interleave.
 */
function fakeUpstash(opts: { status?: number } = {}) {
  const data = new Map<string, number>();
  const calls: { url: string; auth: string | null; command: unknown[] }[] = [];
  const fetchImpl = (async (url: string, init: RequestInit) => {
    const command = JSON.parse(String(init.body)) as unknown[];
    calls.push({ url: String(url), auth: new Headers(init.headers).get('authorization'), command });
    await new Promise((r) => setImmediate(r));
    if (opts.status && opts.status !== 200) return new Response('{"error":"down"}', { status: opts.status });
    const [verb, script, numKeys, key, ...args] = command as [string, string, number, string, ...string[]];
    assert.equal(verb, 'EVAL');
    assert.equal(numKeys, 1);
    let result: number;
    const used = data.get(key) ?? 0;
    if (script === RATE_SCRIPT) {
      data.set(key, used + 1);
      result = used + 1 > Number(args[0]) ? 0 : 1;
    } else if (script === RESERVE_SCRIPT) {
      if (used + Number(args[0]) > Number(args[1])) result = -1;
      else data.set(key, (result = used + Number(args[0])));
    } else if (script === RELEASE_SCRIPT) {
      data.set(key, (result = Math.max(0, used - Number(args[0]))));
    } else {
      throw new Error('unexpected script');
    }
    return new Response(JSON.stringify({ result }), { status: 200 });
  }) as typeof fetch;
  return { data, calls, fetchImpl };
}

const STORE = { url: 'https://store.example.upstash.io', token: 'test-store-token-not-real' };
const TEXT_600 = 'y'.repeat(600);

async function concurrentPair(h1: Harness, h2: Harness, gate: { promise: Promise<void>; resolve: () => void }) {
  const p1 = handleTts(request({ text: TEXT_600 }), h1.deps);
  const p2 = handleTts(request({ text: TEXT_600 }), h2.deps);
  // The loser is rejected at reservation time, while the winner's render is still in flight.
  const first = await Promise.race([p1, p2]);
  assert.equal(first.status, 429);
  gate.resolve();
  return (await Promise.all([p1, p2])).map((r) => r.status).sort();
}

test('concurrent requests cannot jointly exceed the daily cap (one instance)', async () => {
  const gate = deferred();
  const h = harness({ cap: 600, fetch: async () => { await gate.promise; return pcmResponse(22_050); } });
  assert.deepEqual(await concurrentPair(h, h, gate), [200, 429]);
  assert.equal(h.calls.length, 1, 'only one request reaches the paid upstream');
});

test('concurrent requests on two instances sharing the Redis store cannot jointly exceed the cap', async () => {
  const store = fakeUpstash();
  const gate = deferred();
  const upstream = async () => { await gate.promise; return pcmResponse(22_050); };
  const options = { dailyCharCap: 600, requestsPerMinute: 100 };
  const h1 = harness({ fetch: upstream, limiter: new RedisUsageLimiter(STORE, options, store.fetchImpl) });
  const h2 = harness({ fetch: upstream, limiter: new RedisUsageLimiter(STORE, options, store.fetchImpl) });
  assert.deepEqual(await concurrentPair(h1, h2, gate), [200, 429]);
  assert.equal(h1.calls.length + h2.calls.length, 1, 'only one request reaches the paid upstream');
  assert.equal(store.data.get('aerodj-tts:chars:owner:2026-10-28'), 600);
});

test('in-memory limiter is per instance: two instances each allow a full cap (why production needs Redis)', async () => {
  const h1 = harness({ cap: 600 });
  const h2 = harness({ cap: 600 });
  assert.equal((await handleTts(request({ text: TEXT_600 }), h1.deps)).status, 200);
  assert.equal((await handleTts(request({ text: TEXT_600 }), h2.deps)).status, 200);
});

test('daily cap 429 carries Retry-After until the next UTC midnight', async () => {
  const h = harness({ cap: 10 });
  const res = await handleTts(request({ text: 'x'.repeat(11) }), h.deps);
  assert.equal(res.status, 429);
  assert.equal(res.headers['Retry-After'], String(12 * 3600));
  assert.equal(h.calls.length, 0);
});

test('upstream non-2xx refunds the reservation', async () => {
  let fail = true;
  const limiter = new InMemoryUsageLimiter({ dailyCharCap: 600, requestsPerMinute: 100 });
  const h = harness({ limiter, fetch: async () => (fail ? new Response('nope', { status: 500 }) : pcmResponse(22_050)) });
  assert.equal((await handleTts(request({ text: TEXT_600 }), h.deps)).status, 502);
  assert.equal(limiter.used('owner', h.deps.now()), 0);
  fail = false;
  assert.equal((await handleTts(request({ text: TEXT_600 }), h.deps)).status, 200);
  assert.equal(limiter.used('owner', h.deps.now()), 600);
});

test('upstream non-2xx refunds the Redis reservation too', async () => {
  const store = fakeUpstash();
  const limiter = new RedisUsageLimiter(STORE, { dailyCharCap: 600, requestsPerMinute: 100 }, store.fetchImpl);
  const h = harness({ limiter, fetch: async () => new Response('nope', { status: 503 }) });
  assert.equal((await handleTts(request({ text: TEXT_600 }), h.deps)).status, 502);
  assert.equal(store.data.get('aerodj-tts:chars:owner:2026-10-28'), 0);
});

test('network error, timeout and bad audio keep the reservation (may have been billed)', async () => {
  const cases: [number, Harness['deps']['fetch']][] = [
    [502, (async () => { throw new Error('ECONNRESET'); }) as typeof fetch],
    [504, ((_u: string, init: RequestInit) => new Promise<Response>((_r, reject) => {
      init.signal?.addEventListener('abort', () => reject(new DOMException('aborted', 'AbortError')));
    })) as unknown as typeof fetch],
    [502, (async () => new Response(new Uint8Array(0), { status: 200 })) as typeof fetch],
  ];
  for (const [status, fetchImpl] of cases) {
    const limiter = new InMemoryUsageLimiter({ dailyCharCap: 600, requestsPerMinute: 100 });
    const h = harness({ limiter, fetch: fetchImpl as never });
    assert.equal((await handleTts(request({ text: TEXT_600 }), h.deps)).status, status);
    assert.equal(limiter.used('owner', h.deps.now()), 600, `status ${status} keeps the reservation`);
  }
});

test('rate limit is shared across instances through the Redis store', async () => {
  const store = fakeUpstash();
  const options = { dailyCharCap: 20_000, requestsPerMinute: 2 };
  const a = harness({ limiter: new RedisUsageLimiter(STORE, options, store.fetchImpl) });
  const b = harness({ limiter: new RedisUsageLimiter(STORE, options, store.fetchImpl) });
  assert.equal((await handleTts(request(), a.deps)).status, 200);
  assert.equal((await handleTts(request(), b.deps)).status, 200);
  const res = await handleTts(request(), a.deps);
  assert.equal(res.status, 429);
  assert.equal(res.headers['Retry-After'], '60');
  assert.equal(a.calls.length + b.calls.length, 2);
});

test('Redis limiter speaks Upstash REST: bearer store token, one EVAL per operation', async () => {
  const store = fakeUpstash();
  const h = harness({ limiter: new RedisUsageLimiter(STORE, { dailyCharCap: 20_000, requestsPerMinute: 12 }, store.fetchImpl) });
  assert.equal((await handleTts(request(), h.deps)).status, 200);
  assert.equal(store.calls.length, 2);
  for (const call of store.calls) {
    assert.equal(call.url, STORE.url);
    assert.equal(call.auth, `Bearer ${STORE.token}`);
  }
  assert.equal(store.calls[0].command[1], RATE_SCRIPT);
  assert.equal(store.calls[0].command[3], `aerodj-tts:rate:owner:${Math.floor(h.deps.now() / 60_000)}`);
  assert.equal(store.calls[1].command[1], RESERVE_SCRIPT);
  assert.deepEqual(store.calls[1].command.slice(3), ['aerodj-tts:chars:owner:2026-10-28', String('Hello from the DJ booth.'.length), '20000', '172800']);
  assert.ok(!JSON.stringify(store.calls).includes(TOKEN), 'the owner bearer never reaches the store');
});

test('limiter store failure fails closed with 503 and never calls upstream', async () => {
  const store = fakeUpstash({ status: 500 });
  const h = harness({ limiter: new RedisUsageLimiter(STORE, { dailyCharCap: 600, requestsPerMinute: 12 }, store.fetchImpl) });
  const res = await handleTts(request(), h.deps);
  assert.equal(res.status, 503);
  assert.equal(h.calls.length, 0);
  const unreachable = harness({
    limiter: new RedisUsageLimiter(STORE, { dailyCharCap: 600, requestsPerMinute: 12 }, (async () => { throw new Error('dns'); }) as typeof fetch),
  });
  assert.equal((await handleTts(request(), unreachable.deps)).status, 503);
  assert.equal(unreachable.calls.length, 0);
});

test('selectLimiter: Redis when configured; production without a store fails closed unless the owner opts in', async () => {
  assert.ok(selectLimiter({ KV_REST_API_URL: STORE.url, KV_REST_API_TOKEN: STORE.token, VERCEL_ENV: 'production' })?.durable);
  assert.ok(selectLimiter({ UPSTASH_REDIS_REST_URL: STORE.url, UPSTASH_REDIS_REST_TOKEN: STORE.token })?.durable);
  assert.equal(selectLimiter({ KV_REST_API_URL: 'http://plain.example', KV_REST_API_TOKEN: 't', VERCEL_ENV: 'production' }), null);
  assert.equal(selectLimiter({ VERCEL_ENV: 'production' }), null);
  assert.equal(selectLimiter({ VERCEL_ENV: 'production', AERODJ_TTS_ACCEPT_BEST_EFFORT_LIMITS: 'true' })?.durable, false);
  assert.equal(selectLimiter({ VERCEL_ENV: 'preview' })?.durable, false);
  assert.equal(selectLimiter({})?.durable, false);
});

test('no acceptable limiter returns generic 500 without calling upstream', async () => {
  const h = harness({ limiter: null });
  const res = await handleTts(request(), h.deps);
  assert.equal(res.status, 500);
  assert.equal(h.calls.length, 0);
});

// --- Upstream failure diagnostics: integer status + allowlisted detail.status code only ---
async function captureUpstreamFailure(upstream: () => Response, text = SECRET_TEXT) {
  const lines: string[] = [];
  const spies = (['log', 'info', 'warn', 'error', 'debug'] as const).map((m) =>
    mock.method(console, m, (...args: unknown[]) => lines.push(args.map(String).join(' '))),
  );
  let res;
  try {
    const deps = {
      ...defaultDeps(baseEnv()),
      limiter: new InMemoryUsageLimiter({ dailyCharCap: 1e6, requestsPerMinute: 1e6 }),
      fetch: (async () => upstream()) as typeof fetch,
    };
    res = await handleTts(request({ text }), deps);
  } finally {
    spies.forEach((s) => s.mock.restore());
  }
  assert.equal(lines.length, 1);
  return { res, line: lines[0], parsed: JSON.parse(lines[0]) as Record<string, unknown> };
}

const GENERIC_502_KEYS = ['error', 'requestId'];

test('upstream 402 logs upstreamStatus 402 and upstreamCode payment_required, never the message, voice or text', async () => {
  const { res, line, parsed } = await captureUpstreamFailure(
    () => new Response(JSON.stringify({ detail: { status: 'payment_required', message: 'secret text' } }), { status: 402 }),
  );
  assert.equal(parsed.upstreamStatus, 402);
  assert.equal(parsed.upstreamCode, 'payment_required');
  for (const leak of ['secret text', VOICE, SECRET_TEXT, 'message', 'detail']) assert.ok(!line.includes(leak), `log leaked ${leak}`);
  assert.equal(res.status, 502);
  assert.deepEqual(Object.keys(errorBody(res)).sort(), GENERIC_502_KEYS);
  assert.equal(errorBody(res).error, 'Upstream error');
  assert.ok(!res.body.toString().includes('payment_required'));
});

test('upstream non-JSON body logs upstreamCode other', async () => {
  const { parsed } = await captureUpstreamFailure(() => new Response('<html>Bad Gateway</html>', { status: 500 }));
  assert.equal(parsed.upstreamStatus, 500);
  assert.equal(parsed.upstreamCode, 'other');
});

test('absent or invalid detail.status logs upstreamCode other', async () => {
  const bodies = [
    {},
    { detail: 'quota_exceeded' },
    { detail: { message: 'no status' } },
    { detail: { status: 42 } },
    { detail: { status: 'has spaces in it' } },
    { detail: { status: 'UPPER_case' } },
    { detail: { status: 'a'.repeat(65) } },
    { detail: { status: '' } },
  ];
  for (const body of bodies) {
    const { parsed, line } = await captureUpstreamFailure(() => new Response(JSON.stringify(body), { status: 401 }));
    assert.equal(parsed.upstreamStatus, 401);
    assert.equal(parsed.upstreamCode, 'other', JSON.stringify(body));
    assert.ok(!line.includes('has spaces') && !line.includes('a'.repeat(65)) && !line.includes('UPPER'));
  }
  // Exactly 64 allowed characters still passes the allowlist.
  const ok = await captureUpstreamFailure(() => new Response(JSON.stringify({ detail: { status: 'b'.repeat(64) } }), { status: 401 }));
  assert.equal(ok.parsed.upstreamCode, 'b'.repeat(64));
});

test('hostile upstream body: log holds only the two added fields and none of its values', async () => {
  const FAKE_KEY = 'sk_live_FAKE123';
  const LONG = 'L'.repeat(2_000); // keeps the body under the 4 KB cap so it is parsed
  const hostile = JSON.stringify({
    detail: { status: 'quota_exceeded', message: `${SECRET_TEXT} ${VOICE} ${FAKE_KEY}` },
    echo: { text: SECRET_TEXT, voice_id: VOICE, key: FAKE_KEY, xi: API_KEY, token: TOKEN },
    long: LONG,
  });
  assert.ok(Buffer.byteLength(hostile) < 4096);
  const { res, line, parsed } = await captureUpstreamFailure(() => new Response(hostile, { status: 401 }));
  assert.deepEqual(Object.keys(parsed).sort(), ['chars', 'requestId', 'status', 'upstreamCode', 'upstreamStatus']);
  assert.equal(parsed.status, 502);
  assert.equal(parsed.upstreamStatus, 401);
  assert.equal(parsed.upstreamCode, 'quota_exceeded');
  for (const leak of [SECRET_TEXT, VOICE, FAKE_KEY, API_KEY, TOKEN, 'LLLLLLLL', 'message', 'echo']) {
    assert.ok(!line.includes(leak), `log leaked ${leak.slice(0, 20)}`);
    assert.ok(!res.body.toString().includes(leak), `response leaked ${leak.slice(0, 20)}`);
  }
});

test('upstream error body is read at most 4 KB: a status beyond the cap is not parsed', async () => {
  // Valid JSON overall, but detail.status sits after the 4 KB cap, so the truncated text fails to parse.
  const body = JSON.stringify({ pad: 'p'.repeat(5000), detail: { status: 'quota_exceeded' } });
  const { parsed } = await captureUpstreamFailure(() => new Response(body, { status: 429 }));
  assert.equal(parsed.upstreamStatus, 429);
  assert.equal(parsed.upstreamCode, 'other');
});

test('upstream failure still returns the same generic 502 body and refunds the reservation', async () => {
  const limiter = new InMemoryUsageLimiter({ dailyCharCap: 600, requestsPerMinute: 100 });
  const h = harness({
    limiter,
    fetch: async () => new Response(JSON.stringify({ detail: { status: 'payment_required', message: 'secret text' } }), { status: 402 }),
  });
  const res = await handleTts(request({ text: 'x'.repeat(600) }), h.deps);
  assert.equal(res.status, 502);
  assert.deepEqual(errorBody(res), { error: 'Upstream error', requestId: 'req-1' });
  assert.equal(res.headers['Content-Type'], 'application/json');
  assert.deepEqual(h.logs, [{ requestId: 'req-1', status: 502, chars: 600, upstreamStatus: 402, upstreamCode: 'payment_required' }]);
  // Refunded: the full 600-char cap is available again.
  const again = harness({ limiter });
  assert.equal((await handleTts(request({ text: 'x'.repeat(600) }), again.deps)).status, 200);
});
