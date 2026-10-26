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
  if (requested === undefined || !Number.isFinite(requested) || requested <= 0) {
    return DEVELOPER_TOKEN_MAX_TTL_SECONDS;
  }
  return Math.min(Math.floor(requested), DEVELOPER_TOKEN_MAX_TTL_SECONDS);
}

/** Mint a short-lived MusicKit developer token. The private key stays on the server. */
export function mintDeveloperToken(options: {
  teamId: string;
  keyId: string;
  privateKeyPem: string;
  now?: number;
  ttlSeconds?: number;
}): string {
  const issuedAt = options.now ?? Math.floor(Date.now() / 1000);
  const expiresAt = issuedAt + ttlSeconds(options.ttlSeconds);
  const header = base64url(JSON.stringify({ alg: 'ES256', kid: options.keyId }));
  const payload = base64url(JSON.stringify({
    iss: options.teamId,
    iat: issuedAt,
    exp: expiresAt,
  }));
  const signingInput = `${header}.${payload}`;
  const key = createPrivateKey(normalizePrivateKey(options.privateKeyPem));
  const signature = sign('sha256', Buffer.from(signingInput), {
    key,
    dsaEncoding: 'ieee-p1363',
  });
  return `${signingInput}.${base64url(signature)}`;
}
