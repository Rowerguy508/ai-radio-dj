/**
 * A REAL branded `VerifiedTransaction`: signed by the fake CA (test/helpers/fake-ca.ts)
 * and verified by `verifySignedTransaction` on a non-production deployment, the only
 * way `proSubjectFromVerified` accepts one (Sentinel's B2 on #264).
 */
import { X509Certificate } from 'node:crypto';
import { STOREKIT_CONFIG } from '../../src/storekit-config.js';
import { verifySignedTransaction, type VerifiedTransaction } from '../../src/storekit-verify.js';
import { makeChain, signJws } from './fake-ca.js';

const NOW = Date.parse('2026-10-29T22:00:00Z');
const DAY = 86_400_000;
const chain = makeChain('ProTest');

export async function verifiedTransaction(originalTransactionId: string): Promise<VerifiedTransaction> {
  const jws = signJws(
    {
      transactionId: `${originalTransactionId}9`,
      originalTransactionId,
      bundleId: 'com.aerodj.app',
      productId: 'com.aerodj.app.pro.monthly',
      type: 'Auto-Renewable Subscription',
      environment: 'Production',
      inAppOwnershipType: 'PURCHASED',
      purchaseDate: NOW - DAY,
      expiresDate: NOW + 29 * DAY,
      signedDate: NOW - 1000,
    },
    [chain.leafDer, chain.intermediateDer, chain.rootDer],
    chain.leafKey,
  );
  const result = await verifySignedTransaction(jws, {
    config: { ...STOREKIT_CONFIG },
    deployment: 'nonproduction',
    now: () => NOW,
    lastSeen: { lastSignedDate: async () => undefined },
    install: 'install-key-test',
    roots: [new X509Certificate(chain.rootDer)],
  });
  if (!result.ok) throw new Error(`fixture failed to verify: ${result.reason}`);
  return result.transaction;
}
