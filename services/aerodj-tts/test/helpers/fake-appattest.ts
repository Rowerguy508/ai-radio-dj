/**
 * Test-only App Attest factory: a generated fake "App Attestation" CA chain
 * and attestation objects built exactly like Apple's (CBOR attestation object,
 * authData, COSE key, nonce extension), with per-run ECDSA keys. Nothing here
 * is a real Apple key, certificate or device attestation. Every field can be
 * overridden so each verifier check can be broken on its own.
 */
import crypto, { X509Certificate, type KeyObject } from 'node:crypto';
import { enc, makeCert } from './fake-ca.js';

// ---- Minimal CBOR encoder (definite lengths, shortest form unless a test asks otherwise).
export type Cbor = number | string | Buffer | Cbor[] | CborMap;
/** Map as an ordered entry list, so tests can write duplicate keys on purpose. */
export class CborMap {
  constructor(readonly entries: [Cbor, Cbor][]) {}
}
export const cmap = (...entries: [Cbor, Cbor][]) => new CborMap(entries);

function head(major: number, n: number): Buffer {
  const m = major << 5;
  if (n < 24) return Buffer.from([m | n]);
  if (n < 0x100) return Buffer.from([m | 24, n]);
  if (n < 0x10000) return Buffer.from([m | 25, n >> 8, n & 0xff]);
  if (n < 0x100000000) {
    const b = Buffer.alloc(5);
    b[0] = m | 26;
    b.writeUInt32BE(n, 1);
    return b;
  }
  const b = Buffer.alloc(9);
  b[0] = m | 27;
  b.writeBigUInt64BE(BigInt(n), 1);
  return b;
}

export function cbor(v: Cbor): Buffer {
  if (typeof v === 'number') return v >= 0 ? head(0, v) : head(1, -1 - v);
  if (typeof v === 'string') {
    const b = Buffer.from(v, 'utf8');
    return Buffer.concat([head(3, b.length), b]);
  }
  if (Buffer.isBuffer(v)) return Buffer.concat([head(2, v.length), v]);
  if (Array.isArray(v)) return Buffer.concat([head(4, v.length), ...v.map(cbor)]);
  return Buffer.concat([head(5, v.entries.length), ...v.entries.flatMap(([k, x]) => [cbor(k), cbor(x)])]);
}

// ---- Fake App Attestation CA.
export const NONCE_OID = '1.2.840.113635.100.8.2';
export const TEST_APP_ID = 'ABCDE12345.com.aerodj.app';
export const TEST_APP_ID_PREFIX = 'ABCDE12345';
export const AAGUID_PROD = Buffer.concat([Buffer.from('appattest'), Buffer.alloc(7)]);
export const AAGUID_DEV = Buffer.from('appattestdevelop');

const p256 = () => crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });

export interface FakeAttestCa {
  rootDer: Buffer;
  root: X509Certificate;
  rootKey: KeyObject;
  rootCn: string;
  intermediateDer: Buffer;
  intermediateKey: KeyObject;
  intermediateCn: string;
}

export function makeAttestCa(label = 'Fake'): FakeAttestCa {
  const root = p256();
  const inter = p256();
  const rootCn = `${label} App Attestation Root CA`;
  const intermediateCn = `${label} App Attestation CA 1`;
  const rootDer = makeCert({ cn: rootCn, issuerCn: rootCn, issuerKey: root.privateKey, publicKey: root.publicKey, ca: true });
  const intermediateDer = makeCert({
    cn: intermediateCn,
    issuerCn: rootCn,
    issuerKey: root.privateKey,
    publicKey: inter.publicKey,
    ca: true,
    serial: 2,
  });
  return {
    rootDer,
    root: new X509Certificate(rootDer),
    rootKey: root.privateKey,
    rootCn,
    intermediateDer,
    intermediateKey: inter.privateKey,
    intermediateCn,
  };
}

export const nonceExtension = (nonce: Buffer) => enc.seq(enc.ctx(1, enc.octet(nonce)));

export function uncompressedPoint(key: KeyObject): { point: Buffer; x: Buffer; y: Buffer } {
  const jwk = key.export({ format: 'jwk' });
  const x = Buffer.from(jwk.x as string, 'base64url');
  const y = Buffer.from(jwk.y as string, 'base64url');
  return { point: Buffer.concat([Buffer.from([4]), x, y]), x, y };
}

export interface AttestOptions {
  clientDataHash: Buffer;
  appId?: string;
  flags?: number;
  counter?: number;
  aaguid?: Buffer;
  /** Override credentialId bytes (default keyId). */
  credentialId?: Buffer;
  /** Override the COSE key map (default the credential key). */
  cose?: Cbor;
  /** Raw bytes appended after the COSE key (the iOS 27+ extensions map). */
  extensions?: Buffer;
  /** Override the nonce in the cert (default SHA256(authData ‖ clientDataHash)); null omits the extension. */
  nonce?: Buffer | null;
  /** Override the whole nonce extension value. */
  nonceExtensionValue?: Buffer;
  /** Nonce extension twice. */
  duplicateNonce?: boolean;
  credCa?: boolean;
  credKey?: { publicKey: KeyObject; privateKey: KeyObject };
  /** Subject key in the cert, if different from the credential key in authData. */
  certPublicKey?: KeyObject;
  credNotBefore?: Date;
  credNotAfter?: Date;
  /** Sign credCert with this key instead of the intermediate's. */
  credIssuerKey?: KeyObject;
  credIssuerCn?: string;
  x5c?: Buffer[];
  fmt?: Cbor;
  /** Replace the attStmt map. */
  attStmt?: Cbor;
  /** Replace the top-level map. */
  top?: (parts: { fmt: Cbor; attStmt: Cbor; authData: Buffer }) => Cbor;
}

export interface FakeAttestation {
  attestationObject: Buffer;
  keyId: Buffer;
  authData: Buffer;
  credCertDer: Buffer;
  credKey: { publicKey: KeyObject; privateKey: KeyObject };
}

export function makeAttestation(ca: FakeAttestCa, o: AttestOptions): FakeAttestation {
  const credKey = o.credKey ?? p256();
  const { point, x, y } = uncompressedPoint(credKey.publicKey);
  const keyId = crypto.createHash('sha256').update(point).digest();
  const counter = Buffer.alloc(4);
  counter.writeUInt32BE(o.counter ?? 0);
  const credentialId = o.credentialId ?? keyId;
  const idLen = Buffer.alloc(2);
  idLen.writeUInt16BE(credentialId.length);
  const cose = o.cose ?? cmap([1, 2], [3, -7], [-1, 1], [-2, x], [-3, y]);
  const authData = Buffer.concat([
    crypto.createHash('sha256').update(o.appId ?? TEST_APP_ID).digest(),
    Buffer.from([o.flags ?? 0x40]),
    counter,
    o.aaguid ?? AAGUID_PROD,
    idLen,
    credentialId,
    cbor(cose),
    o.extensions ?? Buffer.alloc(0),
  ]);
  const nonce = o.nonce === undefined ? crypto.createHash('sha256').update(authData).update(o.clientDataHash).digest() : o.nonce;
  const extValue = o.nonceExtensionValue ?? (nonce ? nonceExtension(nonce) : undefined);
  const extensions = extValue
    ? [{ oid: NONCE_OID, value: extValue }, ...(o.duplicateNonce ? [{ oid: NONCE_OID, value: extValue }] : [])]
    : [];
  const credCertDer = makeCert({
    cn: keyId.toString('hex'),
    issuerCn: o.credIssuerCn ?? ca.intermediateCn,
    issuerKey: o.credIssuerKey ?? ca.intermediateKey,
    publicKey: o.certPublicKey ?? credKey.publicKey,
    ca: o.credCa ?? false,
    extensions,
    notBefore: o.credNotBefore,
    notAfter: o.credNotAfter,
    serial: 3,
  });
  const fmt = o.fmt ?? 'apple-appattest';
  const attStmt = o.attStmt ?? cmap(['x5c', o.x5c ?? [credCertDer, ca.intermediateDer]], ['receipt', Buffer.from('fake receipt')]);
  const top = o.top ? o.top({ fmt, attStmt, authData }) : cmap(['fmt', fmt], ['attStmt', attStmt], ['authData', authData]);
  return { attestationObject: cbor(top), keyId, authData, credCertDer, credKey };
}
