import type { Env } from './handler.js';

/**
 * Public app flags (#525, -Atlas). `GET /api/flags` answers one small JSON object the app reads
 * as remote kill switches. No auth, no store, no upstream call, and nothing from the request is
 * read or logged: the response depends only on env.
 *
 * - `djAirPlayLongForm`: kill switch for the DJ voice's long-form AirPlay session (iOS #525).
 *   ON by default (Orion, Nov 14): `false` only when `AERODJ_DJ_AIRPLAY_LONGFORM` is exactly
 *   `false`. Unset, empty or any other value (`FALSE`, `0`, `off`): `true`. The app fails open
 *   too: never fetched or a failed fetch is on; only a fetched `false` turns the path off.
 */
export const AIRPLAY_LONGFORM_FLAG = 'AERODJ_DJ_AIRPLAY_LONGFORM';

/**
 * - `onAirlyNowPlayingSession`: kill switch for the iOS 27 OnAirly lock-screen Now Playing session
 *   (#539 follow-up, #600). Same rule: ON by default, `false` only when
 *   `AERODJ_ONAIRLY_NOW_PLAYING_SESSION` is exactly `false`. The app fails open (missing key,
 *   failed fetch or offline is on) and keeps the value in memory for that launch only.
 */
export const ONAIRLY_NOW_PLAYING_SESSION_FLAG = 'AERODJ_ONAIRLY_NOW_PLAYING_SESSION';

export function appFlags(env: Env): { djAirPlayLongForm: boolean; onAirlyNowPlayingSession: boolean } {
  return {
    djAirPlayLongForm: env[AIRPLAY_LONGFORM_FLAG] !== 'false',
    onAirlyNowPlayingSession: env[ONAIRLY_NOW_PLAYING_SESSION_FLAG] !== 'false',
  };
}

export function handleFlags(request: Request, env: Env): Response {
  const headers = { 'Cache-Control': 'no-store', 'Content-Type': 'application/json; charset=utf-8' };
  if (request.method !== 'GET' && request.method !== 'HEAD') {
    return new Response(JSON.stringify({ error: 'method_not_allowed' }), {
      status: 405,
      headers: { ...headers, Allow: 'GET, HEAD' },
    });
  }
  const body = request.method === 'HEAD' ? null : JSON.stringify(appFlags(env));
  return new Response(body, { status: 200, headers });
}
