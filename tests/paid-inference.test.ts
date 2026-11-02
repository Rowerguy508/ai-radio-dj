import { NextRequest } from 'next/server';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import * as commentaryRoute from '@/app/api/commentary/route';
import * as voiceRoute from '@/app/api/voice/route';
import { resetPaidInferenceBudgetForTests } from '@/lib/llm/paid-inference';

const UPSTREAM_MARKER = 'fixture-upstream-body';
const ADMIN_TOKEN = 'fixture-admin-token-0123456789abcdef';

function post(url: string, body: unknown) {
  return new NextRequest(url, {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: `Bearer ${ADMIN_TOKEN}` },
    body: JSON.stringify(body),
  });
}

function station(extra: Record<string, unknown> = {}) {
  return {
    id: 's',
    name: 'Fixture FM',
    energyLevel: 0.5,
    style: 'balanced',
    searchQuery: 'fixture',
    djName: 'Ray',
    djPersonality: 'warm',
    isActive: true,
    ...extra,
  };
}

describe('paid inference routes', () => {
  beforeEach(() => {
    resetPaidInferenceBudgetForTests();
    vi.stubEnv('MINIMAX_API_KEY', 'fixture-minimax-key');
    vi.stubEnv('RAY_DO_ADMIN_TOKEN', ADMIN_TOKEN);
    vi.stubEnv('ENABLE_PAID_INFERENCE', '');
    vi.stubEnv('PAID_INFERENCE_DAILY_CHAR_BUDGET', '6000');
    vi.stubEnv('NODE_ENV', 'test');
    vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify({
      data: { audio: Buffer.from('ok').toString('hex') },
      choices: [{ message: { content: 'fixture line' } }],
    }), { status: 200, headers: { 'content-type': 'application/json' } })));
  });

  afterEach(() => {
    vi.unstubAllEnvs();
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  it('returns 404 in production unless the opt-in flag is set', async () => {
    vi.stubEnv('NODE_ENV', 'production');
    const voice = await voiceRoute.POST(post('http://localhost/api/voice', { text: 'hello' }));
    const commentary = await commentaryRoute.POST(post('http://localhost/api/commentary', {
      context: { station: station(), type: 'intro', timeOfDay: 'morning' },
    }));
    expect(voice.status).toBe(404);
    expect(commentary.status).toBe(404);
    expect(fetch).not.toHaveBeenCalled();
  });

  it('rejects oversize voice text before calling the provider', async () => {
    vi.stubEnv('NODE_ENV', 'production');
    vi.stubEnv('ENABLE_PAID_INFERENCE', 'true');
    const response = await voiceRoute.POST(post('http://localhost/api/voice', {
      text: 'a'.repeat(601),
      speed: 1,
    }));
    expect(response.status).toBe(413);
    expect(fetch).not.toHaveBeenCalled();
  });

  it('rejects an out-of-range speed before calling the provider', async () => {
    vi.stubEnv('NODE_ENV', 'production');
    vi.stubEnv('ENABLE_PAID_INFERENCE', 'true');
    const response = await voiceRoute.POST(post('http://localhost/api/voice', {
      text: 'hello',
      speed: 100,
    }));
    expect(response.status).toBe(400);
    expect(fetch).not.toHaveBeenCalled();
  });

  it('refuses voice synthesis when the daily budget is already spent', async () => {
    vi.stubEnv('NODE_ENV', 'production');
    vi.stubEnv('ENABLE_PAID_INFERENCE', 'true');
    vi.stubEnv('PAID_INFERENCE_DAILY_CHAR_BUDGET', '0');
    const response = await voiceRoute.POST(post('http://localhost/api/voice', { text: 'hello', speed: 1 }));
    expect(response.status).toBe(429);
    await expect(response.json()).resolves.toMatchObject({ error: 'budget_exceeded' });
    expect(fetch).not.toHaveBeenCalled();
  });

  it('rejects oversize commentary before calling the provider', async () => {
    vi.stubEnv('NODE_ENV', 'production');
    vi.stubEnv('ENABLE_PAID_INFERENCE', 'true');
    const response = await commentaryRoute.POST(post('http://localhost/api/commentary', {
      context: {
        station: station({ djPersonality: 'b'.repeat(601) }),
        type: 'intro',
        timeOfDay: 'morning',
      },
    }));
    expect(response.status).toBe(400);
    expect(fetch).not.toHaveBeenCalled();
  });

  it('refuses commentary when the daily budget is already spent', async () => {
    vi.stubEnv('NODE_ENV', 'production');
    vi.stubEnv('ENABLE_PAID_INFERENCE', 'true');
    vi.stubEnv('PAID_INFERENCE_DAILY_CHAR_BUDGET', '0');
    const response = await commentaryRoute.POST(post('http://localhost/api/commentary', {
      context: { station: station(), type: 'intro', timeOfDay: 'morning' },
    }));
    expect(response.status).toBe(429);
    await expect(response.json()).resolves.toMatchObject({ error: 'budget_exceeded' });
    expect(fetch).not.toHaveBeenCalled();
  });

  it('does not log upstream response bodies', async () => {
    vi.stubEnv('NODE_ENV', 'production');
    vi.stubEnv('ENABLE_PAID_INFERENCE', 'true');
    vi.stubGlobal('fetch', vi.fn(async () => new Response(UPSTREAM_MARKER, { status: 502 })));
    const error = vi.spyOn(console, 'error').mockImplementation(() => {});
    const voice = await voiceRoute.POST(post('http://localhost/api/voice', { text: 'hello', speed: 1 }));
    const commentary = await commentaryRoute.POST(post('http://localhost/api/commentary', {
      context: { station: station(), type: 'intro', timeOfDay: 'morning' },
    }));
    expect(voice.status).toBe(500);
    expect(commentary.status).toBe(200);
    const dumped = JSON.stringify(error.mock.calls);
    expect(dumped).not.toContain(UPSTREAM_MARKER);
  });
});
