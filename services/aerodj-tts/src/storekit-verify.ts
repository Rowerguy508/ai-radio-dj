/**
 * Offline verification of a StoreKit 2 / App Store signed transaction (JWS),
 * per docs/design/proxy-per-install-auth.md §5.3. Pure module: no network, no
 * env, no logging, no storage writes. Wired to no endpoint yet (PR 6 does that).
 *
 * Apple sources (developer.apple.com, fetched 2026-10-29): JWSTransaction,
 * JWSTransactionDecodedPayload, environment, inAppOwnershipType, type,
 * revocationDate. Marker OIDs: Apple's app-store-server-library-node
 * (jws_verification.ts). Root: https://www.apple.com/certificateauthority/.
 *
 * Callers must never log the JWS or any returned identifier.
 */
import crypto, { X509Certificate } from 'node:crypto';
import { APPLE_ROOT_CA_G3_PEM } from './apple-root-ca-g3.js';
import { certificateExtensionOids } from './der.js';

export const APPLE_LEAF_MARKER_OID = '1.2.840.113635.100.6.11.1';
export const APPLE_INTERMEDIATE_MARKER_OID = '1.2.840.113635.100.6.2.1';
export const MAX_JWS_BYTES = 16_384;
export const AUTO_RENEWABLE = 'Auto-Renewable Subscription';

export interface StoreKitConfig {
  bundleId: string;
  proProductIds: readonly string[];
  installsPerPurchase: number;
  allowSandboxInProduction: boolean;
  honorGracePeriod: boolean;
  allowFamilyShared: boolean;
}

/** Highest `signedDate` already accepted for an original transaction (caller-owned store). */
export interface LastSeenStore {
  lastSignedDate(originalTransactionId: string): Promise<number | undefined>;
}

export type Deployment = 'production' | 'nonproduction';

export interface StoreKitVerifierOptions {
  config: StoreKitConfig;
  deployment: Deployment;
  now: () => number;
  lastSeen: LastSeenStore;
  /** Pinned roots; defaults to Apple Root CA - G3. Tests inject a fake CA. */
  roots?: readonly X509Certificate[];
}

export type StoreKitFailure =
  | 'malformed'
  | 'header'
  | 'chain'
  | 'signature'
  | 'bundle'
  | 'product'
  | 'type'
  | 'environment'
  | 'expired'
  | 'revoked'
  | 'ownership'
  | 'replayed'
  | 'stale';

export interface VerifiedTransaction {
  originalTransactionId: string;
  transactionId: string;
  productId: string;
  environment: 'Production' | 'Sandbox';
  inAppOwnershipType: 'PURCHASED' | 'FAMILY_SHARED';
  expiresDate: number;
  signedDate: number;
  appAccountToken?: string;
}

export type StoreKitResult = { ok: true; transaction: VerifiedTransaction } | { ok: false; reason: StoreKitFailure };

const B64URL = /^[A-Za-z0-9_-]+$/;
const B64 = /^[A-Za-z0-9+/]+={0,2}$/;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

let defaultRoots: X509Certificate[] | undefined;
export function appleRoots(): X509Certificate[] {
  defaultRoots ??= [new X509Certificate(APPLE_ROOT_CA_G3_PEM)];
  return defaultRoots;
}

function fail(reason: StoreKitFailure): StoreKitResult {
  return { ok: false, reason };
}

function decodeJsonSegment(segment: string): Record<string, unknown> | undefined {
  try {
    const value: unknown = JSON.parse(Buffer.from(segment, 'base64url').toString('utf8'));
    return value && typeof value === 'object' && !Array.isArray(value) ? (value as Record<string, unknown>) : undefined;
  } catch {
    return undefined;
  }
}

function validAt(cert: X509Certificate, ms: number): boolean {
  return Date.parse(cert.validFrom) <= ms && ms <= Date.parse(cert.validTo);
}

function isP256(cert: X509Certificate): boolean {
  const key = cert.publicKey;
  return key.asymmetricKeyType === 'ec' && key.asymmetricKeyDetails?.namedCurve === 'prime256v1';
}

/** Verifies leaf → intermediate → pinned root at `atMs`. */
function chainOk(x5c: string[], roots: readonly X509Certificate[], atMs: number): X509Certificate | undefined {
  let leaf: X509Certificate, intermediate: X509Certificate, root: X509Certificate;
  try {
    [leaf, intermediate, root] = x5c.map((der) => new X509Certificate(Buffer.from(der, 'base64')));
  } catch {
    return undefined;
  }
  // The presented root must be byte-equal to a pinned root; the system trust store is never used.
  const pinned = roots.find((candidate) => candidate.raw.equals(root.raw));
  if (!pinned) return undefined;
  if (!pinned.ca || !intermediate.ca || leaf.ca) return undefined;
  if (intermediate.issuer !== pinned.subject || leaf.issuer !== intermediate.subject) return undefined;
  if (!intermediate.verify(pinned.publicKey) || !leaf.verify(intermediate.publicKey)) return undefined;
  if (![pinned, intermediate, leaf].every((cert) => validAt(cert, atMs))) return undefined;
  try {
    if (!certificateExtensionOids(intermediate.raw).includes(APPLE_INTERMEDIATE_MARKER_OID)) return undefined;
    if (!certificateExtensionOids(leaf.raw).includes(APPLE_LEAF_MARKER_OID)) return undefined;
  } catch {
    return undefined;
  }
  return isP256(leaf) ? leaf : undefined;
}

export async function verifySignedTransaction(jws: unknown, options: StoreKitVerifierOptions): Promise<StoreKitResult> {
  const { config, deployment, lastSeen } = options;
  if (typeof jws !== 'string' || jws.length === 0 || jws.length > MAX_JWS_BYTES) return fail('malformed');
  const parts = jws.split('.');
  if (parts.length !== 3 || !parts.every((part) => B64URL.test(part))) return fail('malformed');
  const [headerPart, payloadPart, signaturePart] = parts;

  const header = decodeJsonSegment(headerPart);
  if (!header) return fail('malformed');
  const x5c = header.x5c;
  // ES256 only: `none`, HS*, RS*, PS* and anything else are refused. The key comes
  // only from the pinned x5c chain; `jwk`, `jku`, `kid` and `x5u` are never read.
  if (header.alg !== 'ES256') return fail('header');
  if (!Array.isArray(x5c) || x5c.length !== 3 || !x5c.every((c) => typeof c === 'string' && B64.test(c))) {
    return fail('header');
  }

  const payload = decodeJsonSegment(payloadPart);
  if (!payload) return fail('malformed');
  const str = (k: string) => (typeof payload[k] === 'string' ? (payload[k] as string) : undefined);
  const num = (k: string) => (Number.isSafeInteger(payload[k]) ? (payload[k] as number) : undefined);
  const signedDate = num('signedDate');
  const expiresDate = num('expiresDate');
  const originalTransactionId = str('originalTransactionId');
  const transactionId = str('transactionId');
  if (signedDate === undefined || expiresDate === undefined || !originalTransactionId || !transactionId) {
    return fail('malformed');
  }

  // Chain and signature before trusting any payload field.
  const leaf = chainOk(x5c as string[], options.roots ?? appleRoots(), signedDate);
  if (!leaf) return fail('chain');
  const signature = Buffer.from(signaturePart, 'base64url');
  if (signature.length !== 64) return fail('signature');
  const signedOk = crypto.verify(
    'sha256',
    Buffer.from(`${headerPart}.${payloadPart}`, 'ascii'),
    { key: leaf.publicKey, dsaEncoding: 'ieee-p1363' },
    signature,
  );
  if (!signedOk) return fail('signature');

  if (str('bundleId') !== config.bundleId) return fail('bundle');
  const productId = str('productId');
  if (!productId || !config.proProductIds.includes(productId)) return fail('product');
  if (str('type') !== AUTO_RENEWABLE) return fail('type');

  const environment = str('environment');
  const envOk =
    environment === 'Production' ||
    (environment === 'Sandbox' && (deployment !== 'production' || config.allowSandboxInProduction));
  if (!envOk) return fail('environment');

  if (payload.revocationDate !== undefined) return fail('revoked');
  if (!(expiresDate > options.now())) return fail('expired');

  const ownership = str('inAppOwnershipType');
  if (!(ownership === 'PURCHASED' || (ownership === 'FAMILY_SHARED' && config.allowFamilyShared))) {
    return fail('ownership');
  }

  const appAccountToken = payload.appAccountToken;
  if (appAccountToken !== undefined && (typeof appAccountToken !== 'string' || !UUID.test(appAccountToken))) {
    return fail('malformed');
  }

  const last = await lastSeen.lastSignedDate(originalTransactionId);
  if (last !== undefined) {
    if (signedDate === last) return fail('replayed');
    if (signedDate < last) return fail('stale');
  }

  return {
    ok: true,
    transaction: {
      originalTransactionId,
      transactionId,
      productId,
      environment: environment as 'Production' | 'Sandbox',
      inAppOwnershipType: ownership as 'PURCHASED' | 'FAMILY_SHARED',
      expiresDate,
      signedDate,
      ...(typeof appAccountToken === 'string' ? { appAccountToken } : {}),
    },
  };
}
