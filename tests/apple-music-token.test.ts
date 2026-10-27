import { generateKeyPairSync, verify } from 'crypto';
import { readFileSync } from 'node:fs';
import { NextRequest } from 'next/server';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { GET } from '@/app/api/apple-music/token/route';
import { fetchDeveloperToken } from '@/lib/apple-music/client-token';
import { DEVELOPER_TOKEN_MAX_TTL_SECONDS, mintDeveloperToken } from '@/lib/apple-music/developer-token';
import { resetTokenRateLimitForTests, TOKEN_REQUESTS_PER_WINDOW } from '@/lib/apple-music/token-access';

const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
const PEM = privateKey.export({ type: 'pkcs8', format: 'pem' }).toString();
const ESCAPED_PEM = PEM.replace(/\n/g, '\\n');
const ALLOWED = 'https://fixture.example';

function decode(part: string): Record<string, unknown> {
  return JSON.parse(Buffer.from(part, 'base64url').toString('utf8'));
}

function tokenRequest(origin?: string, address = '203.0.113.10') {
  const headers = new Headers({ 'x-forwarded-for': address });
  if (origin !== undefined) headers.set('origin', origin);
  return new NextRequest('http://localhost/api/apple-music/token', { headers });
}

function configureKey(allowlist = ALLOWED) {
  vi.stubEnv('APPLE_MUSIC_TEAM_ID', 'FIXTURETEAM');
  vi.stubEnv('APPLE_MUSIC_KEY_ID', 'FIXTUREKEY');
  vi.stubEnv('APPLE_MUSIC_PRIVATE_KEY', ESCAPED_PEM);
  vi.stubEnv('APPLE_MUSIC_ALLOWED_ORIGINS', allowlist);
}

describe('apple music developer token', () => {
  beforeEach(() => {
    resetTokenRateLimitForTests();
  });

  afterEach(() => {
    vi.unstubAllEnvs();
    vi.unstubAllGlobals();
  });

  it('returns 404 when server key material is missing', async () => {
    vi.stubEnv('APPLE_MUSIC_TEAM_ID', '');
    vi.stubEnv('APPLE_MUSIC_KEY_ID', '');
    vi.stubEnv('APPLE_MUSIC_PRIVATE_KEY', '');
    vi.stubEnv('APPLE_MUSIC_ALLOWED_ORIGINS', ALLOWED);
    const response = await GET(tokenRequest(ALLOWED));
    expect(response.status).toBe(404);
    const body = await response.text();
    expect(body).not.toContain('BEGIN');
    expect(body).not.toContain('PRIVATE');
    expect(body).not.toContain('token');
  });

  it('returns 404 for an unusable key and does not echo it', async () => {
    const marker = 'fixture-unusable-key-material';
    vi.stubEnv('APPLE_MUSIC_TEAM_ID', 'FIXTURETEAM');
    vi.stubEnv('APPLE_MUSIC_KEY_ID', 'FIXTUREKEY');
    vi.stubEnv('APPLE_MUSIC_PRIVATE_KEY', marker);
    vi.stubEnv('APPLE_MUSIC_ALLOWED_ORIGINS', ALLOWED);
    const response = await GET(tokenRequest(ALLOWED, '203.0.113.11'));
    expect(response.status).toBe(404);
    const body = await response.text();
    expect(body).not.toContain(marker);
    expect(body).not.toContain('BEGIN');
    expect(body).not.toContain('token');
  });

  it('gives an unauthorized origin no token', async () => {
    configureKey();
    const response = await GET(tokenRequest('https://other.fixture.example', '203.0.113.12'));
    expect(response.status).toBe(403);
    const body = await response.json();
    expect(body.token).toBeUndefined();
    expect(JSON.stringify(body)).not.toContain('BEGIN');
  });

  it('gives a missing origin no token', async () => {
    configureKey();
    const missing = await GET(tokenRequest(undefined, '203.0.113.13'));
    const literalNull = await GET(tokenRequest('null', '203.0.113.14'));
    expect(missing.status).toBe(403);
    expect(literalNull.status).toBe(403);
    expect((await missing.json()).token).toBeUndefined();
    expect((await literalNull.json()).token).toBeUndefined();
  });

  it('gives an allowed origin a token whose origin claim and expiry are correct', async () => {
    configureKey(`${ALLOWED},https://second.fixture.example`);
    const response = await GET(tokenRequest(ALLOWED, '203.0.113.15'));
    expect(response.status).toBe(200);
    const body = await response.json();
    const token = body.token as string;
    const [headerPart, payloadPart, signaturePart] = token.split('.');
    const payload = decode(payloadPart);
    expect(payload.origin).toEqual([ALLOWED, 'https://second.fixture.example']);
    expect(Number(payload.exp) - Number(payload.iat)).toBe(DEVELOPER_TOKEN_MAX_TTL_SECONDS);
    const valid = verify(
      'sha256',
      Buffer.from(`${headerPart}.${payloadPart}`),
      { key: privateKey, dsaEncoding: 'ieee-p1363' },
      Buffer.from(signaturePart, 'base64url'),
    );
    expect(valid).toBe(true);
    expect(JSON.stringify(body)).not.toContain('BEGIN');
    expect(JSON.stringify(body)).not.toContain(PEM);
    expect(readFileSync('app/api/apple-music/token/route.ts', 'utf8')).not.toMatch(/searchParams|ttl/);
  });

  it('refuses a longer lifetime', () => {
    expect(() => mintDeveloperToken({
      teamId: 'FIXTURETEAM',
      keyId: 'FIXTUREKEY',
      privateKeyPem: ESCAPED_PEM,
      origins: [ALLOWED],
      now: 1_700_000_000,
      ttlSeconds: DEVELOPER_TOKEN_MAX_TTL_SECONDS + 1,
    })).toThrow();
    const token = mintDeveloperToken({
      teamId: 'FIXTURETEAM',
      keyId: 'FIXTUREKEY',
      privateKeyPem: ESCAPED_PEM,
      origins: [ALLOWED],
      now: 1_700_000_000,
    });
    const payload = decode(token.split('.')[1]);
    expect(Number(payload.exp) - Number(payload.iat)).toBe(DEVELOPER_TOKEN_MAX_TTL_SECONDS);
    expect(token).not.toContain(PEM);
  });

  it('stops issuing tokens after the per-address limit', async () => {
    configureKey();
    const address = '203.0.113.16';
    for (let i = 0; i < TOKEN_REQUESTS_PER_WINDOW; i += 1) {
      const response = await GET(tokenRequest(ALLOWED, address));
      expect(response.status).toBe(200);
    }
    const blocked = await GET(tokenRequest(ALLOWED, address));
    expect(blocked.status).toBe(429);
    expect((await blocked.json()).token).toBeUndefined();
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
    expect(example).toContain('APPLE_MUSIC_ALLOWED_ORIGINS=');
  });

  it('asks with POST and skips MusicKit setup when the token route refuses', async () => {
    const fetchMock = vi.fn(async () => new Response(JSON.stringify({ error: 'Forbidden' }), { status: 403 }));
    vi.stubGlobal('fetch', fetchMock);
    await expect(fetchDeveloperToken()).resolves.toBeNull();
    expect(fetchMock).toHaveBeenCalledWith('/api/apple-music/token', { method: 'POST' });
  });
});
