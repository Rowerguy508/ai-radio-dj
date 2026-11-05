import { readFileSync } from 'node:fs';
import { NextRequest } from 'next/server';
import { beforeEach, describe, expect, it, vi } from 'vitest';

const createAdminClient = vi.fn(() => {
  throw new Error('database client must not be constructed');
});

vi.mock('@/lib/database/supabase', () => ({
  createAdminClient: () => createAdminClient(),
  createBrowserClient: () => createAdminClient(),
  isSupabaseConfigured: () => true,
}));

import * as messages from '@/app/api/messages/route';
import * as stations from '@/app/api/stations/route';
import * as voices from '@/app/api/voices/route';

const USER_ID = '00000000-0000-4000-8000-000000000001';

type Handler = (request: NextRequest) => Response | Promise<Response>;

function post(url: string, body: unknown) {
  return new NextRequest(url, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
}

async function statuses(calls: Array<[Handler, NextRequest]>) {
  const responses = await Promise.all(calls.map(([handler, request]) => handler(request)));
  return responses.map((response) => response.status);
}

describe('service-role routes', () => {
  beforeEach(() => {
    createAdminClient.mockClear();
    vi.stubEnv('NEXT_PUBLIC_SUPABASE_URL', 'https://fixture.supabase.co');
    vi.stubEnv('NEXT_PUBLIC_SUPABASE_ANON_KEY', 'fixture-anon-key');
    vi.stubEnv('SUPABASE_SERVICE_ROLE_KEY', 'fixture-service-role-key');
  });

  it('returns 404 for message reads and writes without calling the database', async () => {
    const result = await statuses([
      [messages.GET as Handler, new NextRequest(`http://localhost/api/messages?userId=${USER_ID}`)],
      [messages.POST as Handler, post('http://localhost/api/messages', { userId: USER_ID, content: 'fixture' })],
      [messages.PATCH as Handler, post('http://localhost/api/messages', { userId: USER_ID, messageId: USER_ID, action: 'read' })],
    ]);
    expect(result).toEqual([404, 404, 404]);
    expect(createAdminClient).not.toHaveBeenCalled();
    expect(readFileSync('app/api/messages/route.ts', 'utf8')).not.toMatch(/userId|createAdminClient|supabase/);
  });

  it('returns 404 for station reads and writes without calling the database', async () => {
    const result = await statuses([
      [stations.GET as Handler, new NextRequest(`http://localhost/api/stations?userId=${USER_ID}`)],
      [stations.POST as Handler, post('http://localhost/api/stations', { userId: USER_ID, name: 'Fixture FM' })],
      [stations.PUT as Handler, post('http://localhost/api/stations', { userId: USER_ID, stations: [] })],
    ]);
    expect(result).toEqual([404, 404, 404]);
    expect(createAdminClient).not.toHaveBeenCalled();
    expect(readFileSync('app/api/stations/route.ts', 'utf8')).not.toMatch(/userId|createAdminClient|supabase/);
  });

  it('returns 404 for voice reads and writes without calling the database', async () => {
    const result = await statuses([
      [voices.GET as Handler, new NextRequest(`http://localhost/api/voices?userId=${USER_ID}&id=${USER_ID}`)],
      [voices.POST as Handler, post('http://localhost/api/voices', { userId: USER_ID, name: 'Fixture', voiceId: 'fixture-voice' })],
      [voices.DELETE as Handler, new NextRequest(`http://localhost/api/voices?userId=${USER_ID}&id=${USER_ID}`)],
    ]);
    expect(result).toEqual([404, 404, 404]);
    expect(createAdminClient).not.toHaveBeenCalled();
    expect(readFileSync('app/api/voices/route.ts', 'utf8')).not.toMatch(/userId|createAdminClient|supabase/);
  });
});
