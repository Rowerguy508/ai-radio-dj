import crypto from 'node:crypto';

/**
 * Raw request body (note §4.1.4, Sentinel B4). New handlers use the Web
 * `Request` signature and read the stream themselves with a byte cap; they
 * never use Vercel's Node `req.body` helper. The bytes read here are the bytes
 * hashed into the assertion's clientData and the bytes parsed as JSON.
 */
export const BODY_CAPS = Object.freeze({
  challenge: 1024,
  tts: 8 * 1024,
  entitlement: 16 * 1024,
  register: 16 * 1024,
  notifications: 64 * 1024,
});

export type RawBodyResult = { ok: true; bytes: Buffer } | { ok: false; reason: 'too_large' | 'bad_request' };

/**
 * Reads at most `cap` bytes. A declared Content-Length above the cap is
 * refused before reading; a stream that exceeds it is cancelled. Any
 * Content-Encoding other than identity is refused (the hash must cover the
 * bytes the client signed).
 */
export async function readRawBody(request: Request, cap: number): Promise<RawBodyResult> {
  const encoding = request.headers.get('content-encoding');
  if (encoding && encoding.trim().toLowerCase() !== 'identity') return { ok: false, reason: 'bad_request' };
  const declared = request.headers.get('content-length');
  if (declared !== null) {
    if (!/^\d+$/.test(declared.trim())) return { ok: false, reason: 'bad_request' };
    if (Number(declared) > cap) {
      await request.body?.cancel().catch(() => {});
      return { ok: false, reason: 'too_large' };
    }
  }
  if (!request.body) return { ok: true, bytes: Buffer.alloc(0) };
  const reader = request.body.getReader();
  const chunks: Buffer[] = [];
  let total = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > cap) {
        await reader.cancel().catch(() => {});
        return { ok: false, reason: 'too_large' };
      }
      chunks.push(Buffer.from(value.buffer, value.byteOffset, value.byteLength));
    }
  } catch {
    return { ok: false, reason: 'bad_request' };
  } finally {
    reader.releaseLock?.();
  }
  return { ok: true, bytes: Buffer.concat(chunks, total) };
}

const UTF8 = new TextDecoder('utf-8', { fatal: true, ignoreBOM: false });

/** Strict UTF-8 → JSON.parse → plain object, from the same bytes that were hashed. */
export function parseJsonObject(bytes: Buffer): Record<string, unknown> | null {
  // A BOM is refused outright (TextDecoder would silently strip it).
  if (bytes.length >= 3 && bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) return null;
  let text: string;
  try {
    text = UTF8.decode(bytes);
  } catch {
    return null;
  }
  try {
    const value: unknown = JSON.parse(text);
    return value && typeof value === 'object' && !Array.isArray(value) ? (value as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

/** Lowercase hex SHA-256 of the exact body bytes (clientData's body hash, §4.1.3). */
export function bodySha256Hex(bytes: Buffer): string {
  return crypto.createHash('sha256').update(bytes).digest('hex');
}
