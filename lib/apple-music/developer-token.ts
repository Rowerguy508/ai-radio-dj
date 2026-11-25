import { createPrivateKey, sign } from 'crypto';

export const DEVELOPER_TOKEN_MAX_TTL_SECONDS = 3600;

export function normalizePrivateKey(value: string): string {
  return value.replace(/\\n/g, '\n').trim();
}

function base64url(value: Buffer | string): string {
  const buffer = Buffer.isBuffer(value) ? value : Buffer.from(value, 'utf8');
  return buffer.toString('base64url');
}

function ttlSeconds(requested: number | undefined): number {
  if (requested === undefined) return DEVELOPER_TOKEN_MAX_TTL_SECONDS;
  if (!Number.isFinite(requested) || requested <= 0 || requested > DEVELOPER_TOKEN_MAX_TTL_SECONDS) {
    throw new Error('ttl refused');
  }
  return Math.floor(requested);
}

/** Mint a short-lived MusicKit developer token. The private key stays on the server. */
export function mintDeveloperToken(options: {
  teamId: string;
  keyId: string;
  privateKeyPem: string;
  origins: readonly string[];
  now?: number;
  ttlSeconds?: number;
}): string {
  const origins = options.origins.map((origin) => origin.trim()).filter(Boolean);
  if (origins.length === 0) throw new Error('origin required');
  const issuedAt = options.now ?? Math.floor(Date.now() / 1000);
  const expiresAt = issuedAt + ttlSeconds(options.ttlSeconds);
  const header = base64url(JSON.stringify({ alg: 'ES256', kid: options.keyId }));
  const payload = base64url(JSON.stringify({
    iss: options.teamId,
    iat: issuedAt,
    exp: expiresAt,
    origin: origins,
  }));
  const signingInput = `${header}.${payload}`;
  const key = createPrivateKey(normalizePrivateKey(options.privateKeyPem));
  const signature = sign('sha256', Buffer.from(signingInput), {
    key,
    dsaEncoding: 'ieee-p1363',
  });
  return `${signingInput}.${base64url(signature)}`;
}
