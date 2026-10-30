import { existsSync, readFileSync } from 'node:fs';
import { NextRequest } from 'next/server';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { middleware } from '@/middleware';
import * as commentaryRoute from '@/app/api/commentary/route';
import * as voiceRoute from '@/app/api/voice/route';
import { secretMatches } from '@/lib/auth/route-gate';
import { resetPaidInferenceBudgetForTests } from '@/lib/llm/paid-inference';

const ADMIN_TOKEN = 'fixture-admin-token-0123456789abcdef';
const TELEGRAM_SECRET = 'fixture-telegram-secret-0123456789';

// Every reviewed route (see api-route-inventory.test.ts) that needs the admin token.
const ADMIN_ROUTES: Array<[string, string]> = [
  ['POST', '/api/commentary'],
  ['GET', '/api/messages'],
  ['POST', '/api/messages'],
  ['PATCH', '/api/messages'],
  ['GET', '/api/spotify/callback?code=fixture'],
  ['GET', '/api/spotify/disconnect'],
  ['GET', '/api/stations'],
  ['POST', '/api/stations'],
  ['PUT', '/api/stations'],
  ['POST', '/api/voice'],
  ['GET', '/api/voices'],
  ['POST', '/api/voices'],
  ['DELETE', '/api/voices'],
  ['GET', '/api'],
  ['POST', '/api/not-a-route'],
];

const TELEGRAM_ROUTES = ['/api/telegram', '/api/webhooks/telegram'];

function request(method: string, path: string, headers: Record<string, string> = {}) {
  const hasBody = method !== 'GET' && method !== 'HEAD';
  return new NextRequest(`http://localhost${path}`, {
    method,
    headers: { 'content-type': 'application/json', ...headers },
    body: hasBody ? '{}' : undefined,
  });
}

function allowed(response: Response) {
  return response.status === 200 && response.headers.get('x-middleware-next') === '1';
}

describe('ray-do lockdown middleware', () => {
  beforeEach(() => {
    vi.stubEnv('RAY_DO_ADMIN_TOKEN', ADMIN_TOKEN);
    vi.stubEnv('TELEGRAM_WEBHOOK_SECRET', TELEGRAM_SECRET);
  });

  afterEach(() => {
    vi.unstubAllEnvs();
  });

  it('returns 401 on every admin route without credentials', async () => {
    for (const [method, path] of ADMIN_ROUTES) {
      const response = await middleware(request(method, path));
      expect(response.status, `${method} ${path}`).toBe(401);
      expect(await response.json(), path).toEqual({ error: 'unauthorized' });
    }
  });

  it('returns 401 on every admin route with a wrong, partial or extended token', async () => {
    const wrong = [
      `Bearer wrong-${ADMIN_TOKEN}`,
      `Bearer ${ADMIN_TOKEN}x`,
      `Bearer ${ADMIN_TOKEN.slice(0, -1)}`,
      `Bearer ${ADMIN_TOKEN.toUpperCase()}`,
      ADMIN_TOKEN,
      `Basic ${ADMIN_TOKEN}`,
      'Bearer ',
    ];
    for (const [method, path] of ADMIN_ROUTES) {
      for (const authorization of wrong) {
        const response = await middleware(request(method, path, { authorization }));
        expect(response.status, `${method} ${path} ${authorization.slice(0, 7)}`).toBe(401);
      }
    }
  });

  it('does not accept the Telegram secret as an admin credential', async () => {
    for (const [method, path] of ADMIN_ROUTES) {
      const response = await middleware(request(method, path, {
        'x-telegram-bot-api-secret-token': TELEGRAM_SECRET,
        authorization: `Bearer ${TELEGRAM_SECRET}`,
      }));
      expect(response.status, `${method} ${path}`).toBe(401);
    }
  });

  it('lets the correct admin token through on every admin route', async () => {
    for (const [method, path] of ADMIN_ROUTES) {
      const upper = await middleware(request(method, path, { authorization: `Bearer ${ADMIN_TOKEN}` }));
      const lower = await middleware(request(method, path, { authorization: `bearer ${ADMIN_TOKEN}` }));
      expect(allowed(upper), `${method} ${path}`).toBe(true);
      expect(allowed(lower), `${method} ${path}`).toBe(true);
    }
  });

  it('fails closed with 503 when the admin token is unset, empty or too short', async () => {
    for (const value of [undefined, '', 'x'.repeat(31)]) {
      vi.stubEnv('RAY_DO_ADMIN_TOKEN', value);
      for (const [method, path] of ADMIN_ROUTES) {
        const presented = value ?? '';
        const response = await middleware(request(method, path, { authorization: `Bearer ${presented}` }));
        expect(response.status, `${method} ${path} len=${presented.length}`).toBe(503);
        expect(await response.json()).toEqual({ error: 'misconfig' });
      }
    }
  });

  it('fails closed with 503 when the admin token is blank or short after trimming', async () => {
    for (const value of [' ', '   ', '\n', ' \t\r\n ', `  ${'x'.repeat(31)}  `, `\n${'x'.repeat(31)}\n`]) {
      vi.stubEnv('RAY_DO_ADMIN_TOKEN', value);
      for (const [method, path] of ADMIN_ROUTES) {
        for (const authorization of ['Bearer x', `Bearer ${'x'.repeat(31)}`, `Bearer ${ADMIN_TOKEN}`]) {
          const response = await middleware(request(method, path, { authorization }));
          expect(response.status, `${method} ${path} ${JSON.stringify(value)}`).toBe(503);
          expect(await response.json()).toEqual({ error: 'misconfig' });
        }
      }
    }
  });

  it('trims a padded admin token in the env and still matches the exact token', async () => {
    for (const value of [`  ${ADMIN_TOKEN}  `, `${ADMIN_TOKEN}\n`, `\t${ADMIN_TOKEN}\r\n`]) {
      vi.stubEnv('RAY_DO_ADMIN_TOKEN', value);
      for (const [method, path] of ADMIN_ROUTES) {
        const ok = await middleware(request(method, path, { authorization: `Bearer ${ADMIN_TOKEN}` }));
        expect(allowed(ok), `${method} ${path} ${JSON.stringify(value)}`).toBe(true);
        const wrong = await middleware(request(method, path, { authorization: `Bearer ${ADMIN_TOKEN}x` }));
        expect(wrong.status, `${method} ${path}`).toBe(401);
      }
    }
  });

  it('accepts an admin token of exactly 32 characters after trimming', async () => {
    const token = 'k'.repeat(32);
    vi.stubEnv('RAY_DO_ADMIN_TOKEN', ` ${token} `);
    for (const [method, path] of ADMIN_ROUTES) {
      expect(allowed(await middleware(request(method, path, { authorization: `Bearer ${token}` }))), path).toBe(true);
    }
  });

  it('requires the Telegram secret header on the Telegram receivers', async () => {
    for (const path of TELEGRAM_ROUTES) {
      expect((await middleware(request('POST', path))).status, path).toBe(401);
      expect((await middleware(request('POST', path, {
        'x-telegram-bot-api-secret-token': `${TELEGRAM_SECRET}x`,
      }))).status, path).toBe(401);
      expect((await middleware(request('POST', path, {
        authorization: `Bearer ${ADMIN_TOKEN}`,
      }))).status, path).toBe(401);
      expect(allowed(await middleware(request('POST', path, {
        'x-telegram-bot-api-secret-token': TELEGRAM_SECRET,
      }))), path).toBe(true);
      expect(allowed(await middleware(request('POST', `${path}/`, {
        'x-telegram-bot-api-secret-token': TELEGRAM_SECRET,
      }))), `${path}/`).toBe(true);
    }
  });

  it('fails closed with 503 on the Telegram receivers when the secret is unset', async () => {
    vi.stubEnv('TELEGRAM_WEBHOOK_SECRET', '');
    for (const path of TELEGRAM_ROUTES) {
      const response = await middleware(request('POST', path, { 'x-telegram-bot-api-secret-token': '' }));
      expect(response.status, path).toBe(503);
    }
  });

  it('fails closed with 503 on the Telegram receivers when the secret is blank or under 32 chars', async () => {
    const short = 't'.repeat(31);
    for (const value of [' ', ' \t\n ', short, `  ${short}  `, `${short}\n`]) {
      vi.stubEnv('TELEGRAM_WEBHOOK_SECRET', value);
      for (const path of TELEGRAM_ROUTES) {
        for (const presented of [short, value, TELEGRAM_SECRET]) {
          const response = await middleware(request('POST', path, { 'x-telegram-bot-api-secret-token': presented }));
          expect(response.status, `${path} ${JSON.stringify(value)}`).toBe(503);
          expect(await response.json()).toEqual({ error: 'misconfig' });
        }
      }
    }
  });

  it('accepts a Telegram secret of exactly 32 chars, padded or not', async () => {
    const secret = 's'.repeat(32);
    for (const value of [secret, `  ${secret}  `, `${secret}\n`]) {
      vi.stubEnv('TELEGRAM_WEBHOOK_SECRET', value);
      for (const path of TELEGRAM_ROUTES) {
        expect(allowed(await middleware(request('POST', path, {
          'x-telegram-bot-api-secret-token': secret,
        }))), `${path} ${JSON.stringify(value)}`).toBe(true);
        expect((await middleware(request('POST', path, {
          'x-telegram-bot-api-secret-token': `${secret}x`,
        }))).status, path).toBe(401);
      }
    }
  });

  it('returns 410 for set-webhook for every caller and the handler is gone', async () => {
    const callers: Record<string, string>[] = [
      {},
      { authorization: `Bearer ${ADMIN_TOKEN}` },
      { 'x-telegram-bot-api-secret-token': TELEGRAM_SECRET },
    ];
    for (const path of ['/api/telegram/set-webhook', '/api/telegram/set-webhook/']) {
      for (const method of ['GET', 'POST']) {
        for (const headers of callers) {
          const response = await middleware(request(method, path, headers));
          expect(response.status, `${method} ${path}`).toBe(410);
          expect(await response.json()).toEqual({ error: 'gone' });
        }
      }
    }
    expect(existsSync('app/api/telegram/set-webhook/route.ts')).toBe(false);
  });

  it('never matches an empty expected secret', async () => {
    expect(await secretMatches('', '')).toBe(false);
    expect(await secretMatches(null, '')).toBe(false);
    expect(await secretMatches(ADMIN_TOKEN, ADMIN_TOKEN)).toBe(true);
  });

  // Fry's N2 on #262: timing cannot be unit-tested, so pin the mechanism instead.
  // A plain `===` swap gives the same answers, so it is caught structurally.
  it('hashes both sides to fixed-length digests before every compare', async () => {
    const digest = vi.spyOn(crypto.subtle, 'digest');
    try {
      for (const provided of ['x', `${ADMIN_TOKEN}x`, ADMIN_TOKEN, null]) {
        digest.mockClear();
        await secretMatches(provided, ADMIN_TOKEN);
        expect(digest, String(provided)).toHaveBeenCalledTimes(2);
        for (const call of digest.mock.calls) expect(call[0]).toBe('SHA-256');
        const hashed = digest.mock.calls.map((c) => new TextDecoder().decode(c[1] as Uint8Array)).sort();
        expect(hashed).toEqual([provided ?? '', ADMIN_TOKEN].sort());
      }
    } finally {
      digest.mockRestore();
    }
  });

  it('keeps the constant-time XOR fold and never compares secrets with ==', () => {
    const source = readFileSync('lib/auth/route-gate.ts', 'utf8').replace(/\/\*[\s\S]*?\*\/|\/\/.*$/gm, '');
    const body = /export async function secretMatches[\s\S]*?\n}\n/.exec(source)?.[0] ?? '';
    expect(body).toMatch(/sha256\(provided \?\? ''\)/);
    expect(body).toMatch(/sha256\(expected\)/);
    expect(body).toMatch(/for \(let i = 0; i < wanted\.length; i\+\+\) diff \|= actual\[i\] \^ wanted\[i\];/);
    expect(body).toMatch(/return diff === 0;/);
    expect(body).not.toMatch(/\b(provided|expected|actual|wanted)\s*[!=]==?|[!=]==?\s*(provided|expected|actual|wanted)\b/);
    expect(source).not.toMatch(/\b(provided|expected)\s*[!=]==?\s*(provided|expected)\b/);
  });

  it('keeps timingSafeEqual over digests in the Telegram handler check', () => {
    const source = readFileSync('lib/telegram/webhook-auth.ts', 'utf8').replace(/\/\*[\s\S]*?\*\/|\/\/.*$/gm, '');
    expect(source).toMatch(/createHash\('sha256'\)\.update\(provided \?\? '', 'utf8'\)\.digest\(\)/);
    expect(source).toMatch(/createHash\('sha256'\)\.update\(expected, 'utf8'\)\.digest\(\)/);
    expect(source).toMatch(/return timingSafeEqual\(actual, wanted\);/);
    expect(source).not.toMatch(/\b(provided|expected|actual|wanted)\s*[!=]==?|[!=]==?\s*(provided|expected|actual|wanted)\b/);
  });

  it('never trims the presented credential', async () => {
    expect(await secretMatches(` ${ADMIN_TOKEN}`, ADMIN_TOKEN)).toBe(false);
    expect(await secretMatches(`${ADMIN_TOKEN}\n`, ADMIN_TOKEN)).toBe(false);
    expect(await secretMatches(`${ADMIN_TOKEN} `, ADMIN_TOKEN)).toBe(false);
  });
});

describe('paid routes repeat the admin check next to the spend', () => {
  beforeEach(() => {
    resetPaidInferenceBudgetForTests();
    vi.stubEnv('NODE_ENV', 'production');
    vi.stubEnv('ENABLE_PAID_INFERENCE', 'true');
    vi.stubEnv('MINIMAX_API_KEY', 'fixture-minimax-key');
    vi.stubEnv('RAY_DO_ADMIN_TOKEN', ADMIN_TOKEN);
    vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify({
      data: { audio: Buffer.from('ok').toString('hex') },
      choices: [{ message: { content: 'fixture line' } }],
    }), { status: 200, headers: { 'content-type': 'application/json' } })));
  });

  afterEach(() => {
    vi.unstubAllEnvs();
    vi.unstubAllGlobals();
  });

  const commentaryBody = JSON.stringify({
    context: {
      station: { id: 's', name: 'Fixture FM', style: 'balanced', djName: 'Ray', djPersonality: 'warm' },
      type: 'intro',
      timeOfDay: 'morning',
    },
  });

  function paid(path: string, body: string, headers: Record<string, string> = {}) {
    return new NextRequest(`http://localhost${path}`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', ...headers },
      body,
    });
  }

  async function both(headers: Record<string, string> = {}) {
    const voice = await voiceRoute.POST(paid('/api/voice', JSON.stringify({ text: 'hello' }), headers));
    const commentary = await commentaryRoute.POST(paid('/api/commentary', commentaryBody, headers));
    return [voice.status, commentary.status];
  }

  it('returns 401 without or with a wrong token and never calls MiniMax', async () => {
    expect(await both()).toEqual([401, 401]);
    expect(await both({ authorization: `Bearer ${ADMIN_TOKEN}x` })).toEqual([401, 401]);
    expect(fetch).not.toHaveBeenCalled();
  });

  it('returns 503 when the admin token is unset and never calls MiniMax', async () => {
    vi.stubEnv('RAY_DO_ADMIN_TOKEN', '');
    expect(await both({ authorization: 'Bearer ' })).toEqual([503, 503]);
    expect(fetch).not.toHaveBeenCalled();
  });

  it('returns 503 when the admin token is whitespace-only and never calls MiniMax', async () => {
    vi.stubEnv('RAY_DO_ADMIN_TOKEN', ' \t\n ');
    expect(await both({ authorization: 'Bearer x' })).toEqual([503, 503]);
    expect(fetch).not.toHaveBeenCalled();
  });

  it('reaches the provider with the exact token when the env value is padded', async () => {
    vi.stubEnv('RAY_DO_ADMIN_TOKEN', `  ${ADMIN_TOKEN}\n`);
    expect(await both({ authorization: `Bearer ${ADMIN_TOKEN}` })).toEqual([200, 200]);
    expect(fetch).toHaveBeenCalledTimes(2);
  });

  it('reaches the provider only with the admin token', async () => {
    expect(await both({ authorization: `Bearer ${ADMIN_TOKEN}` })).toEqual([200, 200]);
    expect(fetch).toHaveBeenCalledTimes(2);
  });
});
