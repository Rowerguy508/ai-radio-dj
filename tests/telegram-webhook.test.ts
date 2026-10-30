import { NextRequest } from 'next/server';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import * as control from '@/app/api/telegram/route';
import * as intake from '@/app/api/webhooks/telegram/route';

const SECRET = 'fixture-webhook-secret-0123456789ab';
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

  it('rejects both receivers when the secret is blank or under 32 chars after trimming', async () => {
    const short = 'w'.repeat(31);
    for (const value of ['   ', '\n\t', short, `  ${short}\n`]) {
      vi.stubEnv('TELEGRAM_WEBHOOK_SECRET', value);
      for (const presented of [short, value]) {
        const c = await control.POST(post('http://localhost/api/telegram', {
          message: { chat: { id: 1 }, text: '/start' },
        }, presented));
        const i = await intake.POST(post('http://localhost/api/webhooks/telegram', {
          message: { from: { id: 7 }, text: PHRASE },
        }, presented));
        expect([c.status, i.status], JSON.stringify(value)).toEqual([401, 401]);
      }
    }
  });

  it('accepts both receivers with a 32-char secret, padded in the env or not', async () => {
    vi.spyOn(console, 'log').mockImplementation(() => {});
    vi.spyOn(console, 'error').mockImplementation(() => {});
    const secret = 'w'.repeat(32);
    for (const value of [secret, `  ${secret}\n`]) {
      vi.stubEnv('TELEGRAM_WEBHOOK_SECRET', value);
      const c = await control.POST(post('http://localhost/api/telegram', {
        message: { chat: { id: 1 }, text: '/start' },
      }, secret));
      expect(c.status, JSON.stringify(value)).toBe(200);
      const i = await intake.POST(post('http://localhost/api/webhooks/telegram', {
        message: { from: { id: 7 }, text: PHRASE },
      }, secret));
      expect(i.status, JSON.stringify(value)).toBe(200);
    }
  });

  it('does not expose a verify-token GET handler', () => {
    expect('GET' in intake).toBe(false);
  });
});
