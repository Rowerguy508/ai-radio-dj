/**
 * Sentinel's nit on #294, end to end through the deployed entry point: api/tts.ts builds its
 * Deps with `defaultDeps()` from process.env. With an ElevenLabs key, no store and VERCEL_ENV
 * set, it is 500 misconfig (log reason no_store) and makes zero fetches (no ElevenLabs, no
 * store). Own file so the module-level shared limiter starts empty.
 */
import { test, describe, mock } from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import type { Env } from '../src/handler.js';

const TOKEN = 'test-owner-token-not-a-real-secret';
const TOKEN_HASH = crypto.createHash('sha256').update(TOKEN).digest('hex');
const VOICE = 'voiceAllowed123';
const label = (v: string | undefined) => `VERCEL_ENV ${JSON.stringify(v)}`;
const pcm = () => new Response(Buffer.alloc(22_050 * 2, 1), { status: 200, headers: { 'Content-Type': 'audio/pcm' } });
const env = (o: Env = {}): Env => ({
  AERODJ_TTS_TOKEN_SHA256: TOKEN_HASH,
  AERODJ_TTS_VOICE_IDS: VOICE,
  ELEVENLABS_API_KEY: 'test-elevenlabs-key-not-real',
  AERODJ_TTS_RATE_PER_MINUTE: '600',
  AERODJ_TTS_PRO_RATE_PER_MINUTE: '600',
  ...o,
});
const req = () => ({ body: { upstream: 'elevenlabs', voiceId: VOICE, text: 'Hello from the DJ booth.', format: 'text' } });

async function withProcessEnv<T>(patch: Env, fn: () => Promise<T> | T): Promise<T> {
  const saved = new Map<string, string | undefined>();
  for (const [k, v] of Object.entries(patch)) {
    saved.set(k, process.env[k]);
    if (v === undefined) delete process.env[k];
    else process.env[k] = v;
  }
  try {
    return await fn();
  } finally {
    for (const [k, v] of saved) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
  }
}

describe('api/tts on Vercel: key set, no store -> 500 no_store, zero fetches', () => {
  for (const v of ['production', 'preview', 'development']) {
    test(`${label(v)}: the deployed api/tts entry (defaultDeps from process.env) is 500 no_store with zero fetches`, async () => {
      const storeVars = Object.keys(process.env).filter((k) => /^(KV_|UPSTASH_)/.test(k));
      const patch: Env = { ...env({ VERCEL_ENV: v }), AERODJ_TTS_PAID_STOP: undefined, AERODJ_TTS_ACCEPT_BEST_EFFORT_LIMITS: 'true' };
      for (const k of storeVars) patch[k] = undefined;
      const fetchMock = mock.method(globalThis, 'fetch', async () => pcm());
      try {
        await withProcessEnv(patch, async () => {
          const { default: api } = await import('../api/tts.js');
          const headers: Record<string, string> = {};
          let status = 0;
          let out: Buffer | undefined;
          const res = {
            set statusCode(n: number) { status = n; },
            setHeader: (k: string, val: string) => { headers[k] = val; },
            end: (b: Buffer) => { out = b; },
          };
          const lines: string[] = [];
          const logMock = mock.method(console, 'log', (...a: unknown[]) => lines.push(a.map(String).join(' ')));
          try {
            await api({ method: 'POST', headers: { authorization: `Bearer ${TOKEN}` }, body: req().body } as never, res as never);
          } finally {
            logMock.mock.restore();
          }
          assert.equal(status, 500);
          assert.equal(JSON.parse(String(out)).reason, 'misconfig');
          assert.equal(headers['Retry-After'], '3600');
          assert.deepEqual(lines.map((l) => JSON.parse(l).reason), ['no_store'], lines.join('\n'));
        });
        assert.equal(fetchMock.mock.callCount(), 0, 'no ElevenLabs or store fetch');
      } finally {
        fetchMock.mock.restore();
      }
    });
  }
});
