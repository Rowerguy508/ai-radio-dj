/**
 * A REAL branded `VerifiedTransaction`: signed by the fake CA (test/helpers/fake-ca.ts)
 * and verified by `verifySignedTransaction` on a non-production deployment, the only
 * way `proSubjectFromVerified` accepts one (Sentinel's B2 on #264).
 */
import { X509Certificate } from 'node:crypto';
import { STOREKIT_CONFIG } from '../../src/storekit-config.js';
import { verifySignedTransaction, type StoreKitResult, type VerifiedTransaction } from '../../src/storekit-verify.js';
import { makeChain, signJws } from './fake-ca.js';

const NOW = Date.parse('2026-10-29T22:00:00Z');
const DAY = 86_400_000;
const chain = makeChain('ProTest');

export interface VerifyFixtureOptions {
  /** `inAppOwnershipType` in the signed payload; null omits the field. Default PURCHASED. */
  ownership?: string | null;
  /** Passed to the verifier as the Family Sharing setting. Default false (off). */
  allowFamilyShared?: boolean;
}

/** Signs a Pro transaction with the fake CA and runs the real verifier on it. */
export async function verifyFixture(originalTransactionId: string, o: VerifyFixtureOptions = {}): Promise<StoreKitResult> {
  const ownership = o.ownership === undefined ? 'PURCHASED' : o.ownership;
  const jws = signJws(
    {
      transactionId: `${originalTransactionId}9`,
      originalTransactionId,
      bundleId: 'com.aerodj.app',
      productId: 'com.aerodj.app.pro.monthly',
      type: 'Auto-Renewable Subscription',
      environment: 'Production',
      ...(ownership === null ? {} : { inAppOwnershipType: ownership }),
      purchaseDate: NOW - DAY,
      expiresDate: NOW + 29 * DAY,
      signedDate: NOW - 1000,
    },
    [chain.leafDer, chain.intermediateDer, chain.rootDer],
    chain.leafKey,
  );
  return verifySignedTransaction(jws, {
    config: { ...STOREKIT_CONFIG },
    deployment: 'nonproduction',
    now: () => NOW,
    lastSeen: { lastSignedDate: async () => undefined },
    install: 'install-key-test',
    roots: [new X509Certificate(chain.rootDer)],
    allowFamilyShared: o.allowFamilyShared ?? false,
  });
}

export async function verifiedTransaction(originalTransactionId: string, o: VerifyFixtureOptions = {}): Promise<VerifiedTransaction> {
  const result = await verifyFixture(originalTransactionId, o);
  if (!result.ok) throw new Error(`fixture failed to verify: ${result.reason}`);
  return result.transaction;
}
