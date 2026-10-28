# AeroDJ TTS proxy (ElevenLabs, owner-only)

A single Vercel serverless function, `POST /api/tts`, that the iOS
`ProxyVoiceProvider` (`ios/AeroDJCore/Sources/AeroDJCore/Voice/ProxyVoiceProvider.swift`)
calls to render DJ breaks with ElevenLabs. The ElevenLabs key lives only in
this function's server-side environment; the app never holds it.

This is a **self-contained Vercel project**. It is deliberately not part of the
legacy Next.js app at the repo root, whose `app/` routes (including the
unauthenticated `app/api/voice`) must not be deployed.

> **Status: not deployed. No key created.** Sentinel must review this function
> and the app-side wiring before anything is deployed.

## Contract (matches `ProxyVoiceProvider`)

Request:

```
POST /api/tts
Authorization: Bearer <owner token>
Content-Type: application/json

{ "upstream": "elevenlabs", "voiceId": "<allowlisted id>", "text": "...",
  "format": "text" | "ssml", "stationId": "..." }
```

Success: `200`, `Content-Type: audio/wav` (16-bit mono 22,050 Hz PCM in a RIFF
header), body non-empty and at most 5 MB, plus

- `X-Audio-Duration`: seconds, `samples / 22050` (finite, > 0, <= 600)
- `X-Billed-Characters`: ElevenLabs' `character-cost` response header when it
  is present and numeric, otherwise the number of characters sent
- `X-Request-Id`

Errors return a generic JSON body `{ "error": "...", "requestId": "..." }` and
never echo user input or the upstream response:

| Status | When |
| --- | --- |
| 400 | invalid JSON, `upstream` not `elevenlabs`, voice not allowlisted, empty/too-long text, bad `format` |
| 401 | missing, malformed or wrong bearer token |
| 405 | any method other than POST |
| 429 | per-minute rate limit or daily character cap reached (`Retry-After` set) |
| 500 | server misconfigured (token hash or ElevenLabs key unset) |
| 502 | upstream non-2xx, network error, empty or oversized audio |
| 504 | upstream took longer than 15 s (AbortController) |

SSML is stripped to plain text before it is sent, since ElevenLabs does not
accept SSML. SSML input may be up to 4x the text cap before stripping; the
spoken text is then held to the normal cap.

## Auth: owner-only bearer token (interim)

- The server stores only the **SHA-256 hex digest** of the token, in
  `AERODJ_TTS_TOKEN_SHA256`. Each request's bearer token is hashed and compared
  with `crypto.timingSafeEqual` (constant time, always 32 vs 32 bytes).
- Revoke or rotate by changing `AERODJ_TTS_TOKEN_SHA256` in Vercel and
  redeploying.
- The token is **never compiled into any build** and never goes in the repo,
  CI, logs or chat. The owner enters it once through a debug-only field in
  the owner's A/B build, which stores it in the iOS Keychain (Echo's app-side
  wiring).
- This is an interim measure for a single-owner A/B test only. It **must be
  replaced with real per-user auth (Sign in with Apple at minimum, verified
  server-side) before any public build** uses this proxy.

Generating a token (owner, on his own machine, not in chat):

```sh
TOKEN=$(openssl rand -base64 32)          # enter this once in the A/B build
printf %s "$TOKEN" | shasum -a 256 | cut -d' ' -f1   # paste this hex into Vercel
```

## Caps

- Text: at most 600 characters per request (`AERODJ_TTS_MAX_TEXT_CHARS`).
- Voice IDs: only those in `AERODJ_TTS_VOICE_IDS`.
- Daily characters: `AERODJ_TTS_DAILY_CHAR_CAP` (default 20,000), reset at
  00:00 UTC.
- Rate: `AERODJ_TTS_RATE_PER_MINUTE` requests per minute (default 12).
- Upstream timeout: 15 s.

**The rate limit and daily cap are best-effort per instance.** Serverless
functions have no shared memory: the default `InMemoryUsageLimiter` keeps
counters inside one function instance, so parallel instances each have their
own counters and a cold start resets them. The hard `$0` backstop is the
ElevenLabs plan itself (Free plan: 10k credits, no overage) plus the
restricted key's own credit limit. The limiter sits behind the small
`UsageLimiter` interface (`src/limiter.ts`), so Upstash Redis / Vercel KV can
back it later without touching the handler.

## Logging and privacy

Each request logs exactly one JSON line: `{ requestId, status, chars }`.
Text, headers, tokens, voice IDs, station IDs and upstream bodies are never
logged. A test asserts this.

## Environment variables

| Name | Required | Notes |
| --- | --- | --- |
| `ELEVENLABS_API_KEY` | yes | Server-only. Restricted key, Text to Speech only. Production scope only. |
| `AERODJ_TTS_TOKEN_SHA256` | yes | 64-char hex SHA-256 of the owner token. Never the token itself. |
| `AERODJ_TTS_VOICE_IDS` | yes | Comma-separated ElevenLabs voice ID allowlist. |
| `ELEVENLABS_MODEL_ID` | no | Default `eleven_flash_v2_5`. |
| `AERODJ_TTS_MAX_TEXT_CHARS` | no | Default 600. |
| `AERODJ_TTS_DAILY_CHAR_CAP` | no | Default 20000. |
| `AERODJ_TTS_RATE_PER_MINUTE` | no | Default 12. |

## Deploy (owner only, after Sentinel's review)

1. Sentinel reviews this function and Echo's app-side wiring. Nothing is
   deployed before that.
2. In Vercel, create a **new, separate project** from this repo with
   **Root Directory = `services/aerodj-tts`**. Framework preset: Other. This
   deploys only `api/tts.ts`, never the legacy root app.
3. In ElevenLabs, the owner creates a **restricted API key with only the Text
   to Speech permission and its own credit limit**, and pastes it **directly**
   into the Vercel project's environment variables as `ELEVENLABS_API_KEY`,
   **Production only**. The key never goes through chat, the repo, the app, or
   CI.
4. Set `AERODJ_TTS_TOKEN_SHA256` and `AERODJ_TTS_VOICE_IDS` (Production only).
5. Deploy, then point only the owner's A/B build at
   `https://<project>.vercel.app/api/tts` (its host must be in the app's
   `allowedHosts`).
6. App side (Echo): `paidProvidersEnabled` stays **off in every build except
   the owner's A/B build**, and the on-device voice remains the fallback.

## Development

```sh
npm install
npm run typecheck
npm test
```

Tests use `node:test` via `tsx`, a mocked `fetch`, and an injected limiter,
clock and logger. No network and no real keys.
