import { handleRegister, registerDeps } from '../../src/register-handler.js';

/**
 * Web-signature handler (Vercel Node runtime `fetch` export): the raw body is
 * read from the standard `Request` stream with a 16 KiB cap; Vercel's Node
 * `req.body` helper is never involved (note §4.1.4). Off unless
 * AERODJ_TTS_ATTEST_ENABLED is exactly `true`; PAID_STOP wins over everything.
 */
export default {
  fetch(request: Request): Promise<Response> {
    return handleRegister(request, registerDeps());
  },
};
