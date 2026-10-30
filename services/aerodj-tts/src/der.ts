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
