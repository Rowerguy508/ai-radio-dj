/**
 * Offline verification of an App Attest attestation object (#233 note §4.1.2,
 * Sentinel B2 and #246 checklist, Fry #246 rec. 1, 2, 5 and 10). Pure module:
 * no network, no env, no logging, no storage. `register-handler.ts` wires it.
 *
 * Apple source: "Validating apps that connect to your server" and the
 * "Attestation Object Validation Guide" (developer.apple.com, fetched 2026-10-29).
 * Steps, in Apple's order:
 * 1. x5c = [credCert, intermediate], chained to the pinned Apple App Attestation
 *    Root CA without the system trust store, each certificate valid at `now`;
 * 2. clientDataHash = SHA256(challenge) (the challenge string's UTF-8 bytes,
 *    `attestClientDataHash`, computed by the handler);
 * 3. nonce = SHA256(authData ‖ clientDataHash);
 * 4. nonce == the octet string in credCert extension 1.2.840.113635.100.8.2;
 * 5. SHA256(credCert public key, X9.62 uncompressed point) == keyId;
 * 6. authData rpIdHash == SHA256(App ID), App ID = "<AppIDPrefix>.<bundleId>";
 * 7. counter == 0;
 * 8. aaguid == "appattest" + 7 × 0x00 (production), or "appattestdevelop" only
 *    when the policy allows the development environment;
 * 9. credentialId == keyId;
 * plus: the COSE credential public key equals credCert's key, and, when the
 * iOS 27+ `extensions` map carries `apple_validation_category_01`, it must be
 * in the policy's allowed set (Production: 2 TestFlight, 4 App Store).
 *
 * The assertion path (`/api/tts`, `/api/entitlement`) is PR 4; nothing here
 * verifies assertions. Callers must never log the attestation, keyId or challenge.
 */
import crypto, { X509Certificate } from 'node:crypto';
import { APPLE_APP_ATTEST_ROOT_CA_PEM } from './apple-app-attest-root-ca.js';
import { CborError, decodeCbor, decodeCborPrefix, type CborValue } from './cbor.js';
import { appAttestNonceFromExtension, certificateExtensionValue, DerError } from './der.js';
import type { Deployment } from './storekit-verify.js';

export const APP_ATTEST_FORMAT = 'apple-appattest';
export const APP_ATTEST_NONCE_OID = '1.2.840.113635.100.8.2';
export const AAGUID_PRODUCTION = Buffer.concat([Buffer.from('appattest', 'ascii'), Buffer.alloc(7)]);
export const AAGUID_DEVELOPMENT = Buffer.from('appattestdevelop', 'ascii');
/** Decoded attestation-object cap. A 16 KiB base64 body decodes to at most 12 KiB. */
export const MAX_ATTESTATION_BYTES = 12 * 1024;
/** Validation categories Production accepts when the iOS 27+ extension is present (Sentinel rec. 2). */
export const PRODUCTION_VALIDATION_CATEGORIES: ReadonlySet<number> = new Set([2, 4]);
/** Plus 3 (development-signed), only where the development environment is allowed. */
export const DEVELOPMENT_VALIDATION_CATEGORIES: ReadonlySet<number> = new Set([2, 3, 4]);

const FLAG_AT = 0x40; // attested credential data included
const FLAG_ED = 0x80; // extension data included
const AUTH_DATA_FIXED = 32 + 1 + 4 + 16 + 2;
const APP_ID = /^[A-Z0-9]{10}\.[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$/;

export type AppAttestEnvironment = 'production' | 'development';

export interface AttestationPolicy {
  /** "<AppIDPrefix>.<bundleId>"; the rpIdHash is SHA256 of this string. */
  appId: string;
  /** Accept the `appattestdevelop` aaguid. The handler sets this only when the env policy allows it. */
  allowDevelopment: boolean;
  /** Allowed `apple_validation_category_01` values when present. */
  validationCategories: ReadonlySet<number>;
  deployment: Deployment;
  now: number;
  /**
   * Caller-supplied roots (test CAs). Refused (`config`) unless
   * `deployment === 'nonproduction'`; defaults to the pinned Apple root.
   */
  roots?: readonly X509Certificate[];
}

export interface AttestationInput {
  /** Raw 32-byte keyId (base64-decoded `X-OnAirly-Key` / body `keyId`). */
  keyId: Buffer;
  /** Raw CBOR attestation object bytes. */
  attestationObject: Buffer;
  /**
   * The bytes the app passed to `attestKey(_:clientDataHash:)`. AeroDJ pins
   * `attestClientDataHash(challenge)` (#246 Fry rec. 3); the handler computes it.
   * Taking bytes here lets tests replay Apple's published sample, whose app
   * passed the raw challenge bytes instead of a hash.
   */
  clientDataHash: Buffer;
}

export type AttestationFailure =
  | 'config'
  | 'malformed'
  | 'format'
  | 'chain'
  | 'nonce'
  | 'key_id'
  | 'rp_id'
  | 'flags'
  | 'counter'
  | 'aaguid'
  | 'credential_id'
  | 'cose_key'
  | 'extensions'
  | 'validation_category';

export interface VerifiedAttestation {
  /** credCert public key as DER SPKI: what PR 4 verifies assertions with. */
  publicKeySpki: Buffer;
  environment: AppAttestEnvironment;
  /** iOS 27+ only. */
  validationCategory?: number;
  bundleVersion?: string;
}

export type AttestationResult = { ok: true; attestation: VerifiedAttestation } | { ok: false; reason: AttestationFailure };

let pinnedRoots: X509Certificate[] | undefined;
export function appAttestRoots(): X509Certificate[] {
  pinnedRoots ??= [new X509Certificate(APPLE_APP_ATTEST_ROOT_CA_PEM)];
  return pinnedRoots;
}

/** clientDataHash for attestation: SHA256 of the challenge string's UTF-8 bytes. */
export function attestClientDataHash(challenge: string): Buffer {
  return crypto.createHash('sha256').update(challenge, 'utf8').digest();
}

const sha256 = (...parts: Uint8Array[]): Buffer => {
  const h = crypto.createHash('sha256');
  for (const p of parts) h.update(p);
  return h.digest();
};

class Refusal extends Error {
  constructor(readonly reason: AttestationFailure) {
    super(reason);
  }
}
const refuse = (reason: AttestationFailure): never => {
  throw new Refusal(reason);
};

function validAt(cert: X509Certificate, ms: number): boolean {
  return Date.parse(cert.validFrom) <= ms && ms <= Date.parse(cert.validTo);
}

/** credCert → intermediate → a pinned root, at `now`. Returns credCert. */
function verifyChain(x5c: Buffer[], roots: readonly X509Certificate[], now: number): X509Certificate {
  let cred: X509Certificate, intermediate: X509Certificate;
  try {
    cred = new X509Certificate(x5c[0]);
    intermediate = new X509Certificate(x5c[1]);
  } catch {
    return refuse('chain');
  }
  // The root is never taken from the request: the intermediate must be signed by a pinned root.
  const root = roots.find((r) => r.ca && intermediate.issuer === r.subject && intermediate.verify(r.publicKey));
  if (!root) return refuse('chain');
  if (!intermediate.ca || cred.ca) return refuse('chain');
  if (cred.issuer !== intermediate.subject || !cred.verify(intermediate.publicKey)) return refuse('chain');
  if (![root, intermediate, cred].every((c) => validAt(c, now))) return refuse('chain');
  const key = cred.publicKey;
  if (key.asymmetricKeyType !== 'ec' || key.asymmetricKeyDetails?.namedCurve !== 'prime256v1') return refuse('chain');
  return cred;
}

function uncompressedPoint(cert: X509Certificate): { point: Buffer; x: Buffer; y: Buffer } {
  const jwk = cert.publicKey.export({ format: 'jwk' });
  if (typeof jwk.x !== 'string' || typeof jwk.y !== 'string') return refuse('chain');
  const x = Buffer.from(jwk.x, 'base64url');
  const y = Buffer.from(jwk.y, 'base64url');
  if (x.length !== 32 || y.length !== 32) return refuse('chain');
  return { point: Buffer.concat([Buffer.from([0x04]), x, y]), x, y };
}

const asMap = (v: CborValue | undefined): Map<string | number, CborValue> | undefined => (v instanceof Map ? v : undefined);

/** COSE_Key (RFC 9053) EC2 P-256 ES256: exactly {1:2, 3:-7, -1:1, -2:x, -3:y}. */
function coseKeyMatches(value: CborValue, x: Buffer, y: Buffer): boolean {
  const m = asMap(value);
  if (!m || m.size !== 5) return false;
  const kx = m.get(-2);
  const ky = m.get(-3);
  return (
    m.get(1) === 2 &&
    m.get(3) === -7 &&
    m.get(-1) === 1 &&
    Buffer.isBuffer(kx) &&
    Buffer.isBuffer(ky) &&
    kx.equals(x) &&
    ky.equals(y)
  );
}

/** `apple_validation_category_01`: a CBOR uint, or 4 bytes little-endian as observed on devices. */
function validationCategory(value: CborValue): number {
  if (typeof value === 'number' && Number.isInteger(value) && value >= 0 && value <= 0xffffffff) return value;
  if (Buffer.isBuffer(value) && value.length === 4) return value.readUInt32LE(0);
  return refuse('extensions');
}

function check(input: AttestationInput, policy: AttestationPolicy): VerifiedAttestation {
  if (policy.roots !== undefined && policy.deployment !== 'nonproduction') return refuse('config');
  if (policy.roots !== undefined && policy.roots.length === 0) return refuse('config');
  if (typeof policy.appId !== 'string' || !APP_ID.test(policy.appId)) return refuse('config');
  if (!Buffer.isBuffer(input.keyId) || input.keyId.length !== 32) return refuse('malformed');
  if (!Buffer.isBuffer(input.clientDataHash) || input.clientDataHash.length === 0) return refuse('malformed');
  if (!Buffer.isBuffer(input.attestationObject) || input.attestationObject.length > MAX_ATTESTATION_BYTES) {
    return refuse('malformed');
  }

  const top = asMap(decodeCbor(input.attestationObject, { maxBytes: MAX_ATTESTATION_BYTES }));
  if (!top || top.size !== 3 || !top.has('fmt') || !top.has('attStmt') || !top.has('authData')) return refuse('malformed');
  if (top.get('fmt') !== APP_ATTEST_FORMAT) return refuse('format');
  const stmt = asMap(top.get('attStmt'));
  if (!stmt || ![...stmt.keys()].every((k) => k === 'x5c' || k === 'receipt')) return refuse('malformed');
  const receipt = stmt.get('receipt');
  if (receipt !== undefined && !Buffer.isBuffer(receipt)) return refuse('malformed');
  const x5c = stmt.get('x5c');
  if (!Array.isArray(x5c) || x5c.length !== 2 || !x5c.every((c) => Buffer.isBuffer(c) && c.length > 0)) {
    return refuse('chain');
  }
  const authData = top.get('authData');
  if (!Buffer.isBuffer(authData) || authData.length < AUTH_DATA_FIXED) return refuse('malformed');

  // 1. Chain to the pinned root.
  const cred = verifyChain(x5c as Buffer[], policy.roots ?? appAttestRoots(), policy.now);

  // 2-4. Nonce.
  const nonce = sha256(authData, input.clientDataHash);
  const ext = certificateExtensionValue(cred.raw, APP_ATTEST_NONCE_OID);
  if (!ext) return refuse('nonce');
  const certNonce = appAttestNonceFromExtension(ext);
  if (!crypto.timingSafeEqual(Buffer.from(certNonce), nonce)) return refuse('nonce');

  // 5. keyId = SHA256(uncompressed public key).
  const { point, x, y } = uncompressedPoint(cred);
  if (!sha256(point).equals(input.keyId)) return refuse('key_id');

  // 6. rpIdHash.
  if (!authData.subarray(0, 32).equals(sha256(Buffer.from(policy.appId, 'utf8')))) return refuse('rp_id');

  const flags = authData[32];
  if ((flags & FLAG_AT) === 0) return refuse('flags');

  // 7. counter.
  if (authData.readUInt32BE(33) !== 0) return refuse('counter');

  // 8. aaguid.
  const aaguid = authData.subarray(37, 53);
  let environment: AppAttestEnvironment;
  if (aaguid.equals(AAGUID_PRODUCTION)) environment = 'production';
  else if (policy.allowDevelopment && aaguid.equals(AAGUID_DEVELOPMENT)) environment = 'development';
  else return refuse('aaguid');

  // 9. credentialId.
  const idLength = authData.readUInt16BE(53);
  const idEnd = AUTH_DATA_FIXED + idLength;
  if (idLength !== 32 || authData.length <= idEnd) return refuse('credential_id');
  if (!authData.subarray(AUTH_DATA_FIXED, idEnd).equals(input.keyId)) return refuse('credential_id');

  // COSE credential public key must be credCert's key.
  let cose: { value: CborValue; end: number };
  try {
    cose = decodeCborPrefix(authData, idEnd, { maxDepth: 1, maxItems: 8, maxBytes: authData.length });
  } catch {
    return refuse('cose_key');
  }
  if (!coseKeyMatches(cose.value, x, y)) return refuse('cose_key');

  // iOS 27+ extensions map (Apple's published sample leaves the ED flag clear, so
  // trailing bytes are read as extensions either way; ED set requires them).
  let category: number | undefined;
  let bundleVersion: string | undefined;
  if (cose.end < authData.length) {
    let extensions: Map<string | number, CborValue> | undefined;
    try {
      extensions = asMap(decodeCbor(authData.subarray(cose.end), { maxDepth: 1, maxItems: 8, maxBytes: authData.length }));
    } catch {
      return refuse('extensions');
    }
    if (!extensions) return refuse('extensions');
    const rawCategory = extensions.get('apple_validation_category_01');
    if (rawCategory !== undefined) category = validationCategory(rawCategory);
    const rawVersion = extensions.get('apple_bundle_version_01');
    if (rawVersion !== undefined) {
      if (typeof rawVersion !== 'string' || rawVersion.length === 0 || rawVersion.length > 64) return refuse('extensions');
      bundleVersion = rawVersion;
    }
  } else if (flags & FLAG_ED) {
    return refuse('extensions');
  }
  if (category !== undefined && !policy.validationCategories.has(category)) return refuse('validation_category');

  return {
    publicKeySpki: Buffer.from(cred.publicKey.export({ format: 'der', type: 'spki' })),
    environment,
    ...(category !== undefined ? { validationCategory: category } : {}),
    ...(bundleVersion !== undefined ? { bundleVersion } : {}),
  };
}

/** Never throws: every failure is a reason code. */
export function verifyAttestation(input: AttestationInput, policy: AttestationPolicy): AttestationResult {
  try {
    return { ok: true, attestation: check(input, policy) };
  } catch (error) {
    if (error instanceof Refusal) return { ok: false, reason: error.reason };
    if (error instanceof CborError || error instanceof DerError) return { ok: false, reason: 'malformed' };
    return { ok: false, reason: 'malformed' };
  }
}
