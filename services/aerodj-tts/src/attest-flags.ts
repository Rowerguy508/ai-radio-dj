import type { Env } from './handler.js';

/** Only the literal string `true` enables anything (note §4.7). No trim, no case folding. */
export function flagEnabled(env: Env, name: string): boolean {
  return env[name] === 'true';
}

/** Attest kill switch: off unless exactly `true`. Checked before any store access. */
export function attestEnabled(env: Env): boolean {
  return flagEnabled(env, 'AERODJ_TTS_ATTEST_ENABLED');
}

/**
 * Tester-voice switch (#378, owner decision 2026-11-02: internal TestFlight testers only).
 * Off unless exactly `true`, like the attest flag. It is a SECOND, independent lock: with
 * only `AERODJ_TTS_ATTEST_ENABLED=true` (e.g. for Pro later), `/api/attest/token` and the
 * install-token path on `/api/tts` stay 503 `disabled`, so free tester voice never opens
 * by accident. Checked before any store access.
 */
export function testerVoiceEnabled(env: Env): boolean {
  return flagEnabled(env, 'AERODJ_TTS_TESTER_VOICE_ENABLED');
}

/** Both locks: the install-token (tester) path runs only when attest AND tester voice are exactly `true`. */
export function testerVoiceOn(env: Env): boolean {
  return attestEnabled(env) && testerVoiceEnabled(env);
}

/**
 * iOS 26 no-category TestFlight fallback switch (#407 N1/N2).
 *
 * Requires `AERODJ_TTS_TESTER_VOICE_ENABLED === 'true'` and is enabled when
 * `AERODJ_TTS_ALLOW_NO_CATEGORY_FALLBACK` is unset or exactly `'true'` so current
 * TestFlight deploys keep working unchanged until pre-App-Store tightening. Fails
 * closed on any other value (including `'false'` or a typo): new no-category
 * registrations get no tier, and `/api/attest/token` refuses existing
 * `no_category_fallback` (and legacy un-reasoned) tester keys with 403
 * `no_entitlement` while `testflight_category` keys stay unaffected.
 *
 * TODO(#407, App Store release gate): launch-checklist step, not a code change. Before
 * submitting an App Store build, set `AERODJ_TTS_ALLOW_NO_CATEGORY_FALLBACK=false` on
 * production aerodj-tts and redeploy (README "Before App Store submission"), so iOS 26
 * App Store installs cannot reach the tester tier. Rollback: unset it (or `true`) and redeploy.
 */
export function noCategoryFallbackAllowed(env: Env): boolean {
  if (!testerVoiceEnabled(env)) return false;
  const value = env.AERODJ_TTS_ALLOW_NO_CATEGORY_FALLBACK;
  return value === undefined || value === 'true';
}

/**
 * Master stop for every paid path, owner included (note §4.7, Fry D1; PR 3).
 * Fails closed: ANY value except exactly `false` (including empty) stops (a typo stops
 * rather than runs). Only unset or exactly `false` = normal. Checked first,
 * before auth, any limiter or store call and any ElevenLabs call.
 */
export function paidStopped(env: Env): boolean {
  const value = env.AERODJ_TTS_PAID_STOP;
  return value !== undefined && value !== 'false';
}

/** `Retry-After` (s) for 503 `disabled` and 500 `misconfig` (note §4.4). */
export const DISABLED_RETRY_AFTER_SECONDS = 3600;
export const MISCONFIG_RETRY_AFTER_SECONDS = 3600;
/** `Retry-After` (s) for 503 `store` on every path, `/api/tts` and install alike (note §4.4). */
export const STORE_RETRY_AFTER_SECONDS = 30;
