/**
 * #380 P1 review (issue comment 6587744343): does verifyAssertion double-hash Apple's nonce?
 * Answered with GENUINE device assertions (test/fixtures/app-attest-device-assertion.ts), not
 * with our own test signer:
 * - The Secure Enclave signs `nonce` as a MESSAGE with ES256, i.e. ECDSA over SHA256(nonce).
 *   So `crypto.verify('sha256', nonce, …)` is correct, and verifying the preimage
 *   `authenticatorData ‖ clientDataHash` with one SHA-256 (the proposed change) rejects every
 *   real device. Both tests below would catch that change.
 * - Provenance: the veehaitch credCert chains to the real Apple App Attestation Root CA and
 *   carries the assertion's public key.
 * Public sample data only, no secret.
 */
import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import crypto, { X509Certificate } from 'node:crypto';
import { verifyAssertion } from '../src/app-attest-assertion.js';
import { decodeCbor } from '../src/cbor.js';
import { APPLE_APP_ATTEST_ROOT_CA_PEM } from '../src/apple-app-attest-root-ca.js';
import {
  UEBELACK_APP_ID,
  UEBELACK_ASSERTION_B64,
  UEBELACK_CLIENT_DATA,
  UEBELACK_PUBLIC_KEY_PEM,
  VEEHAITCH_APP_ID,
  VEEHAITCH_ASSERTION_B64,
  VEEHAITCH_ATTESTATION_B64,
  VEEHAITCH_CLIENT_DATA_B64,
  VEEHAITCH_CLIENT_DATA_HASH_B64,
  VEEHAITCH_COUNTER,
  VEEHAITCH_KEY_ID,
  VEEHAITCH_PUBLIC_KEY_PEM,
} from './fixtures/app-attest-device-assertion.js';

const sha256 = (...parts: Uint8Array[]): Buffer => {
  const h = crypto.createHash('sha256');
  for (const p of parts) h.update(p);
  return h.digest();
};
const spki = (pem: string): Buffer => crypto.createPublicKey(pem).export({ type: 'spki', format: 'der' });

interface Vector {
  name: string;
  assertion: Buffer;
  clientData: Buffer;
  publicKeySpki: Buffer;
  appId: string;
  counter: number;
}
const VECTORS: Vector[] = [
  {
    name: 'veehaitch iOS 14.4 (Apple-rooted key)',
    assertion: Buffer.from(VEEHAITCH_ASSERTION_B64, 'base64'),
    clientData: Buffer.from(VEEHAITCH_CLIENT_DATA_B64, 'base64'),
    publicKeySpki: spki(VEEHAITCH_PUBLIC_KEY_PEM),
    appId: VEEHAITCH_APP_ID,
    counter: VEEHAITCH_COUNTER,
  },
  {
    name: 'uebelack node-app-attest',
    assertion: Buffer.from(UEBELACK_ASSERTION_B64, 'base64'),
    clientData: Buffer.from(UEBELACK_CLIENT_DATA, 'utf8'),
    publicKeySpki: spki(UEBELACK_PUBLIC_KEY_PEM),
    appId: UEBELACK_APP_ID,
    counter: 1,
  },
];

function parts(assertion: Buffer): { signature: Buffer; authData: Buffer } {
  const m = decodeCbor(assertion, { maxDepth: 1, maxItems: 2, maxBytes: 2048 }) as Map<string, Buffer>;
  return { signature: m.get('signature')!, authData: m.get('authenticatorData')! };
}

describe('genuine device fixture provenance', () => {
  test('veehaitch credCert → Apple App Attestation CA 1 → Apple root, and it carries the assertion key', () => {
    const att = decodeCbor(Buffer.from(VEEHAITCH_ATTESTATION_B64, 'base64'), { maxDepth: 8, maxItems: 64, maxBytes: 12 * 1024 }) as Map<string, any>;
    const x5c = (att.get('attStmt') as Map<string, Buffer[]>).get('x5c')!;
    const leaf = new X509Certificate(x5c[0]);
    const ca = new X509Certificate(x5c[1]);
    const root = new X509Certificate(APPLE_APP_ATTEST_ROOT_CA_PEM);
    assert.equal(ca.verify(root.publicKey), true);
    assert.equal(leaf.verify(ca.publicKey), true);
    assert.ok(leaf.publicKey.export({ type: 'spki', format: 'der' }).equals(spki(VEEHAITCH_PUBLIC_KEY_PEM)));
    // keyId = SHA256(uncompressed point) = last 65 bytes of the P-256 SPKI.
    assert.equal(sha256(spki(VEEHAITCH_PUBLIC_KEY_PEM).subarray(-65)).toString('base64'), VEEHAITCH_KEY_ID);
    assert.equal(sha256(Buffer.from(VEEHAITCH_CLIENT_DATA_B64, 'base64')).toString('base64'), VEEHAITCH_CLIENT_DATA_HASH_B64);
  });
});

describe('verifyAssertion against genuine device assertions (#380 P1)', () => {
  for (const v of VECTORS) {
    test(`${v.name}: verifies, rpId matches, counter ${v.counter}`, () => {
      assert.deepEqual(verifyAssertion(v), { ok: true, counter: v.counter });
    });

    test(`${v.name}: device signed nonce as a message (ECDSA over SHA256(nonce)), not the preimage`, () => {
      const { signature, authData } = parts(v.assertion);
      const key = { key: crypto.createPublicKey({ key: v.publicKeySpki, format: 'der', type: 'spki' }), dsaEncoding: 'der' as const };
      const clientDataHash = sha256(v.clientData);
      const nonce = sha256(authData, clientDataHash);
      // Current convention (and node-app-attest / appattest-checker-node / veehaitch / webauthn4j).
      assert.equal(crypto.verify('sha256', nonce, key, signature), true);
      // The proposed single-hash convention over authenticatorData ‖ clientDataHash: must NOT verify.
      assert.equal(crypto.verify('sha256', Buffer.concat([authData, clientDataHash]), key, signature), false);
    });

    test(`${v.name}: one changed clientData byte → signature`, () => {
      const clientData = Buffer.from(v.clientData);
      clientData[0] ^= 0x01;
      assert.deepEqual(verifyAssertion({ ...v, clientData }), { ok: false, reason: 'signature' });
    });

    test(`${v.name}: another App ID → rp_id`, () => {
      assert.deepEqual(verifyAssertion({ ...v, appId: `${v.appId}x` }), { ok: false, reason: 'rp_id' });
    });
  }

  test('a key from another device → signature', () => {
    const [a, b] = VECTORS;
    assert.deepEqual(verifyAssertion({ ...a, publicKeySpki: b.publicKeySpki }), { ok: false, reason: 'signature' });
  });
});
