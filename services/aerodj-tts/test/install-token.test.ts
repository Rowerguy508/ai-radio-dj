/**
 * #378 (owner decisions 2026-11-02): TestFlight install token + tester voice.
 * - /api/attest/token: issue, wrong key, revoked, missing record, no tester tier, replayed
 *   counter, reused / expired / foreign challenge, mint rate, flags fail closed, mixed auth.
 * - install token: verify, expiry, wrong key, tamper, env, future iat.
 * - AERODJ_TTS_TESTER_VOICE_ENABLED: exact `true` only (unset, TRUE, 1 … all off).
 * - /api/tts with the token: per-install 1,500/day, tester pool 6,000, owner share 3,000
 *   isolated from testers, global 9,000, 429 shape + Retry-After to 00:00 UTC, spoken chars
 *   only, refund on upstream non-2xx, revocation bites mid-token, owner path unchanged.
 * - Logs never carry the token, the key, the keyId / install id, the challenge or script text.
 * All key material is derived here from fixed strings: never an env value, never a secret.
 */
import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import crypto, { type KeyObject } from 'node:crypto';
import { attestClientDataHash } from '../src/app-attest-verify.js';
import { tokenClientData } from '../src/app-attest-assertion.js';
import { attestEnabled, testerVoiceEnabled, testerVoiceOn } from '../src/attest-flags.js';
import {
  counterKey,
  keyRecordKey,
  RedisAttestStore,
  revokedKey,
  TOKEN_MINT_DAILY_CAP,
  tokenMintKey,
  type Keyspace,
} from '../src/attest-store.js';
import { issueChallenge, CHALLENGE_TTL_MS, verifyChallenge } from '../src/challenge.js';
import { handleTts, limiterOptions, secondsUntilNextUtcDay, selectLimiter, type Deps, type Env, type LogEntry, type TtsRequest } from '../src/handler.js';
import {
  INSTALL_TOKEN_TTL_SECONDS,
  installTokenKey,
  mintInstallToken,
  verifyInstallToken,
} from '../src/install-token.js';
import { effectiveTesterPoolCap, RedisUsageLimiter, testerPoolDayKey, utcDay } from '../src/limiter.js';
import { handleRegister, testerTier, type RegisterLogEntry } from '../src/register-handler.js';
import { handleToken, type TokenDeps, type TokenLogEntry } from '../src/token-handler.js';
import { cbor, cmap, makeAttestCa, makeAttestation, TEST_APP_ID, TEST_APP_ID_PREFIX, uncompressedPoint } from './helpers/fake-appattest.js';
import { FakeRedis, fakeUpstash } from './redis-lua.js';

const CHALLENGE_KEY = crypto.createHash('sha256').update('install-token test challenge key, not a secret').digest();
const TOKEN_KEY = crypto.createHash('sha256').update('install-token test token key, not a secret').digest();
const OTHER_TOKEN_KEY = crypto.createHash('sha256').update('another install-token test key').digest();
const OWNER = 'test-owner-token-not-a-real-secret';
const OWNER_HASH = crypto.createHash('sha256').update(OWNER).digest('hex');
const VOICE = 'voiceAllowed123';
const NOW = Date.UTC(2026, 10, 2, 15, 0, 0);
const TOKEN_URL = 'https://proxy.invalid/api/attest/token';
const CA = makeAttestCa();

const ATTEST_ENV: Env = Object.freeze({
  AERODJ_TTS_ATTEST_ENABLED: 'true',
  AERODJ_TTS_TESTER_VOICE_ENABLED: 'true',
  AERODJ_TTS_CHALLENGE_HMAC_KEY: CHALLENGE_KEY.toString('hex'),
  AERODJ_TTS_INSTALL_TOKEN_HMAC_KEY: TOKEN_KEY.toString('hex'),
  AERODJ_TTS_APPLE_APP_ID_PREFIX: TEST_APP_ID_PREFIX,
  VERCEL_ENV: 'preview',
});

const merge = (base: Env, over: Env): Env => {
  const out: Env = { ...base, ...over };
  for (const [k, v] of Object.entries(over)) if (v === undefined) delete out[k];
  return out;
};
const sha256 = (...parts: Buffer[]) => {
  const h = crypto.createHash('sha256');
  for (const p of parts) h.update(p);
  return h.digest();
};

// --- a fake install: P-256 key, keyId = SHA-256 of the uncompressed point (Apple's rule) ---
interface Install {
  key: { publicKey: KeyObject; privateKey: KeyObject };
  keyId: Buffer;
  counter: number;
}
function newInstall(): Install {
  const key = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  return { key, keyId: sha256(uncompressedPoint(key.publicKey).point), counter: 0 };
}
function seed(redis: FakeRedis, keyspace: Keyspace, inst: Install, record: Record<string, unknown> = {}) {
  const spki = inst.key.publicKey.export({ format: 'der', type: 'spki' }) as Buffer;
  redis.data.set(
    keyRecordKey(keyspace, inst.keyId),
    JSON.stringify({ pubKeySpki: spki.toString('base64'), counter: 0, env: 'production', createdDay: '2026-11-02', revoked: false, tier: 'tester', ...record }),
  );
}
/** An App Attest assertion: CBOR {signature, authenticatorData}, ES256 over SHA256(authData ‖ SHA256(clientData)). */
function makeAssertion(
  signer: KeyObject,
  clientData: Buffer,
  counter: number,
  o: { appId?: string; extensions?: Buffer; flags?: number } = {},
): Buffer {
  const c = Buffer.alloc(4);
  c.writeUInt32BE(counter);
  const authData = Buffer.concat([sha256(Buffer.from(o.appId ?? TEST_APP_ID)), Buffer.from([o.flags ?? 0x00]), c, o.extensions ?? Buffer.alloc(0)]);
  const signature = crypto.sign('sha256', sha256(authData, sha256(clientData)), signer);
  return cbor(cmap(['signature', signature], ['authenticatorData', authData]));
}
const tokChallenge = (keyId: Buffer | null, now = NOW, key = CHALLENGE_KEY) => issueChallenge({ key, purpose: 'tok', keyId, now });

interface TokenOpts {
  challenge?: string;
  body?: string;
  signer?: KeyObject;
  counter?: number;
  keyHeader?: string;
  assertionHeader?: string;
  headers?: Record<string, string>;
  method?: string;
  extensions?: Buffer;
  appId?: string;
}
function tokenRequest(inst: Install, o: TokenOpts = {}): Request {
  const challenge = o.challenge ?? tokChallenge(inst.keyId);
  const body = o.body ?? JSON.stringify({ challenge });
  const counter = o.counter ?? ++inst.counter;
  const assertion = makeAssertion(o.signer ?? inst.key.privateKey, tokenClientData(challenge, Buffer.from(body)), counter, {
    extensions: o.extensions,
    appId: o.appId,
  });
  return new Request(TOKEN_URL, {
    method: o.method ?? 'POST',
    ...(o.method && o.method !== 'POST' ? {} : { body }),
    headers: {
      'x-onairly-key': o.keyHeader ?? inst.keyId.toString('base64'),
      'x-onairly-assertion': o.assertionHeader ?? assertion.toString('base64'),
      ...o.headers,
    },
  });
}

function tokenHarness(env: Env = {}, redis = new FakeRedis(() => NOW), now = NOW) {
  const up = fakeUpstash({ redis });
  const logs: TokenLogEntry[] = [];
  const deps: TokenDeps = {
    env: merge(ATTEST_ENV, env),
    store: new RedisAttestStore({ url: 'https://upstash.invalid', token: 'test-store-token-not-real' }, up.fetchImpl),
    log: (e) => logs.push(e),
    now: () => now,
    requestId: () => 'req-tok',
  };
  return { redis, calls: up.calls, logs, deps };
}
async function jsonOf(res: Response) {
  return (await res.json()) as Record<string, unknown>;
}

// ===========================================================================
describe('install token: mint / verify (#378 §1.2)', () => {
  const KID = sha256(Buffer.from('a key id'));
  const mint = (now = NOW, key = TOKEN_KEY, env: Keyspace = 'production') => mintInstallToken({ key, keyId: KID, env, now }).token;

  test('round trip: 30-minute token bound to the keyId, tier tester', () => {
    const t = mint();
    const v = verifyInstallToken(t, { key: TOKEN_KEY, env: 'production', now: NOW });
    assert.ok(v.ok);
    assert.equal(v.claims.sub, KID.toString('base64url'));
    assert.equal(v.claims.exp - v.claims.iat, 1800);
    assert.equal(INSTALL_TOKEN_TTL_SECONDS, 1800);
    assert.equal(v.claims.tier, 'tester');
  });
  test('expiry: valid at 29:59, refused at 30:00 and later (no grace)', () => {
    const t = mint();
    assert.ok(verifyInstallToken(t, { key: TOKEN_KEY, env: 'production', now: NOW + 1799_000 }).ok);
    assert.deepEqual(verifyInstallToken(t, { key: TOKEN_KEY, env: 'production', now: NOW + 1800_000 }), { ok: false, reason: 'expired' });
    assert.deepEqual(verifyInstallToken(t, { key: TOKEN_KEY, env: 'production', now: NOW + 86_400_000 }), { ok: false, reason: 'expired' });
  });
  test('wrong signing key → mac', () => {
    assert.deepEqual(verifyInstallToken(mint(NOW, OTHER_TOKEN_KEY), { key: TOKEN_KEY, env: 'production', now: NOW }), { ok: false, reason: 'mac' });
  });
  test('tampered payload (sub swapped) → mac', () => {
    const [v, , sig] = mint().split('.');
    const forged = Buffer.from(JSON.stringify({ aud: 'aerodj-tts/tts', sub: sha256(Buffer.from('other')).toString('base64url'), tier: 'tester', env: 'production', iat: 1, exp: 2, jti: 'A'.repeat(22) })).toString('base64url');
    assert.deepEqual(verifyInstallToken(`${v}.${forged}.${sig}`, { key: TOKEN_KEY, env: 'production', now: NOW }), { ok: false, reason: 'mac' });
  });
  test('a Preview token is refused on Production (env claim)', () => {
    assert.deepEqual(verifyInstallToken(mint(NOW, TOKEN_KEY, 'nonprod'), { key: TOKEN_KEY, env: 'production', now: NOW }), { ok: false, reason: 'env' });
  });
  test('iat more than 30 s in the future → future', () => {
    assert.deepEqual(verifyInstallToken(mint(NOW + 31_000), { key: TOKEN_KEY, env: 'production', now: NOW }), { ok: false, reason: 'future' });
    assert.ok(verifyInstallToken(mint(NOW + 30_000), { key: TOKEN_KEY, env: 'production', now: NOW }).ok);
  });
  test('malformed: non-string, empty, wrong version, oversize', () => {
    for (const t of [undefined, 42, '', 'v2.abc.def', `v1.${'A'.repeat(600)}.x`, mint() + '=']) {
      const r = verifyInstallToken(t, { key: TOKEN_KEY, env: 'production', now: NOW });
      assert.equal(r.ok, false);
    }
  });
  test('token key: unset, short or equal to the challenge key → null (500 misconfig)', () => {
    assert.equal(installTokenKey({}), null);
    assert.equal(installTokenKey({ AERODJ_TTS_INSTALL_TOKEN_HMAC_KEY: 'abcd' }), null);
    assert.equal(installTokenKey({ AERODJ_TTS_INSTALL_TOKEN_HMAC_KEY: CHALLENGE_KEY.toString('hex'), AERODJ_TTS_CHALLENGE_HMAC_KEY: CHALLENGE_KEY.toString('hex') }), null);
    assert.ok(installTokenKey({ AERODJ_TTS_INSTALL_TOKEN_HMAC_KEY: TOKEN_KEY.toString('hex'), AERODJ_TTS_CHALLENGE_HMAC_KEY: CHALLENGE_KEY.toString('hex') }));
  });
});

describe('`tok` challenge purpose', () => {
  test('key-bound: issuing without a keyId throws; a tok challenge is not a tts/ent one', () => {
    assert.throws(() => issueChallenge({ key: CHALLENGE_KEY, purpose: 'tok', keyId: null, now: NOW }));
    const kid = sha256(Buffer.from('k'));
    const c = tokChallenge(kid);
    assert.deepEqual(verifyChallenge(c, { key: CHALLENGE_KEY, purpose: 'tok', keyId: kid, now: NOW }), { ok: true, issuedAt: NOW });
    assert.deepEqual(verifyChallenge(c, { key: CHALLENGE_KEY, purpose: 'tts', keyId: kid, now: NOW }), { ok: false, reason: 'purpose' });
    assert.equal(verifyChallenge(c, { key: CHALLENGE_KEY, purpose: 'tok', keyId: sha256(Buffer.from('j')), now: NOW }).ok, false);
  });
});

// ===========================================================================
describe('AERODJ_TTS_TESTER_VOICE_ENABLED fails closed (exact `true` only)', () => {
  for (const v of [undefined, '', 'TRUE', 'True', '1', 'yes', 'on', ' true', 'true ', 'false']) {
    test(`${JSON.stringify(v)} → off`, () => {
      const env: Env = v === undefined ? { AERODJ_TTS_ATTEST_ENABLED: 'true' } : { AERODJ_TTS_ATTEST_ENABLED: 'true', AERODJ_TTS_TESTER_VOICE_ENABLED: v };
      assert.equal(testerVoiceEnabled(env), false);
      assert.equal(testerVoiceOn(env), false);
    });
  }
  test('"true" → on, but only with AERODJ_TTS_ATTEST_ENABLED=true as well', () => {
    assert.equal(testerVoiceEnabled({ AERODJ_TTS_TESTER_VOICE_ENABLED: 'true' }), true);
    assert.equal(testerVoiceOn({ AERODJ_TTS_TESTER_VOICE_ENABLED: 'true' }), false);
    assert.equal(testerVoiceOn({ AERODJ_TTS_TESTER_VOICE_ENABLED: 'true', AERODJ_TTS_ATTEST_ENABLED: 'TRUE' }), false);
    assert.equal(attestEnabled({ AERODJ_TTS_ATTEST_ENABLED: '1' }), false);
    assert.equal(testerVoiceOn({ AERODJ_TTS_TESTER_VOICE_ENABLED: 'true', AERODJ_TTS_ATTEST_ENABLED: 'true' }), true);
  });
});

// ===========================================================================
describe('POST /api/attest/token', () => {
  test('issues a 30-minute token bound to the attested key; one script; counter committed', async () => {
    const h = tokenHarness();
    const inst = newInstall();
    seed(h.redis, 'nonprod', inst);
    const res = await handleToken(tokenRequest(inst), h.deps);
    assert.equal(res.status, 200);
    assert.equal(res.headers.get('cache-control'), 'no-store');
    const body = await jsonOf(res);
    assert.equal(body.expiresIn, 1800);
    const v = verifyInstallToken(body.token, { key: TOKEN_KEY, env: 'nonprod', now: NOW });
    assert.ok(v.ok);
    assert.equal(v.claims.sub, inst.keyId.toString('base64url'));
    assert.equal(h.redis.data.get(counterKey('nonprod', inst.keyId)), '1');
    assert.equal(h.redis.data.get(tokenMintKey('nonprod', inst.keyId, utcDay(NOW))), '1');
    assert.equal(h.calls.length, 2, 'GET record + one mint script');
  });

  test('assertion signed by a different key → 401 assertion, nothing committed', async () => {
    const h = tokenHarness();
    const inst = newInstall();
    seed(h.redis, 'nonprod', inst);
    const res = await handleToken(tokenRequest(inst, { signer: newInstall().key.privateKey }), h.deps);
    assert.equal(res.status, 401);
    assert.equal((await jsonOf(res)).reason, 'assertion');
    assert.equal(h.redis.data.get(counterKey('nonprod', inst.keyId)), undefined);
  });

  test('assertion for another App ID → 401 assertion', async () => {
    const h = tokenHarness();
    const inst = newInstall();
    seed(h.redis, 'nonprod', inst);
    const res = await handleToken(tokenRequest(inst, { appId: 'ZZZZZ99999.com.aerodj.app' }), h.deps);
    assert.equal(res.status, 401);
    assert.deepEqual(h.logs.at(-1), { requestId: 'req-tok', status: 401, reason: 'assertion', detail: 'rp_id' });
  });

  test('revocation list entry → 401 reattest (and no token)', async () => {
    const h = tokenHarness();
    const inst = newInstall();
    seed(h.redis, 'nonprod', inst);
    h.redis.data.set(revokedKey('nonprod', inst.keyId), '1');
    const res = await handleToken(tokenRequest(inst), h.deps);
    assert.equal(res.status, 401);
    const body = await jsonOf(res);
    assert.equal(body.reason, 'reattest');
    assert.equal(body.token, undefined);
  });

  test('owner revoke tool: revokeKey puts the key on the list for 90 days → 401 reattest', async () => {
    const h = tokenHarness();
    const inst = newInstall();
    seed(h.redis, 'nonprod', inst);
    assert.equal((await handleToken(tokenRequest(inst), h.deps)).status, 200);
    await (h.deps.store as RedisAttestStore).revokeKey('nonprod', inst.keyId);
    assert.equal(h.redis.expiresAt.get(revokedKey('nonprod', inst.keyId)), NOW + 90 * 86_400_000);
    const res = await handleToken(tokenRequest(inst), h.deps);
    assert.equal(res.status, 401);
    assert.equal((await jsonOf(res)).reason, 'reattest');
  });

  test('record marked revoked → 401 reattest; record missing → 401 reattest', async () => {
    const h = tokenHarness();
    const a = newInstall();
    seed(h.redis, 'nonprod', a, { revoked: true });
    assert.equal((await jsonOf(await handleToken(tokenRequest(a), h.deps))).reason, 'reattest');
    const b = newInstall();
    assert.equal((await jsonOf(await handleToken(tokenRequest(b), h.deps))).reason, 'reattest');
  });

  test('no tester tier (e.g. App Store category 4, or fallback off) → 403 no_entitlement', async () => {
    const h = tokenHarness();
    const inst = newInstall();
    seed(h.redis, 'nonprod', inst, { tier: undefined });
    const res = await handleToken(tokenRequest(inst), h.deps);
    assert.equal(res.status, 403);
    assert.equal((await jsonOf(res)).reason, 'no_entitlement');
  });

  test('tester record but the assertion says App Store (category 4) → 403 no_entitlement', async () => {
    const h = tokenHarness();
    const inst = newInstall();
    seed(h.redis, 'nonprod', inst);
    const res = await handleToken(tokenRequest(inst, { extensions: cbor(cmap(['apple_validation_category_01', 4])) }), h.deps);
    assert.equal(res.status, 403);
    const ok = await handleToken(tokenRequest(inst, { extensions: cbor(cmap(['apple_validation_category_01', 2])) }), h.deps);
    assert.equal(ok.status, 200);
  });

  test('replayed counter (not above the stored one) → 401 assertion', async () => {
    const h = tokenHarness();
    const inst = newInstall();
    seed(h.redis, 'nonprod', inst);
    assert.equal((await handleToken(tokenRequest(inst, { counter: 5 }), h.deps)).status, 200);
    const res = await handleToken(tokenRequest(inst, { counter: 5 }), h.deps);
    assert.equal(res.status, 401);
    assert.deepEqual(h.logs.at(-1), { requestId: 'req-tok', status: 401, reason: 'assertion', detail: 'counter' });
    assert.equal((await handleToken(tokenRequest(inst, { counter: 6 }), h.deps)).status, 200);
  });

  test('a challenge is single-use → second mint 401 assertion', async () => {
    const h = tokenHarness();
    const inst = newInstall();
    seed(h.redis, 'nonprod', inst);
    const challenge = tokChallenge(inst.keyId);
    assert.equal((await handleToken(tokenRequest(inst, { challenge }), h.deps)).status, 200);
    const res = await handleToken(tokenRequest(inst, { challenge }), h.deps);
    assert.equal(res.status, 401);
    assert.equal(h.logs.at(-1)?.detail, 'reused');
  });

  test('challenge bound to another key, or of another purpose → 401 assertion', async () => {
    const h = tokenHarness();
    const inst = newInstall();
    seed(h.redis, 'nonprod', inst);
    assert.equal((await handleToken(tokenRequest(inst, { challenge: tokChallenge(newInstall().keyId) }), h.deps)).status, 401);
    const ttsChallenge = issueChallenge({ key: CHALLENGE_KEY, purpose: 'tts', keyId: inst.keyId, now: NOW });
    assert.equal((await handleToken(tokenRequest(inst, { challenge: ttsChallenge }), h.deps)).status, 401);
  });

  test('expired (unused) challenge → 400 challenge_expired, nothing minted', async () => {
    const h = tokenHarness();
    const inst = newInstall();
    seed(h.redis, 'nonprod', inst);
    const res = await handleToken(tokenRequest(inst, { challenge: tokChallenge(inst.keyId, NOW - CHALLENGE_TTL_MS - 10_000) }), h.deps);
    assert.equal(res.status, 400);
    assert.equal((await jsonOf(res)).reason, 'challenge_expired');
    assert.equal(h.redis.data.get(counterKey('nonprod', inst.keyId)), undefined);
  });

  test(`mint rate: ${TOKEN_MINT_DAILY_CAP}/day per key, then 429 rate with Retry-After to 00:00 UTC`, async () => {
    const h = tokenHarness();
    const inst = newInstall();
    seed(h.redis, 'nonprod', inst);
    h.redis.data.set(tokenMintKey('nonprod', inst.keyId, utcDay(NOW)), String(TOKEN_MINT_DAILY_CAP));
    const res = await handleToken(tokenRequest(inst), h.deps);
    assert.equal(res.status, 429);
    assert.equal(res.headers.get('retry-after'), String(secondsUntilNextUtcDay(NOW)));
    const body = await jsonOf(res);
    assert.equal(body.reason, 'rate');
    assert.equal(body.retryAfterSeconds, secondsUntilNextUtcDay(NOW));
  });

  for (const [name, over] of [
    ['attest flag unset', { AERODJ_TTS_ATTEST_ENABLED: undefined }],
    ['tester flag unset', { AERODJ_TTS_TESTER_VOICE_ENABLED: undefined }],
    ['tester flag TRUE', { AERODJ_TTS_TESTER_VOICE_ENABLED: 'TRUE' }],
    ['tester flag 1', { AERODJ_TTS_TESTER_VOICE_ENABLED: '1' }],
    ['PAID_STOP', { AERODJ_TTS_PAID_STOP: 'true' }],
  ] as [string, Env][]) {
    test(`${name} → 503 disabled, Retry-After 3600, zero store calls`, async () => {
      const h = tokenHarness(over);
      const inst = newInstall();
      seed(h.redis, 'nonprod', inst);
      const res = await handleToken(tokenRequest(inst), h.deps);
      assert.equal(res.status, 503);
      assert.equal(res.headers.get('retry-after'), '3600');
      assert.equal((await jsonOf(res)).reason, 'disabled');
      assert.equal(h.calls.length, 0);
    });
  }

  test('Authorization or an install token on /api/attest/token → 400 mixed_auth, zero store calls', async () => {
    for (const headers of [{ authorization: `Bearer ${OWNER}` }, { 'x-onairly-install-token': 'v1.x.y' }] as Record<string, string>[]) {
      const h = tokenHarness();
      const inst = newInstall();
      seed(h.redis, 'nonprod', inst);
      const res = await handleToken(tokenRequest(inst, { headers }), h.deps);
      assert.equal(res.status, 400);
      assert.equal((await jsonOf(res)).reason, 'mixed_auth');
      assert.equal(h.calls.length, 0);
    }
  });

  test('token key missing or equal to the challenge key → 500 misconfig', async () => {
    for (const over of [{ AERODJ_TTS_INSTALL_TOKEN_HMAC_KEY: undefined }, { AERODJ_TTS_INSTALL_TOKEN_HMAC_KEY: CHALLENGE_KEY.toString('hex') }]) {
      const h = tokenHarness(over);
      const res = await handleToken(tokenRequest(newInstall()), h.deps);
      assert.equal(res.status, 500);
      assert.equal(res.headers.get('retry-after'), '3600');
    }
  });

  test('no store → 503 store; store down → 503 store', async () => {
    const h = tokenHarness();
    assert.equal((await handleToken(tokenRequest(newInstall()), { ...h.deps, store: null })).status, 503);
    const down = fakeUpstash({ status: 500 });
    const res = await handleToken(tokenRequest(newInstall()), { ...h.deps, store: new RedisAttestStore({ url: 'https://upstash.invalid', token: 't' }, down.fetchImpl) });
    assert.equal(res.status, 503);
    assert.equal((await jsonOf(res)).reason, 'store');
  });

  test('bad requests: GET, extra body field, oversize body, bad headers', async () => {
    const h = tokenHarness();
    const inst = newInstall();
    seed(h.redis, 'nonprod', inst);
    assert.equal((await handleToken(tokenRequest(inst, { method: 'GET' }), h.deps)).status, 405);
    const c = tokChallenge(inst.keyId);
    assert.equal((await handleToken(tokenRequest(inst, { challenge: c, body: JSON.stringify({ challenge: c, tier: 'pro' }) }), h.deps)).status, 400);
    assert.equal((await handleToken(tokenRequest(inst, { challenge: c, body: JSON.stringify({ challenge: c, pad: 'x'.repeat(2000) }) }), h.deps)).status, 413);
    assert.equal((await handleToken(tokenRequest(inst, { keyHeader: 'not base64!' }), h.deps)).status, 400);
    assert.equal((await handleToken(tokenRequest(inst, { assertionHeader: 'AAAA====' }), h.deps)).status, 400);
  });

  test('register → token end to end: a TestFlight attestation (category 2) gets tier tester', async () => {
    const redis = new FakeRedis(() => NOW);
    const up = fakeUpstash({ redis });
    const store = new RedisAttestStore({ url: 'https://upstash.invalid', token: 't' }, up.fetchImpl);
    const regLogs: RegisterLogEntry[] = [];
    const register = async (extensions?: Buffer) => {
      const challenge = issueChallenge({ key: CHALLENGE_KEY, purpose: 'attest', keyId: null, now: NOW });
      const a = makeAttestation(CA, { clientDataHash: attestClientDataHash(challenge), ...(extensions ? { extensions } : {}) });
      const body = JSON.stringify({ keyId: a.keyId.toString('base64'), attestationObject: a.attestationObject.toString('base64'), challenge, installId: crypto.randomUUID() });
      const res = await handleRegister(
        new Request('https://proxy.invalid/api/attest/register', { method: 'POST', body, headers: { 'x-vercel-forwarded-for': '203.0.113.9' } }),
        { env: merge(ATTEST_ENV, {}), store, log: (e) => regLogs.push(e), now: () => NOW, requestId: () => 'r', roots: [CA.root] },
      );
      return { res, inst: { key: a.credKey, keyId: a.keyId, counter: 0 } as Install };
    };
    const tester = await register(cbor(cmap(['apple_validation_category_01', 2])));
    assert.equal(tester.res.status, 204, JSON.stringify(regLogs));
    assert.equal(JSON.parse(redis.data.get(keyRecordKey('nonprod', tester.inst.keyId))!).tier, 'tester');
    const h = tokenHarness({}, redis);
    assert.equal((await handleToken(tokenRequest(tester.inst), h.deps)).status, 200);

    assert.equal(regLogs.at(-1)?.testerReason, 'testflight_category');

    // iOS 26 and older: no category field at all → tester via the fallback (owner 2026-11-03).
    const plain = await register();
    assert.equal(plain.res.status, 204);
    assert.equal(regLogs.at(-1)?.testerReason, 'no_category_fallback');
    assert.equal(JSON.parse(redis.data.get(keyRecordKey('nonprod', plain.inst.keyId))!).tier, 'tester');
    assert.equal((await handleToken(tokenRequest(plain.inst), h.deps)).status, 200);

    // Category present but not TestFlight (4 = App Store): still no tier → 403 no_entitlement.
    const store4 = await register(cbor(cmap(['apple_validation_category_01', 4])));
    assert.equal(store4.res.status, 204);
    assert.equal(regLogs.at(-1)?.testerReason, undefined);
    assert.equal(JSON.parse(redis.data.get(keyRecordKey('nonprod', store4.inst.keyId))!).tier, undefined);
    const refused = await handleToken(tokenRequest(store4.inst), h.deps);
    assert.equal(refused.status, 403);
    assert.equal((await refused.json()).reason, 'no_entitlement');
    // Register logs stay enum-only: no keyId, challenge or install id.
    for (const e of regLogs) assert.deepEqual(Object.keys(e).filter((k) => !['requestId', 'status', 'reason', 'detail', 'testerReason'].includes(k)), []);
  });

  test('register with AERODJ_TTS_TESTER_VOICE_ENABLED off: no category → no tier (fallback is gated)', async () => {
    const redis = new FakeRedis(() => NOW);
    const up = fakeUpstash({ redis });
    const store = new RedisAttestStore({ url: 'https://upstash.invalid', token: 't' }, up.fetchImpl);
    const logs: RegisterLogEntry[] = [];
    const challenge = issueChallenge({ key: CHALLENGE_KEY, purpose: 'attest', keyId: null, now: NOW });
    const a = makeAttestation(CA, { clientDataHash: attestClientDataHash(challenge) });
    const body = JSON.stringify({ keyId: a.keyId.toString('base64'), attestationObject: a.attestationObject.toString('base64'), challenge, installId: crypto.randomUUID() });
    const res = await handleRegister(
      new Request('https://proxy.invalid/api/attest/register', { method: 'POST', body, headers: { 'x-vercel-forwarded-for': '203.0.113.9' } }),
      { env: merge(ATTEST_ENV, { AERODJ_TTS_TESTER_VOICE_ENABLED: undefined }), store, log: (e) => logs.push(e), now: () => NOW, requestId: () => 'r', roots: [CA.root] },
    );
    assert.equal(res.status, 204);
    assert.equal(JSON.parse(redis.data.get(keyRecordKey('nonprod', a.keyId))!).tier, undefined);
    assert.deepEqual(logs, [{ requestId: 'r', status: 204 }]);
  });

  test('testerTier: absent → fallback (flag on only); 2 → testflight; other present values → none', () => {
    const on = merge(ATTEST_ENV, {});
    const off = merge(ATTEST_ENV, { AERODJ_TTS_TESTER_VOICE_ENABLED: 'TRUE' });
    assert.equal(testerTier(undefined, on), 'no_category_fallback');
    assert.equal(testerTier(undefined, off), null);
    assert.equal(testerTier(2, on), 'testflight_category');
    assert.equal(testerTier(2, off), 'testflight_category');
    for (const c of [0, 1, 3, 4, 5, 255]) assert.equal(testerTier(c, on), null, `category ${c}`);
  });
});

// ===========================================================================
// /api/tts with an install token, against the real limiter Lua (fengari) and selectLimiter.
const TTS_ENV: Env = Object.freeze({
  AERODJ_TTS_ATTEST_ENABLED: 'true',
  AERODJ_TTS_TESTER_VOICE_ENABLED: 'true',
  AERODJ_TTS_CHALLENGE_HMAC_KEY: CHALLENGE_KEY.toString('hex'),
  AERODJ_TTS_INSTALL_TOKEN_HMAC_KEY: TOKEN_KEY.toString('hex'),
  AERODJ_TTS_TOKEN_SHA256: OWNER_HASH,
  AERODJ_TTS_VOICE_IDS: VOICE,
  ELEVENLABS_API_KEY: 'test-elevenlabs-key-not-real',
  KV_REST_API_URL: 'https://store.example.upstash.io',
  KV_REST_API_TOKEN: 'test-store-token-not-real',
  VERCEL_ENV: 'production',
});

function pcm(): Response {
  return new Response(Buffer.alloc(2205 * 2), { status: 200, headers: { 'Content-Type': 'audio/pcm' } });
}
function ttsHarness(env: Env = {}, redis = new FakeRedis(() => NOW)) {
  const up = fakeUpstash({ redis });
  const merged = merge(TTS_ENV, env);
  const logs: LogEntry[] = [];
  const upstreamBodies: string[] = [];
  let upstreamStatus = 200;
  const deps: Deps = {
    env: merged,
    fetch: (async (_url: string, init: RequestInit) => {
      upstreamBodies.push(String(init.body));
      return upstreamStatus === 200 ? pcm() : new Response('{"detail":{"status":"quota_exceeded"}}', { status: upstreamStatus });
    }) as typeof fetch,
    limiter: selectLimiter(merged, up.fetchImpl),
    log: (e) => logs.push(e),
    now: () => NOW,
    timeoutMs: 5000,
    requestId: () => 'req-tts',
  };
  return { redis, deps, logs, upstreamBodies, setUpstream: (s: number) => (upstreamStatus = s) };
}
function tokenFor(inst: Install, now = NOW, key = TOKEN_KEY): string {
  return mintInstallToken({ key, keyId: inst.keyId, env: 'production', now }).token;
}
const say = (n: number, ch = 'a') => ch.repeat(n);
function ttsReq(text: string, auth: { installToken?: string; authorization?: string; assertion?: string }, extra: Record<string, unknown> = {}): TtsRequest {
  return { method: 'POST', authorization: auth.authorization, ...auth, body: { upstream: 'elevenlabs', voiceId: VOICE, text, ...extra } };
}
const day = utcDay(NOW);

describe('/api/tts with an install token (#378)', () => {
  test('a valid token renders; owner hash not consulted; spoken chars only charged', async () => {
    const h = ttsHarness();
    const inst = newInstall();
    seed(h.redis, 'production', inst);
    const res = await handleTts(ttsReq('Next up [Live] is a song', { installToken: tokenFor(inst) }, { previousText: 'context that is not charged' }), h.deps);
    assert.equal(res.status, 200);
    // "Next up Live is a song" = 22 spoken chars (brackets stripped, context free).
    assert.equal(h.redis.data.get(testerPoolDayKey(day)), '22');
    assert.equal(h.redis.data.get(`aerodj-tts:chars:global:${day}`), '22');
  });

  test('per-install cap: 1,500 spoken chars per UTC day, then 429 install_daily + Retry-After to midnight', async () => {
    const h = ttsHarness();
    const inst = newInstall();
    seed(h.redis, 'production', inst);
    const t = tokenFor(inst);
    for (let i = 0; i < 3; i++) assert.equal((await handleTts(ttsReq(say(500), { installToken: t }), h.deps)).status, 200);
    const res = await handleTts(ttsReq(say(1), { installToken: t }), h.deps);
    assert.equal(res.status, 429);
    assert.equal(res.headers['Retry-After'], String(secondsUntilNextUtcDay(NOW)));
    assert.deepEqual(JSON.parse(res.body.toString()), { error: 'Too many requests', requestId: 'req-tts', reason: 'install_daily', retryAfterSeconds: secondsUntilNextUtcDay(NOW) });
    assert.equal(h.upstreamBodies.length, 3, 'the refused request never reached ElevenLabs');
    assert.equal(h.redis.data.get(testerPoolDayKey(day)), '1500', 'refusal changed no counter');
  });

  test('tester pool: 6,000/day across installs, then 429 global_daily (log tester_pool); owner share untouched', async () => {
    const h = ttsHarness();
    for (let n = 0; n < 4; n++) {
      const inst = newInstall();
      seed(h.redis, 'production', inst);
      const t = tokenFor(inst);
      for (let i = 0; i < 3; i++) assert.equal((await handleTts(ttsReq(say(500), { installToken: t }), h.deps)).status, 200);
    }
    const fifth = newInstall();
    seed(h.redis, 'production', fifth);
    const res = await handleTts(ttsReq(say(10), { installToken: tokenFor(fifth) }), h.deps);
    assert.equal(res.status, 429);
    assert.equal(JSON.parse(res.body.toString()).reason, 'global_daily');
    assert.equal(h.logs.at(-1)?.reason, 'tester_pool');
    assert.equal(res.headers['Retry-After'], String(secondsUntilNextUtcDay(NOW)));
    // The owner's 3,000 share is still whole after testers drained their pool.
    for (let i = 0; i < 6; i++) assert.equal((await handleTts(ttsReq(say(500), { authorization: `Bearer ${OWNER}` }), h.deps)).status, 200, `owner ${i}`);
    const owner7 = await handleTts(ttsReq(say(1), { authorization: `Bearer ${OWNER}` }), h.deps);
    assert.equal(owner7.status, 429);
    assert.equal(JSON.parse(owner7.body.toString()).reason, 'owner_daily');
    assert.equal(h.redis.data.get(`aerodj-tts:chars:global:${day}`), '9000', 'global 9,000 = pool 6,000 + owner 3,000');
  });

  test('owner spending never eats the tester pool; global ceiling refuses testers first', async () => {
    const h = ttsHarness({ AERODJ_TTS_OWNER_DAILY_CHAR_CAP: '3000' });
    for (let i = 0; i < 6; i++) assert.equal((await handleTts(ttsReq(say(500), { authorization: `Bearer ${OWNER}` }), h.deps)).status, 200);
    assert.equal(h.redis.data.get(testerPoolDayKey(day)), undefined);
    const inst = newInstall();
    seed(h.redis, 'production', inst);
    assert.equal((await handleTts(ttsReq(say(500), { installToken: tokenFor(inst) }), h.deps)).status, 200);
    // Global already near its ceiling (e.g. other deployments): testers get global_daily.
    h.redis.data.set(`aerodj-tts:chars:global:${day}`, '8900');
    const res = await handleTts(ttsReq(say(200), { installToken: tokenFor(inst) }), h.deps);
    assert.equal(res.status, 429);
    assert.equal(JSON.parse(res.body.toString()).reason, 'global_daily');
    assert.equal(h.logs.at(-1)?.reason, 'global_daily');
  });

  test('upstream non-2xx refunds install, pool and global; 2xx keeps the charge', async () => {
    const h = ttsHarness();
    const inst = newInstall();
    seed(h.redis, 'production', inst);
    h.setUpstream(500);
    assert.equal((await handleTts(ttsReq(say(400), { installToken: tokenFor(inst) }), h.deps)).status, 502);
    assert.equal(h.redis.data.get(testerPoolDayKey(day)), '0');
    assert.equal(h.redis.data.get(`aerodj-tts:chars:global:${day}`), '0');
    h.setUpstream(200);
    assert.equal((await handleTts(ttsReq(say(400), { installToken: tokenFor(inst) }), h.deps)).status, 200);
    assert.equal(h.redis.data.get(testerPoolDayKey(day)), '400');
  });

  test('expired, foreign-key or garbage token → 401 token_expired, zero store calls', async () => {
    const h = ttsHarness();
    const inst = newInstall();
    seed(h.redis, 'production', inst);
    for (const t of [tokenFor(inst, NOW - 1800_000), tokenFor(inst, NOW, OTHER_TOKEN_KEY), 'garbage', '']) {
      const before = h.redis.commands.length;
      const res = await handleTts(ttsReq('hello', { installToken: t }), h.deps);
      assert.equal(res.status, 401);
      assert.equal(JSON.parse(res.body.toString()).reason, 'token_expired');
      assert.equal(h.redis.commands.length, before);
    }
  });

  test('revocation bites mid-token: revoked key → 401 reattest, nothing charged', async () => {
    const h = ttsHarness();
    const inst = newInstall();
    seed(h.redis, 'production', inst);
    const t = tokenFor(inst);
    assert.equal((await handleTts(ttsReq('hello', { installToken: t }), h.deps)).status, 200);
    h.redis.data.set(revokedKey('production', inst.keyId), '1');
    const res = await handleTts(ttsReq('hello', { installToken: t }), h.deps);
    assert.equal(res.status, 401);
    assert.equal(JSON.parse(res.body.toString()).reason, 'reattest');
    assert.equal(h.redis.data.get(testerPoolDayKey(day)), '5');
    assert.equal(h.upstreamBodies.length, 1);
  });

  test('key record expired (90 days) → 401 reattest', async () => {
    const h = ttsHarness();
    const inst = newInstall();
    const res = await handleTts(ttsReq('hello', { installToken: tokenFor(inst) }), h.deps);
    assert.equal(res.status, 401);
    assert.equal(JSON.parse(res.body.toString()).reason, 'reattest');
  });

  for (const [name, over] of [
    ['tester flag unset', { AERODJ_TTS_TESTER_VOICE_ENABLED: undefined }],
    ['tester flag TRUE', { AERODJ_TTS_TESTER_VOICE_ENABLED: 'TRUE' }],
    ['tester flag 1', { AERODJ_TTS_TESTER_VOICE_ENABLED: '1' }],
    ['attest flag unset', { AERODJ_TTS_ATTEST_ENABLED: undefined }],
  ] as [string, Env][]) {
    test(`install token with ${name} → 503 disabled, no store or upstream call; owner still works`, async () => {
      const h = ttsHarness(over);
      const inst = newInstall();
      seed(h.redis, 'production', inst);
      const before = h.redis.commands.length;
      const res = await handleTts(ttsReq('hello', { installToken: tokenFor(inst) }), h.deps);
      assert.equal(res.status, 503);
      assert.equal(res.headers['Retry-After'], '3600');
      assert.equal(JSON.parse(res.body.toString()).reason, 'disabled');
      assert.equal(h.redis.commands.length, before);
      assert.equal(h.upstreamBodies.length, 0);
      assert.equal((await handleTts(ttsReq('hello', { authorization: `Bearer ${OWNER}` }), h.deps)).status, 200);
    });
  }

  test('mixed auth: bearer + install token, or any assertion header → 400 mixed_auth', async () => {
    const h = ttsHarness();
    const inst = newInstall();
    seed(h.redis, 'production', inst);
    for (const auth of [
      { authorization: `Bearer ${OWNER}`, installToken: tokenFor(inst) },
      { authorization: `Bearer ${OWNER}`, assertion: 'AAAA' },
      { installToken: tokenFor(inst), assertion: 'AAAA' },
    ]) {
      const res = await handleTts(ttsReq('hello', auth), h.deps);
      assert.equal(res.status, 400);
      assert.equal(JSON.parse(res.body.toString()).reason, 'mixed_auth');
      assert.equal(res.headers['Retry-After'], undefined);
    }
    assert.equal(h.upstreamBodies.length, 0);
  });

  test('install path without a token key → 500 misconfig; without the owner hash it still works', async () => {
    const inst = newInstall();
    const a = ttsHarness({ AERODJ_TTS_INSTALL_TOKEN_HMAC_KEY: undefined });
    seed(a.redis, 'production', inst);
    assert.equal((await handleTts(ttsReq('hello', { installToken: tokenFor(inst) }), a.deps)).status, 500);
    const b = ttsHarness({ AERODJ_TTS_TOKEN_SHA256: undefined });
    seed(b.redis, 'production', inst);
    assert.equal((await handleTts(ttsReq('hello', { installToken: tokenFor(inst) }), b.deps)).status, 200);
  });

  test('install path needs the durable store: non-durable limiter → 500 no_store (key set)', async () => {
    const h = ttsHarness();
    const inst = newInstall();
    const res = await handleTts(ttsReq('hello', { installToken: tokenFor(inst) }), { ...h.deps, limiter: null, env: merge(h.deps.env, { KV_REST_API_URL: undefined, KV_REST_API_TOKEN: undefined }) });
    assert.equal(res.status, 500);
  });

  test('logs carry no token, key, keyId / install id, challenge or script text', async () => {
    const h = ttsHarness();
    const inst = newInstall();
    seed(h.redis, 'production', inst);
    const t = tokenFor(inst);
    const SCRIPT = 'Secret script words for the log check';
    await handleTts(ttsReq(SCRIPT, { installToken: t }), h.deps);
    await handleTts(ttsReq(SCRIPT, { installToken: t, authorization: `Bearer ${OWNER}` }), h.deps);
    const stale = tokenFor(inst, NOW - 3600_000);
    await handleTts(ttsReq(SCRIPT, { installToken: stale }), h.deps);
    await handleTts(ttsReq(SCRIPT, { installToken: 'v1.not-a-real-token.x' }), h.deps);
    const th = tokenHarness();
    const tinst = newInstall();
    seed(th.redis, 'nonprod', tinst);
    const challenge = tokChallenge(tinst.keyId);
    const minted = await jsonOf(await handleToken(tokenRequest(tinst, { challenge }), th.deps));
    await handleToken(tokenRequest(tinst, { challenge }), th.deps);
    const all = JSON.stringify([...h.logs, ...th.logs]);
    const forbidden = [
      t, stale, 'not-a-real-token', String(minted.token), OWNER, TOKEN_KEY.toString('hex'), challenge, SCRIPT, 'Secret',
      ...[inst, tinst].flatMap((i) => [i.keyId.toString('base64'), i.keyId.toString('base64url'), i.keyId.toString('hex')]),
    ];
    for (const f of forbidden) assert.ok(!all.includes(f), 'log leaked a forbidden value');
    for (const e of h.logs) assert.deepEqual(Object.keys(e).filter((k) => !['requestId', 'status', 'chars', 'reason', 'upstreamStatus', 'upstreamCode'].includes(k)), []);
    for (const e of th.logs) assert.deepEqual(Object.keys(e).filter((k) => !['requestId', 'status', 'reason', 'detail'].includes(k)), []);
  });
});

// ===========================================================================
describe('limiterOptions: tester pool + owner share (#378)', () => {
  test('tester voice on: global 9,000, pool 6,000, owner 3,000, install 1,500', () => {
    const o = limiterOptions({ VERCEL_ENV: 'production', AERODJ_TTS_ATTEST_ENABLED: 'true', AERODJ_TTS_TESTER_VOICE_ENABLED: 'true' });
    assert.equal(o.dailyCharCap, 9000);
    assert.equal(o.testerPoolDailyCharCap, 6000);
    assert.equal(o.ownerDailyCharCap, 3000);
    assert.equal(o.installDailyCharCap, 1500);
    assert.equal(effectiveTesterPoolCap(o), 6000);
  });
  test('tester voice off (today): owner cap stays the global ceiling, no pool', () => {
    for (const env of [{ VERCEL_ENV: 'production' }, { VERCEL_ENV: 'production', AERODJ_TTS_TESTER_VOICE_ENABLED: 'TRUE', AERODJ_TTS_ATTEST_ENABLED: 'true' }]) {
      const o = limiterOptions(env);
      assert.equal(o.ownerDailyCharCap, 9000);
      assert.equal(o.testerPoolDailyCharCap, undefined);
      assert.equal(effectiveTesterPoolCap(o), null);
    }
  });
  test('pool is clamped to global − owner share; nothing left → null (500 misconfig)', () => {
    assert.equal(effectiveTesterPoolCap({ dailyCharCap: 9000, ownerDailyCharCap: 5000, testerPoolDailyCharCap: 6000 }), 4000);
    assert.equal(effectiveTesterPoolCap({ dailyCharCap: 9000, testerPoolDailyCharCap: 6000 }), null);
    assert.equal(effectiveTesterPoolCap({ dailyCharCap: 9000, ownerDailyCharCap: 9000, testerPoolDailyCharCap: 6000 }), null);
  });
  test('owner pushed to the global ceiling by env → tester requests 500 misconfig, owner fine', async () => {
    const h = ttsHarness({ AERODJ_TTS_OWNER_DAILY_CHAR_CAP: '9000' });
    const inst = newInstall();
    seed(h.redis, 'production', inst);
    assert.equal((await handleTts(ttsReq('hello', { installToken: tokenFor(inst) }), h.deps)).status, 500);
    assert.equal((await handleTts(ttsReq('hello', { authorization: `Bearer ${OWNER}` }), h.deps)).status, 200);
    assert.ok(h.deps.limiter instanceof RedisUsageLimiter);
  });
});
