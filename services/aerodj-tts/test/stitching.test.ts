import { test } from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import {
  handleTts,
  MAX_CONTEXT_CHARS,
  modelFamily,
  sanitizeBrackets,
  upstreamBody,
  V3_VOICE_SETTINGS,
  V4_VOICE_SETTINGS,
  VOICE_SETTINGS,
  voiceSettingsFor,
  type Deps,
  type Env,
  type LogEntry,
  type TtsRequest,
} from '../src/handler.js';
import { InMemoryUsageLimiter } from '../src/limiter.js';

// Intonation plan (owner-approved 2026-11-02): stitching context, per-model settings, bracket safety.

const TOKEN = 'test-owner-token-not-a-real-secret';
const TOKEN_HASH = crypto.createHash('sha256').update(TOKEN).digest('hex');
const VOICE = 'voiceAllowed123';

function pcm(headers: Record<string, string> = {}): Response {
  return new Response(Buffer.alloc(22_050 * 2, 1), { status: 200, headers: { 'Content-Type': 'audio/pcm', ...headers } });
}

function harness(env: Env = {}, fetchImpl: () => Promise<Response> = async () => pcm()) {
  const calls: RequestInit[] = [];
  const logs: LogEntry[] = [];
  const limiter = new InMemoryUsageLimiter({ deployment: 'production', dailyCharCap: 20_000, requestsPerMinute: 100 });
  const deps: Deps = {
    env: { AERODJ_TTS_TOKEN_SHA256: TOKEN_HASH, AERODJ_TTS_VOICE_IDS: VOICE, ELEVENLABS_API_KEY: 'test-key-not-real', ...env },
    fetch: (async (_url: string, init: RequestInit) => {
      calls.push(init);
      return fetchImpl();
    }) as typeof fetch,
    limiter,
    log: (e) => logs.push(e),
    now: () => Date.UTC(2026, 10, 2, 12),
    timeoutMs: 50,
    requestId: () => 'req-1',
    testOnlyAllowNonDurableLimiter: true,
  };
  return { deps, calls, logs, limiter };
}

function request(extra: Record<string, unknown> = {}): TtsRequest {
  return {
    method: 'POST',
    authorization: `Bearer ${TOKEN}`,
    body: { upstream: 'elevenlabs', voiceId: VOICE, text: 'Okay, here comes the next one.', format: 'text', ...extra },
  };
}

const sent = (h: { calls: RequestInit[] }) => JSON.parse(String(h.calls[0].body)) as Record<string, unknown>;

// --- Backward compatibility ---
test('an old app build (no context fields) gets exactly the three-field body', async () => {
  const h = harness();
  assert.equal((await handleTts(request(), h.deps)).status, 200);
  assert.deepEqual(sent(h), { text: 'Okay, here comes the next one.', model_id: 'eleven_flash_v2_5', voice_settings: VOICE_SETTINGS });
});

test('null or empty context is the same as none', async () => {
  const h = harness();
  assert.equal((await handleTts(request({ previousText: null, nextText: '   ', previousRequestIds: null }), h.deps)).status, 200);
  assert.deepEqual(Object.keys(sent(h)).sort(), ['model_id', 'text', 'voice_settings']);
});

// --- Context forwarding ---
test('previousText and nextText are forwarded as previous_text and next_text', async () => {
  const h = harness();
  const res = await handleTts(request({ previousText: "Hey, good morning — you're on Sunday Drive.", nextText: "It's nine-forty." }), h.deps);
  assert.equal(res.status, 200);
  const body = sent(h);
  assert.equal(body.previous_text, "Hey, good morning — you're on Sunday Drive.");
  assert.equal(body.next_text, "It's nine-forty.");
  assert.equal(body.text, 'Okay, here comes the next one.');
});

test('context is not charged: the reservation and the log count the spoken text only', async () => {
  const h = harness();
  const res = await handleTts(request({ previousText: 'p'.repeat(250), nextText: 'n'.repeat(250) }), h.deps);
  assert.equal(res.status, 200);
  assert.equal(h.logs.at(-1)?.chars, 'Okay, here comes the next one.'.length);
  assert.equal(res.headers['X-Billed-Characters'], String('Okay, here comes the next one.'.length));
});

test('context is trimmed to MAX_CONTEXT_CHARS, keeping the side nearest the spoken line', async () => {
  const h = harness();
  const previous = 'a'.repeat(400) + ' END';
  const next = 'START ' + 'b'.repeat(400);
  assert.equal((await handleTts(request({ previousText: previous, nextText: next }), h.deps)).status, 200);
  const body = sent(h);
  assert.ok((body.previous_text as string).length <= MAX_CONTEXT_CHARS);
  assert.ok((body.previous_text as string).endsWith(' END'));
  assert.ok((body.next_text as string).length <= MAX_CONTEXT_CHARS);
  assert.ok((body.next_text as string).startsWith('START '));
});

test('a non-string or absurdly long context field is 400 and nothing is spent', async () => {
  for (const extra of [{ previousText: 42 }, { nextText: ['x'] }, { previousText: 'x'.repeat(MAX_CONTEXT_CHARS * 8 + 1) }]) {
    const h = harness();
    assert.equal((await handleTts(request(extra), h.deps)).status, 400, JSON.stringify(extra).slice(0, 40));
    assert.equal(h.calls.length, 0);
  }
});

test('previousRequestIds: up to 3 shape-checked ids are forwarded; anything else is 400', async () => {
  const h = harness();
  assert.equal((await handleTts(request({ previousRequestIds: ['abc123', 'DEF_456-x'] }), h.deps)).status, 200);
  assert.deepEqual(sent(h).previous_request_ids, ['abc123', 'DEF_456-x']);
  for (const bad of [['a', 'b', 'c', 'd'], 'abc', [1], ['has space'], ['x'.repeat(65)]]) {
    const b = harness();
    assert.equal((await handleTts(request({ previousRequestIds: bad }), b.deps)).status, 400);
    assert.equal(b.calls.length, 0);
  }
});

test("ElevenLabs' request-id comes back as X-Upstream-Request-Id only when it is a plain id", async () => {
  const ok = harness({}, async () => pcm({ 'request-id': 'Abc_123-z' }));
  assert.equal((await handleTts(request(), ok.deps)).headers['X-Upstream-Request-Id'], 'Abc_123-z');
  const odd = harness({}, async () => pcm({ 'request-id': 'not ok; injected' }));
  assert.equal((await handleTts(request(), odd.deps)).headers['X-Upstream-Request-Id'], undefined);
  const none = harness();
  assert.ok(!('X-Upstream-Request-Id' in (await handleTts(request(), none.deps)).headers));
});

test('context on SSML requests is reduced to plain text', async () => {
  const h = harness();
  await handleTts(request({ format: 'ssml', text: '<speak>Here we go.</speak>', previousText: '<speak>Hey <break time="300ms"/> there.</speak>' }), h.deps);
  assert.equal(sent(h).previous_text, 'Hey there.');
});

// --- Per-model settings ---
test('model families and their voice_settings', () => {
  assert.equal(modelFamily('eleven_flash_v2_5'), 'v2');
  assert.equal(modelFamily('eleven_multilingual_v2'), 'v2');
  assert.equal(modelFamily('eleven_v4'), 'v4');
  assert.equal(modelFamily('eleven_v4_turbo'), 'v4');
  assert.equal(modelFamily('eleven_v3'), 'v3');
  assert.equal(modelFamily('eleven_v40_future'), 'v2', 'prefix match is exact');
  assert.deepEqual({ ...VOICE_SETTINGS }, { stability: 0.32, similarity_boost: 0.75, speed: 1.03 });
  assert.deepEqual({ ...V4_VOICE_SETTINGS }, { stability: 0.32, similarity_boost: 0.75 });
  assert.equal(voiceSettingsFor('eleven_flash_v2_5'), VOICE_SETTINGS);
  assert.equal(voiceSettingsFor('eleven_v4_turbo'), V4_VOICE_SETTINGS);
  assert.equal(voiceSettingsFor('eleven_v3'), V3_VOICE_SETTINGS);
  for (const s of [VOICE_SETTINGS, V4_VOICE_SETTINGS, V3_VOICE_SETTINGS]) {
    assert.ok(Object.isFrozen(s));
    assert.ok(!('style' in s) && !('use_speaker_boost' in s));
  }
  assert.ok(VOICE_SETTINGS.speed >= 1.0 && VOICE_SETTINGS.speed <= 1.05, 'speed within the approved [1.0, 1.05]');
});

test('v4 models get only stability and similarity_boost (no speed, no style)', async () => {
  for (const model of ['eleven_v4', 'eleven_v4_turbo']) {
    const h = harness({ ELEVENLABS_MODEL_ID: model });
    await handleTts(request({ previousText: 'Hey there.' }), h.deps);
    const body = sent(h);
    assert.equal(body.model_id, model);
    assert.deepEqual(body.voice_settings, { stability: 0.32, similarity_boost: 0.75 });
    assert.equal(body.previous_text, 'Hey there.', 'v4 supports stitching');
  }
});

test('eleven_v3 gets no stitching fields (not available on v3)', async () => {
  const h = harness({ ELEVENLABS_MODEL_ID: 'eleven_v3' });
  await handleTts(request({ previousText: 'Hey.', nextText: 'Bye.', previousRequestIds: ['abc'] }), h.deps);
  assert.deepEqual(Object.keys(sent(h)).sort(), ['model_id', 'text', 'voice_settings']);
  assert.deepEqual(sent(h).voice_settings, { stability: 0.5, similarity_boost: 0.75 });
});

test('upstreamBody omits empty context', () => {
  assert.deepEqual(Object.keys(upstreamBody('Hi.', 'eleven_flash_v2_5', { previousText: '', nextText: null, previousRequestIds: [] })).sort(), [
    'model_id',
    'text',
    'voice_settings',
  ]);
});

// --- Bracket safety ---
test('sanitizeBrackets: titles and user text can never become audio tags', () => {
  assert.equal(sanitizeBrackets('That was Song [Live] from Band.', true), 'That was Song Live from Band.');
  assert.equal(sanitizeBrackets('[whispers] secret', true), 'whispers secret');
  assert.equal(sanitizeBrackets('[warmly] Hey there.', true), '[warmly] Hey there.');
  assert.equal(sanitizeBrackets('[ Warmly ] Hey.', true), '[warmly] Hey.');
  assert.equal(sanitizeBrackets('[warmly] Hey there.', false), 'Hey there.');
  assert.equal(sanitizeBrackets('a ] [warmly] [ b', true), 'a [warmly] b', 'stray brackets never pair with a kept tag');
  assert.equal(sanitizeBrackets('[[warmly]]', true), '[warmly]');
  assert.equal(sanitizeBrackets('No brackets here.', true), 'No brackets here.');
});

test('on Flash every bracket is removed from the spoken text, and chars are counted after', async () => {
  const h = harness();
  const res = await handleTts(request({ text: '[laughs] That was Song [Live].' }), h.deps);
  assert.equal(res.status, 200);
  assert.equal(sent(h).text, 'laughs That was Song Live .');
  assert.equal(h.logs.at(-1)?.chars, 'laughs That was Song Live .'.length);
});

test('on v4 an allowlisted tag survives; any other bracket in the text does not', async () => {
  const h = harness({ ELEVENLABS_MODEL_ID: 'eleven_v4' });
  await handleTts(request({ text: '[warmly] That was Song [shouts].', previousText: '[warmly] Hi.' }), h.deps);
  assert.equal(sent(h).text, '[warmly] That was Song shouts .');
  assert.equal(sent(h).previous_text, 'Hi.', 'context never carries tags');
});

test('text that is only brackets is 400 and nothing is spent', async () => {
  const h = harness();
  assert.equal((await handleTts(request({ text: '[ ]' }), h.deps)).status, 400);
  assert.equal(h.calls.length, 0);
});
