import crypto from 'node:crypto';
import { DISABLED_RETRY_AFTER_SECONDS, MISCONFIG_RETRY_AFTER_SECONDS, STORE_RETRY_AFTER_SECONDS, paidStopped } from './attest-flags.js';
import { bearerToken, parseTokenHash, tokenMatches } from './auth.js';
import {
  DEFAULT_GLOBAL_DAILY_CHAR_CAP,
  DEFAULT_INSTALL_DAILY_CHAR_CAP,
  DEFAULT_REQUESTS_PER_MINUTE,
  InMemoryUsageLimiter,
  LimiterStoreError,
  MAX_CONFIGURED_CHAR_CAP,
  MAX_CONFIGURED_REQUESTS_PER_MINUTE,
  OWNER_SUBJECT,
  RedisUsageLimiter,
  redisRestConfig,
  subjectBucket,
  type LimiterOptions,
  type ProReservation,
  type QuotaReason,
  type Reservation,
  type UsageLimiter,
} from './limiter.js';
import { isVerifiedProSubject, PRO_DAILY_RENDER_ALLOWANCE, proBucket, proDeployment, type ProSubject } from './pro-allowance.js';
import { ssmlToPlainText } from './ssml.js';
import { pcmToWav, sampleCount, SAMPLE_RATE } from './wav.js';

export const ELEVENLABS_BASE = 'https://api.elevenlabs.io';
export const MAX_RESPONSE_BYTES = 5_000_000; // matches ProxyVoiceProvider.maxResponseBytes
export const MAX_DURATION_SECONDS = 600; // matches ProxyVoiceProvider duration guard
const DEFAULT_MAX_TEXT_CHARS = 600;
const DEFAULT_MODEL_ID = 'eleven_flash_v2_5';
/**
 * ElevenLabs voice_settings sent on every render (owner-approved radio tuning).
 * Fixed server-side: the request contract carries no voice settings, so nothing a
 * client sends can change them. Deliberately no `style` (owner decision) and
 * no `use_speaker_boost`. `speed` stays inside the approved [1.0, 1.05] range.
 */
export const VOICE_SETTINGS = Object.freeze({ stability: 0.4, similarity_boost: 0.75, speed: 1.0 });
const UPSTREAM_TIMEOUT_MS = 15_000;
/**
 * Until per-install attestation lands, the owner bearer is the only authenticated caller,
 * so every request is charged to the fixed owner bucket. It has its own cap and also
 * counts against the global ceiling. Nothing in the request body selects the bucket.
 */
const SUBJECT = OWNER_SUBJECT;
const SUBJECT_BUCKET = subjectBucket(SUBJECT);

/**
 * Machine-readable refusal reason, sent as `reason` in the error body and logged.
 * Enum only: never text, ids or keys. `rate` = per-minute rate, `install_daily` = this
 * install's daily cap, `owner_daily` = the owner bucket's daily cap, `global_daily` = the global daily ceiling, `store` = limiter
 * store unreachable (fails closed), `disabled` = master stop `AERODJ_TTS_PAID_STOP` (PR 3),
 * `misconfig` = server configuration missing or invalid (500, PR 3), `daily_allowance` = this
 * Pro purchase's daily render allowance is used up (429 until the next 00:00 UTC; the app
 * switches to the on-device voice quietly, see src/pro-allowance.ts).
 */
export type ErrorReason = 'rate' | QuotaReason | 'store' | 'disabled' | 'misconfig' | 'daily_allowance';
/** Server-log reasons: the wire reasons, plus `pro_chars` (a Pro char-cap 429 that answers `daily_allowance`). */
export type LogReason = ErrorReason | 'pro_chars';

/**
 * A verified Pro request is charged to its OWN subject (Sentinel's B1 on #264), never the
 * owner's or an install's: its own char bucket and its own per-minute rate bucket, plus
 * the shared global ceiling, which still applies to everyone and is checked FIRST, in the
 * same atomic step (Sentinel), so a full global ceiling refuses a Pro request with
 * `global_daily` and moves no Pro counter. So the per-install char cap
 * (1,500/day) does not apply to Pro (Orion and Nigel: it would contradict 40 breaks a day).
 *
 * Char cap: env `AERODJ_TTS_PRO_DAILY_CHARS`, default 12,000 (owner-confirmed default),
 * effective value clamped to the global ceiling (`effectiveProCharCap`), so 9,000 today.
 * Without it, 160 renders x 600 chars would be 96k chars for one subscriber.
 * Rate: env `AERODJ_TTS_PRO_RATE_PER_MINUTE`, default 12/min (the same default as the
 * owner): a break is at most 4 renders, so 12/min fits 3 breaks a minute, far above 160 a day.
 * Both: unset = default; set, a plain decimal integer in range, else the Pro path answers
 * 500 `misconfig` (a typo never widens or silently replaces the owner's number). The owner
 * path reads neither.
 */
export const DEFAULT_PRO_DAILY_CHARS = 12_000;
/** At least one full-length request (the 600-char default per-request cap) must fit. */
export const MIN_PRO_DAILY_CHARS = 600;

/** The Pro daily char cap, or null when the env value is set but invalid (500 misconfig). */
export function proDailyChars(env: Env): number | null {
  const raw = env.AERODJ_TTS_PRO_DAILY_CHARS;
  if (raw === undefined) return DEFAULT_PRO_DAILY_CHARS;
  const n = parseCharCap(raw);
  return n !== null && n >= MIN_PRO_DAILY_CHARS ? n : null;
}

export const DEFAULT_PRO_REQUESTS_PER_MINUTE = DEFAULT_REQUESTS_PER_MINUTE;

/** The Pro per-minute rate, or null when the env value is set but invalid (500 misconfig). */
export function proRatePerMinute(env: Env): number | null {
  const raw = env.AERODJ_TTS_PRO_RATE_PER_MINUTE;
  if (raw === undefined) return DEFAULT_PRO_REQUESTS_PER_MINUTE;
  return parseRatePerMinute(raw);
}

/** Retry-After (seconds) for a rate 429 and a store 503: an upper bound for both window types. */
export const RATE_RETRY_AFTER_SECONDS = 60;
export { STORE_RETRY_AFTER_SECONDS };

export type Env = Record<string, string | undefined>;

export interface LogEntry {
  requestId: string;
  status: number;
  chars: number;
  /** Upstream non-2xx only: ElevenLabs' integer HTTP status. */
  upstreamStatus?: number;
  /** Upstream non-2xx only: allowlisted `detail.status` code, else 'other'. */
  upstreamCode?: string;
  /** 429, 503 and 500 `misconfig` only: the enum refusal reason. */
  reason?: LogReason;
}

/** Bytes of an upstream error body read for `detail.status`; the rest is discarded. */
export const MAX_ERROR_BODY_BYTES = 4096;
const UPSTREAM_CODE = /^[a-z0-9_]{1,64}$/;

/** Reads at most `MAX_ERROR_BODY_BYTES` of a response body, then cancels the stream. */
async function readCapped(res: Response): Promise<string> {
  const reader = res.body?.getReader();
  if (!reader) return '';
  const chunks: Uint8Array[] = [];
  let total = 0;
  try {
    while (total < MAX_ERROR_BODY_BYTES) {
      const { done, value } = await reader.read();
      if (done || !value) break;
      const take = value.subarray(0, MAX_ERROR_BODY_BYTES - total);
      chunks.push(take);
      total += take.length;
    }
  } finally {
    await reader.cancel().catch(() => {});
  }
  return Buffer.concat(chunks).toString('utf8');
}

/**
 * Returns ElevenLabs' `detail.status` only when it is a short lowercase code
 * (/^[a-z0-9_]{1,64}$/); anything else (absent, non-JSON, invalid) is 'other'.
 * The body itself, `detail.message` and every other field are discarded.
 */
export async function upstreamErrorCode(res: Response): Promise<string> {
  let text: string;
  try {
    text = await readCapped(res);
  } catch {
    return 'other';
  }
  try {
    const parsed: unknown = JSON.parse(text);
    const detail = parsed && typeof parsed === 'object' ? (parsed as Record<string, unknown>).detail : undefined;
    const status = detail && typeof detail === 'object' ? (detail as Record<string, unknown>).status : undefined;
    return typeof status === 'string' && UPSTREAM_CODE.test(status) ? status : 'other';
  } catch {
    return 'other';
  }
}

export interface Deps {
  env: Env;
  fetch: typeof fetch;
  /** null = no acceptable limiter configured (production without a durable store): fail closed. */
  limiter: UsageLimiter | null;
  /** Receives { requestId, status, chars }, plus { upstreamStatus, upstreamCode } on an upstream non-2xx only. */
  log: (entry: LogEntry) => void;
  now: () => number;
  timeoutMs: number;
  requestId: () => string;
  /** Lost-refund log (Fry's nit on #257); defaults to one console.log JSON line. */
  logRefundLost?: (entry: RefundLostLog) => void;
}

/**
 * Emitted once when the refund after an upstream non-2xx fails or times out, so that
 * day's budget stays charged. Enums and numbers only: no keys, install IDs, text or tokens.
 */
export interface RefundLostLog {
  event: 'refund_lost';
  reason: 'store' | 'timeout';
  chars: number;
  /**
   * `pro_render`: the lost refund was a Pro reservation (its chars and its render; Fry's N1 on #264).
   * Absent for a char refund, so that line keeps its #259 shape. Never a bucket or id.
   */
  kind?: 'pro_render';
}

export const logRefundLostToConsole = (entry: RefundLostLog): void => {
  console.log(
    JSON.stringify({ event: entry.event, reason: entry.reason, chars: entry.chars, ...(entry.kind === 'pro_render' ? { kind: entry.kind } : {}) }),
  );
};

export interface TtsRequest {
  method: string | undefined;
  authorization: string | undefined;
  /** Parsed JSON object, raw JSON string/Buffer, or undefined. */
  body: unknown;
  /**
   * The Pro purchase this request is charged to, set ONLY by server code from a JWS it
   * verified (`proSubjectFromVerified`, PR 6 wires it). Never read from the body or a
   * header: api/tts.ts does not set it, so today's owner path never touches the allowance.
   */
  verifiedPro?: ProSubject;
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

/**
 * Parses a character cap. Only a plain decimal integer in [1, MAX_CONFIGURED_CHAR_CAP] is
 * accepted; anything else (unset, empty, garbage, 0, negative, fractional, exponent,
 * hex, Infinity, too large) returns null so the caller uses its safe default. A cap can
 * therefore never become unlimited through configuration.
 */
export function parseCharCap(value: string | undefined): number | null {
  return parseBoundedInt(value, MAX_CONFIGURED_CHAR_CAP);
}

/**
 * Parses `AERODJ_TTS_RATE_PER_MINUTE` by the same rule as the caps: a plain decimal integer
 * in [1, MAX_CONFIGURED_REQUESTS_PER_MINUTE], else null (the caller uses the default of 12).
 */
export function parseRatePerMinute(value: string | undefined): number | null {
  return parseBoundedInt(value, MAX_CONFIGURED_REQUESTS_PER_MINUTE);
}

function parseBoundedInt(value: string | undefined, max: number): number | null {
  const trimmed = value?.trim();
  if (!trimmed || !/^\d{1,9}$/.test(trimmed)) return null;
  const n = Number(trimmed);
  return n >= 1 && n <= max ? n : null;
}

/**
 * Global ceiling: `AERODJ_TTS_GLOBAL_DAILY_CHAR_CAP`, else the legacy single-bucket
 * `AERODJ_TTS_DAILY_CHAR_CAP` (so today's owner-set 9,000 keeps applying), else 9,000.
 * Owner bucket: `AERODJ_TTS_OWNER_DAILY_CHAR_CAP`, else the global ceiling.
 * Per install: `AERODJ_TTS_INSTALL_DAILY_CHAR_CAP`, else 1,500.
 */
export function limiterOptions(env: Env): LimiterOptions {
  const dailyCharCap =
    parseCharCap(env.AERODJ_TTS_GLOBAL_DAILY_CHAR_CAP) ??
    parseCharCap(env.AERODJ_TTS_DAILY_CHAR_CAP) ??
    DEFAULT_GLOBAL_DAILY_CHAR_CAP;
  return {
    dailyCharCap,
    ownerDailyCharCap: parseCharCap(env.AERODJ_TTS_OWNER_DAILY_CHAR_CAP) ?? dailyCharCap,
    installDailyCharCap: parseCharCap(env.AERODJ_TTS_INSTALL_DAILY_CHAR_CAP) ?? DEFAULT_INSTALL_DAILY_CHAR_CAP,
    requestsPerMinute: parseRatePerMinute(env.AERODJ_TTS_RATE_PER_MINUTE) ?? DEFAULT_REQUESTS_PER_MINUTE,
  };
}

/**
 * Picks the limiter for this environment:
 * - Upstash Redis REST credentials present: durable `RedisUsageLimiter` (hard cap).
 * - Otherwise, outside Vercel Production: per-instance `InMemoryUsageLimiter`.
 * - Otherwise (Vercel Production, no store): null, so every request fails closed with
 *   500, unless the owner explicitly accepts best-effort limits with
 *   `AERODJ_TTS_ACCEPT_BEST_EFFORT_LIMITS=true`.
 */
export function selectLimiter(env: Env, fetchImpl: typeof fetch = globalThis.fetch): UsageLimiter | null {
  const redis = redisRestConfig(env);
  if (redis) return new RedisUsageLimiter(redis, limiterOptions(env), fetchImpl);
  const production = env.VERCEL_ENV === 'production';
  if (production && env.AERODJ_TTS_ACCEPT_BEST_EFFORT_LIMITS?.trim() !== 'true') return null;
  return new InMemoryUsageLimiter(limiterOptions(env));
}

function defaultLimiter(env: Env): UsageLimiter | null {
  if (sharedLimiter) return sharedLimiter;
  const limiter = selectLimiter(env);
  if (limiter) sharedLimiter = limiter;
  return limiter;
}

export function defaultDeps(env: Env = process.env): Deps {
  return {
    env,
    fetch: globalThis.fetch,
    limiter: defaultLimiter(env),
    // Structured, minimal: request ID, status and character count; on an upstream
    // non-2xx also the integer upstream status and the allowlisted detail code.
    log: (entry) =>
      console.log(
        JSON.stringify({
          requestId: entry.requestId,
          status: entry.status,
          chars: entry.chars,
          ...(entry.reason !== undefined ? { reason: entry.reason } : {}),
          ...(entry.upstreamStatus !== undefined && entry.upstreamCode !== undefined
            ? { upstreamStatus: entry.upstreamStatus, upstreamCode: entry.upstreamCode }
            : {}),
        }),
      ),
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
  503: 'Service unavailable',
  502: 'Upstream error',
  504: 'Upstream timeout',
};

export function secondsUntilNextUtcDay(now: number): number {
  const next = new Date(now);
  next.setUTCHours(24, 0, 0, 0);
  return Math.max(1, Math.ceil((next.getTime() - now) / 1000));
}

export async function handleTts(req: TtsRequest, deps: Deps): Promise<TtsResponse> {
  const requestId = deps.requestId();
  let chars = 0;

  const fail = (
    status: number,
    extra: Record<string, string> = {},
    upstream?: { upstreamStatus: number; upstreamCode: string },
  ): TtsResponse => {
    deps.log(upstream ? { requestId, status, chars, ...upstream } : { requestId, status, chars });
    return {
      status,
      headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store', 'X-Request-Id': requestId, ...extra },
      body: Buffer.from(JSON.stringify({ error: MESSAGES[status] ?? 'Error', requestId })),
    };
  };
  /**
   * 429 / 503 / 500-misconfig contract: `Retry-After` (integer seconds >= 1) and a body
   * of `{ error, requestId, reason, retryAfterSeconds }`: enum and numbers only.
   */
  const refuse = (status: 429 | 500 | 503, reason: ErrorReason, retryAfterSeconds: number, logReason: LogReason = reason): TtsResponse => {
    const seconds = Math.max(1, Math.ceil(retryAfterSeconds));
    deps.log({ requestId, status, chars, reason: logReason });
    return {
      status,
      headers: {
        'Content-Type': 'application/json',
        'Cache-Control': 'no-store',
        'X-Request-Id': requestId,
        'Retry-After': String(seconds),
      },
      body: Buffer.from(JSON.stringify({ error: MESSAGES[status], requestId, reason, retryAfterSeconds: seconds })),
    };
  };

  // --- Master stop (note §4.7, D1): first, before auth, any limiter call and any upstream call. ---
  if (paidStopped(deps.env)) return refuse(503, 'disabled', DISABLED_RETRY_AFTER_SECONDS);

  if (req.method !== 'POST') return fail(405, { Allow: 'POST' });

  // Server misconfiguration: 500 `misconfig` with Retry-After 3600 (note §4.4).
  const misconfigured = (): TtsResponse => refuse(500, 'misconfig', MISCONFIG_RETRY_AFTER_SECONDS);

  // --- Auth: owner-only bearer token, stored server-side as a SHA-256 hash. ---
  const expectedHash = parseTokenHash(deps.env.AERODJ_TTS_TOKEN_SHA256);
  if (!expectedHash) return misconfigured();
  const token = bearerToken(req.authorization);
  if (!token || !tokenMatches(token, expectedHash)) return fail(401);

  const limiter = deps.limiter;
  if (!limiter) return misconfigured();
  const apiKey = deps.env.ELEVENLABS_API_KEY?.trim();
  if (!apiKey) return misconfigured();

  const now = deps.now();

  // --- Pro identity (src/pro-allowance.ts): only a server-minted ProSubject, never a body
  // field or header. Its deployment, char cap and rate come from env, strictly. ---
  let pro: { bucket: string; charCap: number; rate: number } | undefined;
  if (req.verifiedPro !== undefined) {
    if (!isVerifiedProSubject(req.verifiedPro)) return misconfigured();
    const deployment = proDeployment(deps.env);
    const charCap = proDailyChars(deps.env);
    const rate = proRatePerMinute(deps.env);
    if (deployment === null || charCap === null || rate === null) return misconfigured();
    pro = { bucket: proBucket(req.verifiedPro, deployment), charCap, rate };
  }

  try {
    const allowed = pro ? await limiter.allowRequest(pro.bucket, now, pro.rate) : await limiter.allowRequest(SUBJECT_BUCKET, now);
    if (!allowed) return refuse(429, 'rate', RATE_RETRY_AFTER_SECONDS);
  } catch (error) {
    if (error instanceof LimiterStoreError) return refuse(503, 'store', STORE_RETRY_AFTER_SECONDS);
    throw error;
  }

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

  // --- Daily budgets: atomic reserve-before-render, so concurrent requests cannot jointly
  // exceed a cap. After the 600-char cap, before any upstream call. ---
  let release: () => Promise<boolean>;
  let held: { chars: number; kind?: 'pro_render' };
  if (pro) {
    // Verified Pro (#264): ONE atomic step on the Pro purchase's own buckets plus the global
    // ceiling, never the owner's or an install's (so no per-install 1,500 cap). Order inside
    // it: global ceiling, then the 160-render allowance, then the subscriber's char cap
    // (clamped to global). Any refusal changes no counter. Durable store only.
    if (limiter.durable !== true || !limiter.reservePro || !limiter.releasePro) return refuse(503, 'store', STORE_RETRY_AFTER_SECONDS);
    const releasePro = limiter.releasePro.bind(limiter);
    let reservation: ProReservation;
    try {
      const result = await limiter.reservePro(
        { bucket: pro.bucket, chars, charCap: pro.charCap, renderAllowance: PRO_DAILY_RENDER_ALLOWANCE },
        now,
      );
      if (!result.ok) {
        // Render allowance or own char cap: one wire contract, `daily_allowance` until 00:00
        // UTC (the app switches to on-device quietly); only the log tells them apart.
        if (result.reason === 'pro_renders') return refuse(429, 'daily_allowance', secondsUntilNextUtcDay(now));
        if (result.reason === 'pro_chars') return refuse(429, 'daily_allowance', secondsUntilNextUtcDay(now), 'pro_chars');
        return refuse(429, 'global_daily', secondsUntilNextUtcDay(now));
      }
      reservation = result.reservation;
    } catch (error) {
      if (error instanceof LimiterStoreError) return refuse(503, 'store', STORE_RETRY_AFTER_SECONDS);
      return misconfigured();
    }
    release = () => releasePro(reservation);
    held = { chars: reservation.chars, kind: 'pro_render' };
  } else {
    let reservation: Reservation;
    try {
      const result = await limiter.reserve(SUBJECT, chars, now);
      if (!result.ok) return refuse(429, result.reason, secondsUntilNextUtcDay(now));
      reservation = result.reservation;
    } catch (error) {
      if (error instanceof LimiterStoreError) return refuse(503, 'store', STORE_RETRY_AFTER_SECONDS);
      // Any other reserve failure is a server fault, not a store outage: 500 `misconfig`
      // with Retry-After 3600 (note §4.4; Sentinel's #250 nit), before any upstream call.
      return misconfigured();
    }
    release = () => limiter.release(reservation);
    held = { chars: reservation.chars };
  }
  // Refund only when the upstream definitely did not bill (it answered non-2xx).
  // Network errors, timeouts and bad audio after a 2xx keep the reservation (chars and,
  // for Pro, the render): it may have been billed, so the caps err on spending less.
  // A failed refund logs one enum-only `refund_lost` line (`kind: 'pro_render'` for Pro, Fry's N1).
  const refund = async (): Promise<void> => {
    await release().catch((error: unknown) => {
      const timedOut = error instanceof LimiterStoreError && error.timedOut;
      (deps.logRefundLost ?? logRefundLostToConsole)({
        event: 'refund_lost',
        reason: timedOut ? 'timeout' : 'store',
        chars: held.chars,
        ...(held.kind ? { kind: held.kind } : {}),
      });
    });
  };

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
      body: JSON.stringify({
        text,
        model_id: deps.env.ELEVENLABS_MODEL_ID?.trim() || DEFAULT_MODEL_ID,
        voice_settings: VOICE_SETTINGS,
      }),
      signal: controller.signal,
    });
    if (!upstream.ok) {
      // Read at most 4 KB for the allowlisted detail.status code, then drop the body.
      // Neither the body nor detail.message reaches the logs or the response.
      const upstreamCode = await upstreamErrorCode(upstream);
      // One refund (one Upstash bound) covers chars and, for Pro, the render (Fry's N4).
      await refund();
      return fail(502, {}, { upstreamStatus: upstream.status, upstreamCode });
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
