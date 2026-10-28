import crypto from 'node:crypto';
import { bearerToken, parseTokenHash, tokenMatches } from './auth.js';
import { InMemoryUsageLimiter, type UsageLimiter } from './limiter.js';
import { ssmlToPlainText } from './ssml.js';
import { pcmToWav, sampleCount, SAMPLE_RATE } from './wav.js';

export const ELEVENLABS_BASE = 'https://api.elevenlabs.io';
export const MAX_RESPONSE_BYTES = 5_000_000; // matches ProxyVoiceProvider.maxResponseBytes
export const MAX_DURATION_SECONDS = 600; // matches ProxyVoiceProvider duration guard
const DEFAULT_MAX_TEXT_CHARS = 600;
const DEFAULT_DAILY_CHAR_CAP = 20_000;
const DEFAULT_REQUESTS_PER_MINUTE = 12;
const DEFAULT_MODEL_ID = 'eleven_flash_v2_5';
const UPSTREAM_TIMEOUT_MS = 15_000;
/** Single-owner deployment: every authenticated request shares one usage bucket. */
const OWNER_KEY = 'owner';

export type Env = Record<string, string | undefined>;

export interface LogEntry {
  requestId: string;
  status: number;
  chars: number;
}

export interface Deps {
  env: Env;
  fetch: typeof fetch;
  limiter: UsageLimiter;
  /** Receives exactly { requestId, status, chars } and nothing else. */
  log: (entry: LogEntry) => void;
  now: () => number;
  timeoutMs: number;
  requestId: () => string;
}

export interface TtsRequest {
  method: string | undefined;
  authorization: string | undefined;
  /** Parsed JSON object, raw JSON string/Buffer, or undefined. */
  body: unknown;
}

export interface TtsResponse {
  status: number;
  headers: Record<string, string>;
  body: Buffer;
}

function positiveInt(value: string | undefined, fallback: number): number {
  const n = Number(value);
  return Number.isInteger(n) && n > 0 ? n : fallback;
}

function csv(value: string | undefined): Set<string> {
  return new Set((value ?? '').split(',').map((s) => s.trim()).filter(Boolean));
}

let sharedLimiter: UsageLimiter | undefined;

/** Per-instance, best-effort limiter (see limiter.ts). */
function defaultLimiter(env: Env): UsageLimiter {
  sharedLimiter ??= new InMemoryUsageLimiter({
    dailyCharCap: positiveInt(env.AERODJ_TTS_DAILY_CHAR_CAP, DEFAULT_DAILY_CHAR_CAP),
    requestsPerMinute: positiveInt(env.AERODJ_TTS_RATE_PER_MINUTE, DEFAULT_REQUESTS_PER_MINUTE),
  });
  return sharedLimiter;
}

export function defaultDeps(env: Env = process.env): Deps {
  return {
    env,
    fetch: globalThis.fetch,
    limiter: defaultLimiter(env),
    // Structured, minimal: request ID, status and character count only.
    log: (entry) => console.log(JSON.stringify({ requestId: entry.requestId, status: entry.status, chars: entry.chars })),
    now: Date.now,
    timeoutMs: UPSTREAM_TIMEOUT_MS,
    requestId: () => crypto.randomUUID(),
  };
}

function parseBody(body: unknown): Record<string, unknown> | null {
  let value = body;
  if (Buffer.isBuffer(value)) value = value.toString('utf8');
  if (typeof value === 'string') {
    try {
      value = JSON.parse(value);
    } catch {
      return null;
    }
  }
  return value && typeof value === 'object' && !Array.isArray(value) ? (value as Record<string, unknown>) : null;
}

/** Generic error messages only: never echo user input or upstream bodies. */
const MESSAGES: Record<number, string> = {
  400: 'Bad request',
  401: 'Unauthorized',
  405: 'Method not allowed',
  429: 'Too many requests',
  500: 'Server misconfigured',
  502: 'Upstream error',
  504: 'Upstream timeout',
};

export async function handleTts(req: TtsRequest, deps: Deps): Promise<TtsResponse> {
  const requestId = deps.requestId();
  let chars = 0;

  const fail = (status: number, extra: Record<string, string> = {}): TtsResponse => {
    deps.log({ requestId, status, chars });
    return {
      status,
      headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store', 'X-Request-Id': requestId, ...extra },
      body: Buffer.from(JSON.stringify({ error: MESSAGES[status] ?? 'Error', requestId })),
    };
  };

  if (req.method !== 'POST') return fail(405, { Allow: 'POST' });

  // --- Auth: owner-only bearer token, stored server-side as a SHA-256 hash. ---
  const expectedHash = parseTokenHash(deps.env.AERODJ_TTS_TOKEN_SHA256);
  if (!expectedHash) return fail(500);
  const token = bearerToken(req.authorization);
  if (!token || !tokenMatches(token, expectedHash)) return fail(401);

  const now = deps.now();
  if (!(await deps.limiter.allowRequest(OWNER_KEY, now))) return fail(429, { 'Retry-After': '60' });

  // --- Validation ---
  const body = parseBody(req.body);
  if (!body) return fail(400);
  if (body.upstream !== 'elevenlabs') return fail(400);
  const voiceId = body.voiceId;
  if (typeof voiceId !== 'string' || !csv(deps.env.AERODJ_TTS_VOICE_IDS).has(voiceId)) return fail(400);
  const format = body.format ?? 'text';
  if (format !== 'text' && format !== 'ssml') return fail(400);
  if (typeof body.text !== 'string') return fail(400);
  const maxChars = positiveInt(deps.env.AERODJ_TTS_MAX_TEXT_CHARS, DEFAULT_MAX_TEXT_CHARS);
  // SSML markup is allowed some headroom before stripping; the spoken text is capped below.
  if (body.text.length > (format === 'ssml' ? maxChars * 4 : maxChars)) return fail(400);
  const text = format === 'ssml' ? ssmlToPlainText(body.text) : body.text.trim();
  if (text.length === 0 || text.length > maxChars) return fail(400);
  chars = text.length;

  if (!(await deps.limiter.canSpend(OWNER_KEY, chars, now))) return fail(429, { 'Retry-After': '3600' });

  const apiKey = deps.env.ELEVENLABS_API_KEY?.trim();
  if (!apiKey) return fail(500);

  // --- Upstream ---
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), deps.timeoutMs);
  let pcm: Buffer;
  let upstreamCost: string | null;
  try {
    const url = `${ELEVENLABS_BASE}/v1/text-to-speech/${encodeURIComponent(voiceId)}?output_format=pcm_22050`;
    const upstream = await deps.fetch(url, {
      method: 'POST',
      headers: { 'xi-api-key': apiKey, 'Content-Type': 'application/json', Accept: 'audio/pcm' },
      body: JSON.stringify({ text, model_id: deps.env.ELEVENLABS_MODEL_ID?.trim() || DEFAULT_MODEL_ID }),
      signal: controller.signal,
    });
    if (!upstream.ok) {
      // Drain without reading into logs or the response.
      await upstream.body?.cancel().catch(() => {});
      return fail(502);
    }
    upstreamCost = upstream.headers.get('character-cost');
    pcm = Buffer.from(await upstream.arrayBuffer());
  } catch {
    return fail(controller.signal.aborted ? 504 : 502);
  } finally {
    clearTimeout(timer);
  }

  const samples = sampleCount(pcm.length);
  const duration = samples / SAMPLE_RATE;
  const wav = pcmToWav(pcm);
  if (samples === 0 || wav.length > MAX_RESPONSE_BYTES || !(duration > 0) || duration > MAX_DURATION_SECONDS) {
    return fail(502);
  }

  const cost = upstreamCost !== null && /^\d+$/.test(upstreamCost.trim()) ? Number(upstreamCost) : chars;
  await deps.limiter.recordSpend(OWNER_KEY, chars, now);
  deps.log({ requestId, status: 200, chars });
  return {
    status: 200,
    headers: {
      'Content-Type': 'audio/wav',
      'Content-Length': String(wav.length),
      'Cache-Control': 'no-store',
      'X-Audio-Duration': String(duration),
      'X-Billed-Characters': String(cost),
      'X-Request-Id': requestId,
    },
    body: wav,
  };
}
