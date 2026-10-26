import { generateKeyPairSync, verify } from 'crypto';
import { readFileSync } from 'node:fs';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { GET } from '@/app/api/apple-music/token/route';
import { fetchDeveloperToken } from '@/lib/apple-music/client-token';
import { DEVELOPER_TOKEN_MAX_TTL_SECONDS, mintDeveloperToken } from '@/lib/apple-music/developer-token';

const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
const PEM = privateKey.export({ type: 'pkcs8', format: 'pem' }).toString();
const ESCAPED_PEM = PEM.replace(/\n/g, '\\n');

function decode(part: string): Record<string, unknown> {
  return JSON.parse(Buffer.from(part, 'base64url').toString('utf8'));
}

describe('apple music developer token', () => {
  afterEach(() => {
    vi.unstubAllEnvs();
    vi.unstubAllGlobals();
  });

  it('returns 404 when server key material is missing', async () => {
    vi.stubEnv('APPLE_MUSIC_TEAM_ID', '');
    vi.stubEnv('APPLE_MUSIC_KEY_ID', '');
    vi.stubEnv('APPLE_MUSIC_PRIVATE_KEY', '');
    const response = await GET();
    expect(response.status).toBe(404);
    const body = await response.text();
    expect(body).not.toContain('BEGIN');
    expect(body).not.toContain('PRIVATE');
  });

  it('returns 404 for an unusable key and does not echo it', async () => {
    const marker = 'fixture-unusable-key-material';
    vi.stubEnv('APPLE_MUSIC_TEAM_ID', 'FIXTURETEAM');
    vi.stubEnv('APPLE_MUSIC_KEY_ID', 'FIXTUREKEY');
    vi.stubEnv('APPLE_MUSIC_PRIVATE_KEY', marker);
    const response = await GET();
    expect(response.status).toBe(404);
    const body = await response.text();
    expect(body).not.toContain(marker);
    expect(body).not.toContain('BEGIN');
  });

  it('mints a short-lived token and caps the lifetime', () => {
    const token = mintDeveloperToken({
      teamId: 'FIXTURETEAM',
      keyId: 'FIXTUREKEY',
      privateKeyPem: ESCAPED_PEM,
      now: 1_700_000_000,
      ttlSeconds: 999_999,
    });
    const [headerPart, payloadPart, signaturePart] = token.split('.');
    expect(decode(headerPart)).toEqual({ alg: 'ES256', kid: 'FIXTUREKEY' });
    const payload = decode(payloadPart);
    expect(payload.iss).toBe('FIXTURETEAM');
    expect(payload.exp).toBe(1_700_000_000 + DEVELOPER_TOKEN_MAX_TTL_SECONDS);
    expect(Number(payload.exp) - Number(payload.iat)).toBeLessThanOrEqual(DEVELOPER_TOKEN_MAX_TTL_SECONDS);
    const valid = verify(
      'sha256',
      Buffer.from(`${headerPart}.${payloadPart}`),
      { key: privateKey, dsaEncoding: 'ieee-p1363' },
      Buffer.from(signaturePart, 'base64url'),
    );
    expect(valid).toBe(true);
    expect(token).not.toContain('BEGIN');
    expect(token).not.toContain(PEM);
  });

  it('serves that token from the route without accepting a longer lifetime', async () => {
    vi.stubEnv('APPLE_MUSIC_TEAM_ID', 'FIXTURETEAM');
    vi.stubEnv('APPLE_MUSIC_KEY_ID', 'FIXTUREKEY');
    vi.stubEnv('APPLE_MUSIC_PRIVATE_KEY', ESCAPED_PEM);
    const response = await GET();
    expect(response.status).toBe(200);
    const body = await response.json();
    const token = body.token as string;
    const payload = decode(token.split('.')[1]);
    expect(Number(payload.exp) - Number(payload.iat)).toBe(DEVELOPER_TOKEN_MAX_TTL_SECONDS);
    expect(JSON.stringify(body)).not.toContain('BEGIN');
    expect(JSON.stringify(body)).not.toContain(PEM);
    expect(readFileSync('app/api/apple-music/token/route.ts', 'utf8')).not.toMatch(/searchParams|ttl/);
  });

  it('keeps the private key and the public token env var off the client path', () => {
    const player = readFileSync('lib/apple-music/player.tsx', 'utf8');
    const client = readFileSync('lib/apple-music/client-token.ts', 'utf8');
    const example = readFileSync('.env.example', 'utf8');
    expect(player).not.toContain('NEXT_PUBLIC_APPLE_MUSIC_DEVELOPER_TOKEN');
    expect(player).toContain('fetchDeveloperToken');
    expect(player).not.toContain('developer-token');
    expect(client).not.toMatch(/from 'crypto'|APPLE_MUSIC_PRIVATE_KEY|NEXT_PUBLIC_/);
    expect(example).not.toContain('NEXT_PUBLIC_APPLE_MUSIC_DEVELOPER_TOKEN');
    expect(example).toContain('APPLE_MUSIC_PRIVATE_KEY=');
  });

  it('skips MusicKit setup when the token route refuses', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify({ error: 'Not found' }), { status: 404 })));
    await expect(fetchDeveloperToken()).resolves.toBeNull();
  });
});
