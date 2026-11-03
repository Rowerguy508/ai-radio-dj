import { handleToken, tokenDeps } from '../../src/token-handler.js';

/**
 * Web-signature handler (Vercel Node runtime `fetch` export): the raw body is read from the
 * standard `Request` stream with a 1 KiB cap (it is hashed into the assertion's clientData).
 * Off unless BOTH AERODJ_TTS_ATTEST_ENABLED and AERODJ_TTS_TESTER_VOICE_ENABLED are exactly
 * `true`; PAID_STOP wins over everything (#378).
 */
export default {
  fetch(request: Request): Promise<Response> {
    return handleToken(request, tokenDeps());
  },
};
