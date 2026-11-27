import { generateKeyPairSync } from 'crypto';
import { NextRequest } from 'next/server';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { POST } from '@/app/api/apple-music/token/route';
import {
  permitTokenRequest,
  resetTokenRateLimitForTests,
  TOKEN_REQUESTS_PER_WINDOW,
  TOKEN_WINDOW_MS,
} from '@/lib/apple-music/token-access';

// #78 follow-up: limiter window edges and the exact refusal bodies of the token route.

const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
const ESCAPED_PEM = privateKey.export({ type: 'pkcs8', format: 'pem' }).toString().replace(/\n/g, '\\n');
const ALLOWED = 'https://fixture.example';
const T0 = 1_700_000_000_000;

function tokenRequest(origin: string, headers: Record<string, string> = {}) {
  const h = new Headers(headers);
  h.set('origin', origin);
  return new NextRequest('http://localhost/api/apple-music/token', { method: 'POST', headers: h });
}

describe('apple music token limiter window edges (#78)', () => {
  beforeEach(() => {
    resetTokenRateLimitForTests();
  });

  it('keeps a full bucket full when the clock steps backwards', () => {
    for (let i = 0; i < TOKEN_REQUESTS_PER_WINDOW; i += 1) {
      expect(permitTokenRequest('198.51.100.40', T0)).toBe(true);
    }
    expect(permitTokenRequest('198.51.100.40', T0 - 1)).toBe(false);
    expect(permitTokenRequest('198.51.100.40', T0 - 10 * TOKEN_WINDOW_MS)).toBe(false);
  });

  it('starts the window at the first request and never allows more than twice the limit across a boundary', () => {
    expect(permitTokenRequest('198.51.100.41', T0)).toBe(true);
    let allowed = 0;
    for (let i = 0; i < 50; i += 1) if (permitTokenRequest('198.51.100.41', T0 + TOKEN_WINDOW_MS - 1)) allowed += 1;
    expect(allowed).toBe(TOKEN_REQUESTS_PER_WINDOW - 1);
    for (let i = 0; i < 50; i += 1) if (permitTokenRequest('198.51.100.41', T0 + TOKEN_WINDOW_MS)) allowed += 1;
    expect(allowed).toBe(2 * TOKEN_REQUESTS_PER_WINDOW - 1);
  });
});

describe('apple music token refusal bodies (#78)', () => {
  beforeEach(() => {
    resetTokenRateLimitForTests();
    vi.stubEnv('APPLE_MUSIC_TEAM_ID', 'FIXTURETEAM');
    vi.stubEnv('APPLE_MUSIC_KEY_ID', 'FIXTUREKEY');
    vi.stubEnv('APPLE_MUSIC_PRIVATE_KEY', ESCAPED_PEM);
    vi.stubEnv('APPLE_MUSIC_ALLOWED_ORIGINS', ALLOWED);
  });

  afterEach(() => {
    vi.unstubAllEnvs();
  });

  it('answers 429 with a fixed body, no-store and no Retry-After', async () => {
    const ip = { 'x-real-ip': '198.51.100.42' };
    for (let i = 0; i < TOKEN_REQUESTS_PER_WINDOW; i += 1) {
      expect((await POST(tokenRequest(ALLOWED, ip))).status).toBe(200);
    }
    const blocked = await POST(tokenRequest(ALLOWED, ip));
    expect(blocked.status).toBe(429);
    expect(await blocked.json()).toEqual({ error: 'Too many requests' });
    expect(blocked.headers.get('cache-control')).toBe('no-store');
    expect(blocked.headers.get('retry-after')).toBeNull();
  });

  it('answers a refused origin with a fixed 403 body and no-store', async () => {
    const refused = await POST(tokenRequest('https://other.fixture.example', { 'x-real-ip': '198.51.100.43' }));
    expect(refused.status).toBe(403);
    expect(await refused.json()).toEqual({ error: 'Forbidden' });
    expect(refused.headers.get('cache-control')).toBe('no-store');
  });

  it('answers a mint failure with exactly the fixed 404 body and no-store', async () => {
    vi.stubEnv('APPLE_MUSIC_PRIVATE_KEY', 'not a pem');
    const failed = await POST(tokenRequest(ALLOWED, { 'x-real-ip': '198.51.100.44' }));
    expect(failed.status).toBe(404);
    expect(await failed.json()).toEqual({ error: 'Not found' });
    expect(failed.headers.get('cache-control')).toBe('no-store');
  });
});
