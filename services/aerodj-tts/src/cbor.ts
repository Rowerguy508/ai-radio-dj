/**
 * Minimal, strict CBOR (RFC 8949) decoder for App Attest attestation objects,
 * COSE keys and authenticator-data extensions (#233 note §9 PR 3, Fry #246
 * rec. 5). Pure data: no tags, no floats, no simple values, no `eval`, no
 * dynamic decoding, no object prototypes (maps decode to `Map`).
 *
 * Limits (each violation throws `CborError`):
 * - definite lengths only (indefinite-length items are refused);
 * - shortest-form heads only (a length or integer must use the smallest encoding);
 * - nesting depth at most `maxDepth` containers (default 4);
 * - at most `maxItems` entries per array or map (default 16);
 * - total input at most `maxBytes` (default 16 KiB, the register body cap);
 * - integers must be safe JS integers;
 * - text must be valid UTF-8;
 * - map keys must be text or integers, with no duplicates;
 * - `decodeCbor` refuses trailing bytes.
 */

export class CborError extends Error {}

export type CborValue = number | string | Buffer | CborValue[] | Map<string | number, CborValue>;

export interface CborLimits {
  maxDepth?: number;
  maxItems?: number;
  maxBytes?: number;
}

const DEFAULTS = { maxDepth: 4, maxItems: 16, maxBytes: 16 * 1024 } as const;
const UTF8 = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true });

interface Cursor {
  buf: Buffer;
  pos: number;
  maxDepth: number;
  maxItems: number;
}

function need(c: Cursor, n: number): void {
  if (n < 0 || c.pos + n > c.buf.length) throw new CborError('truncated');
}

/** Reads the argument of a head; enforces shortest form and safe-integer range. */
function readArgument(c: Cursor, info: number): number {
  if (info < 24) return info;
  let value: number;
  switch (info) {
    case 24:
      need(c, 1);
      value = c.buf[c.pos];
      c.pos += 1;
      if (value < 24) throw new CborError('non-minimal');
      return value;
    case 25:
      need(c, 2);
      value = c.buf.readUInt16BE(c.pos);
      c.pos += 2;
      if (value <= 0xff) throw new CborError('non-minimal');
      return value;
    case 26:
      need(c, 4);
      value = c.buf.readUInt32BE(c.pos);
      c.pos += 4;
      if (value <= 0xffff) throw new CborError('non-minimal');
      return value;
    case 27: {
      need(c, 8);
      const big = c.buf.readBigUInt64BE(c.pos);
      c.pos += 8;
      if (big <= 0xffffffffn) throw new CborError('non-minimal');
      if (big > BigInt(Number.MAX_SAFE_INTEGER)) throw new CborError('integer range');
      return Number(big);
    }
    default:
      // 28-30 reserved, 31 indefinite length.
      throw new CborError(info === 31 ? 'indefinite length' : 'reserved');
  }
}

function readItem(c: Cursor, depth: number): CborValue {
  need(c, 1);
  const head = c.buf[c.pos];
  c.pos += 1;
  const major = head >> 5;
  const info = head & 0x1f;
  switch (major) {
    case 0:
      return readArgument(c, info);
    case 1: {
      const n = readArgument(c, info);
      if (n >= Number.MAX_SAFE_INTEGER) throw new CborError('integer range');
      return -1 - n;
    }
    case 2: {
      const len = readArgument(c, info);
      need(c, len);
      const out = Buffer.from(c.buf.subarray(c.pos, c.pos + len));
      c.pos += len;
      return out;
    }
    case 3: {
      const len = readArgument(c, info);
      need(c, len);
      let text: string;
      try {
        text = UTF8.decode(c.buf.subarray(c.pos, c.pos + len));
      } catch {
        throw new CborError('utf8');
      }
      c.pos += len;
      return text;
    }
    case 4: {
      if (depth >= c.maxDepth) throw new CborError('depth');
      const len = readArgument(c, info);
      if (len > c.maxItems) throw new CborError('too many items');
      const out: CborValue[] = [];
      for (let i = 0; i < len; i += 1) out.push(readItem(c, depth + 1));
      return out;
    }
    case 5: {
      if (depth >= c.maxDepth) throw new CborError('depth');
      const len = readArgument(c, info);
      if (len > c.maxItems) throw new CborError('too many items');
      const out = new Map<string | number, CborValue>();
      for (let i = 0; i < len; i += 1) {
        const key = readItem(c, depth + 1);
        if (typeof key !== 'string' && typeof key !== 'number') throw new CborError('map key type');
        if (out.has(key)) throw new CborError('duplicate map key');
        out.set(key, readItem(c, depth + 1));
      }
      return out;
    }
    default:
      // 6 = tags, 7 = floats and simple values: not used by App Attest.
      throw new CborError(major === 6 ? 'tag' : 'simple/float');
  }
}

function cursor(bytes: Uint8Array, limits: CborLimits): Cursor {
  const maxBytes = limits.maxBytes ?? DEFAULTS.maxBytes;
  if (!(bytes instanceof Uint8Array)) throw new CborError('input');
  if (bytes.length === 0) throw new CborError('empty');
  if (bytes.length > maxBytes) throw new CborError('too large');
  return {
    buf: Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength),
    pos: 0,
    maxDepth: limits.maxDepth ?? DEFAULTS.maxDepth,
    maxItems: limits.maxItems ?? DEFAULTS.maxItems,
  };
}

/** Decodes exactly one item that spans all of `bytes` (trailing bytes are refused). */
export function decodeCbor(bytes: Uint8Array, limits: CborLimits = {}): CborValue {
  const c = cursor(bytes, limits);
  const value = readItem(c, 0);
  if (c.pos !== c.buf.length) throw new CborError('trailing bytes');
  return value;
}

/**
 * Decodes one item starting at `offset` and returns it with the offset just past it.
 * For authenticator data, where a COSE key is followed by an optional extensions map.
 */
export function decodeCborPrefix(bytes: Uint8Array, offset: number, limits: CborLimits = {}): { value: CborValue; end: number } {
  const c = cursor(bytes, limits);
  if (!Number.isSafeInteger(offset) || offset < 0 || offset >= c.buf.length) throw new CborError('offset');
  c.pos = offset;
  const value = readItem(c, 0);
  return { value, end: c.pos };
}
