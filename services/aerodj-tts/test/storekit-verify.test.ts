import assert from 'node:assert/strict';
import crypto, { X509Certificate } from 'node:crypto';
import { describe, it } from 'node:test';
import { APPLE_ROOT_CA_G3_PEM } from '../src/apple-root-ca-g3.js';
import { STOREKIT_CONFIG, parseStoreKitConfig } from '../src/storekit-config.js';
import {
  appleRoots,
  deploymentFromEnv,
  environmentAllowed,
  verifySignedTransaction,
  type LastSeenStore,
  type StoreKitConfig,
  type StoreKitVerifierOptions,
} from '../src/storekit-verify.js';
import { LEAF_OID, INTERMEDIATE_OID, makeCert, makeChain, signJws, type FakeChain } from './helpers/fake-ca.js';

const NOW = Date.parse('2026-10-29T22:00:00Z');
const DAY = 86_400_000;
const PINNED_G3_SHA256 =
  '63:34:3A:BF:B8:9A:6A:03:EB:B5:7E:9B:3F:5F:A7:BE:7C:4F:5C:75:6F:30:17:B3:A8:C4:88:C3:65:3E:91:79';

const chain = makeChain('Fake');
const x5c = (c: FakeChain) => [c.leafDer, c.intermediateDer, c.rootDer];
const config: StoreKitConfig = { ...STOREKIT_CONFIG };

const emptyStore: LastSeenStore = { lastSignedDate: async () => undefined };
const INSTALL_A = 'install-key-A';
const INSTALL_B = 'install-key-B';
const OTID = '2000000000000001';

/** A last-seen store keyed per (install, originalTransactionId), like PR 6's. */
function mapStore(entries: Array<[install: string, otid: string, ms: number]>): LastSeenStore {
  const m = new Map(entries.map(([i, o, ms]) => [`${i}\u0000${o}`, ms]));
  return { lastSignedDate: async (install, otid) => m.get(`${install}\u0000${otid}`) };
}

// Tests run as non-production: an injected (fake) root is refused on production (V2).
function opts(over: Partial<StoreKitVerifierOptions> = {}): StoreKitVerifierOptions {
  return {
    config,
    deployment: 'nonproduction',
    now: () => NOW,
    lastSeen: emptyStore,
    install: INSTALL_A,
    roots: [new X509Certificate(chain.rootDer)],
    allowFamilyShared: false,
    ...over,
  };
}

function payload(over: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    transactionId: '2000000000000002',
    originalTransactionId: '2000000000000001',
    bundleId: 'com.aerodj.app',
    productId: 'com.aerodj.app.pro.monthly',
    type: 'Auto-Renewable Subscription',
    environment: 'Production',
    inAppOwnershipType: 'PURCHASED',
    purchaseDate: NOW - DAY,
    expiresDate: NOW + 29 * DAY,
    signedDate: NOW - 1000,
    appAccountToken: '7d3f2b1e-4c5a-4b6d-9e8f-0a1b2c3d4e5f',
    ...over,
  };
}

const good = (over: Record<string, unknown> = {}) => signJws(payload(over), x5c(chain), chain.leafKey);

async function reason(jws: unknown, o: Partial<StoreKitVerifierOptions> = {}): Promise<string> {
  const result = await verifySignedTransaction(jws, opts(o));
  return result.ok ? 'ok' : result.reason;
}

describe('Apple root pin and config', () => {
  it('pins the real Apple Root CA - G3 by SHA-256 fingerprint and subject', () => {
    const root = new X509Certificate(APPLE_ROOT_CA_G3_PEM);
    assert.equal(root.fingerprint256, PINNED_G3_SHA256);
    assert.match(root.subject, /CN=Apple Root CA - G3/);
    assert.equal(root.ca, true);
    assert.equal(appleRoots()[0].fingerprint256, PINNED_G3_SHA256);
  });

  it('defaults to the Apple root, so a fake-CA transaction fails without an injected root', async () => {
    for (const deployment of ['production', 'nonproduction'] as const) {
      const result = await verifySignedTransaction(good(), { ...opts({ deployment }), roots: undefined });
      assert.deepEqual(result, { ok: false, reason: 'chain' }, deployment);
    }
  });

  it('V2: refuses an injected root on production, even the one that would verify', async () => {
    assert.equal(await reason(good(), { deployment: 'production' }), 'config');
    assert.equal(await reason(good(), { deployment: 'production', roots: [] }), 'config');
    assert.equal(await reason(good(), { deployment: 'nonproduction' }), 'ok');
  });

  it('V2: deployment from VERCEL_ENV fails closed (unknown or unset -> production)', () => {
    assert.equal(deploymentFromEnv({ VERCEL_ENV: 'preview' }), 'nonproduction');
    assert.equal(deploymentFromEnv({ VERCEL_ENV: 'development' }), 'nonproduction');
    for (const v of ['production', undefined, '', 'Preview', 'preview ', 'staging']) {
      assert.equal(deploymentFromEnv({ VERCEL_ENV: v }), 'production', String(v));
    }
  });

  it('refuses a missing install identity', async () => {
    assert.equal(await reason(good(), { install: '' }), 'config');
  });

  it('ships the interim policy defaults and placeholder product IDs', () => {
    assert.equal(STOREKIT_CONFIG.bundleId, 'com.aerodj.app');
    assert.deepEqual([...STOREKIT_CONFIG.proProductIds], ['com.aerodj.app.pro.monthly', 'com.aerodj.app.pro.yearly']);
    assert.equal(STOREKIT_CONFIG.installsPerPurchase, 5);
    assert.equal(STOREKIT_CONFIG.allowSandboxInProduction, false);
    assert.equal(STOREKIT_CONFIG.honorGracePeriod, false);
    // Family Sharing is no longer a config value: its single setting is the env flag
    // AERODJ_TTS_PRO_ALLOW_FAMILY_SHARED (default off; test/family-sharing.test.ts).
    assert.equal(Object.prototype.hasOwnProperty.call(STOREKIT_CONFIG, 'allowFamilyShared'), false);
  });

  it('rejects an invalid config', () => {
    assert.throws(() => parseStoreKitConfig({ ...STOREKIT_CONFIG, proProductIds: [] }));
    assert.throws(() => parseStoreKitConfig({ ...STOREKIT_CONFIG, allowFamilyShared: 'false' }));
    // A leftover config key would be a second, ignored knob: refused whatever its value.
    assert.throws(() => parseStoreKitConfig({ ...STOREKIT_CONFIG, allowFamilyShared: false }));
    assert.throws(() => parseStoreKitConfig({ ...STOREKIT_CONFIG, allowFamilyShared: true }));
    assert.doesNotThrow(() => parseStoreKitConfig({ ...STOREKIT_CONFIG }));
    assert.throws(() => parseStoreKitConfig({ ...STOREKIT_CONFIG, installsPerPurchase: 0 }));
    assert.throws(() => parseStoreKitConfig({ ...STOREKIT_CONFIG, installsPerPurchase: 11 }));
    assert.throws(() => parseStoreKitConfig({ ...STOREKIT_CONFIG, installsPerPurchase: 2.5 }));
    const { allowSandboxInProduction: _omit, ...missing } = STOREKIT_CONFIG;
    assert.throws(() => parseStoreKitConfig(missing));
  });
});

describe('verifySignedTransaction: accepts', () => {
  it('a valid Production transaction from the pinned chain', async () => {
    const result = await verifySignedTransaction(good(), opts());
    assert.equal(result.ok, true);
    if (result.ok) {
      assert.equal(result.transaction.originalTransactionId, '2000000000000001');
      assert.equal(result.transaction.productId, 'com.aerodj.app.pro.monthly');
      assert.equal(result.transaction.environment, 'Production');
      assert.equal(result.transaction.appAccountToken, '7d3f2b1e-4c5a-4b6d-9e8f-0a1b2c3d4e5f');
    }
  });

  it('the yearly product, and a transaction without appAccountToken', async () => {
    assert.equal(await reason(good({ productId: 'com.aerodj.app.pro.yearly', appAccountToken: undefined })), 'ok');
  });

  it('Sandbox on a non-production deployment', async () => {
    assert.equal(await reason(good({ environment: 'Sandbox' })), 'ok');
  });

  it('Sandbox on production only when the config allows it (policy function used by the verifier)', () => {
    assert.equal(environmentAllowed('Sandbox', 'production', { ...config, allowSandboxInProduction: true }), true);
    assert.equal(environmentAllowed('Production', 'production', config), true);
  });

  it('FAMILY_SHARED only when the Family Sharing setting allows it', async () => {
    assert.equal(
      await reason(good({ inAppOwnershipType: 'FAMILY_SHARED' }), { allowFamilyShared: true }),
      'ok',
    );
  });

  it('a newer transaction than the last one this install presented', async () => {
    const result = await verifySignedTransaction(good(), opts({ lastSeen: mapStore([[INSTALL_A, OTID, NOW - 5000]]) }));
    assert.equal(result.ok && result.freshness, 'new');
  });

  it('V3: a second install presenting the same current transaction', async () => {
    const lastSeen = mapStore([[INSTALL_A, OTID, NOW - 1000]]);
    const result = await verifySignedTransaction(good(), opts({ lastSeen, install: INSTALL_B }));
    assert.equal(result.ok && result.freshness, 'new');
  });

  it('V3: the same install re-posting the same signedDate is an idempotent re-post', async () => {
    const lastSeen = mapStore([[INSTALL_A, OTID, NOW - 1000]]);
    const result = await verifySignedTransaction(good(), opts({ lastSeen }));
    assert.equal(result.ok && result.freshness, 'repost');
  });

  it('V3: the last-seen store is asked for this install and this purchase', async () => {
    const calls: string[][] = [];
    const lastSeen: LastSeenStore = { lastSignedDate: async (i, o) => (calls.push([i, o]), undefined) };
    assert.equal(await reason(good(), { lastSeen, install: INSTALL_B }), 'ok');
    assert.deepEqual(calls, [[INSTALL_B, OTID]]);
  });
});

describe('verifySignedTransaction: must fail (Sentinel criterion 7)', () => {
  it('forged signature (payload swapped after signing)', async () => {
    const [h, , s] = good().split('.');
    const forged = Buffer.from(JSON.stringify(payload({ productId: 'com.aerodj.app.pro.yearly' }))).toString('base64url');
    assert.equal(await reason(`${h}.${forged}.${s}`), 'signature');
  });

  it('forged signature (signed by a key that is not the leaf)', async () => {
    const other = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' }).privateKey;
    assert.equal(await reason(signJws(payload(), x5c(chain), other)), 'signature');
  });

  it('wrong root (a self-made chain not pinned)', async () => {
    const rogue = makeChain('Rogue');
    assert.equal(await reason(signJws(payload(), x5c(rogue), rogue.leafKey)), 'chain');
  });

  it('wrong root (pinned root presented, but intermediate signed by another CA)', async () => {
    const rogue = makeChain('Rogue');
    const mixed = [rogue.leafDer, rogue.intermediateDer, chain.rootDer];
    assert.equal(await reason(signJws(payload(), mixed, rogue.leafKey)), 'chain');
  });

  it('wrong bundle', async () => {
    assert.equal(await reason(good({ bundleId: 'com.example.other' })), 'bundle');
  });

  it('wrong bundle: prefix and extension lookalikes are refused (exact match only; Fry N1 on #243)', async () => {
    // Longer IDs that start with the real one (kills an `startsWith` mutant) ...
    for (const bundleId of ['com.aerodj.app.evil', 'com.aerodj.app.share', 'com.aerodj.app.phonon', 'com.aerodj.app.pro', 'com.aerodj.app ']) {
      assert.equal(await reason(good({ bundleId })), 'bundle', bundleId);
    }
    // ... and shorter IDs the real one starts with (kills a reversed-prefix mutant).
    for (const bundleId of ['com.aerodj.ap', 'com.aerodj', '']) {
      assert.equal(await reason(good({ bundleId })), 'bundle', JSON.stringify(bundleId));
    }
    assert.equal(await reason(good({ bundleId: 'COM.AERODJ.APP' })), 'bundle');
  });

  it('product not allowlisted', async () => {
    assert.equal(await reason(good({ productId: 'com.aerodj.app.pro.lifetime' })), 'product');
  });

  it('non-subscription type', async () => {
    assert.equal(await reason(good({ type: 'Non-Consumable' })), 'type');
  });

  it('expired', async () => {
    assert.equal(await reason(good({ expiresDate: NOW - 1 })), 'expired');
    assert.equal(await reason(good({ expiresDate: NOW })), 'expired');
  });

  it('revoked (refunded or removed from Family Sharing)', async () => {
    assert.equal(await reason(good({ revocationDate: NOW - DAY, revocationReason: 0 })), 'revoked');
  });

  it('revoked: any present non-null revocationDate is refused, including 0 (Fry N2 on #243)', async () => {
    // 0 is falsy (kills a truthiness mutant).
    for (const revocationDate of [0, NOW + DAY, '', false]) {
      assert.equal(await reason(good({ revocationDate })), 'revoked', JSON.stringify(revocationDate));
    }
  });

  it('revocation_null: a null revocationDate is refused with its own reason (Sentinel on PR 3)', async () => {
    const result = await verifySignedTransaction(good({ revocationDate: null }), opts());
    assert.equal(result.ok, false);
    assert.equal(await reason(good({ revocationDate: null })), 'revocation_null');
  });

  it('revoked: only an absent revocationDate passes (control for the cases above)', async () => {
    const result = await verifySignedTransaction(good(), opts());
    assert.equal(result.ok, true);
    assert.equal('revocationDate' in payload(), false);
  });

  it('sandbox in prod (config default)', () => {
    assert.equal(environmentAllowed('Sandbox', 'production', config), false);
    assert.equal(environmentAllowed('Sandbox', 'nonproduction', config), true);
    assert.equal(environmentAllowed('Xcode', 'nonproduction', config), false);
    assert.equal(environmentAllowed(undefined, 'nonproduction', config), false);
  });

  it('unknown environment (e.g. Xcode) everywhere', async () => {
    assert.equal(await reason(good({ environment: 'Xcode' }), { deployment: 'nonproduction' }), 'environment');
  });

  it('FAMILY_SHARED or ASSIGNED while Family Sharing is off', async () => {
    assert.equal(await reason(good({ inAppOwnershipType: 'FAMILY_SHARED' })), 'ownership');
    assert.equal(await reason(good({ inAppOwnershipType: 'ASSIGNED' }), { allowFamilyShared: true }), 'ownership');
  });

  it('V3: an older signedDate than this install already presented for this purchase', async () => {
    assert.equal(await reason(good(), { lastSeen: mapStore([[INSTALL_A, OTID, NOW]]) }), 'stale');
    assert.equal(await reason(good(), { lastSeen: mapStore([[INSTALL_A, OTID, NOW - 999]]) }), 'stale');
    // Another install's newer entry for the same purchase does not make this one stale.
    assert.equal(await reason(good(), { lastSeen: mapStore([[INSTALL_B, OTID, NOW]]) }), 'ok');
  });

  it('malformed JWS', async () => {
    for (const bad of [undefined, 42, '', 'a.b', 'a.b.c.d', 'a.b!.c', 'x'.repeat(16_385)]) {
      assert.equal(await reason(bad), 'malformed', String(bad).slice(0, 20));
    }
    const [h, , s] = good().split('.');
    assert.equal(await reason(`${h}.${Buffer.from('not json').toString('base64url')}.${s}`), 'malformed');
    assert.equal(await reason(good({ signedDate: 'yesterday' })), 'malformed');
    assert.equal(await reason(good({ appAccountToken: 'user@example.com' })), 'malformed');
  });

  it('JWS header: alg none, HS256, RS256, ES384 and missing alg are refused', async () => {
    for (const alg of ['none', 'HS256', 'RS256', 'ES384', 'es256', undefined]) {
      assert.equal(await reason(signJws(payload(), x5c(chain), chain.leafKey, { alg })), 'header', String(alg));
    }
  });

  it('JWS header: any crit is refused', async () => {
    for (const crit of [['b64'], [], 'exp']) {
      assert.equal(await reason(signJws(payload(), x5c(chain), chain.leafKey, { crit })), 'header', JSON.stringify(crit));
    }
  });

  it('JWS header: x5c missing, not an array, or not exactly three certs', async () => {
    assert.equal(await reason(signJws(payload(), x5c(chain), chain.leafKey, { x5c: undefined })), 'header');
    assert.equal(await reason(signJws(payload(), x5c(chain), chain.leafKey, { x5c: 'abc' })), 'header');
    assert.equal(await reason(signJws(payload(), [chain.leafDer, chain.rootDer], chain.leafKey)), 'header');
    const four = [chain.leafDer, chain.intermediateDer, chain.intermediateDer, chain.rootDer];
    assert.equal(await reason(signJws(payload(), four, chain.leafKey)), 'header');
  });

  it('JWS header: jwk/jku/kid/x5u are ignored (an attacker key there does not verify)', async () => {
    const rogue = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
    const jwk = rogue.publicKey.export({ format: 'jwk' });
    const extra = { jwk, jku: 'https://attacker.example/keys', kid: 'k1', x5u: 'https://attacker.example/c' };
    assert.equal(await reason(signJws(payload(), x5c(chain), rogue.privateKey, extra)), 'signature');
    assert.equal(await reason(signJws(payload(), x5c(chain), chain.leafKey, extra)), 'ok');
  });

  it('lookalike root (same subject, different key and bytes)', async () => {
    const lookalike = makeChain('Fake');
    assert.equal(await reason(signJws(payload(), x5c(lookalike), lookalike.leafKey)), 'chain');
  });

  it('lookalike intermediate (issuer name matches the pinned root) under the real pinned root', async () => {
    const lookalike = makeChain('Fake');
    const mixed = [lookalike.leafDer, lookalike.intermediateDer, chain.rootDer];
    assert.equal(await reason(signJws(payload(), mixed, lookalike.leafKey)), 'chain');
  });

  it('genuine leaf and intermediate, but a lookalike root presented in x5c', async () => {
    const lookalike = makeChain('Fake');
    const mixed = [chain.leafDer, chain.intermediateDer, lookalike.rootDer];
    assert.equal(await reason(signJws(payload(), mixed, chain.leafKey)), 'chain');
  });

  it('leaf certificate valid now but not yet valid at signedDate', async () => {
    const late = makeChain('Late', { leafNotBefore: new Date(NOW - 2000) });
    const jws = signJws(payload({ signedDate: NOW - 5000 }), x5c(late), late.leafKey);
    assert.equal(await reason(jws, { roots: [new X509Certificate(late.rootDer)] }), 'chain');
  });

  it('V1: forged leaf not signed by the genuine intermediate (same names and marker OID)', async () => {
    // Attacker key self-signs a leaf that copies the intermediate's subject as issuer;
    // presented under the genuine intermediate and pinned root (both public in every JWS).
    const attacker = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
    const forgedLeaf = makeCert({
      cn: 'Fake StoreKit Signing',
      issuerCn: chain.intermediateCn,
      issuerKey: attacker.privateKey,
      publicKey: attacker.publicKey,
      ca: false,
      markerOids: [LEAF_OID],
      serial: 3,
    });
    const jws = signJws(payload(), [forgedLeaf, chain.intermediateDer, chain.rootDer], attacker.privateKey);
    assert.equal(await reason(jws), 'chain');
  });

  it('leaf whose issuer name does not match the intermediate (signature still valid)', async () => {
    const k = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
    const leaf = makeCert({
      cn: 'Fake StoreKit Signing',
      issuerCn: 'Some Other Intermediate',
      issuerKey: chain.intermediateKey,
      publicKey: k.publicKey,
      ca: false,
      markerOids: [LEAF_OID],
    });
    assert.equal(await reason(signJws(payload(), [leaf, chain.intermediateDer, chain.rootDer], k.privateKey)), 'chain');
  });

  it('intermediate whose issuer name does not match the pinned root (signature still valid)', async () => {
    const ik = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
    const k = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
    const inter = makeCert({
      cn: chain.intermediateCn,
      issuerCn: 'Some Other Root',
      issuerKey: chain.rootKey,
      publicKey: ik.publicKey,
      ca: true,
      markerOids: [INTERMEDIATE_OID],
      serial: 8,
    });
    const leaf = makeCert({
      cn: 'Fake StoreKit Signing',
      issuerCn: chain.intermediateCn,
      issuerKey: ik.privateKey,
      publicKey: k.publicKey,
      ca: false,
      markerOids: [LEAF_OID],
    });
    assert.equal(await reason(signJws(payload(), [leaf, inter, chain.rootDer], k.privateKey)), 'chain');
  });

  it('leaf marked as a CA, or intermediate not a CA', async () => {
    const k = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
    const caLeaf = makeCert({
      cn: 'Fake StoreKit Signing',
      issuerCn: chain.intermediateCn,
      issuerKey: chain.intermediateKey,
      publicKey: k.publicKey,
      ca: true,
      markerOids: [LEAF_OID],
    });
    assert.equal(await reason(signJws(payload(), [caLeaf, chain.intermediateDer, chain.rootDer], k.privateKey)), 'chain');

    const ik = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
    const nonCaInter = makeCert({
      cn: chain.intermediateCn,
      issuerCn: chain.rootCn,
      issuerKey: chain.rootKey,
      publicKey: ik.publicKey,
      ca: false,
      markerOids: [INTERMEDIATE_OID],
      serial: 7,
    });
    const leaf = makeCert({
      cn: 'Fake StoreKit Signing',
      issuerCn: chain.intermediateCn,
      issuerKey: ik.privateKey,
      publicKey: k.publicKey,
      ca: false,
      markerOids: [LEAF_OID],
    });
    assert.equal(await reason(signJws(payload(), [leaf, nonCaInter, chain.rootDer], k.privateKey)), 'chain');
  });

  it('leaf key not P-256 (P-384) under the genuine intermediate', async () => {
    const k = crypto.generateKeyPairSync('ec', { namedCurve: 'secp384r1' });
    const leaf = makeCert({
      cn: 'Fake StoreKit Signing',
      issuerCn: chain.intermediateCn,
      issuerKey: chain.intermediateKey,
      publicKey: k.publicKey,
      ca: false,
      markerOids: [LEAF_OID],
    });
    assert.equal(await reason(signJws(payload(), [leaf, chain.intermediateDer, chain.rootDer], k.privateKey)), 'chain');
  });

  it('chain order swapped (intermediate presented as leaf)', async () => {
    const swapped = [chain.intermediateDer, chain.leafDer, chain.rootDer];
    assert.equal(await reason(signJws(payload(), swapped, chain.leafKey)), 'chain');
  });

  it('missing Apple marker extensions (leaf or intermediate)', async () => {
    for (const o of [{ leafMarker: false }, { intermediateMarker: false }]) {
      const bare = makeChain('Bare', o);
      const jws = signJws(payload(), x5c(bare), bare.leafKey);
      assert.equal(await reason(jws, { roots: [new X509Certificate(bare.rootDer)] }), 'chain', JSON.stringify(o));
    }
  });

  it('leaf certificate expired at signedDate', async () => {
    const old = makeChain('Old', { leafNotAfter: new Date(NOW - DAY) });
    const jws = signJws(payload(), x5c(old), old.leafKey);
    assert.equal(await reason(jws, { roots: [new X509Certificate(old.rootDer)] }), 'chain');
  });

  it('a client isPro flag is ignored', async () => {
    assert.equal(await reason(good({ expiresDate: NOW - 1, isPro: true })), 'expired');
  });
});
