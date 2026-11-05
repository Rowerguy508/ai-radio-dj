/**
 * Test-only X.509 + JWS factory: a generated fake CA (root, intermediate, leaf)
 * shaped like Apple's App Store signing chain, with ECDSA P-256 keys made per
 * run. Nothing here is a real Apple key or certificate.
 */
import crypto, { type KeyObject } from 'node:crypto';

/** Minimal DER encoder (test-only). */
export const enc = {
  tlv(tag: number, body: Buffer): Buffer {
    const n = body.length;
    const len =
      n < 0x80 ? Buffer.from([n]) : n < 0x100 ? Buffer.from([0x81, n]) : Buffer.from([0x82, n >> 8, n & 0xff]);
    return Buffer.concat([Buffer.from([tag]), len, body]);
  },
  seq: (...items: Buffer[]) => enc.tlv(0x30, Buffer.concat(items)),
  set: (...items: Buffer[]) => enc.tlv(0x31, Buffer.concat(items)),
  int(n: number): Buffer {
    const bytes: number[] = [];
    let v = n;
    do {
      bytes.unshift(v & 0xff);
      v = Math.floor(v / 256);
    } while (v > 0);
    if (bytes[0] & 0x80) bytes.unshift(0);
    return enc.tlv(0x02, Buffer.from(bytes));
  },
  oid(dotted: string): Buffer {
    const p = dotted.split('.').map(Number);
    const out: number[] = [p[0] * 40 + p[1]];
    for (const v of p.slice(2)) {
      const chunk: number[] = [v & 0x7f];
      let x = Math.floor(v / 128);
      while (x > 0) {
        chunk.unshift((x & 0x7f) | 0x80);
        x = Math.floor(x / 128);
      }
      out.push(...chunk);
    }
    return enc.tlv(0x06, Buffer.from(out));
  },
  utf8: (s: string) => enc.tlv(0x0c, Buffer.from(s, 'utf8')),
  time(d: Date): Buffer {
    const s = d.toISOString().replace(/[-:T]/g, '').slice(0, 14) + 'Z';
    return enc.tlv(0x18, Buffer.from(s, 'ascii')); // GeneralizedTime
  },
  bits: (b: Buffer) => enc.tlv(0x03, Buffer.concat([Buffer.from([0]), b])),
  octet: (b: Buffer) => enc.tlv(0x04, b),
  bool: (v: boolean) => enc.tlv(0x01, Buffer.from([v ? 0xff : 0])),
  null: () => Buffer.from([0x05, 0x00]),
  ctx: (n: number, b: Buffer) => enc.tlv(0xa0 + n, b),
};

const ECDSA_SHA256 = '1.2.840.10045.4.3.2';

export interface CertSpec {
  cn: string;
  issuerCn: string;
  issuerKey: KeyObject;
  publicKey: KeyObject;
  ca: boolean;
  markerOids?: string[];
  /** Extra extensions: `value` is the extnValue contents (DER), wrapped in an OCTET STRING here. */
  extensions?: { oid: string; value: Buffer }[];
  notBefore?: Date;
  notAfter?: Date;
  serial?: number;
}

const name = (cn: string) => enc.seq(enc.set(enc.seq(enc.oid('2.5.4.3'), enc.utf8(cn))));

export function makeCert(spec: CertSpec): Buffer {
  const exts = [
    enc.seq(enc.oid('2.5.29.19'), enc.bool(true), enc.octet(spec.ca ? enc.seq(enc.bool(true)) : enc.seq())),
    ...(spec.markerOids ?? []).map((oid) => enc.seq(enc.oid(oid), enc.octet(enc.null()))),
    ...(spec.extensions ?? []).map((e) => enc.seq(enc.oid(e.oid), enc.octet(e.value))),
  ];
  const tbs = enc.seq(
    enc.ctx(0, enc.int(2)),
    enc.int(spec.serial ?? 1),
    enc.seq(enc.oid(ECDSA_SHA256)),
    name(spec.issuerCn),
    enc.seq(enc.time(spec.notBefore ?? new Date('2020-01-01T00:00:00Z')), enc.time(spec.notAfter ?? new Date('2040-01-01T00:00:00Z'))),
    name(spec.cn),
    spec.publicKey.export({ type: 'spki', format: 'der' }),
    enc.ctx(3, enc.seq(...exts)),
  );
  const sig = crypto.sign('sha256', tbs, spec.issuerKey);
  return enc.seq(tbs, enc.seq(enc.oid(ECDSA_SHA256)), enc.bits(sig));
}

export const LEAF_OID = '1.2.840.113635.100.6.11.1';
export const INTERMEDIATE_OID = '1.2.840.113635.100.6.2.1';

export interface FakeChain {
  rootDer: Buffer;
  intermediateDer: Buffer;
  leafDer: Buffer;
  leafKey: KeyObject;
  /** Test-only: lets a test mint its own certs under this intermediate or root. */
  intermediateKey: KeyObject;
  rootKey: KeyObject;
  rootCn: string;
  intermediateCn: string;
}

const keyPair = () => crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });

export interface ChainOptions {
  leafMarker?: boolean;
  intermediateMarker?: boolean;
  leafNotAfter?: Date;
  leafNotBefore?: Date;
}

export function makeChain(label = 'Fake', o: ChainOptions = {}): FakeChain {
  const root = keyPair();
  const inter = keyPair();
  const leaf = keyPair();
  const rootCn = `${label} Root CA - G3`;
  const interCn = `${label} WWDR Intermediate`;
  const rootDer = makeCert({ cn: rootCn, issuerCn: rootCn, issuerKey: root.privateKey, publicKey: root.publicKey, ca: true });
  const intermediateDer = makeCert({
    cn: interCn,
    issuerCn: rootCn,
    issuerKey: root.privateKey,
    publicKey: inter.publicKey,
    ca: true,
    markerOids: o.intermediateMarker === false ? [] : [INTERMEDIATE_OID],
    serial: 2,
  });
  const leafDer = makeCert({
    cn: `${label} StoreKit Signing`,
    issuerCn: interCn,
    issuerKey: inter.privateKey,
    publicKey: leaf.publicKey,
    ca: false,
    markerOids: o.leafMarker === false ? [] : [LEAF_OID],
    notAfter: o.leafNotAfter,
    notBefore: o.leafNotBefore,
    serial: 3,
  });
  return {
    rootDer,
    intermediateDer,
    leafDer,
    leafKey: leaf.privateKey,
    intermediateKey: inter.privateKey,
    rootKey: root.privateKey,
    rootCn,
    intermediateCn: interCn,
  };
}

export function signJws(
  payload: Record<string, unknown>,
  x5c: Buffer[],
  key: KeyObject,
  header: Record<string, unknown> = {},
): string {
  const h = Buffer.from(JSON.stringify({ alg: 'ES256', x5c: x5c.map((c) => c.toString('base64')), ...header })).toString('base64url');
  const p = Buffer.from(JSON.stringify(payload)).toString('base64url');
  const sig = crypto.sign('sha256', Buffer.from(`${h}.${p}`), { key, dsaEncoding: 'ieee-p1363' });
  return `${h}.${p}.${sig.toString('base64url')}`;
}
