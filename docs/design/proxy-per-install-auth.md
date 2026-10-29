# Design: per-install proxy auth and durable TTS budget

Status: **design only, for review (Fry, Sentinel)**. No code, config, key or
paid-service change comes with this note. Addresses #174 §6 blocker 1
(per-user proxy auth) and #80 (durable budget) for the `aerodj-tts` proxy.
Base: `integration/device-duo` @ `ce6a529`. Author: Atlas.

## 1. Current state

**Auth.** One shared owner bearer token. The server keeps only its SHA-256
(`AERODJ_TTS_TOKEN_SHA256`) and compares in constant time
(`services/aerodj-tts/src/auth.ts:6-26`, `src/handler.ts:231-235`). The app
reads the token from an owner-only Keychain entry, compiled only under
`AERODJ_OWNER_AB` (`ios/AeroDJ/OwnerVoiceTrial+App.swift:4,48-50`), and sends
it as `Authorization: Bearer` (`ProxyVoiceProvider.swift:65`). No install,
device or user identity reaches the server.

**Budget.** Every request shares one bucket, `OWNER_KEY = 'owner'`
(`handler.ts:30-31`). The per-minute rate (`handler.ts:244`) and the daily
character cap (`handler.ts:266-275`, env `AERODJ_TTS_DAILY_CHAR_CAP`, code
default 20,000 at `handler.ts:19`, owner-set 9,000 per
`PremiumVoiceCatalog.swift:58-60`) are both keyed on it. Reservation is
atomic reserve-before-render with refund only on upstream non-2xx.

**Why "not durable" today.** The durable path exists: `RedisUsageLimiter`
runs each operation as one Lua script over Upstash REST
(`src/limiter.ts:112-131,152-198`) and is chosen when `KV_REST_API_*` or
`UPSTASH_REDIS_REST_*` is set (`limiter.ts:145-150`, `handler.ts:142-148`).
The gaps are:
1. Without those env vars the proxy uses `InMemoryUsageLimiter`
   (`limiter.ts:66-107`), which is per instance and resets on cold start. In
   Production it fails closed (500) unless
   `AERODJ_TTS_ACCEPT_BEST_EFFORT_LIMITS=true` (`handler.ts:145-146`). Whether
   the deployed project actually has the Upstash integration is **unverified**:
   we read no env. Owner to confirm (§9).
2. One global bucket means one caller with the token can spend the whole
   9k and lock everyone else out until 00:00 UTC. There is no per-install
   quota and no way to revoke one caller.
3. #80's original finding (module-memory `usedChars`/`usedDay` in the legacy
   root app's `/api/voice` and `/api/commentary`) is about `ray-do`, which is
   out of scope here and covered by #178. This design satisfies #80's four
   requirements for `aerodj-tts`, the only paid path the iOS app uses.

**App side.** `ProxyVoiceProvider` treats every non-200 the same
(`ProxyVoiceProvider.swift:71`), ignores `Retry-After`, and sends a
`stationId` the server never reads (`:68`, `handler.ts:251-264`). The app
prices the route at 0, so its own `VoiceBudget` never limits it
(`PremiumVoiceCatalog.swift:152-159`).

## 2. Threat model

| Threat | Today | Required control |
| --- | --- | --- |
| Shared secret extracted from a public build | Fatal: one token = all spend | No static secret in any public binary. Per-install keys held in the Secure Enclave. |
| Replay of a captured request | Possible within token lifetime | One-time server challenge plus the App Attest monotonic counter, per request. |
| One install exhausts the budget | Yes (single bucket) | Per-install daily quota, under a global daily ceiling. |
| Many fresh installs from one device (key farming) | n/a | Global enrollment throttle per minute/day; optional DeviceCheck bit per device (phase 2); App Attest fraud-metric receipt (phase 3). |
| Jailbroken device relaying signatures for a modified client | n/a | Not fully preventable. Bounded by the per-install quota, revocation and the enrollment throttle. |
| Simulator, Debug and dev-signed builds | n/a | App Attest unsupported on the simulator: on-device voice only. Production accepts only the production `aaguid` and App Store or TestFlight validation categories. |
| Limiter store down | 503, fails closed | Unchanged: fail closed and never call ElevenLabs. |
| Personal text leaving the device | Out of scope here | #176 renderer gate and the consent gate. Auth must never widen what leaves the device. |

## 3. Options

| | App Attest only | DeviceCheck only | App Attest + DeviceCheck |
| --- | --- | --- | --- |
| Proves a genuine app instance | Yes (key bound to app ID and team) | Weak: the token proves a real device, not our unmodified app | Yes |
| Per-request proof, replay-safe | Yes (assertions with counter) | No (token can be relayed) | Yes |
| Survives reinstall | No (new key per install) | Yes (2 bits per device) | Device bits survive |
| Extra owner secrets | None (Team ID and bundle ID are public) | DeviceCheck `.p8` key | `.p8` key |
| Availability | iOS 14+ on hardware, not the simulator, can be `isSupported == false` | iOS 11+ hardware | |

**Recommendation: App Attest required for the paid voice. DeviceCheck
deferred to phase 2**, used only as an enrollment throttle per device (for
example, "this device enrolled a key in the last 24 h"). Where
`DCAppAttestService.isSupported` is false, or attestation fails, the paid
route is omitted and the on-device voice plays. There is no DeviceCheck-only
path to paid voice, because DeviceCheck cannot prove an unmodified app
and its tokens can be relayed. The app targets iOS 17 (`ios/project.yml:9-10`),
so every supported device that can run App Attest does.

## 4. Recommended design

### 4.1 Endpoints (same Vercel project, new files under `api/`)

1. `POST /api/attest/challenge` returns `{ challenge, expiresIn: 300 }`: 32
   random bytes, base64url. The server stores `chal:<sha256(challenge)>` with
   a 300 s TTL and consumes it once with `GETDEL`. Throttled globally, not by
   IP.
2. `POST /api/attest/register` accepts `{ keyId, attestationObject, challenge }`.
   The server verifies per Apple's steps ("Validating apps that connect to your
   server", fetched 2026-10-29): the x5c chain to the pinned **Apple App
   Attestation Root CA** (a public cert, safe to commit), the nonce at OID
   `1.2.840.113635.100.8.2`, `sha256(pubkey) == keyId == credentialId`,
   `rpIdHash == sha256("<TeamID>.com.aerodj.app")`, `counter == 0`, `aaguid`
   matching the configured environment, and the validation category when
   present (Production: 4 App Store, 2 TestFlight). It refuses a `keyId`
   that is already registered. It stores
   `key:<keyId> = { pubKeySpki, counter: 0, env, createdDay, revoked: false }`
   with a 90-day TTL that each successful request extends. The receipt is
   stored only if phase 3 is adopted. Success returns `204`.
3. `POST /api/tts`, with the body unchanged except that `stationId` is
   dropped. New headers:
   `X-OnAirly-Key: <keyId>`, `X-OnAirly-Challenge: <challenge>`,
   `X-OnAirly-Assertion: <base64 CBOR>`.
   `clientData = "onairly-tts-v1\n" + challenge + "\n" + hex(sha256(rawBody))`.
   The server consumes the challenge, verifies the ECDSA signature over
   `sha256(authData || sha256(clientData))` with the stored key, checks
   `rpIdHash`, and requires `counter > stored`. Binding to the body hash
   stops a valid assertion from being reused for different text.

**Per-request assertion, not a session token.** A bearer session token
minted after attestation is itself a stealable secret. Assertions are
generated locally in the Secure Enclave (no network), and the challenge
call adds one small round trip. Breaks are rendered ahead of airtime, so
this latency is acceptable. If Fry's on-device timing (#195) shows it is not,
the fallback is a 10-minute HMAC token bound to `keyId`, with assertions
still required at issue. That is recorded as an alternative, not the plan.

### 4.2 Identity

The **install id is the App Attest `keyId`**: an opaque hash of a random
Secure Enclave public key. It is not derived from the user, the Apple ID or
the hardware, and a reinstall resets it. Nothing else identifies the
caller. No IP, no user agent and no account is stored.

### 4.3 Quotas and atomicity

One Lua script per TTS request (`RESERVE2`, a single Upstash round trip) does all of the
following atomically:
`revoked?` → `counter > stored` then `SET counter` → per-install minute rate →
**reserve chars on both** `chars:install:<keyId>:<UTCday>` (cap
`AERODJ_TTS_INSTALL_DAILY_CHAR_CAP`) **and** `chars:global:<UTCday>` (cap
`AERODJ_TTS_GLOBAL_DAILY_CHAR_CAP`, defaulting to today's 9,000). All keys
use the hash tag `{aerodj-tts}` so a multi-key EVAL stays on one slot. If
either cap would be exceeded, nothing is incremented. Refund semantics stay
as they are today (release both on upstream non-2xx only). The reset window
stays the UTC day with a 2-day key TTL, matching the existing
`secondsUntilNextUtcDay` (`handler.ts:206-210`).

The owner bucket (§4.5) reserves against the global ceiling too, so total
spend can never exceed `GLOBAL`, whoever calls. The ElevenLabs plan's hard
credit limit and the key's own credit cap remain the last backstop.

**Storage: keep Upstash Redis** (already implemented and tested in
`limiter.ts`). Do not use Supabase: it belongs to the legacy root app and
`ray-do` (#178), and it would add a second paid service and a service-role key
to this function. Key records and counters together are tiny (well under 1 KB
per install). Upstash persists to disk. If the store is unreachable, the
proxy fails closed with 503.

### 4.4 Error contract (for Fry's app-side backoff)

Every error keeps the generic body and adds a `reason` enum:
`{ error, requestId, reason }`.

| Status | `reason` | `Retry-After` | App behavior |
| --- | --- | --- | --- |
| 429 | `rate` | seconds left in the minute window | Pause the paid route for that long, on-device meanwhile |
| 429 | `install_daily` / `global_daily` | seconds to 00:00 UTC | Pause the paid route until then, persisted across launches |
| 429 | `enroll` | seconds | Do not re-attest before then |
| 401 | `reattest` (unknown, revoked or expired key) | none | Delete the key, re-attest **once**. On a second 401, stop until the next launch |
| 401 | `assertion` (bad signature, counter or challenge) | none | Fetch a new challenge and retry once, then on-device |
| 503 | `store` / `disabled` | 60 / 3600 | Back off, on-device |

`Retry-After` is always integer seconds, at least 1. The app never retries
a 429 sooner, and never retries a 2xx-billed failure. Music never waits on
the proxy: every non-200 falls through to the existing on-device route.

### 4.5 Owner A/B builds

The owner bearer stays as a separate, flag-gated path
(`AERODJ_TTS_OWNER_TOKEN_ENABLED`, default **off** once phase 1 ships) with its
own `owner` bucket, under the same global ceiling. A/B builds should move
to App Attest too (TestFlight builds attest in production with validation
category 2), after which the owner token and its Keychain field are
deleted. `check-release-disables-paid-voice.sh` stays required. Public
builds only get the paid route once §6's other blockers (consent gate,
#176) are closed. Auth alone does not enable it.

### 4.6 Privacy

- Stored server-side: `keyId`, the public key, the counter, the environment,
  a created day, a revoked flag, and per-day character counters. No script
  text, voice choice, station, IP or user id.
- Logs stay one JSON line of enums, bools and numbers: `requestId`, `status`,
  `chars`, `reason`, `upstreamStatus` and `upstreamCode`. **No `keyId` in
  logs** (tests assert this, as they do today for text and tokens).
- App diagnostics: `PremiumVoiceRoutes.OmitReason` gains cases such as
  `attestUnsupported` and `attestFailed`, plus a paused-until timestamp. No
  key material.
- Label impact: the install id is likely a "Device ID" used for app
  functionality and fraud prevention, not linked to the user. **Sentinel to
  confirm for the revised App Privacy label (#174).**

### 4.7 Kill switch and revocation

- `AERODJ_TTS_ATTEST_ENABLED=false`: every attested request returns 503
  `disabled`, and the app falls back to on-device.
- `AERODJ_TTS_GLOBAL_DAILY_CHAR_CAP`: lowering it takes effect on the next
  request.
- Per-install revoke: `revoked=true` on `key:<keyId>`. This is an owner-run
  script reading from stdin, never committed with real ids.
- Each change takes effect on redeploy or env change. No app release is
  needed.

## 5. Test plan

**Proxy (`node:test`, CI job `tts-proxy`, no network, no real keys).**
- An injected `AttestationVerifier` interface, with a fake for the handler tests.
- Real verifier tests against a self-signed test CA chain built in the test
  (wrong root, wrong rpId, nonce mismatch, `counter != 0`, wrong `aaguid`,
  `keyId` mismatch, duplicate `keyId`).
- Assertion tests: replay (same counter), lower counter, reused or expired
  challenge, body-hash mismatch, revoked key.
- Quota tests: two concurrent requests at the per-install edge, and global
  exhaustion by N installs with each under its own cap. The Lua scripts are
  run against a fake EVAL, and `RESERVE2` is checked as all-or-nothing.
- The `reason` and `Retry-After` contract for every row of §4.4.
- Log tests: no `keyId`, text, challenge or assertion in any line.
- Fail-closed tests when the store throws.

**iOS (`AeroDJCore`, Linux and iOS CI).**
- An `AppAttesting` protocol, with `DCAppAttestService` adapted in the app
  target only.
- Client tests with a fake attester and transport: the challenge-then-assert
  order, the clientData format matching the server fixture byte for byte,
  the §4.4 backoff table including a persisted `install_daily` pause,
  re-attest happening only once, unsupported devices omitting the route, and
  no `stationId` in the body.
- A real-device check by Fry on the Duo (#224 checklist) with a TestFlight
  build.

## 6. PR breakdown (small, sequenced, each with exact-head CI and Fry + Sentinel sign-off)

1. **Proxy: quota keys and 429 contract.** Per-install and global
   two-bucket `RESERVE2` Lua, the `reason` enum, `Retry-After` on every 429,
   and the owner path counted against global. Behavior is unchanged for the
   owner today.
2. **Proxy: challenge endpoint** with single-use TTL storage, plus the
   global enrollment throttle.
3. **Proxy: App Attest attestation verifier and `register`.** Pinned Apple
   root, minimal in-house CBOR/ASN.1 decoding on `node:crypto`
   (`X509Certificate`). Using a dependency instead is a review choice for
   Sentinel.
4. **Proxy: assertion verification on `/api/tts`** with counter CAS folded
   into the reserve script, plus the kill switch. Still disabled by default.
5. **iOS: `AppAttesting` client, the 429/401 backoff in
   `ProxyVoiceProvider`, and dropping `stationId`.** Coordinate with Fry's 429
   backoff work so only one implementation lands.
6. **iOS: App Attest entitlement**
   (`com.apple.developer.devicecheck.appattest-environment`) in
   `AeroDJ.entitlements`, with the route wired for A/B builds first. This
   needs the owner's capability step.
7. **Retire the owner bearer** once A/B runs on App Attest.
8. (Phase 2, optional) **DeviceCheck enrollment throttle.** (Phase 3,
   optional) **fraud-metric receipt refresh.**

Docs updates (the proxy README and `docs/privacy/*`) ride with the PR that
changes the behavior.

## 7. Rollout

1. Merge PRs 1-4 with `AERODJ_TTS_ATTEST_ENABLED` unset. The owner path is
   unchanged.
2. The owner completes §9, then enables attest for the Production
   deployment only.
3. Owner A/B TestFlight build on App Attest: validate quotas, the 429
   contract and fallback on the Duo.
4. Turn off the owner token (PR 7).
5. Public builds get the paid route only after the consent gate and #176 also
   merge, and the owner approves the public spend.

## 8. Paid-service and owner decisions (not ours to make)

- **Quota sizes:** the per-install daily cap (proposal: 1,500 chars, about
  three breaks' worth) and the global daily ceiling. With 9,000 global, only
  about 6 heavy listeners a day get the paid voice. A bigger ceiling means a
  bigger ElevenLabs plan, which is the owner's spend decision.
- Whether public users get the paid voice at all in v1, or on-device first with
  paid voice for the owner only.
- Whether a DeviceCheck key (phase 2) is worth the extra secret.
- ElevenLabs logging and training opt-out (#174 blocker 7). Sentinel is
  listing these; it is unchanged by this design.
- Accepting the "Device ID / app functionality" label wording (with Sentinel).

## 9. Owner actions (the owner does these, and we never create keys)

1. **Apple Developer → Identifiers → `com.aerodj.app`:** enable the **App
   Attest** capability, then regenerate the provisioning profiles. The bundle
   ID stays unchanged through the OnAirly rename. The App Attest `rpId` is
   `TeamID.bundleID`, so a later bundle-ID change would invalidate every
   registered key.
2. Phase 2 only: **Apple Developer → Keys:** create a DeviceCheck key and paste
   the `.p8`, key ID and team ID directly into Vercel (Production only). It
   never goes through chat, the repo or CI.
3. **Confirm the Upstash Redis integration** on the `aerodj-tts` Vercel project,
   Production scope (`KV_REST_API_URL`/`KV_REST_API_TOKEN` present), and
   that `AERODJ_TTS_ACCEPT_BEST_EFFORT_LIMITS` is unset.
4. Set the non-secret env vars when enabling: `AERODJ_TTS_APPLE_TEAM_ID`,
   `AERODJ_TTS_BUNDLE_ID=com.aerodj.app`,
   `AERODJ_TTS_APP_ATTEST_ENV=production`, `AERODJ_TTS_INSTALL_DAILY_CHAR_CAP`,
   `AERODJ_TTS_GLOBAL_DAILY_CHAR_CAP`, `AERODJ_TTS_ATTEST_ENABLED`, and later
   `AERODJ_TTS_OWNER_TOKEN_ENABLED=false`.
5. Keep the ElevenLabs restricted key's own credit limit as the backstop.

-Atlas
