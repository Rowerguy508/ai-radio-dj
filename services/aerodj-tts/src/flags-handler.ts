import type { Env } from './handler.js';
import { flagEnabled } from './attest-flags.js';

/**
 * Public app flags (#525, -Atlas). `GET /api/flags` answers one small JSON object the app reads
 * as remote kill switches. No auth, no store, no upstream call, and nothing from the request is
 * read or logged: the response depends only on env.
 *
 * - `djAirPlayLongForm`: the DJ voice's long-form AirPlay session (iOS #525). On only when
 *   `AERODJ_DJ_AIRPLAY_LONGFORM` is exactly `true` (the proxy's flag rule, note §4.7). Unset,
 *   empty or any other value: `false`, and the app runs today's session.
 */
export const AIRPLAY_LONGFORM_FLAG = 'AERODJ_DJ_AIRPLAY_LONGFORM';

export function appFlags(env: Env): { djAirPlayLongForm: boolean } {
  return { djAirPlayLongForm: flagEnabled(env, AIRPLAY_LONGFORM_FLAG) };
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
