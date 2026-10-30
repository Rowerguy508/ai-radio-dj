/**
 * Minimal, strict DER reader: just enough to list the extension OIDs of an
 * X.509 certificate that `node:crypto` has already parsed and verified.
 * Definite lengths only, bounded depth, no trailing bytes.
 */

export class DerError extends Error {}

interface Tlv {
  tag: number;
  start: number; // first content byte
  end: number; // one past the last content byte
}

function readTlv(buf: Uint8Array, offset: number, limit: number): Tlv {
  if (offset + 2 > limit) throw new DerError('truncated');
  const tag = buf[offset];
  if ((tag & 0x1f) === 0x1f) throw new DerError('high tag');
  let len = buf[offset + 1];
  let pos = offset + 2;
  if (len & 0x80) {
    const n = len & 0x7f;
    if (n === 0 || n > 3) throw new DerError('length');
    if (pos + n > limit) throw new DerError('truncated');
    len = 0;
    for (let i = 0; i < n; i += 1) len = (len << 8) | buf[pos + i];
    pos += n;
    if (len < 0x80) throw new DerError('non-minimal length');
  }
  if (pos + len > limit) throw new DerError('truncated');
  return { tag, start: pos, end: pos + len };
}

function children(buf: Uint8Array, parent: Tlv): Tlv[] {
  const out: Tlv[] = [];
  let pos = parent.start;
  while (pos < parent.end) {
    const child = readTlv(buf, pos, parent.end);
    out.push(child);
    pos = child.end;
    if (out.length > 64) throw new DerError('too many items');
  }
  return out;
}

export function decodeOid(bytes: Uint8Array): string {
  if (bytes.length === 0 || bytes.length > 64) throw new DerError('oid');
  const parts: number[] = [];
  let value = 0;
  for (let i = 0; i < bytes.length; i += 1) {
    value = value * 128 + (bytes[i] & 0x7f);
    if (value > Number.MAX_SAFE_INTEGER) throw new DerError('oid');
    if ((bytes[i] & 0x80) === 0) {
      if (parts.length === 0) {
        const first = value < 80 ? Math.floor(value / 40) : 2;
        parts.push(first, value - first * 40);
      } else parts.push(value);
      value = 0;
    } else if (i === bytes.length - 1) throw new DerError('oid');
  }
  return parts.join('.');
}

/** Extension OIDs of a DER certificate (empty when it has no extensions). */
export function certificateExtensionOids(der: Uint8Array): string[] {
  const cert = readTlv(der, 0, der.length);
  if (cert.tag !== 0x30 || cert.end !== der.length) throw new DerError('certificate');
  const [tbs] = children(der, cert);
  if (!tbs || tbs.tag !== 0x30) throw new DerError('tbs');
  const ext = children(der, tbs).find((item) => item.tag === 0xa3);
  if (!ext) return [];
  const [list] = children(der, ext);
  if (!list || list.tag !== 0x30) throw new DerError('extensions');
  return children(der, list).map((extension) => {
    const [oid] = children(der, extension);
    if (!oid || oid.tag !== 0x06) throw new DerError('extension oid');
    return decodeOid(der.subarray(oid.start, oid.end));
  });
}

/** Every extension of a DER certificate as `{ oid, value }` (value = extnValue contents). */
function certificateExtensions(der: Uint8Array): { oid: string; value: Uint8Array }[] {
  const cert = readTlv(der, 0, der.length);
  if (cert.tag !== 0x30 || cert.end !== der.length) throw new DerError('certificate');
  const [tbs] = children(der, cert);
  if (!tbs || tbs.tag !== 0x30) throw new DerError('tbs');
  const ext = children(der, tbs).find((item) => item.tag === 0xa3);
  if (!ext) return [];
  const [list] = children(der, ext);
  if (!list || list.tag !== 0x30) throw new DerError('extensions');
  return children(der, list).map((extension) => {
    if (extension.tag !== 0x30) throw new DerError('extension');
    const parts = children(der, extension);
    const [oid] = parts;
    if (!oid || oid.tag !== 0x06) throw new DerError('extension oid');
    // extnID, [critical BOOLEAN], extnValue OCTET STRING.
    const value = parts[parts.length - 1];
    if (parts.length < 2 || parts.length > 3 || value.tag !== 0x04) throw new DerError('extension value');
    if (parts.length === 3 && parts[1].tag !== 0x01) throw new DerError('extension critical');
    return { oid: decodeOid(der.subarray(oid.start, oid.end)), value: der.subarray(value.start, value.end) };
  });
}

/**
 * The extnValue contents of the extension `oid`, or undefined when absent.
 * A certificate carrying the same extension twice is refused (RFC 5280 §4.2).
 */
export function certificateExtensionValue(der: Uint8Array, oid: string): Uint8Array | undefined {
  const matches = certificateExtensions(der).filter((e) => e.oid === oid);
  if (matches.length > 1) throw new DerError('duplicate extension');
  return matches[0]?.value;
}

/**
 * App Attest nonce extension (OID 1.2.840.113635.100.8.2): a DER
 * `SEQUENCE { [1] EXPLICIT OCTET STRING }`. Returns the single 32-byte octet
 * string; anything else (extra items, other tags, trailing bytes) throws.
 */
export function appAttestNonceFromExtension(value: Uint8Array): Uint8Array {
  const seq = readTlv(value, 0, value.length);
  if (seq.tag !== 0x30 || seq.end !== value.length) throw new DerError('nonce sequence');
  const items = children(value, seq);
  if (items.length !== 1 || items[0].tag !== 0xa1) throw new DerError('nonce tag');
  const inner = children(value, items[0]);
  if (inner.length !== 1 || inner[0].tag !== 0x04) throw new DerError('nonce octet string');
  const nonce = value.subarray(inner[0].start, inner[0].end);
  if (nonce.length !== 32) throw new DerError('nonce length');
  return nonce;
}
