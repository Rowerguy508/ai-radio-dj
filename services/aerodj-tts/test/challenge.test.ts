import { test, describe, mock } from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { readFileSync } from 'node:fs';
import {
  CHALLENGE_BYTES,
  CHALLENGE_TTL_MS,
  CLOCK_SKEW_MS,
  USED_TTL_SECONDS,
  issueChallenge,
  parseChallengeKey,
  parseKeyId,
  usedKey,
  verifyChallenge,
  type Purpose,
} from '../src/challenge.js';
import { verifyAndConsumeChallenge } from '../src/challenge-consume.js';
import { ChallengeStoreError, RedisChallengeStore, selectChallengeStore, type ChallengeStore } from '../src/challenge-store.js';
import { handleChallenge, type AttestLogEntry, type ChallengeDeps } from '../src/challenge-handler.js';
import { flagEnabled } from '../src/attest-flags.js';
import { BODY_CAPS, bodySha256Hex, parseJsonObject, readRawBody } from '../src/raw-body.js';
import challengeEndpoint from '../api/attest/challenge.js';

// Test-only key material: generated here, never an env value, never a real secret.
const KEY = crypto.createHash('sha256').update('aerodj-tts test challenge key, not a secret').digest();
const KEY_HEX = KEY.toString('hex');
const OTHER_KEY = crypto.createHash('sha256').update('another test key').digest();
const NOW = Date.UTC(2026, 9, 29, 12);
const KEY_ID_A = crypto.createHash('sha256').update('install A').digest();
const KEY_ID_B = crypto.createHash('sha256').update('install B').digest();
const KEY_ID_A_B64 = KEY_ID_A.toString('base64');

function issue(purpose: Purpose, keyId: Buffer | null = purpose === 'attest' ? null : KEY_ID_A, now = NOW, key = KEY) {
  return issueChallenge({ key, purpose, keyId, now });
}
function check(challenge: unknown, purpose: Purpose, keyId: Buffer | null = purpose === 'attest' ? null : KEY_ID_A, now = NOW, key = KEY) {
  return verifyChallenge(challenge, { key, purpose, keyId, now });
}
/** Re-MACs a tampered header with the right key, to reach checks after the MAC. */
function remac(challenge: string, mutate: (header: Buffer) => void, keyId: Buffer | null): string {
  const bytes = Buffer.from(challenge, 'base64url');
  const header = Buffer.from(bytes.subarray(0, CHALLENGE_BYTES - 32));
  mutate(header);
  const h = crypto.createHmac('sha256', KEY).update(Buffer.from('onairly-challenge-v1\0')).update(header);
  if (keyId) h.update(keyId);
  return Buffer.concat([header, h.digest()]).toString('base64url');
}

class FakeStore implements ChallengeStore {
  durable = true;
  calls: { key: string; ttl: number }[] = [];
  used = new Set<string>();
  fail = false;
  async markUsed(key: string, ttl: number): Promise<boolean> {
    this.calls.push({ key, ttl });
    if (this.fail) throw new ChallengeStoreError('down');
    if (this.used.has(key)) return false;
    this.used.add(key);
    return true;
  }
  reads: string[] = [];
  async isUsed(key: string): Promise<boolean> {
    this.reads.push(key);
    if (this.fail) throw new ChallengeStoreError('down');
    return this.used.has(key);
  }
}

// ---------------------------------------------------------------------------
describe('stateless challenge (note §4.1.1, Sentinel B1)', () => {
  test('round trip for every purpose', () => {
    for (const p of ['attest', 'tts', 'ent'] as const) {
      const c = issue(p);
      assert.equal(Buffer.from(c, 'base64url').length, CHALLENGE_BYTES);
      assert.deepEqual(check(c, p), { ok: true, issuedAt: NOW });
    }
  });

  test('attest challenge may be bound to a keyId and then needs the same keyId', () => {
    const c = issue('attest', KEY_ID_A);
    assert.equal(check(c, 'attest', KEY_ID_A).ok, true);
    assert.equal(check(c, 'attest', KEY_ID_B).ok, false);
    assert.deepEqual(check(c, 'attest', null), { ok: false, reason: 'key_binding' });
  });

  test('two issuances differ (random nonce)', () => {
    assert.notEqual(issue('tts'), issue('tts'));
  });

  test('bad MAC: every flipped byte, and a different key, fail', () => {
    const c = issue('tts');
    const bytes = Buffer.from(c, 'base64url');
    for (let i = 0; i < bytes.length; i++) {
      const t = Buffer.from(bytes);
      t[i] ^= 0x01;
      const r = check(t.toString('base64url'), 'tts');
      assert.equal(r.ok, false, `byte ${i}`);
    }
    assert.deepEqual(check(c, 'tts', KEY_ID_A, NOW, OTHER_KEY), { ok: false, reason: 'mac' });
  });

  test('MAC compared with timingSafeEqual on 32-byte buffers', () => {
    const spy = mock.method(crypto, 'timingSafeEqual');
    try {
      check(issue('ent'), 'ent');
      assert.equal(spy.mock.callCount(), 1);
      const [a, b] = spy.mock.calls[0].arguments as unknown as [Buffer, Buffer];
      assert.equal(a.length, 32);
      assert.equal(b.length, 32);
    } finally {
      spy.mock.restore();
    }
  });

  test('expired after 120 s; valid at exactly 120 s', () => {
    const c = issue('tts');
    assert.equal(check(c, 'tts', KEY_ID_A, NOW + CHALLENGE_TTL_MS).ok, true);
    assert.deepEqual(check(c, 'tts', KEY_ID_A, NOW + CHALLENGE_TTL_MS + 1), { ok: false, reason: 'expired' });
  });

  test('issued in the future beyond the skew is refused', () => {
    const c = issue('tts', KEY_ID_A, NOW + CLOCK_SKEW_MS + 1);
    assert.deepEqual(check(c, 'tts'), { ok: false, reason: 'future' });
    assert.equal(check(issue('tts', KEY_ID_A, NOW + CLOCK_SKEW_MS), 'tts').ok, true);
  });

  test('wrong purpose: attest cannot be spent on tts, tts not on ent, ent not on attest', () => {
    assert.deepEqual(check(issue('tts'), 'ent'), { ok: false, reason: 'purpose' });
    assert.deepEqual(check(issue('ent'), 'tts'), { ok: false, reason: 'purpose' });
    assert.deepEqual(check(issue('tts'), 'attest', KEY_ID_A), { ok: false, reason: 'purpose' });
    assert.deepEqual(check(issue('attest', KEY_ID_A), 'tts'), { ok: false, reason: 'purpose' });
  });

  test('install scope (Sentinel rec. 6): tts/ent challenge only verifies with its own keyId', () => {
    const c = issue('tts', KEY_ID_A);
    assert.deepEqual(check(c, 'tts', KEY_ID_B), { ok: false, reason: 'mac' });
    assert.deepEqual(check(c, 'tts', null), { ok: false, reason: 'key_binding' });
  });

  test('unbound challenge with a valid MAC is refused for tts/ent', () => {
    const forged = remac(issue('attest'), (h) => { h[1] = 2; }, null);
    assert.deepEqual(check(forged, 'tts'), { ok: false, reason: 'key_binding' });
  });

  test('unknown version with a valid MAC is refused', () => {
    const v2 = remac(issue('tts'), (h) => { h[0] = 2; }, KEY_ID_A);
    assert.deepEqual(check(v2, 'tts'), { ok: false, reason: 'version' });
  });

  test('issuing tts/ent without keyId throws', () => {
    assert.throws(() => issueChallenge({ key: KEY, purpose: 'tts', keyId: null, now: NOW }));
    assert.throws(() => issueChallenge({ key: KEY, purpose: 'ent', keyId: null, now: NOW }));
  });

  test('malformed inputs', () => {
    const c = issue('tts');
    for (const bad of [undefined, null, 42, '', 'not base64url!', c + 'A', c.slice(0, -1), c + '=', 'A'.repeat(200)]) {
      assert.equal(check(bad, 'tts').ok, false, String(bad));
    }
    const badFlags = remac(c, (h) => { h[2] = 0x02; }, KEY_ID_A);
    assert.deepEqual(check(badFlags, 'tts'), { ok: false, reason: 'malformed' });
  });

  test('parseChallengeKey: owner-provided hex or base64 of ≥32 bytes, else null', () => {
    assert.equal(parseChallengeKey(undefined), null);
    assert.equal(parseChallengeKey(''), null);
    assert.equal(parseChallengeKey('ab'.repeat(31)), null);
    assert.equal(parseChallengeKey('not a key!'), null);
    assert.deepEqual(parseChallengeKey(KEY_HEX), KEY);
    assert.deepEqual(parseChallengeKey(KEY.toString('base64')), KEY);
    assert.deepEqual(parseChallengeKey(KEY.toString('base64url')), KEY);
  });

  test('parseKeyId: base64 of 32 bytes only', () => {
    assert.deepEqual(parseKeyId(KEY_ID_A_B64), KEY_ID_A);
    for (const bad of [undefined, 1, '', KEY_ID_A.toString('base64url'), KEY_ID_A.subarray(0, 31).toString('base64'), KEY_ID_A_B64 + 'A']) {
      assert.equal(parseKeyId(bad), null);
    }
  });
});

// ---------------------------------------------------------------------------
describe('consumption only after signature verification (Sentinel B1)', () => {
  const base = (store: ChallengeStore | null, verifySignature: () => Promise<boolean>, challenge: unknown = issue('tts')) => ({
    challenge, purpose: 'tts' as const, keyId: KEY_ID_A, key: KEY, now: NOW, store, verifySignature,
  });

  test('valid signature consumes once with SET NX EX 300 on used:{aerodj-tts}:<sha256>', async () => {
    const store = new FakeStore();
    const c = issue('tts');
    assert.deepEqual(await verifyAndConsumeChallenge(base(store, async () => true, c)), { ok: true });
    assert.deepEqual(store.calls, [{ key: usedKey(c), ttl: USED_TTL_SECONDS }]);
    assert.match(usedKey(c), /^used:\{aerodj-tts\}:[0-9a-f]{64}$/);
    assert.equal(usedKey(c).includes(c), false);
    assert.ok(USED_TTL_SECONDS * 1000 > CHALLENGE_TTL_MS + CLOCK_SKEW_MS);
  });

  test('replay: second use is 401 assertion (reused)', async () => {
    const store = new FakeStore();
    const c = issue('tts');
    await verifyAndConsumeChallenge(base(store, async () => true, c));
    assert.deepEqual(await verifyAndConsumeChallenge(base(store, async () => true, c)), {
      ok: false, status: 401, reason: 'assertion', detail: 'reused',
    });
  });

  test('failed signature writes nothing; the challenge stays usable by the real install', async () => {
    const store = new FakeStore();
    const c = issue('tts');
    const r = await verifyAndConsumeChallenge(base(store, async () => false, c));
    assert.deepEqual(r, { ok: false, status: 401, reason: 'assertion', detail: 'signature' });
    assert.equal(store.calls.length, 0);
    assert.deepEqual(await verifyAndConsumeChallenge(base(store, async () => true, c)), { ok: true });
  });

  test('stateless failure: no signature work, no store call', async () => {
    const store = new FakeStore();
    let sig = 0;
    const r = await verifyAndConsumeChallenge(base(store, async () => { sig++; return true; }, issue('ent')));
    assert.deepEqual(r, { ok: false, status: 401, reason: 'assertion', detail: 'purpose' });
    assert.equal(sig, 0);
    assert.equal(store.calls.length, 0);
  });

  test('no store or non-durable store: 503 store, fail closed', async () => {
    assert.deepEqual(await verifyAndConsumeChallenge(base(null, async () => true)), { ok: false, status: 503, reason: 'store' });
    const s = new FakeStore();
    s.durable = false;
    assert.deepEqual(await verifyAndConsumeChallenge(base(s, async () => true)), { ok: false, status: 503, reason: 'store' });
    assert.equal(s.calls.length, 0);
  });

  test('store error: 503 store', async () => {
    const s = new FakeStore();
    s.fail = true;
    assert.deepEqual(await verifyAndConsumeChallenge(base(s, async () => true)), { ok: false, status: 503, reason: 'store' });
  });
});

describe('RedisChallengeStore (Upstash REST)', () => {
  const cfg = { url: 'https://example-upstash.invalid', token: 'test-token-not-real' };
  const fake = (respond: () => Response | Promise<Response>) => {
    const calls: unknown[] = [];
    const f = (async (_url: string, init: RequestInit) => { calls.push(JSON.parse(String(init.body))); return respond(); }) as unknown as typeof fetch;
    return { calls, f };
  };

  test('sends SET key 1 NX EX ttl; OK → first use, null → reused', async () => {
    const a = fake(() => Response.json({ result: 'OK' }));
    assert.equal(await new RedisChallengeStore(cfg, a.f).markUsed('used:{aerodj-tts}:x', 300), true);
    assert.deepEqual(a.calls, [['SET', 'used:{aerodj-tts}:x', '1', 'NX', 'EX', '300']]);
    const b = fake(() => Response.json({ result: null }));
    assert.equal(await new RedisChallengeStore(cfg, b.f).markUsed('k', 300), false);
  });

  test('transport, HTTP, error payload and odd results throw ChallengeStoreError', async () => {
    const cases: (() => Response | Promise<Response>)[] = [
      () => { throw new Error('net'); },
      () => new Response('x', { status: 500 }),
      () => Response.json({ error: 'ERR' }),
      () => Response.json({}),
      () => Response.json({ result: 1 }),
      () => new Response('not json'),
    ];
    for (const c of cases) {
      await assert.rejects(new RedisChallengeStore(cfg, fake(c).f).markUsed('k', 300), ChallengeStoreError);
    }
  });

  test('selectChallengeStore: durable only with https Upstash creds; no in-memory fallback', () => {
    assert.equal(selectChallengeStore({}), null);
    assert.equal(selectChallengeStore({ VERCEL_ENV: 'development' }), null);
    assert.equal(selectChallengeStore({ KV_REST_API_URL: 'http://x', KV_REST_API_TOKEN: 't' }), null);
    assert.equal(selectChallengeStore({ KV_REST_API_URL: 'https://x', KV_REST_API_TOKEN: 't' })?.durable, true);
  });
});

// ---------------------------------------------------------------------------
describe('POST /api/attest/challenge (note §4.1.1, §4.4, §4.7)', () => {
  const ENABLED = { AERODJ_TTS_ATTEST_ENABLED: 'true', AERODJ_TTS_CHALLENGE_HMAC_KEY: KEY_HEX };
  function harness(env: Record<string, string | undefined> = ENABLED, store: ChallengeStore | null = new FakeStore()) {
    const logs: AttestLogEntry[] = [];
    const deps: ChallengeDeps = { env, store, log: (e) => logs.push(e), now: () => NOW, requestId: () => 'req-1' };
    return { deps, logs, store };
  }
  const post = (body: string | Uint8Array | ReadableStream | null, headers: Record<string, string> = {}, method = 'POST') =>
    new Request('https://proxy.invalid/api/attest/challenge', {
      method, body: method === 'GET' ? null : body, headers: { 'Content-Type': 'application/json', ...headers },
      ...(body instanceof ReadableStream ? { duplex: 'half' } : {}),
    } as RequestInit);
  const ttsBody = JSON.stringify({ purpose: 'tts', keyId: KEY_ID_A_B64 });

  test('issues a verifiable, key-bound challenge with no store call', async () => {
    const h = harness();
    const res = await handleChallenge(post(ttsBody), h.deps);
    assert.equal(res.status, 200);
    assert.equal(res.headers.get('cache-control'), 'no-store');
    const body = (await res.json()) as { challenge: string; expiresIn: number };
    assert.equal(body.expiresIn, 120);
    assert.equal(check(body.challenge, 'tts', KEY_ID_A).ok, true);
    assert.equal((h.store as FakeStore).calls.length, 0);
  });

  test('no Redis call at issuance, against the real Upstash client (fetch spy)', async () => {
    let calls = 0;
    const store = new RedisChallengeStore({ url: 'https://u.invalid', token: 't' }, (async () => { calls++; return Response.json({ result: 'OK' }); }) as unknown as typeof fetch);
    const res = await handleChallenge(post(ttsBody), harness(ENABLED, store).deps);
    assert.equal(res.status, 200);
    assert.equal(calls, 0);
  });

  test('attest purpose works without keyId', async () => {
    const res = await handleChallenge(post(JSON.stringify({ purpose: 'attest' })), harness().deps);
    assert.equal(res.status, 200);
  });

  test('kill switch off by default: 503 disabled, Retry-After 3600, before key or store', async () => {
    for (const v of [undefined, '', 'TRUE', 'True', '1', 'yes', 'true ', ' true', 'false']) {
      const h = harness({ AERODJ_TTS_ATTEST_ENABLED: v, AERODJ_TTS_CHALLENGE_HMAC_KEY: KEY_HEX });
      const res = await handleChallenge(post(ttsBody), h.deps);
      assert.equal(res.status, 503, String(v));
      assert.equal(res.headers.get('retry-after'), '3600');
      assert.deepEqual(await res.json(), { error: 'Service unavailable', requestId: 'req-1', reason: 'disabled', retryAfterSeconds: 3600 });
      assert.equal((h.store as FakeStore).calls.length, 0);
    }
    assert.equal((await handleChallenge(post(ttsBody), harness({ AERODJ_TTS_ATTEST_ENABLED: 'true' }, null).deps)).status, 500);
  });

  test('flagEnabled accepts only the literal "true"', () => {
    assert.equal(flagEnabled({ X: 'true' }, 'X'), true);
    for (const v of [undefined, 'TRUE', 'true ', '1']) assert.equal(flagEnabled({ X: v }, 'X'), false);
  });

  test('missing or short HMAC key: 500 misconfig, Retry-After 3600', async () => {
    for (const k of [undefined, '', 'ab'.repeat(31)]) {
      const res = await handleChallenge(post(ttsBody), harness({ AERODJ_TTS_ATTEST_ENABLED: 'true', AERODJ_TTS_CHALLENGE_HMAC_KEY: k }).deps);
      assert.equal(res.status, 500);
      assert.equal(res.headers.get('retry-after'), '3600');
      assert.equal(((await res.json()) as { reason: string }).reason, 'misconfig');
    }
  });

  test('no durable store configured: 503 store, Retry-After 30 (PR 3 gate, fail closed)', async () => {
    for (const store of [null, Object.assign(new FakeStore(), { durable: false })]) {
      const res = await handleChallenge(post(ttsBody), harness(ENABLED, store).deps);
      assert.equal(res.status, 503);
      assert.equal(res.headers.get('retry-after'), '30');
      assert.equal(((await res.json()) as { reason: string }).reason, 'store');
    }
  });

  test('405 with Allow: POST', async () => {
    const res = await handleChallenge(post(null, {}, 'GET'), harness().deps);
    assert.equal(res.status, 405);
    assert.equal(res.headers.get('allow'), 'POST');
  });

  test('bad requests: 400 bad_request', async () => {
    const bodies = [
      '', 'null', '[]', '{', JSON.stringify({ purpose: 'other' }), JSON.stringify({ purpose: 'tts' }),
      JSON.stringify({ purpose: 'ent' }), JSON.stringify({ purpose: 'tts', keyId: 'short' }),
      JSON.stringify({ purpose: 'attest', keyId: 7 }), JSON.stringify({ purpose: 'tts', keyId: KEY_ID_A_B64, extra: 1 }),
    ];
    for (const b of bodies) {
      const res = await handleChallenge(post(b), harness().deps);
      assert.equal(res.status, 400, b);
      assert.equal(((await res.json()) as { reason: string }).reason, 'bad_request');
    }
  });

  test('413 too_large from Content-Length and from a stream without it', async () => {
    const big = 'x'.repeat(BODY_CAPS.challenge + 1);
    const a = await handleChallenge(post(big), harness().deps);
    assert.equal(a.status, 413);
    const stream = new ReadableStream({ start(c) { c.enqueue(new TextEncoder().encode(big)); c.close(); } });
    const b = await handleChallenge(post(stream), harness().deps);
    assert.equal(b.status, 413);
    assert.equal(((await b.json()) as { reason: string }).reason, 'too_large');
  });

  test('logs carry only requestId, status, reason: never keyId or challenge', async () => {
    const h = harness();
    const res = await handleChallenge(post(ttsBody), h.deps);
    const { challenge } = (await res.json()) as { challenge: string };
    await handleChallenge(post(JSON.stringify({ purpose: 'tts', keyId: KEY_ID_A_B64, x: 1 })), h.deps);
    const text = JSON.stringify(h.logs);
    for (const secret of [KEY_ID_A_B64, challenge, KEY_HEX]) assert.equal(text.includes(secret), false);
    for (const e of h.logs) assert.deepEqual(Object.keys(e).filter((k) => !['requestId', 'status', 'reason'].includes(k)), []);
  });

  test('deployed entry is a Web-signature fetch export and is off without the flag', async () => {
    assert.equal(typeof challengeEndpoint.fetch, 'function');
    const saved = process.env.AERODJ_TTS_ATTEST_ENABLED;
    delete process.env.AERODJ_TTS_ATTEST_ENABLED;
    try {
      const res = await challengeEndpoint.fetch(post(ttsBody));
      assert.equal(res.status, 503);
      assert.equal(((await res.json()) as { reason: string }).reason, 'disabled');
    } finally {
      if (saved !== undefined) process.env.AERODJ_TTS_ATTEST_ENABLED = saved;
    }
  });
});

// ---------------------------------------------------------------------------
describe('raw body (note §4.1.4, Sentinel B4)', () => {
  const FIXTURE = readFileSync(new URL('./fixtures/raw-body-v1.bin', import.meta.url));
  // Computed independently with `sha256sum test/fixtures/raw-body-v1.bin`.
  const FIXTURE_SHA256 = '7b22d085dee859db8b2f664a6ca1d301d442a60c619788c15a444814a4505952';
  const req = (body: BodyInit | null, headers: Record<string, string> = {}) =>
    new Request('https://proxy.invalid/x', { method: 'POST', body, headers, ...(body instanceof ReadableStream ? { duplex: 'half' } : {}) } as RequestInit);
  const chunked = (parts: Uint8Array[]) => new ReadableStream<Uint8Array>({ start(c) { for (const p of parts) c.enqueue(p); c.close(); } });

  test('exact-bytes fixture hashes to the shared value; JSON parsed from the same bytes', async () => {
    const r = await readRawBody(req(FIXTURE), BODY_CAPS.tts);
    assert.ok(r.ok);
    assert.deepEqual(r.bytes, FIXTURE);
    assert.equal(bodySha256Hex(r.bytes), FIXTURE_SHA256);
    assert.equal(parseJsonObject(r.bytes)?.text, 'Up next: café jazz — live');
  });

  test('whitespace and key-order variants are the same JSON but a different hash', () => {
    const obj = JSON.parse(FIXTURE.toString('utf8')) as Record<string, unknown>;
    const spaced = Buffer.from(JSON.stringify(obj, null, 1));
    const reordered = Buffer.from(JSON.stringify(Object.fromEntries(Object.entries(obj).reverse())));
    const trailing = Buffer.concat([FIXTURE, Buffer.from('\n')]);
    for (const v of [spaced, reordered, trailing]) {
      assert.deepEqual(parseJsonObject(v), obj);
      assert.notEqual(bodySha256Hex(v), FIXTURE_SHA256);
    }
  });

  test('multi-chunk stream (UTF-8 split across chunks) yields the exact bytes', async () => {
    const parts = [FIXTURE.subarray(0, 61), FIXTURE.subarray(61, 62), FIXTURE.subarray(62)];
    const r = await readRawBody(req(chunked(parts)), BODY_CAPS.tts);
    assert.ok(r.ok);
    assert.equal(bodySha256Hex(r.bytes), FIXTURE_SHA256);
  });

  test('cap boundary: exactly cap ok, cap + 1 too_large (declared and streamed)', async () => {
    const cap = 64;
    assert.equal((await readRawBody(req(Buffer.alloc(cap, 0x61)), cap)).ok, true);
    assert.deepEqual(await readRawBody(req(Buffer.alloc(cap + 1, 0x61)), cap), { ok: false, reason: 'too_large' });
    const s = chunked([Buffer.alloc(40, 0x61), Buffer.alloc(25, 0x61)]);
    assert.deepEqual(await readRawBody(req(s), cap), { ok: false, reason: 'too_large' });
  });

  test('declared Content-Length above the cap is refused before reading; exactly cap is read', async () => {
    let pulled = 0;
    const lazy = new ReadableStream<Uint8Array>({ pull(c) { pulled++; c.close(); } });
    const r = await readRawBody(req(lazy, { 'content-length': '65' }), 64);
    assert.deepEqual(r, { ok: false, reason: 'too_large' });
    assert.equal(pulled, 0);
    const exact = await readRawBody(req(chunked([Buffer.alloc(64, 0x61)]), { 'content-length': '64' }), 64);
    assert.equal(exact.ok, true);
    assert.deepEqual(await readRawBody(req(FIXTURE, { 'content-length': '1e3' }), 1e6), { ok: false, reason: 'bad_request' });
  });

  test('a lying small Content-Length does not lift the cap', async () => {
    const s = chunked([Buffer.alloc(100, 0x61)]);
    const r = await readRawBody(req(s, { 'content-length': '10' }), 64);
    assert.deepEqual(r, { ok: false, reason: 'too_large' });
  });

  test('Content-Encoding other than identity and bad Content-Length are 400', async () => {
    assert.deepEqual(await readRawBody(req(FIXTURE, { 'content-encoding': 'gzip' }), 1e6), { ok: false, reason: 'bad_request' });
    assert.equal((await readRawBody(req(FIXTURE, { 'content-encoding': 'identity' }), 1e6)).ok, true);
  });

  test('caps match the note: tts 8 KB, entitlement/register 16 KB, notifications 64 KB', () => {
    assert.equal(BODY_CAPS.tts, 8192);
    assert.equal(BODY_CAPS.entitlement, 16384);
    assert.equal(BODY_CAPS.register, 16384);
    assert.equal(BODY_CAPS.notifications, 65536);
  });

  test('parseJsonObject: invalid UTF-8, BOM, arrays and scalars are refused', () => {
    assert.equal(parseJsonObject(Buffer.from([0x7b, 0x22, 0xff, 0x22, 0x7d])), null);
    assert.equal(parseJsonObject(Buffer.concat([Buffer.from([0xef, 0xbb, 0xbf]), Buffer.from('{}')])), null);
    for (const s of ['[]', '1', '"x"', 'null', '']) assert.equal(parseJsonObject(Buffer.from(s)), null);
    assert.deepEqual(parseJsonObject(Buffer.from('{"a":1}')), { a: 1 });
  });

  test('empty body reads as zero bytes', async () => {
    const r = await readRawBody(req(null), 10);
    assert.deepEqual(r, { ok: true, bytes: Buffer.alloc(0) });
  });
});

// ---------------------------------------------------------------------------
// PR 3 (#233): pinned challenge body cap, 400 challenge_expired, master stop.
describe('PR 3: challenge endpoint body cap is pinned at 1024 bytes (Fry, #246 mutation survivor)', () => {
  const ENABLED = { AERODJ_TTS_ATTEST_ENABLED: 'true', AERODJ_TTS_CHALLENGE_HMAC_KEY: KEY_HEX };
  const deps = (): ChallengeDeps => ({ env: ENABLED, store: new FakeStore(), log: () => {}, now: () => NOW, requestId: () => 'req-1' });
  /** A valid `{"purpose":"attest"}` body padded with JSON whitespace to exactly `n` bytes. */
  const padded = (n: number) => {
    const core = JSON.stringify({ purpose: 'attest' });
    return core.slice(0, -1) + ' '.repeat(n - core.length) + '}';
  };
  const post = (body: string, streamed: boolean) =>
    new Request('https://proxy.invalid/api/attest/challenge', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: streamed ? new ReadableStream({ start(c) { c.enqueue(new TextEncoder().encode(body)); c.close(); } }) : body,
      ...(streamed ? { duplex: 'half' } : {}),
    } as RequestInit);

  test('the constant is 1024 (a literal, not relative to itself)', () => {
    assert.equal(BODY_CAPS.challenge, 1024);
  });

  test('exactly 1024 bytes is accepted, 1025 bytes is 413 too_large (declared and streamed)', async () => {
    assert.equal(Buffer.byteLength(padded(1024)), 1024);
    assert.equal(Buffer.byteLength(padded(1025)), 1025);
    for (const streamed of [false, true]) {
      const ok = await handleChallenge(post(padded(1024), streamed), deps());
      assert.equal(ok.status, 200, `1024 bytes, streamed=${streamed}`);
      const big = await handleChallenge(post(padded(1025), streamed), deps());
      assert.equal(big.status, 413, `1025 bytes, streamed=${streamed}`);
      assert.equal(((await big.json()) as { reason: string }).reason, 'too_large');
    }
  });
});

describe('PR 3: expired challenge → 400 challenge_expired only when otherwise valid', () => {
  const LATE = NOW + CHALLENGE_TTL_MS + 1;
  const run = (store: ChallengeStore | null, challenge: unknown, opts: { sig?: boolean; keyId?: Buffer | null; purpose?: Purpose; now?: number } = {}) => {
    let sigCalls = 0;
    const result = verifyAndConsumeChallenge({
      challenge,
      purpose: opts.purpose ?? 'tts',
      keyId: opts.keyId === undefined ? KEY_ID_A : opts.keyId,
      key: KEY,
      now: opts.now ?? LATE,
      store,
      verifySignature: async () => { sigCalls++; return opts.sig ?? true; },
    });
    return { result, sigCalls: () => sigCalls };
  };

  test('valid MAC, purpose, key and signature, unused, past 120 s → 400 challenge_expired; nothing written', async () => {
    const store = new FakeStore();
    const c = issue('tts');
    const r = run(store, c);
    assert.deepEqual(await r.result, { ok: false, status: 400, reason: 'challenge_expired' });
    assert.equal(r.sigCalls(), 1, 'signature is verified before the expired reason is given');
    assert.equal(store.calls.length, 0, 'an expired challenge is never marked (no write)');
    assert.deepEqual(store.reads, [usedKey(c)], 'one read-only EXISTS on its used mark');
  });

  test('the same for attest and ent purposes', async () => {
    assert.deepEqual(await run(new FakeStore(), issue('attest'), { purpose: 'attest', keyId: null }).result, { ok: false, status: 400, reason: 'challenge_expired' });
    assert.deepEqual(await run(new FakeStore(), issue('ent'), { purpose: 'ent' }).result, { ok: false, status: 400, reason: 'challenge_expired' });
  });

  test('boundary: at exactly 120 s it is still valid and consumed', async () => {
    assert.deepEqual(await run(new FakeStore(), issue('tts'), { now: NOW + CHALLENGE_TTL_MS }).result, { ok: true });
  });

  test('forged (wrong HMAC key) and expired → 401 assertion, no signature work, no store access', async () => {
    const store = new FakeStore();
    const r = run(store, issue('tts', KEY_ID_A, NOW, OTHER_KEY));
    assert.deepEqual(await r.result, { ok: false, status: 401, reason: 'assertion', detail: 'mac' });
    assert.equal(r.sigCalls(), 0);
    assert.equal(store.reads.length + store.calls.length, 0);
  });

  test('tampered timestamp (MAC no longer matches) → 401 assertion', async () => {
    const c = issue('tts');
    const bytes = Buffer.from(c, 'base64url');
    bytes.writeBigUInt64BE(BigInt(NOW - 10 * CHALLENGE_TTL_MS), 3);
    const r = run(new FakeStore(), bytes.toString('base64url'), { now: NOW });
    assert.deepEqual(await r.result, { ok: false, status: 401, reason: 'assertion', detail: 'mac' });
  });

  test('expired but otherwise bad → 401 assertion: wrong purpose, other keyId, bad version, unbound', async () => {
    const store = new FakeStore();
    assert.deepEqual(await run(store, issue('ent')).result, { ok: false, status: 401, reason: 'assertion', detail: 'purpose' });
    assert.deepEqual(await run(store, issue('tts', KEY_ID_B)).result, { ok: false, status: 401, reason: 'assertion', detail: 'mac' });
    const badVersion = remac(issue('tts'), (h) => { h[0] = 2; }, KEY_ID_A);
    assert.deepEqual(await run(store, badVersion).result, { ok: false, status: 401, reason: 'assertion', detail: 'version' });
    const unbound = issue('attest', null);
    assert.deepEqual(await run(store, unbound).result, { ok: false, status: 401, reason: 'assertion', detail: 'purpose' });
    assert.equal(store.reads.length + store.calls.length, 0);
  });

  test('expired with a bad signature → 401 assertion (signature), no store read', async () => {
    const store = new FakeStore();
    const r = run(store, issue('tts'), { sig: false });
    assert.deepEqual(await r.result, { ok: false, status: 401, reason: 'assertion', detail: 'signature' });
    assert.equal(store.reads.length, 0);
  });

  test('reused, then presented after expiry → 401 assertion (reused), never challenge_expired', async () => {
    const store = new FakeStore();
    const c = issue('tts');
    assert.deepEqual(await run(store, c, { now: NOW }).result, { ok: true });
    assert.deepEqual(await run(store, c).result, { ok: false, status: 401, reason: 'assertion', detail: 'reused' });
    assert.equal(store.calls.length, 1, 'only the first, in-time use wrote');
  });

  test('issued in the future stays 401 assertion', async () => {
    const r = run(new FakeStore(), issue('tts', KEY_ID_A, NOW + CLOCK_SKEW_MS + 1), { now: NOW });
    assert.deepEqual(await r.result, { ok: false, status: 401, reason: 'assertion', detail: 'future' });
  });

  test('expired with no durable store, or a store error on the read → 503 store (fail closed)', async () => {
    assert.deepEqual(await run(null, issue('tts')).result, { ok: false, status: 503, reason: 'store' });
    const down = new FakeStore();
    down.fail = true;
    assert.deepEqual(await run(down, issue('tts')).result, { ok: false, status: 503, reason: 'store' });
  });

  test('RedisChallengeStore.isUsed sends EXISTS and maps 1/0; anything else throws', async () => {
    const cfg = { url: 'https://example-upstash.invalid', token: 'test-token-not-real' };
    const calls: unknown[] = [];
    const store = (result: unknown) =>
      new RedisChallengeStore(cfg, (async (_u: string, init: RequestInit) => { calls.push(JSON.parse(String(init.body))); return Response.json({ result }); }) as unknown as typeof fetch);
    assert.equal(await store(1).isUsed('used:{aerodj-tts}:x'), true);
    assert.equal(await store(0).isUsed('used:{aerodj-tts}:x'), false);
    assert.deepEqual(calls[0], ['EXISTS', 'used:{aerodj-tts}:x']);
    for (const odd of [null, 'OK', 2, '1']) await assert.rejects(store(odd).isUsed('k'), ChallengeStoreError);
  });
});
