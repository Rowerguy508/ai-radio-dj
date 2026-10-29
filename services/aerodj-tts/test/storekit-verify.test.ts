import assert from 'node:assert/strict';
import crypto, { X509Certificate } from 'node:crypto';
import { describe, it } from 'node:test';
import { APPLE_ROOT_CA_G3_PEM } from '../src/apple-root-ca-g3.js';
import { STOREKIT_CONFIG, parseStoreKitConfig } from '../src/storekit-config.js';
import {
  appleRoots,
  verifySignedTransaction,
  type LastSeenStore,
  type StoreKitConfig,
  type StoreKitVerifierOptions,
} from '../src/storekit-verify.js';
import { makeChain, signJws, type FakeChain } from './helpers/fake-ca.js';

const NOW = Date.parse('2026-10-29T22:00:00Z');
const DAY = 86_400_000;
const PINNED_G3_SHA256 =
  '63:34:3A:BF:B8:9A:6A:03:EB:B5:7E:9B:3F:5F:A7:BE:7C:4F:5C:75:6F:30:17:B3:A8:C4:88:C3:65:3E:91:79';

const chain = makeChain('Fake');
const x5c = (c: FakeChain) => [c.leafDer, c.intermediateDer, c.rootDer];
const config: StoreKitConfig = { ...STOREKIT_CONFIG };

const emptyStore: LastSeenStore = { lastSignedDate: async () => undefined };
const storeWith = (ms: number): LastSeenStore => ({ lastSignedDate: async () => ms });

function opts(over: Partial<StoreKitVerifierOptions> = {}): StoreKitVerifierOptions {
  return {
    config,
    deployment: 'production',
    now: () => NOW,
    lastSeen: emptyStore,
    roots: [new X509Certificate(chain.rootDer)],
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
    const result = await verifySignedTransaction(good(), { ...opts(), roots: undefined });
    assert.deepEqual(result, { ok: false, reason: 'chain' });
  });

  it('ships the interim policy defaults and placeholder product IDs', () => {
    assert.equal(STOREKIT_CONFIG.bundleId, 'com.aerodj.app');
    assert.deepEqual([...STOREKIT_CONFIG.proProductIds], ['com.aerodj.app.pro.monthly', 'com.aerodj.app.pro.yearly']);
    assert.equal(STOREKIT_CONFIG.installsPerPurchase, 5);
    assert.equal(STOREKIT_CONFIG.allowSandboxInProduction, false);
    assert.equal(STOREKIT_CONFIG.honorGracePeriod, false);
    assert.equal(STOREKIT_CONFIG.allowFamilyShared, false);
  });

  it('rejects an invalid config', () => {
    assert.throws(() => parseStoreKitConfig({ ...STOREKIT_CONFIG, proProductIds: [] }));
    assert.throws(() => parseStoreKitConfig({ ...STOREKIT_CONFIG, allowFamilyShared: 'false' }));
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
    assert.equal(await reason(good({ environment: 'Sandbox' }), { deployment: 'nonproduction' }), 'ok');
  });

  it('Sandbox on production only when the config allows it', async () => {
    assert.equal(await reason(good({ environment: 'Sandbox' }), { config: { ...config, allowSandboxInProduction: true } }), 'ok');
  });

  it('FAMILY_SHARED only when the config allows it', async () => {
    assert.equal(
      await reason(good({ inAppOwnershipType: 'FAMILY_SHARED' }), { config: { ...config, allowFamilyShared: true } }),
      'ok',
    );
  });

  it('a newer transaction than the last one seen', async () => {
    assert.equal(await reason(good(), { lastSeen: storeWith(NOW - 5000) }), 'ok');
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

  it('sandbox in prod (config default)', async () => {
    assert.equal(await reason(good({ environment: 'Sandbox' })), 'environment');
  });

  it('unknown environment (e.g. Xcode) everywhere', async () => {
    assert.equal(await reason(good({ environment: 'Xcode' }), { deployment: 'nonproduction' }), 'environment');
  });

  it('FAMILY_SHARED or ASSIGNED while Family Sharing is off', async () => {
    assert.equal(await reason(good({ inAppOwnershipType: 'FAMILY_SHARED' })), 'ownership');
    assert.equal(await reason(good({ inAppOwnershipType: 'ASSIGNED' }), { config: { ...config, allowFamilyShared: true } }), 'ownership');
  });

  it('replayed transaction (same signedDate already seen)', async () => {
    assert.equal(await reason(good(), { lastSeen: storeWith(NOW - 1000) }), 'replayed');
  });

  it('older transaction than the last one seen', async () => {
    assert.equal(await reason(good(), { lastSeen: storeWith(NOW) }), 'stale');
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
