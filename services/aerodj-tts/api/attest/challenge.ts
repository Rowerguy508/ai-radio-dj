import { challengeDeps, handleChallenge } from '../../src/challenge-handler.js';

/**
 * Web-signature handler (Vercel Node runtime `fetch` export), so the raw body
 * is read from the standard `Request` stream and Vercel's Node `req.body`
 * helper is never involved (note §4.1.4). Off unless
 * AERODJ_TTS_ATTEST_ENABLED is exactly `true`.
 */
export default {
  fetch(request: Request): Promise<Response> {
    return handleChallenge(request, challengeDeps());
  },
};
