import crypto from 'node:crypto';
import { decodeCbor, type CborValue } from './cbor.js';

/**
 * Offline verification of an App Attest ASSERTION (#378 design §1.1, step 4). Pure module:
 * no network, env, logging or storage. The token handler loads the stored public key, calls
 * this, and commits the counter in its single store script.
 *
 * Apple, "Validating apps that connect to your server" → "Verify the assertion":
 * 1. clientDataHash = SHA256(clientData);
 * 2. nonce = SHA256(authenticatorData ‖ clientDataHash);
 * 3. the signature is valid for `nonce` under the stored public key. The Secure Enclave
 *    signs `nonce` with ES256 (ECDSA P-256 over SHA-256 of its input), so the message
 *    handed to the verifier is `nonce` itself;
 * 4. authenticatorData rpIdHash == SHA256(App ID);
 * 5. counter > the stored counter (checked atomically by the caller's script; returned here);
 * 6. the challenge inside clientData is the one the server issued (the caller builds
 *    clientData from the challenge it verified, so a different challenge fails step 3);
 * 7. if the iOS 27+ extensions map carries `apple_validation_category_01`, it is returned
 *    so the caller can require TestFlight (2).
 *
 * Step 3 convention, checked against GENUINE device assertions (test/app-attest-assertion.test.ts,
 * fixtures from veehaitch/devicecheck-appattest, Apple-rooted key, and uebelack/node-app-attest):
 * the device signature is ECDSA over SHA256(nonce), so `crypto.verify('sha256', nonce, …)` is
 * correct. Do NOT "fix" this to one hash over authenticatorData ‖ clientDataHash: that rejects
 * every real device and the fixture tests fail (#380 P1 review). Not yet run with an assertion
 * from our own app on a device.
 */

export const MAX_ASSERTION_BYTES = 2 * 1024;
const AUTH_DATA_MIN = 32 + 1 + 4;

export type AssertionFailure = 'malformed' | 'signature' | 'rp_id' | 'extensions';
export type AssertionResult =
  | { ok: true; counter: number; validationCategory?: number }
  | { ok: false; reason: AssertionFailure };

export interface AssertionInput {
  /** Raw CBOR `{ signature, authenticatorData }`. */
  assertion: Buffer;
  /** The exact clientData bytes the app passed (hashed) to generateAssertion. */
  clientData: Buffer;
  /** Stored credential public key, DER SPKI (from register). */
  publicKeySpki: Buffer;
  /** "<AppIDPrefix>.<bundleId>". */
  appId: string;
}

const sha256 = (...parts: Uint8Array[]): Buffer => {
  const h = crypto.createHash('sha256');
  for (const p of parts) h.update(p);
  return h.digest();
};

function category(value: CborValue): number | null {
  if (typeof value === 'number' && Number.isInteger(value) && value >= 0 && value <= 0xffffffff) return value;
  if (Buffer.isBuffer(value) && value.length === 4) return value.readUInt32LE(0);
  return null;
}

/** Never throws: every failure is a reason code. */
export function verifyAssertion(input: AssertionInput): AssertionResult {
  try {
    if (!Buffer.isBuffer(input.assertion) || input.assertion.length === 0 || input.assertion.length > MAX_ASSERTION_BYTES) {
      return { ok: false, reason: 'malformed' };
    }
    const top = decodeCbor(input.assertion, { maxDepth: 1, maxItems: 2, maxBytes: MAX_ASSERTION_BYTES });
    if (!(top instanceof Map) || top.size !== 2) return { ok: false, reason: 'malformed' };
    const signature = top.get('signature');
    const authData = top.get('authenticatorData');
    if (!Buffer.isBuffer(signature) || !Buffer.isBuffer(authData) || signature.length === 0 || authData.length < AUTH_DATA_MIN) {
      return { ok: false, reason: 'malformed' };
    }
    let key: crypto.KeyObject;
    try {
      key = crypto.createPublicKey({ key: input.publicKeySpki, format: 'der', type: 'spki' });
    } catch {
      return { ok: false, reason: 'malformed' };
    }
    if (key.asymmetricKeyType !== 'ec' || key.asymmetricKeyDetails?.namedCurve !== 'prime256v1') return { ok: false, reason: 'malformed' };

    const nonce = sha256(authData, sha256(input.clientData));
    let valid = false;
    try {
      valid = crypto.verify('sha256', nonce, { key, dsaEncoding: 'der' }, signature);
    } catch {
      valid = false;
    }
    if (!valid) return { ok: false, reason: 'signature' };
    if (!authData.subarray(0, 32).equals(sha256(Buffer.from(input.appId, 'utf8')))) return { ok: false, reason: 'rp_id' };
    const counter = authData.readUInt32BE(33);

    let validationCategory: number | undefined;
    if (authData.length > AUTH_DATA_MIN) {
      let ext: CborValue;
      try {
        ext = decodeCbor(authData.subarray(AUTH_DATA_MIN), { maxDepth: 1, maxItems: 8, maxBytes: MAX_ASSERTION_BYTES });
      } catch {
        return { ok: false, reason: 'extensions' };
      }
      if (!(ext instanceof Map)) return { ok: false, reason: 'extensions' };
      const raw = ext.get('apple_validation_category_01');
      if (raw !== undefined) {
        const c = category(raw);
        if (c === null) return { ok: false, reason: 'extensions' };
        validationCategory = c;
      }
    }
    return { ok: true, counter, ...(validationCategory !== undefined ? { validationCategory } : {}) };
  } catch {
    return { ok: false, reason: 'malformed' };
  }
}

/** clientData for a token mint (design §1.1): "onairly-tok-v1\n" + challenge + "\n" + hex(sha256(rawBody)). */
export function tokenClientData(challenge: string, rawBody: Buffer): Buffer {
  return Buffer.from(`onairly-tok-v1\n${challenge}\n${sha256(rawBody).toString('hex')}`, 'utf8');
}

/** TestFlight's `apple_validation_category_01` value (design §1.5). */
export const TESTFLIGHT_VALIDATION_CATEGORY = 2;
