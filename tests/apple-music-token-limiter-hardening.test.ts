import { generateKeyPairSync } from 'crypto';
import { readFileSync } from 'node:fs';
import { NextRequest } from 'next/server';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { POST } from '@/app/api/apple-music/token/route';
import {
  clientAddress,
  EVICTION_MIN_GAP_AT_CAPACITY_MS,
  MAX_CLIENT_KEY_LENGTH,
  MAX_TRACKED_CLIENTS,
  OVERFLOW_CLIENT,
  permitTokenRequest,
  resetTokenRateLimitForTests,
  tokenBucketCountForTests,
  TOKEN_REQUESTS_PER_WINDOW,
  TOKEN_WINDOW_MS,
  UNKNOWN_CLIENT,
} from '@/lib/apple-music/token-access';

// #78 hardening: atomic spend, bounded memory, validated per-client key, no token or
// key material in logs or refusals. Fail-closed on a limiter error is in
// apple-music-token-limiter-failclosed.test.ts (it needs a module mock).

const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
const PEM = privateKey.export({ type: 'pkcs8', format: 'pem' }).toString();
const ESCAPED_PEM = PEM.replace(/\n/g, '\\n');
const ALLOWED = 'https://fixture.example';
const T0 = 1_700_000_000_000;

function tokenRequest(origin: string, headers: Record<string, string> = {}) {
  const h = new Headers(headers);
  h.set('origin', origin);
  return new NextRequest('http://localhost/api/apple-music/token', { method: 'POST', headers: h });
}

function ip(n: number): string {
  return `10.${(n >> 16) & 255}.${(n >> 8) & 255}.${n & 255}`;
}

describe('apple music token limiter hardening (#78)', () => {
  beforeEach(() => {
    resetTokenRateLimitForTests();
    vi.stubEnv('APPLE_MUSIC_TEAM_ID', 'FIXTURETEAM');
    vi.stubEnv('APPLE_MUSIC_KEY_ID', 'FIXTUREKEY');
    vi.stubEnv('APPLE_MUSIC_PRIVATE_KEY', ESCAPED_PEM);
    vi.stubEnv('APPLE_MUSIC_ALLOWED_ORIGINS', ALLOWED);
  });

  afterEach(() => {
    vi.unstubAllEnvs();
    vi.restoreAllMocks();
  });

  describe('atomic spend', () => {
    it('lets exactly the limit through when requests are issued concurrently', async () => {
      const responses = await Promise.all(
        Array.from({ length: TOKEN_REQUESTS_PER_WINDOW * 5 }, () =>
          Promise.resolve(POST(tokenRequest(ALLOWED, { 'x-real-ip': '198.51.100.60' })))),
      );
      const statuses = responses.map((r) => r.status);
      expect(statuses.filter((s) => s === 200)).toHaveLength(TOKEN_REQUESTS_PER_WINDOW);
      expect(statuses.filter((s) => s === 429)).toHaveLength(TOKEN_REQUESTS_PER_WINDOW * 4);
    });

    it('checks and spends in one synchronous call: no await between read and write', () => {
      const source = readFileSync('lib/apple-music/token-access.ts', 'utf8');
      const body = source.slice(source.indexOf('export function permitTokenRequest'));
      expect(body).not.toMatch(/\bawait\b|\basync\b|Promise|setTimeout/);
    });
  });

  describe('per-client key is validated and bounded', () => {
    it('accepts IPv4 and IPv6 addresses and lower-cases them', () => {
      expect(clientAddress(new Headers({ 'x-real-ip': ' 198.51.100.9 ' }))).toBe('198.51.100.9');
      expect(clientAddress(new Headers({ 'x-real-ip': '2001:DB8::1' }))).toBe('2001:db8::1');
      expect(clientAddress(new Headers({ 'x-real-ip': '::ffff:198.51.100.9' }))).toBe('::ffff:198.51.100.9');
    });

    it('sends oversized or non-address values to the shared unknown key, never storing them', () => {
      const long = '1'.repeat(MAX_CLIENT_KEY_LENGTH + 1);
      for (const value of [long, 'x'.repeat(5000), 'not an ip', '198.51.100.9, 203.0.113.1', 'a.b.c.d/../..',
        'Bearer abc.def.ghi', 'eyJhbGciOiJFUzI1NiJ9.eyJpc3MiOiJ4In0.sig']) {
        expect(clientAddress(new Headers({ 'x-real-ip': value })), value.slice(0, 20)).toBe(UNKNOWN_CLIENT);
      }
    });

    it('never stores an oversized key even when handed one directly', () => {
      permitTokenRequest('9'.repeat(10_000), T0);
      expect(tokenBucketCountForTests()).toBe(1);
      // It shares the unknown bucket rather than minting a fresh budget.
      for (let i = 1; i < TOKEN_REQUESTS_PER_WINDOW; i += 1) expect(permitTokenRequest(UNKNOWN_CLIENT, T0)).toBe(true);
      expect(permitTokenRequest('8'.repeat(10_000), T0)).toBe(false);
    });
  });

  describe('bounded memory', () => {
    it('tracks at most MAX_TRACKED_CLIENTS distinct clients (plus one overflow bucket) in a window', () => {
      for (let i = 0; i < MAX_TRACKED_CLIENTS + 500; i += 1) permitTokenRequest(ip(i), T0);
      expect(tokenBucketCountForTests()).toBeLessThanOrEqual(MAX_TRACKED_CLIENTS + 1);
    });

    it('puts clients past the cap in one shared, still rate-limited overflow bucket', () => {
      for (let i = 0; i < MAX_TRACKED_CLIENTS; i += 1) permitTokenRequest(ip(i), T0);
      let allowed = 0;
      for (let i = 0; i < 500; i += 1) if (permitTokenRequest(ip(MAX_TRACKED_CLIENTS + i), T0 + 1)) allowed += 1;
      expect(allowed).toBe(TOKEN_REQUESTS_PER_WINDOW);
      expect(permitTokenRequest(OVERFLOW_CLIENT, T0 + 2)).toBe(false);
    });

    it('still serves clients already tracked when the cap is full', () => {
      for (let i = 0; i < MAX_TRACKED_CLIENTS; i += 1) permitTokenRequest(ip(i), T0);
      for (let i = 0; i < 500; i += 1) permitTokenRequest(ip(MAX_TRACKED_CLIENTS + i), T0 + 1);
      expect(permitTokenRequest(ip(0), T0 + 2)).toBe(true);
    });

    it('frees the cap once windows expire, without waiting a whole extra window', () => {
      for (let i = 0; i < MAX_TRACKED_CLIENTS; i += 1) permitTokenRequest(ip(i), T0);
      const later = T0 + TOKEN_WINDOW_MS + EVICTION_MIN_GAP_AT_CAPACITY_MS;
      expect(permitTokenRequest(ip(MAX_TRACKED_CLIENTS + 1), later)).toBe(true);
      expect(tokenBucketCountForTests()).toBeLessThan(10);
      // A fresh client now gets its own bucket, not the overflow one.
      for (let i = 1; i < TOKEN_REQUESTS_PER_WINDOW; i += 1) {
        expect(permitTokenRequest(ip(MAX_TRACKED_CLIENTS + 1), later + i)).toBe(true);
      }
      expect(permitTokenRequest(ip(MAX_TRACKED_CLIENTS + 2), later + 100)).toBe(true);
    });

    it('bounds the eviction sweeps at capacity to one per gap', () => {
      for (let i = 0; i < MAX_TRACKED_CLIENTS; i += 1) permitTokenRequest(ip(i), T0);
      const forEach = vi.spyOn(Map.prototype, 'forEach');
      for (let i = 0; i < 200; i += 1) permitTokenRequest(ip(MAX_TRACKED_CLIENTS + i), T0 + 10);
      expect(forEach.mock.calls.length).toBeLessThanOrEqual(1);
    });
  });

  describe('no token, key or header value leaks', () => {
    it('writes nothing to the console on 200, 403, 429 or a mint failure', async () => {
      const spies = (['log', 'info', 'warn', 'error', 'debug'] as const).map((m) =>
        vi.spyOn(console, m).mockImplementation(() => {}));
      const secretHeader = 'Bearer s3cret-admin-token-value';
      const headers = { 'x-real-ip': '198.51.100.61', authorization: secretHeader, 'x-forwarded-for': 'leaky-value' };
      const ok = await POST(tokenRequest(ALLOWED, headers));
      expect(ok.status).toBe(200);
      const minted = (await ok.json()).token as string;
      for (let i = 1; i < TOKEN_REQUESTS_PER_WINDOW; i += 1) await POST(tokenRequest(ALLOWED, headers));
      const limited = await POST(tokenRequest(ALLOWED, headers));
      expect(limited.status).toBe(429);
      expect((await POST(tokenRequest('https://other.fixture.example', headers))).status).toBe(403);
      vi.stubEnv('APPLE_MUSIC_PRIVATE_KEY', 'not a pem');
      expect((await POST(tokenRequest(ALLOWED, { 'x-real-ip': '198.51.100.62' }))).status).toBe(404);

      const printed = spies.flatMap((s) => s.mock.calls).map((call) => JSON.stringify(call)).join('\n');
      expect(printed).toBe('');
      for (const secret of [minted, secretHeader, 'leaky-value', 'FIXTUREKEY', 'FIXTURETEAM', 'PRIVATE KEY']) {
        expect(printed).not.toContain(secret);
      }
    });

    it('keeps a minted token and the private key out of every refusal body', async () => {
      const headers = { 'x-real-ip': '198.51.100.63' };
      const minted = (await (await POST(tokenRequest(ALLOWED, headers))).json()).token as string;
      for (let i = 1; i < TOKEN_REQUESTS_PER_WINDOW; i += 1) await POST(tokenRequest(ALLOWED, headers));
      const bodies = [
        await (await POST(tokenRequest(ALLOWED, headers))).text(),
        await (await POST(tokenRequest('https://other.fixture.example', headers))).text(),
      ];
      for (const body of bodies) {
        expect(body).not.toContain(minted);
        expect(body).not.toContain('PRIVATE KEY');
        expect(body).not.toContain('FIXTURE');
      }
    });

    it('has no logging and no token handling in the limiter source', () => {
      const source = readFileSync('lib/apple-music/token-access.ts', 'utf8');
      expect(source).not.toMatch(/console\.|\blogger\b|process\.env|authorization|private/i);
      const route = readFileSync('app/api/apple-music/token/route.ts', 'utf8');
      expect(route).not.toMatch(/console\./);
    });
  });
});
