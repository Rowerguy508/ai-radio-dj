# AeroDJ TTS proxy (ElevenLabs, owner-only)

A single Vercel serverless function, `POST /api/tts`, that the iOS
`ProxyVoiceProvider` (`ios/AeroDJCore/Sources/AeroDJCore/Voice/ProxyVoiceProvider.swift`)
calls to render DJ breaks with ElevenLabs. The ElevenLabs key lives only in
this function's server-side environment; the app never holds it.

This is a **self-contained Vercel project**. It is deliberately not part of the
legacy Next.js app at the repo root, whose `app/` routes (including the
unauthenticated `app/api/voice`) must not be deployed.

> **Status: not deployed. No key created.** Sentinel must review this function
> and the app-side wiring before anything is deployed. Any deploy needs the
> owner's OK.

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
| 429 | per-minute rate limit or a daily character cap reached (`Retry-After` and `reason` set, see below) |
| 500 | server misconfigured (token hash or ElevenLabs key unset, or Production without a durable limiter store; `Retry-After: 3600`, `reason: "misconfig"`) |
| 503 | limiter store unreachable or erroring (fails closed; `Retry-After: 30`, `reason: "store"`), or the master stop `AERODJ_TTS_PAID_STOP` is set (`Retry-After: 3600`, `reason: "disabled"`) |
| 502 | upstream non-2xx, network error, empty or oversized audio |
| 504 | upstream took longer than 15 s (AbortController) |

### 429 / 503 / 500 refusal contract

A refusal from the limiter, the master stop or a misconfiguration carries `Retry-After` (integer seconds, at least 1) and
a body of enums and numbers only:

```
{ "error": "Too many requests", "requestId": "...", "reason": "<enum>", "retryAfterSeconds": <n> }
```

| Status | `reason` | `Retry-After` |
| --- | --- | --- |
| 429 | `rate` | 60 (upper bound of the minute window) |
| 429 | `owner_daily` | seconds until 00:00 UTC |
| 429 | `install_daily` | seconds until 00:00 UTC (not reachable until per-install auth lands) |
| 429 | `global_daily` | seconds until 00:00 UTC |
| 429 | `daily_allowance` | seconds until 00:00 UTC (verified Pro only, not reachable until PR 6 wires Pro: 160 renders or the Pro char cap used up; the log says `daily_allowance` or `pro_chars`) |
| 503 | `store` | 30 |
| 503 | `disabled` (master stop, below) | 3600 |
| 500 | `misconfig` | 3600 |

Every other error keeps the `{ error, requestId }` body with no `reason`. Logs add
only the same `reason` enum to that request's one line.

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
  per-owner). 429 `rate` with `Retry-After: 60`.
- Daily characters, UTC day, two buckets reserved together (all or nothing):
  - **Global ceiling** across every caller: `AERODJ_TTS_GLOBAL_DAILY_CHAR_CAP`, else
    the legacy `AERODJ_TTS_DAILY_CHAR_CAP`, else **9,000**.
  - **The caller's own bucket.** Today the only caller is the owner bearer, charged
    to a fixed `owner` bucket: `AERODJ_TTS_OWNER_DAILY_CHAR_CAP`, else the global
    ceiling. Per-install buckets (`AERODJ_TTS_INSTALL_DAILY_CHAR_CAP`, default
    **1,500**) exist in the limiter but no request can select one until App Attest
    lands (design note `docs/design/proxy-per-install-auth.md`, PRs 3-4). Nothing in
    the request body chooses the bucket.
  - Caps accept only a plain integer from 1 to 10,000,000. Anything else (empty,
    0, negative, fractional, `Infinity`, too large) uses the default, so a cap can
    never become unlimited.
- **Verified Pro** (`src/pro-allowance.ts`; inert until PR 6 sets `verifiedPro` from a
  JWS that `verifySignedTransaction` verified, never from the body or a header). Charged
  to the purchase's own buckets `pro:<VERCEL_ENV>:<sha256(originalTransactionId)>`, never
  the owner's or an install's, so the per-install 1,500 cap does not apply. One atomic
  step, in order: global ceiling (`global_daily`), then 160 renders a day (40 breaks x 4),
  then the Pro char cap `AERODJ_TTS_PRO_DAILY_CHARS` (default 12,000, clamped to the
  global ceiling, so 9,000 today); either Pro limit answers 429 `daily_allowance`. Own
  rate bucket `AERODJ_TTS_PRO_RATE_PER_MINUTE` (default 12). Unlike the owner settings,
  an invalid Pro value or a `VERCEL_ENV` other than production/preview/development makes
  a Pro request 500 `misconfig`; the owner path is unaffected. Durable store only.
  Family Sharing fails closed until the owner decides: only `PURCHASED` counts as Pro
  unless `AERODJ_TTS_PRO_ALLOW_FAMILY_SHARED` is exactly `true` (the single setting).
- Rate accepts only a plain integer from 1 to 600 by the same rule as the caps.
  Anything else (`1e9`, `Infinity`, `601`, fractional, empty) uses the default 12,
  so the rate limit can never be switched off by configuration.
- Upstream timeout: 15 s.

### How the daily cap is enforced

The characters are **reserved atomically before** the ElevenLabs call: one Lua
script checks the caller's bucket and the global ceiling and increments both, or
neither. Concurrent requests therefore cannot jointly exceed either cap. The
reservation is **released (refunded) only when ElevenLabs answers non-2xx**, since
then nothing was billed. A network error, timeout, or bad audio after a 2xx keeps
the reservation, because the render may have been billed.

**Per-charge refund marker (#233 PR 3, Fry D2).** Every reservation carries a
server-generated id (`rid`, a random UUID; never from the client). A refund applies
**at most once per `rid`**: `RELEASE2` first runs
`SET refund:{aerodj-tts}:<rid> 1 NX EX 172800` and changes nothing if the marker
already exists; the in-memory limiter keeps the same rule with a per-instance set.
Releasing the same reservation twice therefore refunds it once, on both limiters
(one test each in `test/quota.test.ts`). The handler still releases at most once and
never retries a release. There is no `character-cost` top-up script yet; when one is
added it must use its own `topup:{aerodj-tts}:<rid>` marker the same way (note §4.3).

**Install reservations require Redis (#233 PR 3, Sentinel B3).** Every per-install
reservation goes through `reserveForInstall` (`src/install-quota.ts`). Without a
durable store (`limiter.durable === true`, i.e. Upstash) it refuses with
**503 `store`, `Retry-After: 30`**, in every environment, and makes no limiter call;
`AERODJ_TTS_ACCEPT_BEST_EFFORT_LIMITS` does not apply to installs. A store error from
the durable limiter is also 503 `store`; any other throw from `reserve` is **500
`misconfig`, `Retry-After: 3600`** (PR 4), never a bare platform 500. The owner
`/api/tts` reserve uses the same mapping (503 `store` with `Retry-After: 30`, else 500
`misconfig`). No request reaches an install reservation yet (the attested `/api/tts`
path and PR 3b's `register` wire it).

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
ElevenLabs. Each Upstash call is bounded at 2 s (`UPSTASH_FETCH_TIMEOUT_MS`,
request and body); a store that does not answer in time is the same 503 `store`.

Independent of the limiter, the $0 backstop is the ElevenLabs plan itself (Free
plan: no overage) plus the restricted key's own credit limit. The owner should
confirm both on the ElevenLabs side; the proxy cannot verify them.

## Master stop: `AERODJ_TTS_PAID_STOP` (#233 PR 3, note §4.7)

One switch that stops **every paid path, the owner included**, and the attest
endpoints (`/api/attest/*`). It is checked **first**, before the method, auth, any
limiter or Redis call and any ElevenLabs call. Stopped → `503`, `reason: "disabled"`,
`Retry-After: 3600`.

It fails closed: **any value except exactly `false` stops, including empty** (`true`, `1`,
`TRUE`, `False`, `false ` with a space, and typos all stop). Only unset or exactly
`false` → normal behaviour (Sentinel confirmed). Like every env change on Vercel, it takes effect only on
the next deployment: set it, then redeploy Production.

## Attestation endpoints (off by default; #233 PRs 2-4)

`POST /api/attest/challenge` issues a stateless, HMAC-signed challenge (no Redis call
at issuance). It is **off unless `AERODJ_TTS_ATTEST_ENABLED` is exactly `true`**
(`TRUE`, `1`, `true ` with a space are all off); off → 503 `disabled`,
`Retry-After: 3600`. It reads the raw request body from the Web `Request` stream with
a **1024-byte cap** (413 `too_large` above it) and never uses Vercel's `req.body`.

The challenge MAC key is `AERODJ_TTS_CHALLENGE_HMAC_KEY`:

- **Dedicated**: used for nothing else (not the token hash, not the ID-hash key).
- **At least 32 bytes** of randomness, as 64+ hex characters or base64/base64url of
  32+ bytes. Shorter or malformed → 500 `misconfig`.
- **Created by the owner**, on his own machine, and pasted directly into the Vercel
  project's environment (Production scope). Never in chat, the repo, CI, a build or a
  log. We never create it. For example: `openssl rand -hex 32`.
- Attestation must not be enabled before this key exists.

An expired challenge (older than 120 s) whose MAC, purpose, key binding and the
request's signature all verify, and that was never used, is refused with
**400 `challenge_expired`** (no write); the app fetches a fresh challenge and signs
again, at most once per cue. A forged, tampered, wrong-purpose, reused or
badly signed challenge is **401 `assertion`**.

### `POST /api/attest/register` (#233 PR 3b, note §4.1.2)

Body `{ keyId, attestationObject, challenge }`: `keyId` is the 44-character
standard-base64 key ID from `DCAppAttestService.generateKey`, `attestationObject`
the standard-base64 CBOR from `attestKey`, `challenge` a purpose-`attest` challenge
from `/api/attest/challenge`. The app must call `attestKey` with
**`clientDataHash = SHA256(UTF-8 bytes of the challenge string)`**. Success is
**204** with no body. Same gates as the challenge endpoint (PAID_STOP first, then
405, then the attest flag), then config (500 `misconfig`), then a durable store
(503 `store`, `Retry-After: 30`, no in-memory fallback in any environment), then a
**16 KiB raw-body cap** (413).
Each key-store call to Upstash is bounded at 2 s (`UPSTASH_FETCH_TIMEOUT_MS`,
request and body); a store that does not answer in time is 503 `store` too.

Verification is offline, against the pinned **Apple App Attestation Root CA**
(`src/apple-app-attest-root-ca.ts`), never the system trust store: x5c chain and
validity dates, nonce `SHA256(authData ‖ clientDataHash)` at OID
`1.2.840.113635.100.8.2`, `keyId = SHA256(public key) = credentialId`,
`rpIdHash = SHA256("<AppIDPrefix>.com.aerodj.app")`, `counter = 0`, production
`aaguid`, the COSE key, and on iOS 27+ the validation category (Production: 2
TestFlight or 4 App Store). CBOR is decoded by a small strict in-repo decoder
(`src/cbor.ts`: definite lengths, depth 4, 16 items, no tags or floats, no
duplicate keys, no trailing bytes). Any failure is **401 `assertion`** and writes
nothing; the reason enum is logged, never returned.

Then one Redis script: refuse a used challenge (401); refuse if today's verified
enrollments from this device bucket reached `AERODJ_TTS_ENROLL_DEVICE_DAILY_CAP`
(default **3**), then if today's verified enrollments overall reached
`AERODJ_TTS_ENROLL_DAILY_CAP` (default **20**) (both **429 `enroll`**, same body,
`Retry-After` = seconds to the next UTC midnight; nothing written, so a
device-capped request spends no global budget); mark the challenge used;
`SET key:{aerodj-tts}:<keyId> NX` with `{ pubKeySpki, counter: 0, env, createdDay,
revoked: false }` and a 90-day TTL (an existing keyId: 401, record and counters
untouched); and count the enrollment in both counters (2-day TTL).

**Enroll caps (owner decision, 2026-10-29):** 20 a day overall and 3 a day per
device. Nothing in the request or the attestation identifies a device across
re-enrollments (the keyId is new on every `generateKey()`), so the per-device
bucket is the **client network** as Vercel's edge reports it
(`x-vercel-forwarded-for` only; `x-real-ip` and `x-forwarded-for` are never read):
the IPv4 address or the IPv6 /64,
hashed as `HMAC-SHA256(challenge key, domain ‖ UTC day ‖ network)` into
`enrolldev:{aerodj-tts}:<day>:<hex>`. The address itself is never stored, logged
or returned, and the day inside the MAC makes buckets unlinkable across days. A
request with a missing or unparseable `x-vercel-forwarded-for` is refused with
**400 `network`** (no `Retry-After`; the log carries only the reason enum) before
the challenge is consumed or any store call is made, so it fails closed with no
shared bucket. The app treats it like any other unlisted 400 reason (`bad_request`
handling: no retry, on-device voice; paid voice stays on).
Limits: devices behind one NAT/CGNAT/office network share the 3; a device that
changes networks gets 3 more per network.

**Per-install cap (stacked on #256; Orion and Sentinel, 2026-10-29):** the app sends
`installId` in the register body (Fry's contract: a Keychain UUID v4, lowercase, 36
characters, register only). A register must pass the network 3/day, the install 3/day
(`AERODJ_TTS_ENROLL_INSTALL_DAILY_CAP`, default 3, parsed like the device cap) and the
global 20/day. The counter is `enrollinst:{aerodj-tts}:<day>:<HMAC-SHA256(challenge key,
install domain ‖ day ‖ installId)>` with the same 2-day TTL; the raw ID is never stored
or logged. A missing or invalid `installId` is **400 `install`** (no `Retry-After`)
before any store call, so the challenge is not consumed. The install-cap 429 is the
same `enroll` body and `Retry-After` as the other two (log detail `install_cap`).
The install ID is client-chosen, so the network cap stays: rotating IDs on one network
still hits it.

**Key records slide (owner decision, 2026-10-29):** the 90-day TTL set on register
is refreshed to 90 days on every successful use (`useAttestKey`, one `EXPIRE`),
not only on register. A key unused for 90 days expires; its next assertion is 401
`assertion` (unknown key) and the app re-attests. A refresh store error or timeout
is 503 `store` (Retry-After 30). The assertion path (PR 4) calls it after the
assertion verifies. An expired but otherwise valid challenge: 400
`challenge_expired`, nothing written.

**Preview never writes what Production trusts:** unless `VERCEL_ENV` is exactly
`production`, every key (record, enroll counters, used mark) is prefixed `nonprod:`.
Test root CAs can be injected by code only, never by env, and only on a Preview or
Development deployment; anywhere else that is 500 `misconfig`. The assertion path
that uses the stored key is PR 4.

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
| `AERODJ_TTS_GLOBAL_DAILY_CHAR_CAP` | no | Global daily ceiling. Default: `AERODJ_TTS_DAILY_CHAR_CAP`, else 9000. |
| `AERODJ_TTS_DAILY_CHAR_CAP` | no | Legacy name, used for the global ceiling when the new name is unset. |
| `AERODJ_TTS_OWNER_DAILY_CHAR_CAP` | no | Owner bucket cap. Default: the global ceiling. |
| `AERODJ_TTS_INSTALL_DAILY_CHAR_CAP` | no | Per-install cap. Default 1500. Inert until per-install auth lands. |
| `AERODJ_TTS_RATE_PER_MINUTE` | no | Default 12. Plain integer 1-600; anything else uses 12. |
| `AERODJ_TTS_PRO_DAILY_CHARS` | no | Per Pro subscriber daily chars. Default 12000, clamped to the global ceiling. Plain integer 600-10,000,000; anything else makes Pro requests 500 `misconfig`. |
| `AERODJ_TTS_PRO_RATE_PER_MINUTE` | no | Per Pro subscriber rate. Default 12. Plain integer 1-600; anything else makes Pro requests 500 `misconfig`. |
| `AERODJ_TTS_PRO_ALLOW_FAMILY_SHARED` | no | Family Sharing, **open owner question** (Sentinel's N3 on #264). Unset or exactly `false` (default): only `PURCHASED` counts as Pro; a `FAMILY_SHARED` purchase is refused by the verifier (`ownership`), gets no Pro subject and takes the non-Pro path. Exactly `true`: `FAMILY_SHARED` also counts. Missing or unknown ownership never counts. Anything else (`TRUE`, `1`, empty, spaces) makes Pro requests 500 `misconfig`. Owner decision only; must match the App Store Connect Family Sharing toggle, which Apple does not let you turn off once on. |
| `KV_REST_API_URL`, `KV_REST_API_TOKEN` | yes in Production | Injected by the Upstash Redis integration (Vercel Marketplace, free tier). `UPSTASH_REDIS_REST_URL` / `UPSTASH_REDIS_REST_TOKEN` also work. HTTPS only. |
| `AERODJ_TTS_ACCEPT_BEST_EFFORT_LIMITS` | no | `true` lets Production run with the per-instance limiter (owner path only; never install reservations). Owner decision only; leave unset. |
| `AERODJ_TTS_PAID_STOP` | no | Master stop. Any value except exactly `false` (including empty) → every paid path and `/api/attest/*` return 503 `disabled`. Unset in normal operation. |
| `AERODJ_TTS_ATTEST_ENABLED` | no | Attest kill switch. Only exactly `true` enables `/api/attest/*`; anything else is off. Leave unset until the owner enables attestation. |
| `AERODJ_TTS_CHALLENGE_HMAC_KEY` | before attest is enabled | Server-only. Dedicated key, at least 32 bytes, **created by the owner** and pasted directly into Vercel (Production). Never in chat, repo, CI or builds. |
| `AERODJ_TTS_APPLE_APP_ID_PREFIX` | before attest is enabled | The 10-character App ID prefix from the Apple Developer account (not assumed to equal the Team ID). Public identifier, not a secret. Missing or not `[A-Z0-9]{10}` → register is 500 `misconfig`. |
| `AERODJ_TTS_BUNDLE_ID` | no | If set, must equal `com.aerodj.app` (from `config/storekit.json`); anything else → 500 `misconfig`. It cannot change the bundle. |
| `AERODJ_TTS_APP_ATTEST_ENV` | no | Unset or `production`: only the production `aaguid`. `development` also accepts `appattestdevelop` (and validation category 3), **only** on a Preview/Development deployment with no `ELEVENLABS_API_KEY`; anywhere else, or any other value → 500 `misconfig`. |
| `AERODJ_TTS_ENROLL_DAILY_CAP` | no | Verified enrollments per UTC day overall (default 20, owner decision 2026-10-29). Plain integer 1-100000; anything else uses the default. |
| `AERODJ_TTS_ENROLL_DEVICE_DAILY_CAP` | no | Verified enrollments per UTC day per device bucket (keyed hash of the client network; see above) (default 3, owner decision 2026-10-29). Plain integer 1-1000; anything else uses the default. |

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
7. **Before enabling attestation** (owner, not part of any PR): create
   `AERODJ_TTS_CHALLENGE_HMAC_KEY` (above), and add a **per-IP Vercel Firewall
   rate-limit rule on `/api/attest/*`** (design note §4.1.1, §12; the function keeps
   only a day-scoped keyed hash of the network for the enroll sub-cap, never an IP, so
   the request-rate limit lives at the edge). Only then set
   `AERODJ_TTS_ATTEST_ENABLED=true` and redeploy. This README documents the rule; no
   PR changes Vercel settings.
8. **Emergency stop:** set `AERODJ_TTS_PAID_STOP=true` (any value but `false`) and
   redeploy Production. Rotating the ElevenLabs key also stops spend without a
   redeploy.

## Development

```sh
npm install
npm run typecheck
npm test
```

Tests use `node:test` via `tsx`, a mocked `fetch`, and an injected limiter,
clock and logger. No network and no real keys.
