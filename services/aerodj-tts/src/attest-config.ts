import type { X509Certificate } from 'node:crypto';
import {
  DEVELOPMENT_VALIDATION_CATEGORIES,
  PRODUCTION_VALIDATION_CATEGORIES,
  type AttestationPolicy,
} from './app-attest-verify.js';
import { keyspaceFromEnv, type Keyspace } from './attest-store.js';
import { parseChallengeKey } from './challenge.js';
import { DEFAULT_ENROLL_DEVICE_DAILY_CAP, MAX_ENROLL_DEVICE_DAILY_CAP } from './enroll-device.js';
import { parseBoundedInt, type Env } from './handler.js';
import { STOREKIT_CONFIG } from './storekit-config.js';
import { deploymentFromEnv } from './storekit-verify.js';

/**
 * Register-endpoint configuration from env (note §12). No secret lives here:
 * the App ID prefix and bundle ID are public identifiers, and the bundle ID
 * comes from `config/storekit.json`. Any invalid value makes the whole
 * endpoint 500 `misconfig` (fail closed), never a weaker policy.
 *
 * - `AERODJ_TTS_APPLE_APP_ID_PREFIX` (required): the 10-character App ID
 *   prefix. Not assumed equal to the Team ID (#233 Sentinel).
 * - `AERODJ_TTS_BUNDLE_ID` (optional): if set it must equal the config's
 *   bundle ID (`com.aerodj.app`); it cannot change it.
 * - `AERODJ_TTS_APP_ATTEST_ENV`: unset or `production` → only the production
 *   aaguid. `development` additionally accepts `appattestdevelop`, and only on
 *   a Preview/Development deployment with no ElevenLabs key set (note §4.1.2:
 *   never on a deployment holding a real key). Anything else → misconfig.
 * - `AERODJ_TTS_ENROLL_DAILY_CAP`: verified enrollments per UTC day overall, a
 *   plain integer in [1, 100000]; anything else uses the default of 20 (owner
 *   decision, 2026-10-29: "Keep 20 a day overall and 3 per device for now").
 * - `AERODJ_TTS_ENROLL_DEVICE_DAILY_CAP`: verified enrollments per UTC day per
 *   device bucket (enroll-device.ts: the client network, not a true device id), a
 *   plain integer in [1, 1000]; anything else uses the default of 3 (same decision).
 * - Test roots (`roots`, injected by code only, never from env) are refused
 *   unless the deployment is Preview/Development.
 */
/** Owner decision (2026-10-29): 20 verified enrollments a day overall. */
export const DEFAULT_ENROLL_DAILY_CAP = 20;
export const MAX_ENROLL_DAILY_CAP = 100_000;
const APP_ID_PREFIX = /^[A-Z0-9]{10}$/;

export interface RegisterConfig {
  challengeKey: Buffer;
  policy: Omit<AttestationPolicy, 'now'>;
  keyspace: Keyspace;
  enrollCap: number;
  enrollDeviceCap: number;
}

export function registerConfig(env: Env, roots?: readonly X509Certificate[]): RegisterConfig | null {
  const challengeKey = parseChallengeKey(env.AERODJ_TTS_CHALLENGE_HMAC_KEY);
  if (!challengeKey) return null;
  const prefix = env.AERODJ_TTS_APPLE_APP_ID_PREFIX;
  if (typeof prefix !== 'string' || !APP_ID_PREFIX.test(prefix)) return null;
  const bundleId = STOREKIT_CONFIG.bundleId;
  if (env.AERODJ_TTS_BUNDLE_ID !== undefined && env.AERODJ_TTS_BUNDLE_ID !== bundleId) return null;

  const deployment = deploymentFromEnv(env);
  const attestEnv = env.AERODJ_TTS_APP_ATTEST_ENV;
  let allowDevelopment: boolean;
  if (attestEnv === undefined || attestEnv === 'production') {
    allowDevelopment = false;
  } else if (attestEnv === 'development') {
    if (deployment !== 'nonproduction' || (env.ELEVENLABS_API_KEY ?? '').trim() !== '') return null;
    allowDevelopment = true;
  } else {
    return null;
  }
  if (roots !== undefined && deployment !== 'nonproduction') return null;

  return {
    challengeKey,
    policy: {
      appId: `${prefix}.${bundleId}`,
      allowDevelopment,
      validationCategories: allowDevelopment ? DEVELOPMENT_VALIDATION_CATEGORIES : PRODUCTION_VALIDATION_CATEGORIES,
      deployment,
      ...(roots !== undefined ? { roots } : {}),
    },
    keyspace: keyspaceFromEnv(env),
    enrollCap: parseBoundedInt(env.AERODJ_TTS_ENROLL_DAILY_CAP, MAX_ENROLL_DAILY_CAP) ?? DEFAULT_ENROLL_DAILY_CAP,
    enrollDeviceCap:
      parseBoundedInt(env.AERODJ_TTS_ENROLL_DEVICE_DAILY_CAP, MAX_ENROLL_DEVICE_DAILY_CAP) ?? DEFAULT_ENROLL_DEVICE_DAILY_CAP,
  };
}
