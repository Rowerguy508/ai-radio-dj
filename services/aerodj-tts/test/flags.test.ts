import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import { appFlags, handleFlags, AIRPLAY_LONGFORM_FLAG } from '../src/flags-handler.js';
import flagsEndpoint from '../api/flags.js';

describe('GET /api/flags (#525)', () => {
  test('djAirPlayLongForm is a kill switch: off only for the exact string false', () => {
    assert.equal(AIRPLAY_LONGFORM_FLAG, 'AERODJ_DJ_AIRPLAY_LONGFORM');
    assert.deepEqual(appFlags({}), { djAirPlayLongForm: true }, 'unset: on');
    for (const value of ['', 'FALSE', 'False', ' false', 'false ', '0', 'no', 'off', 'true']) {
      assert.deepEqual(appFlags({ AERODJ_DJ_AIRPLAY_LONGFORM: value }), { djAirPlayLongForm: true }, JSON.stringify(value));
    }
    assert.deepEqual(appFlags({ AERODJ_DJ_AIRPLAY_LONGFORM: 'false' }), { djAirPlayLongForm: false });
  });

  test('GET answers the flags as JSON, never cached', async () => {
    const res = handleFlags(new Request('https://proxy.invalid/api/flags'), { AERODJ_DJ_AIRPLAY_LONGFORM: 'false' });
    assert.equal(res.status, 200);
    assert.equal(res.headers.get('cache-control'), 'no-store');
    assert.match(res.headers.get('content-type') ?? '', /^application\/json/);
    assert.deepEqual(await res.json(), { djAirPlayLongForm: false });
  });

  test('the response depends only on env, not on the request', async () => {
    const req = new Request('https://proxy.invalid/api/flags?x=1', {
      headers: { Authorization: 'Bearer anything', Cookie: 'a=b', 'X-Install': 'id' },
    });
    const res = handleFlags(req, {});
    assert.deepEqual(await res.json(), { djAirPlayLongForm: true });
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
      assert.deepEqual(await on.json(), { djAirPlayLongForm: true }, 'unset: on');
      process.env.AERODJ_DJ_AIRPLAY_LONGFORM = 'false';
      const off = flagsEndpoint.fetch(new Request('https://proxy.invalid/api/flags'));
      assert.deepEqual(await off.json(), { djAirPlayLongForm: false });
    } finally {
      if (before === undefined) delete process.env.AERODJ_DJ_AIRPLAY_LONGFORM;
      else process.env.AERODJ_DJ_AIRPLAY_LONGFORM = before;
    }
  });
});
