import type { Env } from './handler.js';

/** Only the literal string `true` enables anything (note §4.7). No trim, no case folding. */
export function flagEnabled(env: Env, name: string): boolean {
  return env[name] === 'true';
}

/** Attest kill switch: off unless exactly `true`. Checked before any store access. */
export function attestEnabled(env: Env): boolean {
  return flagEnabled(env, 'AERODJ_TTS_ATTEST_ENABLED');
}
