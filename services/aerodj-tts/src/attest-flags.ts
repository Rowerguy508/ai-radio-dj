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
