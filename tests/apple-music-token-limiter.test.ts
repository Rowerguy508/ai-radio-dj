import { generateKeyPairSync } from 'crypto';
import { readFileSync } from 'node:fs';
import { NextRequest } from 'next/server';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { POST } from '@/app/api/apple-music/token/route';
import {
  clientAddress,
  permitTokenRequest,
  resetTokenRateLimitForTests,
  tokenBucketCountForTests,
  TOKEN_REQUESTS_PER_WINDOW,
  TOKEN_WINDOW_MS,
  UNKNOWN_CLIENT,
} from '@/lib/apple-music/token-access';

// #78: the token limiter keys on Vercel's x-real-ip, checks Origin before spending
// budget, and is documented as best-effort per instance.

const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
const ESCAPED_PEM = privateKey.export({ type: 'pkcs8', format: 'pem' }).toString().replace(/\n/g, '\\n');
const ALLOWED = 'https://fixture.example';

function tokenRequest(origin: string | undefined, headers: Record<string, string> = {}) {
  const h = new Headers(headers);
  if (origin !== undefined) h.set('origin', origin);
  return new NextRequest('http://localhost/api/apple-music/token', { method: 'POST', headers: h });
}

describe('apple music token limiter (#78)', () => {
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

  describe('(1) keys on x-real-ip, never on client-supplied x-forwarded-for', () => {
    it('reads x-real-ip and ignores x-forwarded-for', () => {
      expect(clientAddress(new Headers({ 'x-real-ip': '198.51.100.7', 'x-forwarded-for': '203.0.113.1' })))
        .toBe('198.51.100.7');
      expect(clientAddress(new Headers({ 'x-forwarded-for': '203.0.113.1, 198.51.100.7' }))).toBe(UNKNOWN_CLIENT);
      expect(clientAddress(new Headers({ 'x-real-ip': '   ' }))).toBe(UNKNOWN_CLIENT);
      expect(clientAddress(new Headers())).toBe(UNKNOWN_CLIENT);
    });

    it('does not hand out a fresh bucket when the caller rotates x-forwarded-for', async () => {
      for (let i = 0; i < TOKEN_REQUESTS_PER_WINDOW; i += 1) {
        const ok = await POST(tokenRequest(ALLOWED, { 'x-real-ip': '198.51.100.7', 'x-forwarded-for': `203.0.113.${i}` }));
        expect(ok.status).toBe(200);
      }
      const blocked = await POST(tokenRequest(ALLOWED, { 'x-real-ip': '198.51.100.7', 'x-forwarded-for': '203.0.113.250' }));
      expect(blocked.status).toBe(429);
      expect((await blocked.json()).token).toBeUndefined();

      const other = await POST(tokenRequest(ALLOWED, { 'x-real-ip': '198.51.100.8' }));
      expect(other.status).toBe(200);
    });

    it('puts every request without x-real-ip in one shared unknown bucket', async () => {
      for (let i = 0; i < TOKEN_REQUESTS_PER_WINDOW; i += 1) {
        const ok = await POST(tokenRequest(ALLOWED, { 'x-forwarded-for': `203.0.113.${i}` }));
        expect(ok.status).toBe(200);
      }
      const blocked = await POST(tokenRequest(ALLOWED, { 'x-forwarded-for': '203.0.113.251' }));
      expect(blocked.status).toBe(429);
    });
  });

  describe('(2) checks Origin before spending any budget', () => {
    it('refused origins do not drain the bucket', async () => {
      const ip = { 'x-real-ip': '198.51.100.20' };
      for (let i = 0; i < TOKEN_REQUESTS_PER_WINDOW * 3; i += 1) {
        expect((await POST(tokenRequest('https://other.fixture.example', ip))).status).toBe(403);
        expect((await POST(tokenRequest(undefined, ip))).status).toBe(403);
        expect((await POST(tokenRequest('null', ip))).status).toBe(403);
      }
      for (let i = 0; i < TOKEN_REQUESTS_PER_WINDOW; i += 1) {
        expect((await POST(tokenRequest(ALLOWED, ip))).status).toBe(200);
      }
      expect((await POST(tokenRequest(ALLOWED, ip))).status).toBe(429);
    });

    it('answers 403, not 429, to a refused origin once the bucket is empty', async () => {
      const ip = { 'x-real-ip': '198.51.100.21' };
      for (let i = 0; i < TOKEN_REQUESTS_PER_WINDOW; i += 1) {
        expect((await POST(tokenRequest(ALLOWED, ip))).status).toBe(200);
      }
      expect((await POST(tokenRequest(ALLOWED, ip))).status).toBe(429);
      expect((await POST(tokenRequest('https://other.fixture.example', ip))).status).toBe(403);
    });
  });

  describe('(3) in-memory buckets, documented as best-effort per instance', () => {
    it('limits per window and refills after it', () => {
      const t0 = 1_700_000_000_000;
      for (let i = 0; i < TOKEN_REQUESTS_PER_WINDOW; i += 1) {
        expect(permitTokenRequest('198.51.100.30', t0 + i)).toBe(true);
      }
      expect(permitTokenRequest('198.51.100.30', t0 + TOKEN_WINDOW_MS - 1)).toBe(false);
      expect(permitTokenRequest('198.51.100.30', t0 + TOKEN_WINDOW_MS)).toBe(true);
    });

    it('drops expired buckets on write so the Map does not grow per address', () => {
      const t0 = 1_700_000_000_000;
      for (let i = 0; i < 50; i += 1) permitTokenRequest(`198.51.100.${i}`, t0);
      permitTokenRequest('203.0.113.1', t0 + TOKEN_WINDOW_MS / 2);
      expect(tokenBucketCountForTests()).toBe(51);
      permitTokenRequest('203.0.113.2', t0 + TOKEN_WINDOW_MS);
      // The 50 from t0 have expired; the mid-window bucket is still live and keeps its count.
      expect(tokenBucketCountForTests()).toBe(2);
      for (let i = 1; i < TOKEN_REQUESTS_PER_WINDOW; i += 1) {
        expect(permitTokenRequest('203.0.113.1', t0 + TOKEN_WINDOW_MS + i)).toBe(true);
      }
      expect(permitTokenRequest('203.0.113.1', t0 + TOKEN_WINDOW_MS + 20)).toBe(false);
    });

    it('uses a module-level Map with no shared store, and says so in the code', () => {
      const source = readFileSync('lib/apple-music/token-access.ts', 'utf8');
      expect(source).toContain('new Map<string, Bucket>()');
      expect(source).toMatch(/BEST-EFFORT ONLY/);
      expect(source).toMatch(/each serverless\s+\/\/ instance keeps its own count/);
      expect(source).toMatch(/no shared store/);
      expect(source).not.toMatch(/^import /m);
      expect(source).not.toMatch(/x-forwarded-for['"]\)/);
    });
  });
});
