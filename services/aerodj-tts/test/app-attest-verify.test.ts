import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import crypto, { X509Certificate } from 'node:crypto';
import {
  AAGUID_DEVELOPMENT,
  AAGUID_PRODUCTION,
  appAttestRoots,
  attestClientDataHash,
  DEVELOPMENT_VALIDATION_CATEGORIES,
  MAX_ATTESTATION_BYTES,
  PRODUCTION_VALIDATION_CATEGORIES,
  verifyAttestation,
  type AttestationPolicy,
} from '../src/app-attest-verify.js';
import { APPLE_APP_ATTEST_ROOT_CA_PEM } from '../src/apple-app-attest-root-ca.js';
import { appAttestNonceFromExtension, certificateExtensionValue, DerError } from '../src/der.js';
import { decodeCbor } from '../src/cbor.js';
import {
  AAGUID_DEV,
  AAGUID_PROD,
  cbor,
  cmap,
  makeAttestCa,
  makeAttestation,
  nonceExtension,
  TEST_APP_ID,
  type AttestOptions,
} from './helpers/fake-appattest.js';
import { enc, makeCert } from './helpers/fake-ca.js';
import {
  SAMPLE_APP_ID,
  SAMPLE_ATTESTATION_B64,
  SAMPLE_CHALLENGE,
  SAMPLE_KEY_ID,
  SAMPLE_NONCE,
  SAMPLE_NOW,
  SAMPLE_RP_ID_HASH,
  SAMPLE_VALID_FROM,
  SAMPLE_VALID_TO,
} from './fixtures/apple-app-attest-sample.js';

const NOW = Date.UTC(2026, 9, 29, 12);
const CHALLENGE = 'test-challenge-not-a-secret';
const CDH = attestClientDataHash(CHALLENGE);
const CA = makeAttestCa();

const policy = (over: Partial<AttestationPolicy> = {}): AttestationPolicy => ({
  appId: TEST_APP_ID,
  allowDevelopment: false,
  validationCategories: PRODUCTION_VALIDATION_CATEGORIES,
  deployment: 'nonproduction',
  now: NOW,
  roots: [CA.root],
  ...over,
});
function run(o: Partial<AttestOptions> = {}, p: Partial<AttestationPolicy> = {}, keyIdOverride?: Buffer) {
  const a = makeAttestation(CA, { clientDataHash: CDH, ...o });
  return { a, r: verifyAttestation({ keyId: keyIdOverride ?? a.keyId, attestationObject: a.attestationObject, clientDataHash: CDH }, policy(p)) };
}
const reason = (o: Partial<AttestOptions> = {}, p: Partial<AttestationPolicy> = {}, keyId?: Buffer) => {
  const { r } = run(o, p, keyId);
  return r.ok ? 'ok' : r.reason;
};

describe('Pinned Apple App Attestation Root CA', () => {
  test('is the published root, by SHA-256 fingerprint, subject and validity', () => {
    const root = new X509Certificate(APPLE_APP_ATTEST_ROOT_CA_PEM);
    assert.equal(
      root.fingerprint256,
      '1C:B9:82:3B:A2:8B:A6:AD:2D:33:A0:06:94:1D:E2:AE:4F:51:3E:F1:D4:E8:31:B9:F7:E0:FA:7B:62:42:C9:32',
    );
    assert.match(root.subject, /CN=Apple App Attestation Root CA/);
    assert.ok(root.ca);
    assert.equal(Date.parse(root.validTo), Date.parse('2045-03-15T00:00:00Z'));
    assert.equal(appAttestRoots()[0].fingerprint256, root.fingerprint256);
  });
});

describe("Apple's published sample attestation (real Apple chain, public data)", () => {
  const att = Buffer.from(SAMPLE_ATTESTATION_B64, 'base64');
  const keyId = Buffer.from(SAMPLE_KEY_ID, 'base64');
  // The sample app passed the raw challenge bytes as clientDataHash (see the fixture header).
  const cdh = Buffer.from(SAMPLE_CHALLENGE, 'utf8');
  const samplePolicy = (over: Partial<AttestationPolicy> = {}): AttestationPolicy => ({
    appId: SAMPLE_APP_ID,
    allowDevelopment: false,
    validationCategories: new Set([1]),
    deployment: 'production',
    now: SAMPLE_NOW,
    ...over,
  });
  const verify = (over: Partial<AttestationPolicy> = {}, input: { keyId?: Buffer; att?: Buffer; cdh?: Buffer } = {}) =>
    verifyAttestation({ keyId: input.keyId ?? keyId, attestationObject: input.att ?? att, clientDataHash: input.cdh ?? cdh }, samplePolicy(over));

  test('verifies end to end against the pinned root with production policy', () => {
    const r = verify();
    assert.ok(r.ok, JSON.stringify(r));
    assert.equal(r.attestation.environment, 'production');
    assert.equal(r.attestation.validationCategory, 1); // h'01000000', 4-byte little-endian
    assert.equal(r.attestation.bundleVersion, '1');
    const spki = crypto.createPublicKey({ key: r.attestation.publicKeySpki, format: 'der', type: 'spki' });
    assert.equal(spki.asymmetricKeyDetails?.namedCurve, 'prime256v1');
  });
  test("intermediate values match Apple's guide (nonce, rpIdHash, keyId)", () => {
    const top = decodeCbor(att) as Map<string, unknown>;
    const authData = top.get('authData') as Buffer;
    const cred = ((top.get('attStmt') as Map<string, unknown>).get('x5c') as Buffer[])[0];
    const nonce = crypto.createHash('sha256').update(authData).update(cdh).digest();
    assert.equal(nonce.toString('base64'), SAMPLE_NONCE);
    const ext = certificateExtensionValue(cred, '1.2.840.113635.100.8.2');
    assert.ok(ext);
    assert.equal(Buffer.from(appAttestNonceFromExtension(ext)).toString('base64'), SAMPLE_NONCE);
    assert.equal(authData.subarray(0, 32).toString('base64'), SAMPLE_RP_ID_HASH);
    assert.equal(authData.subarray(55, 87).toString('base64'), SAMPLE_KEY_ID);
    const cert = new X509Certificate(cred);
    assert.equal(Date.parse(cert.validFrom), SAMPLE_VALID_FROM);
    assert.equal(Date.parse(cert.validTo), SAMPLE_VALID_TO);
  });
  test('production categories {2,4} refuse its category 1 (Sentinel rec. 2)', () => {
    assert.deepEqual(verify({ validationCategories: PRODUCTION_VALIDATION_CATEGORIES }), { ok: false, reason: 'validation_category' });
  });
  test('AeroDJ clientDataHash = SHA256(challenge) does not match a raw-bytes client', () => {
    assert.deepEqual(verify({}, { cdh: attestClientDataHash(SAMPLE_CHALLENGE) }), { ok: false, reason: 'nonce' });
  });
  test('wrong App ID prefix or bundle, wrong challenge, wrong keyId', () => {
    assert.deepEqual(verify({ appId: '1234567891.com.example.myapp' }), { ok: false, reason: 'rp_id' });
    assert.deepEqual(verify({ appId: '1234567890.com.aerodj.app' }), { ok: false, reason: 'rp_id' });
    assert.deepEqual(verify({}, { cdh: Buffer.from('example_server_challengf') }), { ok: false, reason: 'nonce' });
    const other = Buffer.from(keyId);
    other[0] ^= 1;
    assert.deepEqual(verify({}, { keyId: other }), { ok: false, reason: 'key_id' });
  });
  test('outside the credCert validity window', () => {
    assert.deepEqual(verify({ now: SAMPLE_VALID_FROM - 1000 }), { ok: false, reason: 'chain' });
    assert.deepEqual(verify({ now: SAMPLE_VALID_TO + 1000 }), { ok: false, reason: 'chain' });
    assert.ok(verify({ now: SAMPLE_VALID_TO }).ok);
  });
  test('a fake root instead of the pinned one does not verify it, and test roots are refused on production', () => {
    assert.deepEqual(verify({ deployment: 'nonproduction', roots: [CA.root] }), { ok: false, reason: 'chain' });
    assert.deepEqual(verify({ roots: appAttestRoots() }), { ok: false, reason: 'config' });
  });
  test('any flipped byte in authData is refused', () => {
    const top = decodeCbor(att) as Map<string, unknown>;
    const authData = top.get('authData') as Buffer;
    const start = att.indexOf(authData);
    for (const offset of [0, 31, 32, 33, 36, 37, 52, 53, 55, 86, 100, authData.length - 1]) {
      const copy = Buffer.from(att);
      copy[start + offset] ^= 0x01;
      const r = verify({}, { att: copy });
      assert.equal(r.ok, false, `offset ${offset}`);
    }
  });
});

describe('Fake-CA attestations: each check on its own', () => {
  test('a well-formed attestation verifies; SPKI is the credential key', () => {
    const { a, r } = run();
    assert.ok(r.ok, JSON.stringify(r));
    assert.equal(r.attestation.environment, 'production');
    assert.deepEqual(r.attestation.publicKeySpki, a.credKey.publicKey.export({ format: 'der', type: 'spki' }));
  });
  test('fmt must be apple-appattest', () => {
    assert.equal(reason({ fmt: 'packed' }), 'format');
    assert.equal(reason({ fmt: 1 }), 'format');
  });
  test('top-level map must be exactly fmt, attStmt, authData', () => {
    assert.equal(reason({ top: (p) => cmap(['fmt', p.fmt], ['attStmt', p.attStmt]) }), 'malformed');
    assert.equal(reason({ top: (p) => cmap(['fmt', p.fmt], ['attStmt', p.attStmt], ['authData', p.authData], ['x', 1]) }), 'malformed');
    assert.equal(reason({ top: (p) => cmap(['fmt', p.fmt], ['attStmt', p.attStmt], ['authdata', p.authData]) }), 'malformed');
    assert.equal(reason({ top: (p) => [p.fmt, p.attStmt, p.authData] }), 'malformed');
    assert.equal(reason({ top: (p) => cmap(['fmt', p.fmt], ['attStmt', p.attStmt], ['authData', 'text']) }), 'malformed');
  });
  test('attStmt: only x5c and receipt; x5c exactly [credCert, intermediate]', () => {
    assert.equal(reason({ attStmt: cmap(['x5c', []], ['alg', -7]) }), 'malformed');
    assert.equal(reason({ attStmt: cmap(['x5c', [Buffer.from('a')]], ['receipt', 'text']) }), 'malformed');
    assert.equal(reason({ x5c: [] }), 'chain');
    assert.equal(reason({ x5c: [CA.intermediateDer] }), 'chain');
    const a = makeAttestation(CA, { clientDataHash: CDH });
    assert.equal(reason({ x5c: [a.credCertDer, CA.intermediateDer, CA.rootDer] }), 'chain');
    assert.equal(reason({ attStmt: cmap(['x5c', 'nope']) }), 'chain');
    assert.equal(reason({ x5c: [Buffer.from('not a cert'), CA.intermediateDer] }), 'chain');
  });
  test('the chain must reach a pinned root: other roots, self-signed, wrong issuer, CA leaf, non-CA intermediate', () => {
    const other = makeAttestCa('Other');
    assert.equal(reason({}, { roots: [other.root] }), 'chain');
    // credCert signed by a key that is not the intermediate's.
    assert.equal(reason({ credIssuerKey: other.intermediateKey }), 'chain');
    assert.equal(reason({ credIssuerCn: 'Someone Else' }), 'chain');
    // Intermediate from another CA presented with our credCert.
    const a = makeAttestation(CA, { clientDataHash: CDH });
    assert.equal(reason({ x5c: [a.credCertDer, other.intermediateDer] }), 'chain');
    // Root itself in the intermediate slot: the leaf is not signed by it.
    assert.equal(reason({ x5c: [a.credCertDer, CA.rootDer] }), 'chain');
    assert.equal(reason({ credCa: true }), 'chain');
    // Intermediate without the CA flag.
    const inter = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
    const notCa = { ...CA, intermediateDer: makeCert({ cn: CA.intermediateCn, issuerCn: CA.rootCn, issuerKey: CA.rootKey, publicKey: inter.publicKey, ca: false, serial: 9 }), intermediateKey: inter.privateKey };
    const b = makeAttestation(notCa, { clientDataHash: CDH });
    assert.equal(verifyAttestation({ keyId: b.keyId, attestationObject: b.attestationObject, clientDataHash: CDH }, policy()).ok ? 'ok' : 'refused', 'refused');
  });
  test('an impostor chain with the pinned root\'s exact names but another key is refused', () => {
    // Same subject/issuer names as the pinned (test) root, so only the signature check
    // on the intermediate can tell them apart.
    const impostorRoot = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
    const inter = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
    const forged = {
      ...CA,
      intermediateDer: makeCert({ cn: CA.intermediateCn, issuerCn: CA.rootCn, issuerKey: impostorRoot.privateKey, publicKey: inter.publicKey, ca: true, serial: 7 }),
      intermediateKey: inter.privateKey,
    };
    const b = makeAttestation(forged, { clientDataHash: CDH });
    assert.deepEqual(verifyAttestation({ keyId: b.keyId, attestationObject: b.attestationObject, clientDataHash: CDH }, policy()), { ok: false, reason: 'chain' });
    // Control: the same construction signed by the real test root key verifies.
    const genuine = { ...forged, intermediateDer: makeCert({ cn: CA.intermediateCn, issuerCn: CA.rootCn, issuerKey: CA.rootKey, publicKey: inter.publicKey, ca: true, serial: 7 }) };
    const g = makeAttestation(genuine, { clientDataHash: CDH });
    assert.ok(verifyAttestation({ keyId: g.keyId, attestationObject: g.attestationObject, clientDataHash: CDH }, policy()).ok);
  });
  test('certificate validity is checked at now', () => {
    assert.equal(reason({ credNotAfter: new Date(NOW - 1000) }), 'chain');
    assert.equal(reason({ credNotBefore: new Date(NOW + 60_000) }), 'chain');
    assert.equal(reason({}, { now: Date.UTC(2041, 0, 1) }), 'chain');
  });
  test('the credential key must be P-256', () => {
    const k384 = crypto.generateKeyPairSync('ec', { namedCurve: 'secp384r1' });
    assert.equal(reason({ certPublicKey: k384.publicKey }), 'chain');
    // secp256k1 has 32-byte coordinates too, so only the curve name catches it.
    const k1 = crypto.generateKeyPairSync('ec', { namedCurve: 'secp256k1' });
    assert.equal(reason({ credKey: k1 }), 'chain');
  });
  test('nonce: wrong value, missing, duplicated, malformed extension', () => {
    assert.equal(reason({ nonce: Buffer.alloc(32, 7) }), 'nonce');
    assert.equal(reason({ nonce: null }), 'nonce');
    assert.equal(reason({ duplicateNonce: true }), 'malformed');
    assert.equal(reason({ nonceExtensionValue: enc.seq(enc.ctx(2, enc.octet(Buffer.alloc(32)))) }), 'malformed');
    assert.equal(reason({ nonceExtensionValue: enc.seq(enc.ctx(1, enc.octet(Buffer.alloc(31)))) }), 'malformed');
    assert.equal(reason({ nonceExtensionValue: enc.octet(Buffer.alloc(32)) }), 'malformed');
    assert.equal(reason({ nonceExtensionValue: Buffer.concat([nonceExtension(Buffer.alloc(32)), Buffer.from([0])]) }), 'malformed');
    // A different challenge than the one the app attested.
    const a = makeAttestation(CA, { clientDataHash: CDH });
    const r = verifyAttestation({ keyId: a.keyId, attestationObject: a.attestationObject, clientDataHash: attestClientDataHash('other') }, policy());
    assert.deepEqual(r, { ok: false, reason: 'nonce' });
  });
  test('keyId must be SHA256 of the credCert public key', () => {
    const wrong = crypto.createHash('sha256').update('someone else').digest();
    // credentialId is set to the same wrong id, so only the key-id check can catch it.
    assert.equal(reason({ credentialId: wrong }, {}, wrong), 'key_id');
  });
  test('rpIdHash must be SHA256(App ID prefix . bundle)', () => {
    assert.equal(reason({ appId: 'ABCDE12345.com.aerodj.other' }), 'rp_id');
    assert.equal(reason({ appId: 'ZZZZZ12345.com.aerodj.app' }), 'rp_id');
    assert.equal(reason({ appId: 'com.aerodj.app' }), 'rp_id');
  });
  test('the AT flag must be set; ED set without extensions is refused', () => {
    assert.equal(reason({ flags: 0x00 }), 'flags');
    assert.equal(reason({ flags: 0x01 }), 'flags');
    assert.equal(reason({ flags: 0xc0 }), 'extensions');
    assert.equal(reason({ flags: 0x41 }), 'ok');
  });
  test('counter must be 0', () => {
    assert.equal(reason({ counter: 1 }), 'counter');
    assert.equal(reason({ counter: 0xffffffff }), 'counter');
  });
  test('aaguid: production always; development only when the policy allows it', () => {
    assert.equal(reason({ aaguid: AAGUID_DEV }), 'aaguid');
    const { r } = run({ aaguid: AAGUID_DEV }, { allowDevelopment: true });
    assert.ok(r.ok);
    assert.equal(r.attestation.environment, 'development');
    assert.equal(reason({ aaguid: Buffer.alloc(16) }, { allowDevelopment: true }), 'aaguid');
    assert.equal(reason({ aaguid: Buffer.concat([Buffer.from('appattest'), Buffer.alloc(6), Buffer.from([1])]) }), 'aaguid');
    assert.deepEqual(AAGUID_PRODUCTION, AAGUID_PROD);
    assert.deepEqual(AAGUID_DEVELOPMENT, AAGUID_DEV);
  });
  test('credentialId must equal keyId and be 32 bytes', () => {
    const a = makeAttestation(CA, { clientDataHash: CDH });
    const other = Buffer.from(a.keyId);
    other[31] ^= 0xff;
    const k = a.credKey;
    assert.equal(reason({ credKey: k, credentialId: other }, {}, a.keyId), 'credential_id');
    assert.equal(reason({ credKey: k, credentialId: Buffer.concat([a.keyId, Buffer.alloc(1)]) }, {}, a.keyId), 'credential_id');
    assert.equal(reason({ credKey: k, credentialId: a.keyId.subarray(0, 31) }, {}, a.keyId), 'credential_id');
  });
  test('COSE key must be EC2 P-256 ES256 with the credCert point, exactly five entries', () => {
    const a = makeAttestation(CA, { clientDataHash: CDH });
    const jwk = a.credKey.publicKey.export({ format: 'jwk' });
    const x = Buffer.from(jwk.x as string, 'base64url');
    const y = Buffer.from(jwk.y as string, 'base64url');
    const k = a.credKey;
    const other = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' }).publicKey.export({ format: 'jwk' });
    const ox = Buffer.from(other.x as string, 'base64url');
    assert.equal(reason({ credKey: k, cose: cmap([1, 2], [3, -7], [-1, 1], [-2, ox], [-3, y]) }), 'cose_key');
    assert.equal(reason({ credKey: k, cose: cmap([1, 3], [3, -7], [-1, 1], [-2, x], [-3, y]) }), 'cose_key');
    assert.equal(reason({ credKey: k, cose: cmap([1, 2], [3, -8], [-1, 1], [-2, x], [-3, y]) }), 'cose_key');
    assert.equal(reason({ credKey: k, cose: cmap([1, 2], [3, -7], [-1, 2], [-2, x], [-3, y]) }), 'cose_key');
    assert.equal(reason({ credKey: k, cose: cmap([1, 2], [3, -7], [-1, 1], [-2, x]) }), 'cose_key');
    assert.equal(reason({ credKey: k, cose: cmap([1, 2], [3, -7], [-1, 1], [-2, x], [-3, y], [-4, 0]) }), 'cose_key');
    assert.equal(reason({ credKey: k, cose: [1, 2] }), 'cose_key');
    assert.equal(reason({ credKey: k, cose: cmap([1, 2], [3, -7], [-1, 1], [-2, x], [-3, y]) }), 'ok');
  });
  test('iOS 27+ extensions: validation category allowlist and format', () => {
    const ext = (cat: number | Buffer, version: unknown = '1.0') =>
      cbor(cmap(['apple_bundle_version_01', version as string], ['apple_validation_category_01', cat]));
    const le = (n: number) => {
      const b = Buffer.alloc(4);
      b.writeUInt32LE(n);
      return b;
    };
    for (const c of [2, 4]) {
      const { r } = run({ extensions: ext(le(c)) });
      assert.ok(r.ok, `category ${c}`);
      assert.equal(r.attestation.validationCategory, c);
      assert.equal(r.attestation.bundleVersion, '1.0');
      assert.equal(reason({ extensions: ext(c), flags: 0xc0 }), 'ok');
    }
    for (const c of [0, 1, 3, 5, 0x02000000]) assert.equal(reason({ extensions: ext(le(c)) }), 'validation_category', `category ${c}`);
    assert.equal(reason({ extensions: ext(le(3)) }, { allowDevelopment: true, validationCategories: DEVELOPMENT_VALIDATION_CATEGORIES }), 'ok');
    assert.equal(reason({ extensions: ext(Buffer.from([2, 0, 0])) }), 'extensions');
    assert.equal(reason({ extensions: ext('2' as unknown as number) }), 'extensions');
    assert.equal(reason({ extensions: ext(le(2), 5) }), 'extensions');
    assert.equal(reason({ extensions: ext(le(2), '') }), 'extensions');
    assert.equal(reason({ extensions: Buffer.from([0xa1]) }), 'extensions');
    assert.equal(reason({ extensions: cbor([1]) }), 'extensions');
    assert.equal(reason({ extensions: Buffer.concat([cbor(cmap(['a', 1])), Buffer.from([0])]) }), 'extensions');
    // Absent category (iOS < 27): accepted.
    assert.equal(reason({ extensions: cbor(cmap(['apple_bundle_version_01', '1.0'])) }), 'ok');
  });
  test('input and policy guards', () => {
    const a = makeAttestation(CA, { clientDataHash: CDH });
    const v = (input: Partial<{ keyId: Buffer; attestationObject: Buffer; clientDataHash: Buffer }>, p: Partial<AttestationPolicy> = {}) =>
      verifyAttestation({ keyId: a.keyId, attestationObject: a.attestationObject, clientDataHash: CDH, ...input }, policy(p));
    assert.deepEqual(v({ keyId: a.keyId.subarray(1) }), { ok: false, reason: 'malformed' });
    assert.deepEqual(v({ clientDataHash: Buffer.alloc(0) }), { ok: false, reason: 'malformed' });
    assert.deepEqual(v({ attestationObject: Buffer.alloc(MAX_ATTESTATION_BYTES + 1) }), { ok: false, reason: 'malformed' });
    assert.deepEqual(v({ attestationObject: Buffer.from([0xff]) }), { ok: false, reason: 'malformed' });
    assert.deepEqual(v({}, { deployment: 'production' }), { ok: false, reason: 'config' });
    assert.deepEqual(v({}, { roots: [] }), { ok: false, reason: 'config' });
    assert.deepEqual(v({}, { appId: 'com.aerodj.app' }), { ok: false, reason: 'config' });
    assert.deepEqual(v({}, { appId: 'abcde12345.com.aerodj.app' }), { ok: false, reason: 'config' });
    // Without injected roots the pinned Apple root applies, so a fake chain fails.
    assert.deepEqual(v({}, { roots: undefined, deployment: 'production' }), { ok: false, reason: 'chain' });
  });
  test('truncated authData is refused without throwing', () => {
    for (const cut of [0, 36, 54, 60, 86, 87, 100]) {
      const r = run({ top: (p) => cmap(['fmt', p.fmt], ['attStmt', p.attStmt], ['authData', p.authData.subarray(0, cut)]) }).r;
      assert.equal(r.ok, false, `cut ${cut}`);
    }
  });
});

describe('DER helpers for App Attest', () => {
  test('nonce extension parser accepts exactly SEQUENCE{[1]{OCTET STRING(32)}}', () => {
    const n = Buffer.alloc(32, 5);
    assert.deepEqual(Buffer.from(appAttestNonceFromExtension(nonceExtension(n))), n);
    assert.throws(() => appAttestNonceFromExtension(enc.seq(enc.ctx(1, enc.octet(n)), enc.null())), DerError);
    assert.throws(() => appAttestNonceFromExtension(enc.seq(enc.ctx(1, Buffer.concat([enc.octet(n), enc.null()])))), DerError);
    assert.throws(() => appAttestNonceFromExtension(enc.seq()), DerError);
  });
  test('certificateExtensionValue: absent, present, duplicate', () => {
    const k = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
    const base = { cn: 'x', issuerCn: 'x', issuerKey: k.privateKey, publicKey: k.publicKey, ca: false };
    assert.equal(certificateExtensionValue(makeCert(base), '1.2.3'), undefined);
    const one = makeCert({ ...base, extensions: [{ oid: '1.2.3', value: enc.null() }] });
    assert.deepEqual(Buffer.from(certificateExtensionValue(one, '1.2.3')!), enc.null());
    const two = makeCert({ ...base, extensions: [{ oid: '1.2.3', value: enc.null() }, { oid: '1.2.3', value: enc.null() }] });
    assert.throws(() => certificateExtensionValue(two, '1.2.3'), DerError);
  });
});
