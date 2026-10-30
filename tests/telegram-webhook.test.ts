import { NextRequest } from 'next/server';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import * as control from '@/app/api/telegram/route';
import * as intake from '@/app/api/webhooks/telegram/route';

const SECRET = 'fixture-webhook-secret';
const PHRASE = 'fixture-message-phrase';

function post(url: string, body: unknown, secret?: string) {
  const headers: Record<string, string> = { 'content-type': 'application/json' };
  if (secret !== undefined) headers['x-telegram-bot-api-secret-token'] = secret;
  return new NextRequest(url, { method: 'POST', headers, body: JSON.stringify(body) });
}

describe('telegram webhook authentication', () => {
  beforeEach(() => {
    vi.stubEnv('TELEGRAM_WEBHOOK_SECRET', SECRET);
    vi.stubGlobal('fetch', vi.fn(() => {
      throw new Error('network disabled in test');
    }));
  });

  afterEach(() => {
    vi.unstubAllEnvs();
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  it('rejects the control receiver when the secret is unset', async () => {
    vi.stubEnv('TELEGRAM_WEBHOOK_SECRET', '');
    const response = await control.POST(post('http://localhost/api/telegram', {
      message: { chat: { id: 1 }, text: '/start' },
    }));
    expect(response.status).toBe(401);
  });

  it('rejects the control receiver when the secret does not match', async () => {
    const response = await control.POST(post('http://localhost/api/telegram', {
      message: { chat: { id: 1 }, text: '/start' },
    }, 'wrong-fixture-secret'));
    expect(response.status).toBe(401);
  });

  it('accepts the control receiver when the secret matches', async () => {
    const response = await control.POST(post('http://localhost/api/telegram', {
      message: { chat: { id: 1 }, text: '/start' },
    }, SECRET));
    expect(response.status).toBe(200);
  });

  it('rejects the intake receiver when the secret is unset', async () => {
    vi.stubEnv('TELEGRAM_WEBHOOK_SECRET', '');
    const response = await intake.POST(post('http://localhost/api/webhooks/telegram', {
      message: { from: { id: 7 }, text: PHRASE },
    }));
    expect(response.status).toBe(401);
  });

  it('rejects the intake receiver when the secret does not match', async () => {
    const response = await intake.POST(post('http://localhost/api/webhooks/telegram', {
      message: { from: { id: 7 }, text: PHRASE },
    }, 'wrong-fixture-secret'));
    expect(response.status).toBe(401);
  });

  it('accepts the intake receiver without logging the message body', async () => {
    const log = vi.spyOn(console, 'log').mockImplementation(() => {});
    const error = vi.spyOn(console, 'error').mockImplementation(() => {});
    const response = await intake.POST(post('http://localhost/api/webhooks/telegram', {
      message: { from: { id: 7 }, text: PHRASE },
    }, SECRET));
    expect(response.status).toBe(200);
    const dumped = JSON.stringify(log.mock.calls) + JSON.stringify(error.mock.calls);
    expect(dumped).not.toContain(PHRASE);
  });

  it('does not expose a verify-token GET handler', () => {
    expect('GET' in intake).toBe(false);
  });
});
