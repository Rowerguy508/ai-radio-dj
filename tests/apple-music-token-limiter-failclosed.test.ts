import { generateKeyPairSync } from 'crypto';
import { NextRequest } from 'next/server';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

// #78: the limiter fails CLOSED. If it throws, the route refuses the request with a fixed
// 503 body and mints nothing. (Failing open would hand out tokens while the limit is broken.)

const permit = vi.hoisted(() => vi.fn<(address: string) => boolean>());
const address = vi.hoisted(() => vi.fn<(headers: Headers) => string>());
const mint = vi.hoisted(() => vi.fn(() => 'minted-token'));

vi.mock('@/lib/apple-music/token-access', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/lib/apple-music/token-access')>();
  return { ...actual, permitTokenRequest: permit, clientAddress: address };
});
vi.mock('@/lib/apple-music/developer-token', () => ({ mintDeveloperToken: mint }));

import { POST } from '@/app/api/apple-music/token/route';

const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
const ESCAPED_PEM = privateKey.export({ type: 'pkcs8', format: 'pem' }).toString().replace(/\n/g, '\\n');
const ALLOWED = 'https://fixture.example';

function tokenRequest() {
  return new NextRequest('http://localhost/api/apple-music/token', {
    method: 'POST',
    headers: { origin: ALLOWED, 'x-real-ip': '198.51.100.70' },
  });
}

describe('apple music token limiter fails closed (#78)', () => {
  beforeEach(() => {
    permit.mockReset();
    address.mockReset().mockReturnValue('198.51.100.70');
    mint.mockClear();
    vi.stubEnv('APPLE_MUSIC_TEAM_ID', 'FIXTURETEAM');
    vi.stubEnv('APPLE_MUSIC_KEY_ID', 'FIXTUREKEY');
    vi.stubEnv('APPLE_MUSIC_PRIVATE_KEY', ESCAPED_PEM);
    vi.stubEnv('APPLE_MUSIC_ALLOWED_ORIGINS', ALLOWED);
  });

  afterEach(() => {
    vi.unstubAllEnvs();
  });

  it('control: when the limiter allows, a token is minted', async () => {
    permit.mockReturnValue(true);
    const res = await POST(tokenRequest());
    expect(res.status).toBe(200);
    expect(mint).toHaveBeenCalledTimes(1);
  });

  it('refuses with a fixed 503 and mints nothing when the limiter throws', async () => {
    permit.mockImplementation(() => { throw new Error('boom: secret-detail'); });
    const res = await POST(tokenRequest());
    expect(res.status).toBe(503);
    expect(await res.json()).toEqual({ error: 'Service unavailable' });
    expect(res.headers.get('cache-control')).toBe('no-store');
    expect(mint).not.toHaveBeenCalled();
  });

  it('refuses the same way when deriving the client key throws', async () => {
    address.mockImplementation(() => { throw new Error('bad header'); });
    const res = await POST(tokenRequest());
    expect(res.status).toBe(503);
    expect(mint).not.toHaveBeenCalled();
  });

  it('does not echo the limiter error text', async () => {
    permit.mockImplementation(() => { throw new Error('boom: secret-detail'); });
    const res = await POST(tokenRequest());
    expect(await res.text()).not.toContain('secret-detail');
  });
});
