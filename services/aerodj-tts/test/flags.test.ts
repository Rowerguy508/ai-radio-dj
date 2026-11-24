import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import { appFlags, handleFlags, AIRPLAY_LONGFORM_FLAG, ONAIRLY_NOW_PLAYING_SESSION_FLAG } from '../src/flags-handler.js';
import flagsEndpoint from '../api/flags.js';

describe('GET /api/flags (#525)', () => {
  test('djAirPlayLongForm is a kill switch: off only for the exact string false', () => {
    assert.equal(AIRPLAY_LONGFORM_FLAG, 'AERODJ_DJ_AIRPLAY_LONGFORM');
    assert.deepEqual(appFlags({}), { djAirPlayLongForm: true, onAirlyNowPlayingSession: true }, 'unset: on');
    for (const value of ['', 'FALSE', 'False', ' false', 'false ', '0', 'no', 'off', 'true']) {
      assert.deepEqual(appFlags({ AERODJ_DJ_AIRPLAY_LONGFORM: value }), { djAirPlayLongForm: true, onAirlyNowPlayingSession: true }, JSON.stringify(value));
    }
    assert.deepEqual(appFlags({ AERODJ_DJ_AIRPLAY_LONGFORM: 'false' }), { djAirPlayLongForm: false, onAirlyNowPlayingSession: true });
  });

  test('onAirlyNowPlayingSession is a kill switch: off only for the exact string false (#600)', () => {
    assert.equal(ONAIRLY_NOW_PLAYING_SESSION_FLAG, 'AERODJ_ONAIRLY_NOW_PLAYING_SESSION');
    for (const value of ['', 'FALSE', 'False', ' false', 'false ', '0', 'no', 'off', 'true']) {
      assert.deepEqual(appFlags({ AERODJ_ONAIRLY_NOW_PLAYING_SESSION: value }),
        { djAirPlayLongForm: true, onAirlyNowPlayingSession: true }, JSON.stringify(value));
    }
    assert.deepEqual(appFlags({ AERODJ_ONAIRLY_NOW_PLAYING_SESSION: 'false' }),
      { djAirPlayLongForm: true, onAirlyNowPlayingSession: false }, 'independent of the AirPlay flag');
  });

  test('GET answers the flags as JSON, never cached', async () => {
    const res = handleFlags(new Request('https://proxy.invalid/api/flags'), { AERODJ_DJ_AIRPLAY_LONGFORM: 'false' });
    assert.equal(res.status, 200);
    assert.equal(res.headers.get('cache-control'), 'no-store');
    assert.match(res.headers.get('content-type') ?? '', /^application\/json/);
    assert.deepEqual(await res.json(), { djAirPlayLongForm: false, onAirlyNowPlayingSession: true });
  });

  test('the response depends only on env, not on the request', async () => {
    const req = new Request('https://proxy.invalid/api/flags?x=1', {
      headers: { Authorization: 'Bearer anything', Cookie: 'a=b', 'X-Install': 'id' },
    });
    const res = handleFlags(req, {});
    assert.deepEqual(await res.json(), { djAirPlayLongForm: true, onAirlyNowPlayingSession: true });
  });

  test('other methods are refused', async () => {
    for (const method of ['POST', 'PUT', 'DELETE', 'PATCH']) {
      const res = handleFlags(new Request('https://proxy.invalid/api/flags', { method, body: '{}' }), {});
      assert.equal(res.status, 405, method);
      assert.equal(res.headers.get('allow'), 'GET, HEAD');
    }
    const head = handleFlags(new Request('https://proxy.invalid/api/flags', { method: 'HEAD' }), {});
    assert.equal(head.status, 200);
    assert.equal(await head.text(), '');
  });

  test('the Vercel entry reads process.env', async () => {
    const before = process.env.AERODJ_DJ_AIRPLAY_LONGFORM;
    try {
      delete process.env.AERODJ_DJ_AIRPLAY_LONGFORM;
      const on = flagsEndpoint.fetch(new Request('https://proxy.invalid/api/flags'));
      assert.deepEqual(await on.json(), { djAirPlayLongForm: true, onAirlyNowPlayingSession: true }, 'unset: on');
      process.env.AERODJ_DJ_AIRPLAY_LONGFORM = 'false';
      const off = flagsEndpoint.fetch(new Request('https://proxy.invalid/api/flags'));
      assert.deepEqual(await off.json(), { djAirPlayLongForm: false, onAirlyNowPlayingSession: true });
    } finally {
      if (before === undefined) delete process.env.AERODJ_DJ_AIRPLAY_LONGFORM;
      else process.env.AERODJ_DJ_AIRPLAY_LONGFORM = before;
    }
  });
});

describe('GET /api/flags logs nothing (#525 privacy)', () => {
  const methods = ['log', 'info', 'warn', 'error', 'debug', 'trace', 'dir', 'table'] as const;

  function spyConsole(): { calls: unknown[][]; restore: () => void } {
    const calls: unknown[][] = [];
    const originals = methods.map((m) => [m, console[m]] as const);
    for (const m of methods) {
      (console as unknown as Record<string, (...args: unknown[]) => void>)[m] = (...args: unknown[]) => {
        calls.push([m, ...args]);
      };
    }
    return {
      calls,
      restore: () => {
        for (const [m, fn] of originals) (console as unknown as Record<string, unknown>)[m] = fn;
      },
    };
  }

  const IP = '203.0.113.77';
  const REAL_IP = '198.51.100.23';
  const UA = 'OnAirly/41 CFNetwork/3826 Darwin/26.0 spy-marker';
  const headers = { 'x-forwarded-for': `${IP}, 10.0.0.1`, 'x-real-ip': REAL_IP, 'user-agent': UA, 'x-vercel-forwarded-for': IP };

  for (const env of [{}, { AERODJ_DJ_AIRPLAY_LONGFORM: 'false' }, { AERODJ_DJ_AIRPLAY_LONGFORM: 'junk' }]) {
    test(`no console output at all (env ${JSON.stringify(env)}), GET, HEAD and a refused method`, async () => {
      const spy = spyConsole();
      try {
        for (const method of ['GET', 'HEAD', 'POST']) {
          const res = handleFlags(new Request('https://proxy.invalid/api/flags', { method, headers }), env);
          await res.text();
        }
        const before = process.env.AERODJ_DJ_AIRPLAY_LONGFORM;
        try {
          if ('AERODJ_DJ_AIRPLAY_LONGFORM' in env) process.env.AERODJ_DJ_AIRPLAY_LONGFORM = env.AERODJ_DJ_AIRPLAY_LONGFORM;
          else delete process.env.AERODJ_DJ_AIRPLAY_LONGFORM;
          await flagsEndpoint.fetch(new Request('https://proxy.invalid/api/flags', { headers })).text();
        } finally {
          if (before === undefined) delete process.env.AERODJ_DJ_AIRPLAY_LONGFORM;
          else process.env.AERODJ_DJ_AIRPLAY_LONGFORM = before;
        }
      } finally {
        spy.restore();
      }
      const logged = JSON.stringify(spy.calls);
      for (const value of [IP, REAL_IP, UA, 'spy-marker', '10.0.0.1']) {
        assert.ok(!logged.includes(value), `logged ${value}`);
      }
      assert.equal(spy.calls.length, 0, `nothing is logged: ${logged}`);
    });
  }

  test('the handler source has no console call and reads no request header', async () => {
    const { readFileSync } = await import('node:fs');
    for (const file of ['src/flags-handler.ts', 'api/flags.ts']) {
      const source = readFileSync(new URL(`../${file}`, import.meta.url), 'utf8');
      assert.ok(!/console\./.test(source), `${file}: console`);
      assert.ok(!/headers\.get|x-forwarded-for|x-real-ip|user-agent/i.test(source), `${file}: reads a request header`);
    }
  });
});
