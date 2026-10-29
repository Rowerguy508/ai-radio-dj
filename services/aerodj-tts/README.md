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
| 500 | server misconfigured (token hash or ElevenLabs key unset, or Production without a durable limiter store) |
| 503 | limiter store unreachable or erroring (fails closed) |
| 502 | upstream non-2xx, network error, empty or oversized audio |
| 504 | upstream took longer than 15 s (AbortController) |

SSML is stripped to plain text before it is sent, since ElevenLabs does not
accept SSML. SSML input may be up to 4x the text cap before stripping; the
spoken text is then held to the normal cap.

## Voice settings (fixed server-side)

Every render sends the owner-approved radio tuning:

```json
"voice_settings": { "stability": 0.4, "similarity_boost": 0.75, "speed": 1.0 }
```

- Set in `VOICE_SETTINGS` in `src/handler.ts`, not by env and not by the
  client: the request contract carries no voice settings, and any
  `voice_settings`, `style`, `speed` or `model_id` field a client adds is
  ignored.
- No `style` and no `use_speaker_boost` are sent.
- `speed` is fixed at 1.0, inside the approved 1.0-1.05 range. Changing it
  (or any other value) is a code change with review, never an env edit.
- The model is unchanged: `eleven_flash_v2_5` unless `ELEVENLABS_MODEL_ID`
  overrides it.
- Voice settings do not affect the character caps: only the spoken text is
  counted.

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

## Caps and limits

- Text: at most 600 characters per request (`AERODJ_TTS_MAX_TEXT_CHARS`).
- Voice IDs: only those in `AERODJ_TTS_VOICE_IDS`.
- Rate: `AERODJ_TTS_RATE_PER_MINUTE` requests per minute (default 12), one bucket
  for the single owner bearer (the contract carries no device ID, so per-bearer is
  per-owner). 429 with `Retry-After: 60`.
- Daily characters: `AERODJ_TTS_DAILY_CHAR_CAP` (default 20,000), UTC day. 429
  with `Retry-After` = seconds until 00:00 UTC.
- Upstream timeout: 15 s.

### How the daily cap is enforced

The characters are **reserved atomically before** the ElevenLabs call (one
check-and-add), so concurrent requests cannot jointly exceed the cap. The
reservation is **released (refunded) only when ElevenLabs answers non-2xx**, since
then nothing was billed. A network error, timeout, or bad audio after a 2xx keeps
the reservation, because the render may have been billed.

### Which store backs the limits

| Environment | Store | Hard across instances? |
| --- | --- | --- |
| `KV_REST_API_URL` + `KV_REST_API_TOKEN` (or `UPSTASH_REDIS_REST_URL` + `UPSTASH_REDIS_REST_TOKEN`) set | Upstash Redis over REST; each operation is one Lua script (atomic in Redis) | **Yes** |
| Not set, outside Vercel Production | in-memory, per instance | No: each instance and cold start has its own counters |
| Not set, Vercel Production | none: every request returns 500 (fails closed) | n/a |
| Not set, Vercel Production, `AERODJ_TTS_ACCEPT_BEST_EFFORT_LIMITS=true` | in-memory, per instance (owner explicitly accepts best-effort) | No |

Rate counters are fixed one-minute windows in Redis (a burst at a minute boundary
can reach 2x the per-minute rate) and a sliding window in memory. If the store is
unreachable or errors, the request fails closed with 503 and never reaches
ElevenLabs.

Independent of the limiter, the $0 backstop is the ElevenLabs plan itself (Free
plan: no overage) plus the restricted key's own credit limit. The owner should
confirm both on the ElevenLabs side; the proxy cannot verify them.

## Logging and privacy

Each request logs exactly one JSON line: `{ requestId, status, chars }`.
When ElevenLabs answers non-2xx, that line also carries `upstreamStatus` (the
integer HTTP status) and `upstreamCode`: the body's `detail.status` if it
matches `^[a-z0-9_]{1,64}$`, otherwise `other`. At most 4 KB of the error body
is read for this and then dropped. Text, headers, tokens, voice IDs, station
IDs, `detail.message` and upstream bodies are never logged. Tests assert this.

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
| `KV_REST_API_URL`, `KV_REST_API_TOKEN` | yes in Production | Injected by the Upstash Redis integration (Vercel Marketplace, free tier). `UPSTASH_REDIS_REST_URL` / `UPSTASH_REDIS_REST_TOKEN` also work. HTTPS only. |
| `AERODJ_TTS_ACCEPT_BEST_EFFORT_LIMITS` | no | `true` lets Production run with the per-instance limiter. Owner decision only; leave unset. |

## Deploy (owner only, after Sentinel's review)

1. Sentinel reviews this function and Echo's app-side wiring. Nothing is
   deployed before that.
2. In Vercel, create a **new, separate project** named `aerodj-tts` from this
   repo with **Root Directory = `services/aerodj-tts`**, Framework preset: Other.
   This deploys only `api/tts.ts`, never the legacy root app. `vercel.json` sets
   an ignore command so the project only builds when this directory changes.
   Confirm the production domain is exactly `aerodj-tts.vercel.app` (Vercel adds
   a suffix if the name is taken; the app pin must match it exactly).
3. Add the Upstash Redis integration (Vercel Marketplace, free tier) to that
   project, Production scope, so `KV_REST_API_URL` and `KV_REST_API_TOKEN` are
   set. Without it, Production fails closed (500).
4. In ElevenLabs, the owner creates a **restricted API key with only the Text
   to Speech permission and its own credit limit**, and pastes it **directly**
   into the Vercel project's environment variables as `ELEVENLABS_API_KEY`,
   **Production only**. The key never goes through chat, the repo, the app, or
   CI.
5. Set `AERODJ_TTS_TOKEN_SHA256` and `AERODJ_TTS_VOICE_IDS` (Production only).
   Deploy, then point only the owner's A/B build at
   `https://aerodj-tts.vercel.app/api/tts` (`PremiumVoiceRoutes.allowedHosts`
   must contain exactly that host).
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
