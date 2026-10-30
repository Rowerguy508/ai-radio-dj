/**
 * Family Sharing fails closed until the owner decides (Orion, 2026-10-29; Sentinel's N3 on
 * #264). Only PURCHASED counts as Pro; FAMILY_SHARED only with
 * AERODJ_TTS_PRO_ALLOW_FAMILY_SHARED exactly `true`; missing/unknown ownership never.
 * Every transaction here is REAL: signed by the fake CA and run through the real verifier
 * (test/helpers/verified-tx.ts), then the real handler with the real Lua (test/redis-lua.ts).
 */
import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { handleTts, type Deps, type Env, type TtsRequest } from '../src/handler.js';
import { RedisUsageLimiter, proDayKeys } from '../src/limiter.js';
import {
  isVerifiedProSubject,
  ownershipCountsAsPro,
  proAllowFamilyShared,
  proSubjectFromVerified,
  type ProSubject,
} from '../src/pro-allowance.js';
import { FakeRedis, fakeUpstash } from './redis-lua.js';
import { verifiedTransaction, verifyFixture } from './helpers/verified-tx.js';

const TOKEN = 'test-owner-token-not-a-real-secret';
const TOKEN_HASH = crypto.createHash('sha256').update(TOKEN).digest('hex');
const VOICE = 'voiceAllowed123';
const STORE = { url: 'https://store.example.upstash.io', token: 'test-store-token-not-real' };
const NOON = Date.UTC(2026, 9, 29, 12);
const DAY = '2026-10-29';
const OTID = '2000000555555555';
const TEXT = 'Next up, a little something for the drive home.';
const BASE: Env = {
  AERODJ_TTS_TOKEN_SHA256: TOKEN_HASH,
  AERODJ_TTS_VOICE_IDS: VOICE,
  ELEVENLABS_API_KEY: 'test-elevenlabs-key-not-real',
  VERCEL_ENV: 'production',
};
const sha = (s: string) => crypto.createHash('sha256').update(s, 'utf8').digest('hex');
const RENDERS = proDayKeys(`pro:production:${sha(OTID)}`, DAY)[2];
const OWNER_KEY = `aerodj-tts:chars:owner:${DAY}`;
const BAD_FLAGS = ['', 'TRUE', 'True', 'FALSE', '1', '0', 'yes', 'on', ' true', 'true ', 'false\n', '"true"'];

const pcm = () => new Response(Buffer.alloc(22_050 * 2, 1), { status: 200, headers: { 'Content-Type': 'audio/pcm' } });

function harness(env: Env = {}) {
  const redis = new FakeRedis(() => NOON);
  const up = fakeUpstash({ redis });
  const d: Deps = {
    env: { ...BASE, ...env },
    fetch: (async () => pcm()) as unknown as typeof fetch,
    limiter: new RedisUsageLimiter(STORE, { dailyCharCap: 10_000_000, requestsPerMinute: 600 }, up.fetchImpl),
    log: () => {},
    now: () => NOON,
    timeoutMs: 50,
    requestId: () => 'req-1',
    logRefundLost: () => {},
  };
  return { d, redis, calls: up.calls };
}

const req = (pro: ProSubject | undefined): TtsRequest => ({
  method: 'POST',
  authorization: `Bearer ${TOKEN}`,
  body: { upstream: 'elevenlabs', voiceId: VOICE, text: TEXT, format: 'text' },
  verifiedPro: pro,
});

/**
 * What PR 6's caller does: read the one setting, verify with it, mint with it. Returns the
 * Pro subject, `not_pro` (no ProSubject: the request goes on without `verifiedPro`), or
 * `misconfig` (bad flag).
 */
async function proFor(ownership: string | null, env: Env): Promise<ProSubject | 'not_pro' | 'misconfig'> {
  const allowFamilyShared = proAllowFamilyShared(env);
  if (allowFamilyShared === null) return 'misconfig';
  const result = await verifyFixture(OTID, { ownership, allowFamilyShared });
  if (!result.ok) {
    assert.equal(result.reason, 'ownership');
    return 'not_pro';
  }
  return proSubjectFromVerified(result.transaction, { allowFamilyShared });
}

/** Runs one request the way the caller would (Pro subject or none) and reports what was counted. */
async function serve(subject: ProSubject | 'not_pro', env: Env) {
  const h = harness(env);
  const r = await handleTts(req(subject === 'not_pro' ? undefined : subject), h.d);
  return { status: r.status, proRenders: h.redis.get(RENDERS) ?? 0, ownerChars: h.redis.get(OWNER_KEY) ?? 0 };
}

describe('Family Sharing: the setting AERODJ_TTS_PRO_ALLOW_FAMILY_SHARED (strict)', () => {
  test('unset or exactly "false" is off; exactly "true" is on', () => {
    assert.equal(proAllowFamilyShared({}), false);
    assert.equal(proAllowFamilyShared({ AERODJ_TTS_PRO_ALLOW_FAMILY_SHARED: undefined }), false);
    assert.equal(proAllowFamilyShared({ AERODJ_TTS_PRO_ALLOW_FAMILY_SHARED: 'false' }), false);
    assert.equal(proAllowFamilyShared({ AERODJ_TTS_PRO_ALLOW_FAMILY_SHARED: 'true' }), true);
  });

  for (const v of BAD_FLAGS) {
    test(`bad value ${JSON.stringify(v)} is misconfig (null), never on or off`, () => {
      assert.equal(proAllowFamilyShared({ AERODJ_TTS_PRO_ALLOW_FAMILY_SHARED: v }), null);
    });
  }

  test('ownershipCountsAsPro: PURCHASED always; FAMILY_SHARED only when allowed; anything else never', () => {
    for (const allowFamilyShared of [false, true]) {
      assert.equal(ownershipCountsAsPro('PURCHASED', { allowFamilyShared }), true);
      for (const o of [undefined, null, '', 'ASSIGNED', 'purchased', 'family_shared', 'PURCHASED ', 1]) {
        assert.equal(ownershipCountsAsPro(o, { allowFamilyShared }), false, `${String(o)} ${allowFamilyShared}`);
      }
    }
    assert.equal(ownershipCountsAsPro('FAMILY_SHARED', { allowFamilyShared: false }), false);
    assert.equal(ownershipCountsAsPro('FAMILY_SHARED', { allowFamilyShared: true }), true);
  });
});

describe('Family Sharing: fails closed end to end (real signed transactions)', () => {
  test('PURCHASED is Pro (flag unset, "false" or "true"): the Pro render counter moves, the owner bucket does not', async () => {
    for (const env of [{}, { AERODJ_TTS_PRO_ALLOW_FAMILY_SHARED: 'false' }, { AERODJ_TTS_PRO_ALLOW_FAMILY_SHARED: 'true' }]) {
      const pro = await proFor('PURCHASED', env);
      assert.ok(isVerifiedProSubject(pro), JSON.stringify(env));
      assert.equal((pro as ProSubject).hash, sha(OTID));
      assert.deepEqual(await serve(pro as ProSubject, env), { status: 200, proRenders: 1, ownerChars: 0 });
    }
  });

  test('FAMILY_SHARED is NOT Pro by default (unset or "false"): verifier refuses `ownership`, no ProSubject, the non-Pro path serves it and no Pro counter moves', async () => {
    for (const env of [{}, { AERODJ_TTS_PRO_ALLOW_FAMILY_SHARED: 'false' }]) {
      assert.equal(await proFor('FAMILY_SHARED', env), 'not_pro', JSON.stringify(env));
      // The same request as any request with no verified purchase (today: the owner path).
      assert.deepEqual(await serve('not_pro', env), { status: 200, proRenders: 0, ownerChars: TEXT.length });
    }
  });

  test('FAMILY_SHARED with the flag "true" is Pro', async () => {
    const env = { AERODJ_TTS_PRO_ALLOW_FAMILY_SHARED: 'true' };
    const pro = await proFor('FAMILY_SHARED', env);
    assert.ok(isVerifiedProSubject(pro));
    assert.deepEqual(await serve(pro as ProSubject, env), { status: 200, proRenders: 1, ownerChars: 0 });
  });

  test('missing or unknown ownership is NOT Pro, even with the flag "true"', async () => {
    for (const env of [{}, { AERODJ_TTS_PRO_ALLOW_FAMILY_SHARED: 'true' }]) {
      for (const o of [null, 'ASSIGNED', 'purchased', 'family_shared', '']) {
        assert.equal(await proFor(o, env), 'not_pro', `${String(o)} ${JSON.stringify(env)}`);
      }
    }
  });

  test('minting refuses FAMILY_SHARED unless the policy allows it (default off), even from a verified transaction', async () => {
    const tx = await verifiedTransaction(OTID, { ownership: 'FAMILY_SHARED', allowFamilyShared: true });
    assert.equal(tx.inAppOwnershipType, 'FAMILY_SHARED');
    assert.throws(() => proSubjectFromVerified(tx), /not pro ownership/);
    assert.throws(() => proSubjectFromVerified(tx, { allowFamilyShared: false }), /not pro ownership/);
    assert.ok(isVerifiedProSubject(proSubjectFromVerified(tx, { allowFamilyShared: true })));
    const purchased = await verifiedTransaction(OTID);
    assert.ok(isVerifiedProSubject(proSubjectFromVerified(purchased)));
  });

  for (const v of BAD_FLAGS) {
    test(`bad flag ${JSON.stringify(v)}: the caller gets misconfig, and a Pro request is 500 misconfig before any store or upstream call; the owner path is unaffected`, async () => {
      const env = { AERODJ_TTS_PRO_ALLOW_FAMILY_SHARED: v };
      assert.equal(await proFor('PURCHASED', env), 'misconfig');
      const pro = proSubjectFromVerified(await verifiedTransaction(OTID));
      const h = harness(env);
      const r = await handleTts(req(pro), h.d);
      assert.equal(r.status, 500);
      assert.equal(JSON.parse(r.body.toString('utf8')).reason, 'misconfig');
      assert.equal(h.calls.length, 0);
      assert.equal((await handleTts(req(undefined), h.d)).status, 200);
    });
  }
});
