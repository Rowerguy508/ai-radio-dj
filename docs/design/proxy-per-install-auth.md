# Design: per-install proxy auth, Pro entitlement and durable TTS budget

Status: **design only, for review (Fry, Sentinel; Nova for §5)**. No code,
config, key or paid-service change comes with this note. Addresses #174 §6
blocker 1 (per-user proxy auth), #80 (durable budget) and the owner's v1
decision that **in-app purchase is part of OnAirly v1** (free tier =
on-device voice, Pro = ElevenLabs voice; placeholder Pro $4.99/mo and
$34.99/yr, price not final). Base: `integration/device-duo` @ `ce6a529`.
Author: Atlas.

Revision 2 folds in Sentinel's review (comment 6509681944, B1-B5 and
recommendations 1-11), Fry's review (comment 6509655362, B1-B4) and the
entitlement assignment. Apple facts are cited to developer.apple.com pages
fetched 2026-10-29 (§13). Where Apple's docs did not settle a point, the
note says **unverified**.

## 1. Current state

**Auth.** One shared owner bearer token. The server keeps only its SHA-256
(`AERODJ_TTS_TOKEN_SHA256`) and compares in constant time
(`services/aerodj-tts/src/auth.ts:6-26`, `src/handler.ts:231-235`). The owner
path is on whenever that hash is set. The app reads the token from an
owner-only Keychain entry, compiled only under `AERODJ_OWNER_AB`
(`ios/AeroDJ/OwnerVoiceTrial+App.swift:4,48-50`), and sends it as
`Authorization: Bearer` (`ProxyVoiceProvider.swift:65`). No install, device,
purchase or user identity reaches the server. The app has no StoreKit code.

**Budget.** Every request shares one bucket, `OWNER_KEY = 'owner'`
(`handler.ts:30-31`). The per-minute rate (`handler.ts:244`) and the daily
character cap (`handler.ts:266-275`, env `AERODJ_TTS_DAILY_CHAR_CAP`, code
default 20,000 at `handler.ts:19`, owner-set 9,000 per
`PremiumVoiceCatalog.swift:58-60`) are both keyed on it. Reservation is
atomic reserve-before-render. Refund happens only on upstream non-2xx;
network errors, timeouts and bad audio after a 2xx keep the reservation
(`handler.ts:277-321`).

**Why "not durable" today.** `RedisUsageLimiter` runs each operation as one
Lua script over Upstash REST (`src/limiter.ts:112-131,152-198`) and is chosen
when `KV_REST_API_*` or `UPSTASH_REDIS_REST_*` is set (`limiter.ts:145-150`).
The gaps:
1. Without those env vars `selectLimiter` (`handler.ts:142-148`) uses the
   per-instance `InMemoryUsageLimiter` **on every non-Production deployment**
   (Preview included), and in Production too when
   `AERODJ_TTS_ACCEPT_BEST_EFFORT_LIMITS=true`. Whether the deployed project
   has Upstash is **unverified** (we read no env; owner to confirm, §12).
2. One global bucket: one caller can spend the whole 9k and lock everyone
   out until 00:00 UTC. No per-install quota, no revocation of one caller.
3. #80's original finding (module-memory counters in the legacy root app's
   `/api/voice` and `/api/commentary`) is `ray-do`, covered by #178/#232.
   This design satisfies #80's requirements for `aerodj-tts`, the only paid
   path the iOS app uses.

**App side.** `ProxyVoiceProvider` treats every non-200 the same
(`ProxyVoiceProvider.swift:71`) and sends a `stationId` the server never
reads. Fry's #234 (head `31a792f`) adds the backoff of §4.4.

## 2. Threat model

| Threat | Required control |
| --- | --- |
| Shared secret extracted from a public build | No static secret in any public binary. Per-install keys in the Secure Enclave. No App Store / IAP secret in the app (§5.9). |
| Replay of a captured request | Stateless HMAC challenge, single use marked after signature verification, plus the App Attest monotonic counter (§4.1). |
| Anonymous flood of `challenge`/`register` costing Upstash commands or starving enrollment | Challenge issuance writes nothing (§4.1.1). Per-IP limit at the Vercel edge (owner Firewall rule). Enrollment counter counts only **verified** attestations (§4.1.2). |
| One install exhausts the budget | Per-install daily quota under a global daily ceiling (§4.3). |
| Key farming (many fresh installs) | Enrollment cap per day; **Pro entitlement required for paid voice** (§5), so a farmed key without a subscription renders nothing; optional lower day-0 quota; DeviceCheck phase 2. |
| Client claims to be Pro (`isPro` flag, patched app) | Server never trusts a client flag. It verifies Apple's signed transaction itself (§5.3). |
| Forged or tampered transaction JWS | Full x5c chain to the pinned Apple Root CA - G3, ES256 signature, bundle/product/environment checks (§5.3). |
| One purchase shared across many installs (JWS passed around) | Entitlement bound to attested install keys, capped at 5 active installs per `originalTransactionId` (§5.5). |
| Pre-refund JWS replayed after a refund | Server-side tombstone from the verified REFUND/REVOKE notification; a stored tombstone beats any older JWS (§5.6). |
| Sandbox purchases spending production budget | Sandbox refused in Production unless an exact-`true` flag, and then only from a small separate bucket (§5.7). |
| Leaked owner token | Owner path only on exact `true`, own small cap, never a fallback, removed before any public paid voice (§4.5). |
| Limiter store missing or down | Every verified path requires `limiter.durable === true` in **every** environment, else 503 `store` (§4.3). Never call ElevenLabs. |
| Apple outage or an unverifiable transaction | Fail closed: no paid render, on-device voice (§5.8). |
| Jailbroken device relaying signatures | Not fully preventable. Bounded by entitlement, per-install quota, install cap and revocation. |
| Simulator, Debug, dev-signed builds | App Attest unsupported on the simulator: on-device only. Production accepts only the production `aaguid`. |
| Personal text leaving the device | #176 renderer gate and the consent gate. Neither auth nor the paywall ever widens what leaves the device; the consent sheet comes before any paywall (§5.10). |

## 3. Options (unchanged)

| | App Attest only | DeviceCheck only | App Attest + DeviceCheck |
| --- | --- | --- | --- |
| Proves a genuine app instance | Yes | Weak (real device, not our app) | Yes |
| Per-request proof, replay-safe | Yes (assertions with counter) | No | Yes |
| Survives reinstall | No | Yes (2 bits per device) | Device bits survive |
| Extra owner secrets | Challenge HMAC key only | DeviceCheck `.p8` | `.p8` |

**Recommendation: App Attest required for paid voice; DeviceCheck deferred
to phase 2** as an enrollment throttle only (no device token stored). No
DeviceCheck-only path to paid voice. The app targets iOS 17
(`ios/project.yml:9-10`).

## 4. Attestation, quotas and contract

### 4.1 Endpoints (same Vercel project, new files under `api/`)

All handlers read the **raw request bytes** themselves (§4.1.4). All return
503 `disabled` before any Redis call when the kill switch is off (§4.7).

#### 4.1.1 `POST /api/attest/challenge` (stateless; Sentinel B1)

Returns `{ challenge, expiresIn: 120 }`, where
`challenge = base64url(v ‖ purpose ‖ ts ‖ rand16 ‖ HMAC-SHA256(K, v ‖ purpose ‖ ts ‖ rand16))`,
`purpose ∈ { attest, tts, ent }` and `K = AERODJ_TTS_CHALLENGE_HMAC_KEY`
(server-only env secret, owner-generated, never in a build, repo, CI or chat).
**Issuance performs no Redis read or write.** Verification checks the MAC in
constant time, the version, the purpose expected by the consuming endpoint
(an `attest` challenge cannot be spent on `/api/tts`), and `ts` within 120 s.
Single use is enforced only at consumption, `SET used:{aerodj-tts}:<sha256(challenge)> NX EX 300`,
inside the endpoint's one script and **only after the signature checks
out**. Per-IP rate limits for `/api/attest/*`, `/api/entitlement` and
`/api/tts` live at the edge (owner-set Vercel Firewall rule, §12), so the
function stores no IP. Optionally the app sends `keyId` with `tts`/`ent`
challenge requests, mixed into the MAC, so a burned challenge only affects
that key (Sentinel rec. 6).

*Resolves the conflict between Fry's "consume before verifying" note and
Sentinel B1 in Sentinel's favour:* consuming before verification would make
every junk request a Redis write. A failed verification writes nothing; the
challenge still dies at 120 s, and the counter (§4.3) blocks assertion
replay.

#### 4.1.2 `POST /api/attest/register` (Sentinel B2)

Accepts `{ keyId, attestationObject, challenge }`. Order:
1. Body cap 16 KB on raw bytes, before parsing (413 `too_large`).
2. Stateless challenge check, purpose `attest` (no Redis).
3. Full verification per Apple ("Validating apps that connect to your
   server"): `clientDataHash = SHA256(challenge)`;
   `nonce = SHA256(authData ‖ clientDataHash)` equals the value at OID
   `1.2.840.113635.100.8.2`; x5c chain to the pinned **Apple App Attestation
   Root CA** verified without the system trust store, with validity dates;
   `sha256(pubkey) == keyId == credentialId`;
   `rpIdHash == SHA256("<AppIDPrefix>.com.aerodj.app")` (App ID prefix, not
   assumed equal to Team ID); `counter == 0`; `aaguid` = production
   (`appattest` followed by seven `0x00` bytes) on Production, never
   `appattestdevelop` on a deployment holding a real ElevenLabs key.
   Validation category and bundle version fields appear only on iOS 27+
   attestations (Sentinel rec. 2): when present, Production accepts only 2
   (TestFlight) and 4 (App Store).
4. One script: `SET key:{aerodj-tts}:<keyId> NX` (atomic set-if-absent; a
   duplicate `keyId` fails, no GET-then-SET) + `INCR enroll:{aerodj-tts}:<UTCday>`
   against `AERODJ_TTS_ENROLL_DAILY_CAP` + consume the challenge. The
   enrollment counter therefore counts only verified attestations.
   Key record: `{ pubKeySpki, counter: 0, env, createdDay, revoked: false }`,
   90-day sliding TTL. Success returns 204.

#### 4.1.3 `POST /api/tts` and `POST /api/entitlement` (assertion-signed)

Headers: `X-OnAirly-Key: <keyId>`, `X-OnAirly-Challenge: <challenge>`,
`X-OnAirly-Assertion: <base64 CBOR>`.
`clientData = "onairly-<purpose>-v1\n" + challenge + "\n" + hex(sha256(rawBody))`
with `<purpose>` = `tts` or `ent`.
Assertion check (Sentinel rec. 1): `nonce = SHA256(authenticatorData ‖ SHA256(clientData))`,
ECDSA-P256-SHA256 signature over `nonce` with the stored key, `rpIdHash`
match, then the counter rule of §4.3. Binding to the body hash stops a valid
assertion from being reused for different text or a different transaction.
The verifier is pinned with a **real-device fixture** captured from a dev
build on the Duo, in addition to the self-signed test chain.

A request carrying **both** `Authorization` and any `X-OnAirly-*` header is
rejected with 400 `mixed_auth` (Fry B1).

#### 4.1.4 Raw body (Sentinel B4)

`api/tts.ts:10` passes Vercel's parsed `req.body` today. The new handlers
read the request stream themselves with a byte cap (`/api/tts` 8 KB,
`/api/entitlement` 16 KB, `/api/appstore/notifications` 64 KB, `register`
16 KB; 413 `too_large` above it) and **never touch `req.body`**. They hash
those exact bytes, then `JSON.parse` the same buffer. Whether Vercel's Node
helper leaves the stream unread when `req.body` is never accessed is
**unverified**; PR 2 confirms it with a test, and if not, switches the
function to the Web `Request` signature and `await request.arrayBuffer()`.
Tests: an exact-bytes fixture shared with iOS, and whitespace/key-order
variants that must fail.

**Per-request assertion, not a session token** (unchanged rationale). If
Fry's on-device timing (#195) shows the extra round trip hurts, the
alternative is a 10-minute HMAC token bound to `keyId`; recorded, not
planned.

### 4.2 Identity

The **install id is the App Attest `keyId`**: an opaque hash of a random
Secure Enclave public key, reset on reinstall, never put in a URL or query
string (Vercel request logs record paths). Pro adds two pseudonymous
identifiers, `originalTransactionId` and `appAccountToken` (§5.4), stored
only as `HMAC-SHA256(AERODJ_TTS_ID_HMAC_KEY, value)`. No IP, user agent,
Apple ID or account is stored by the function.

### 4.3 Quotas, counter and atomicity (Fry B3, Sentinel B3 and rec. 3-4)

After the signature verifies against the stored key, **one Lua script**
(`RESERVE2`, a single Upstash round trip) does, in order:
1. consume the challenge (`SET used:… NX`; already used → 401 `assertion`);
2. `revoked?` on the key → 401 `reattest`;
3. `counter > stored`, then **commit the counter**. The counter is advanced
   even if a later step refuses the request, because the assertion is spent;
4. entitlement check (§5.5): active link and unexpired, untombstoned
   entitlement → else 403 `no_entitlement`;
5. per-install minute rate → 429 `rate`;
6. reserve chars on **both** `chars:install:<keyId>:<UTCday>`
   (`AERODJ_TTS_INSTALL_DAILY_CHAR_CAP`) and `chars:global:<UTCday>`
   (`AERODJ_TTS_GLOBAL_DAILY_CHAR_CAP`, default 9,000). All-or-nothing: if
   either would be exceeded nothing is incremented. If both fail, the reason
   is `global_daily` (it is the one the user cannot fix by waiting less).

All keys use the hash tag `{aerodj-tts}`. Refunds are one `RELEASE2` script
over both buckets, bound to the reservation's original day (as
`Reservation.day` does today), and **never roll back the counter or the
challenge mark**. Refund only on upstream non-2xx; network errors, timeouts
and bad audio after a 2xx keep the reservation (`handler.ts:277-321`). The
server reserves its own post-validation count (`handler.ts:262-264`), never a
client number; if ElevenLabs' `character-cost` header is higher, a top-up
script adds the difference to both buckets after the fact.

**Durability is mandatory on every verified path, in every environment**
(Sentinel B3): `RESERVE2`, `register`, the entitlement script and the
notifications script require `limiter.durable === true`, else 503 `store`.
That covers Preview and Production with `ACCEPT_BEST_EFFORT_LIMITS` set. The
in-memory limiter remains only for the legacy owner path's local dev tests.

**Storage: Upstash Redis** (already implemented). Not Supabase (it belongs to
the legacy app and `ray-do`). Records are well under 1 KB per install or
entitlement. Upstash's command quota is an owner check (§11): running out
means the paid route is down (fails closed).

### 4.4 Error contract (Fry B2; app side is Fry's #234)

Every error body is `{ error, requestId, reason }`; refusals also carry
`retryAfterSeconds` (as #238 ships). `Retry-After` is integer
seconds ≥ 1. **Every 429 and every 503 carries `Retry-After`.** The app
trusts `Retry-After` over its own clock. Music never waits on the proxy:
every non-200 falls through to the on-device voice for that cue.

| Status | `reason` | From | `Retry-After` | App behaviour (#234 at `31a792f` unless marked NEW) |
| --- | --- | --- | --- | --- |
| 200 / 204 | – | tts / register, entitlement | – | Play / continue |
| 400 | `bad_request` | all | – | Do not retry that request; on-device for the cue. NEW in #234 |
| 400 | `mixed_auth` | tts | – | Treated as a client bug: stop paid calls until next launch. NEW |
| 401 | `reattest` (unknown, revoked or expired key) | tts, ent | – | Stop paid calls until next launch; on next launch delete the key and attest **once** |
| 401 | `assertion` (bad signature, counter, used/expired/wrong-purpose challenge) | tts, ent, register | – | Stop paid calls until next launch (#234). Out-of-order counters are avoided by serialising proxy calls per key (Sentinel rec. 7) |
| 401 | `owner_token` (bearer when owner path off, or wrong) | tts | – | Stop paid calls until next launch; never falls back to anything else |
| 403 | `no_entitlement` (no link, expired, refunded, revoked, stale, family/sandbox not allowed) | tts | – | NEW: if StoreKit shows a current entitlement, re-sync once via `/api/entitlement` (§5.2); otherwise, or if that fails, no paid calls until `Transaction.updates` emits or next launch. Never opens the paywall by itself |
| 403 | `install_limit` | ent | – | NEW: no paid calls until next launch; Nova's UI may explain "too many devices" |
| 405 | – | all | – | Client bug, stop until next launch |
| 413 | `too_large` | all | – | Do not retry that request. NEW |
| 429 | `rate` | tts, ent | seconds left in window | Wait `Retry-After`, else 60 s |
| 429 | `enroll` | register | seconds | Wait `Retry-After`, else 60 s; do not re-attest before then |
| 429 | `install_daily` / `global_daily` / `owner_daily` / `sandbox_daily` | tts | seconds to 00:00 UTC | Wait `Retry-After`, else next UTC midnight, persisted across launches |
| 500 | `misconfig` | all | 3600 | Treat as 503 unknown |
| 502 | `upstream` | tts | 60 | Treat as 503 unknown. An ElevenLabs 429/quota error surfaces as 502 with `upstreamCode` in logs, **not** as `global_daily` |
| 503 | `store` | all | 30 | Exponential backoff from `Retry-After` |
| 503 | `disabled` | all | 3600 | Wait `Retry-After` (1 h) |
| 503 | `apple` (status API unreachable, §5.6) | ent | 300 | Wait `Retry-After`; on-device meanwhile |
| 504 | `upstream_timeout` | tts | 60 | Treat as 503 unknown |

**Unknown or missing `reason` / header** (as #234 implements): 429 →
`Retry-After`, else next UTC midnight; 503 and other 5xx → `Retry-After`,
else exponential backoff; any other 4xx → stop paid calls until next launch.

**#234 must also handle (NEW):** 403 `no_entitlement` and `install_limit`,
400/413 no-retry, `owner_daily`/`sandbox_daily` as daily caps, and the
503 `apple` reason. 401 or attest failure **never selects the owner token**
in an A/B build that has both paths (Fry B1), with an iOS test.

### 4.5 Owner A/B builds and the owner token (Sentinel B5, Fry B1/B4)

- The owner bearer path is enabled **only** when
  `AERODJ_TTS_OWNER_TOKEN_ENABLED` is exactly `true` **and**
  `AERODJ_TTS_TOKEN_SHA256` is set. Unset, empty, `TRUE`, `true ` or `1` all
  mean off. This changes today's behaviour (on whenever the hash is set), so
  the owner sets the flag explicitly before the PR that introduces it
  (PR 4) deploys (§12.6). It never defaults to on. PR 1 (#238) adds no flag.
- The owner bucket has **its own cap**, `AERODJ_TTS_OWNER_DAILY_CHAR_CAP`,
  and also reserves against the global ceiling. As shipped in #238, unset
  cap = the global ceiling. Proposal: equal to global while the owner is
  the only paid user; 1,500 once any public install has paid voice.
- **The owner keeps the paid voice without buying** through this flagged
  token until it is retired. The owner token is **not** subject to the
  entitlement check, and is never a fallback for an attest or entitlement
  failure. After retirement the owner can use either a TestFlight build
  with a Sandbox purchase (only if the sandbox policy in §5.7 allows it on
  that deployment) or a subscription offer code from App Store Connect (an
  ASC feature; owner/Orion to confirm availability for this group).
- **PR 10 (retire the owner bearer from server and app, delete the Keychain
  field and the `AERODJ_OWNER_AB` path) is a hard gate before any public
  paid voice.** `check-release-disables-paid-voice.sh` is extended to fail
  if a Release build references the owner-token Keychain key.
- TestFlight and App Store builds always use the production App Attest
  environment; dev-signed builds stay on `development`, which a Production
  server refuses (Sentinel rec. 10).

### 4.6 Privacy (attest part; Pro in §5.11)

- Stored: `keyId`, public key, counter, environment, created day, revoked
  flag, per-day character counters. No script text, voice, station, IP or
  user id in the function's storage. Vercel's platform request logs do see
  IPs and paths, which is why no identifier goes in a path (Fry).
- Script text **does** leave the device to ElevenLabs when paid voice plays,
  gated by #176 and consent (Fry wording fix).
- Logs: one JSON line of enums, bools and numbers: `requestId`, `status`,
  `chars`, `reason`, `upstreamStatus`, `upstreamCode`. Never `keyId`,
  challenge, assertion, any `X-OnAirly-*` value, JWS, transaction id or
  `appAccountToken` (tests assert this).
- Retention: key records 90 days sliding; revoked records kept 90 days then
  expire. KeyIds are not shared with ElevenLabs or anyone else.
- App diagnostics: `PremiumVoiceRoutes.OmitReason` gains cases such as
  `attestUnsupported`, `attestFailed`, `noEntitlement`, plus a paused-until
  timestamp. No key material, no transaction data.
- Label (Sentinel rec. 9): Identifiers → Device ID, App Functionality, Not
  Linked, not Tracking, while keyId is not joined to IP or other data.

### 4.7 Flags, kill switch and revocation (Sentinel B5, Fry B4)

- **Only the literal string `true` enables anything.** That applies to
  `AERODJ_TTS_ATTEST_ENABLED`, `AERODJ_TTS_OWNER_TOKEN_ENABLED`,
  `AERODJ_TTS_ENTITLEMENT_REQUIRED`, `AERODJ_TTS_STATUS_API_ENABLED`.
  Purchase policy (sandbox, Family Sharing, grace, installs per purchase) is
  not env: it lives in the single StoreKit config (§5.1).
  Anything else is off.
- Attest kill switch off → `challenge`, `register`, `entitlement` and the
  attested `/api/tts` return 503 `disabled` **before any Redis call**.
- **`AERODJ_TTS_ENTITLEMENT_REQUIRED` fails closed in the other direction**:
  it exists only to stage rollout. Attested `/api/tts` is refused with
  503 `disabled` unless it is exactly `true` (there is no "attested but not
  entitled" paid path in any build that reaches the public). The only
  non-entitled paid path is the owner token (§4.5).
- `AERODJ_TTS_GLOBAL_DAILY_CHAR_CAP=0` is the master stop for every path,
  owner included.
- **Env changes apply only to new deployments** on Vercel (correcting
  revision 1). Runbook: change env → redeploy Production (minutes). For an
  instant stop, a Redis key `cfg:{aerodj-tts}:paid_off` is read inside each
  script; set → 503 `disabled`; unreadable → 503 `store` (fails closed). An
  optional `cfg:{aerodj-tts}:global_cap` may only **lower** the env cap.
  Whether to adopt the Redis switch is an owner decision (§11).
- Per-install revoke: `revoked=true` on `key:<keyId>`; per-purchase revoke:
  tombstone the entitlement (§5.6). Owner-run scripts reading ids from stdin,
  never committed with real ids.

## 5. Pro entitlement (new)

### 5.1 Product configuration

- One subscription group, two auto-renewable products: Pro monthly
  (placeholder $4.99) and Pro yearly (placeholder $34.99). Product IDs are
  placeholders until Orion and the owner create them in App Store Connect:
  `com.aerodj.app.pro.monthly`, `com.aerodj.app.pro.yearly`.
- **One config file** holds them, e.g. `config/onairly-products.json`
  `{ "subscriptionGroup": "...", "proProductIds": [...] }`, read by the iOS
  build (Nova's paywall), Fry's `.storekit` file (a test asserts the IDs
  match), and the proxy (imported at build time as the allowlist). Whoever
  lands first creates it; the others import it.
- **Proxy side, single config:** `services/aerodj-tts/config/storekit.json`
  (the Vercel project deploys from `services/aerodj-tts`, so the proxy keeps
  its own copy; a later CI check asserts its product IDs equal the app's).
  It holds the bundle ID, the Pro product allowlist and one value per
  purchase policy. **Orion's interim defaults until the owner answers:**
  `installsPerPurchase: 5`, `allowSandboxInProduction: false` (Sandbox
  rejected on Production), `honorGracePeriod: false` (no grace period),
  `allowFamilyShared: false` (Family Sharing off). Each is one value, so a
  change is a one-line edit plus a deploy.
- **App-side Pro gate (owned by Fry on `fry/storekit-config`, credit Fry and
  Nova):** Fry gates bundled clips and the paid-voice route config on Pro,
  reading the entitlement through Nova's paywall protocol; Nova's paywall
  gates on Pro **plus** consent. PR 9 consumes their protocol rather than
  defining its own. The server-side check (§5.3-§5.6) stays Atlas's.
- Free tier = on-device voice, always available. Pro unlocks only the
  ElevenLabs route. Per App Review Guideline 3.1.1, unlocking that feature
  must use in-app purchase: no external payment links, codes or other
  unlock mechanism.

### 5.2 Flow

1. Install attests (§4.1.2).
2. User consents to the voice/data terms first (consent sheet), then may
   open Nova's paywall. Paywall state never gates privacy controls.
3. Purchase: `product.purchase(options: [.appAccountToken(token)])` with the
   token of §5.4. StoreKit returns a `VerificationResult<Transaction>`.
4. The app posts the signed transaction to `POST /api/entitlement`:
   body `{ "signedTransaction": "<JWS>" }`, assertion-signed with purpose
   `ent`. The JWS is the transaction's JWS representation from
   `VerificationResult` (StoreKit's `jwsRepresentation`; exact accessor to be
   confirmed in PR 9, the per-symbol doc page did not resolve). The app
   finishes the transaction only after its own StoreKit verification, not
   after the server call.
5. The app re-posts the latest transaction from `Transaction.currentEntitlements`
   on launch, on `Transaction.updates`, on restore, and once after a 403
   `no_entitlement`. Apple documents that `currentEntitlements` excludes
   refunded and revoked products and includes subscriptions that are
   subscribed or in grace period.
6. Server verifies (§5.3), links (§5.5), returns 204.
7. `/api/tts` then requires: valid assertion + active entitlement link +
   per-install daily cap + global ceiling (§4.3).

### 5.3 Offline JWS verification (`AppStoreJwsVerifier`)

The verifier is shared by `/api/entitlement` and the notifications
endpoint. Every check must pass; any failure → 403 `no_entitlement`
(entitlement) or 400 (notifications), and nothing is stored.
1. Compact JWS, three parts; header `alg == "ES256"`; `x5c` present, 3
   certs (leaf, intermediate, root). Size caps before decoding.
2. Chain: leaf → intermediate → the **pinned Apple Root CA - G3**
   (`AppleRootCA-G3.cer`, public, from apple.com/certificateauthority,
   committed with its SHA-256 fingerprint in a test). The `x5c` root must be
   byte-equal to the pinned one; the system trust store is never used.
   Validity dates are checked at the JWS `signedDate`, and at now for the
   leaf. Apple's App Store Server Library additionally requires the marker
   extensions `1.2.840.113635.100.6.11.1` (leaf) and
   `1.2.840.113635.100.6.2.1` (intermediate); we copy that check. Those OIDs
   come from Apple's open-source library (github.com/apple), **not** from a
   developer.apple.com page: Sentinel to accept the source. The library's
   optional OCSP revocation check is deferred (no network in the verify path).
3. ES256 signature over `header.payload` with the leaf key (JOSE raw
   `r‖s`, converted for `node:crypto`).
4. Payload (`JWSTransactionDecodedPayload` fields only):
   - `bundleId == "com.aerodj.app"`;
   - `productId` in the config allowlist; `type` is an auto-renewable
     subscription (exact enum string verified against Apple's `type` page in
     PR 5);
   - `environment == "Production"` on Production; `"Sandbox"` only per §5.7;
     anything else (including Xcode StoreKit-testing transactions, which are
     not signed by Apple's chain) refused;
   - `expiresDate > now` (ms), after grace handling in §5.6;
   - no `revocationDate`;
   - `inAppOwnershipType == "PURCHASED"`; `FAMILY_SHARED` only per §5.5;
     `ASSIGNED` refused;
   - `appAccountToken`, if present, a well-formed UUID (§5.4).
5. **Never trust a client `isPro` flag** or any client-supplied expiry.

### 5.4 `appAccountToken` definition

Apple: a UUID the app creates at purchase "that associates the transaction
with a customer on your own service"; StoreKit returns the same value in the
transaction and renewal info; it can be set or updated later only through
the Set App Account Token server endpoint.

**Ours:** a random UUIDv4 generated by the app the first time it starts a
purchase, stored in the Keychain as a synchronizable item (so it follows the
user's own devices when iCloud Keychain is on), reused for every later
purchase from that Keychain. It is **not** the App Attest `keyId`, not
derived from the device, the Apple ID, an email or any user identifier, and
not sent anywhere except inside `purchase(options:)`.

**What the binding does, honestly:** the server stores
`HMAC(appAccountToken)` on the entitlement record at first link and refuses
a later link whose JWS carries a *different* token for the same
`originalTransactionId` unless that JWS has a newer `signedDate` (Apple lets
the token change). It is **not a secret**: it sits in the JWS payload, so
anyone holding a shared JWS also holds the token. The real anti-sharing
control is the per-purchase install cap (§5.5). Restores and purchases
made outside the app (offer codes) may lack the token, so absence is allowed.

### 5.5 Storage, linking and installs per purchase

Keys (hash tag `{aerodj-tts}`; `h(x) = HMAC-SHA256(AERODJ_TTS_ID_HMAC_KEY, x)`):
- `ent:<h(originalTransactionId)>` = `{ productId, env, expiresMs,
  graceUntilMs, status, lastSignedMs, aatHash, ownership }`; TTL =
  expiry + grace + 60 days (Apple's billing retry window).
- `tomb:<h(originalTransactionId)>` = `{ revokedMs, reason }`; TTL ≥ the
  revoked transaction's `expiresDate` + max grace + 1 day (an older JWS
  fails the expiry check after that anyway).
- `link:<keyId>` = `h(originalTransactionId)`, 30-day sliding TTL.
- `members:<h(originalTransactionId)>` = sorted set of keyIds by last use.

One `ENTLINK` script, after the assertion and JWS verify: consume challenge
→ counter → tombstone check (tomb present and JWS `signedDate` ≤ `revokedMs`
→ 403 `no_entitlement`) → upsert `ent` if `signedDate` is newer → evict
members idle > 30 days → if this keyId is not a member and members ≥
**`installsPerPurchase` in the StoreKit config (interim 5)** → 403 `install_limit`;
also at most 10 new links per purchase per rolling 30 days (reinstall churn
without unlimited rotation) → add member, set `link`.

**Why 5:** the typical Pro user has an iPhone, maybe an iPad, plus
reinstalls (each reinstall is a new keyId); idle links age out in 30 days.
Five is enough for one person and too few to run a shared-purchase farm.
Owner decision (§11).

**Family Sharing:** recommendation is **off** for v1, because each paid
listener costs ElevenLabs credits. Then only `PURCHASED` is accepted.
If the owner enables it, `allowFamilyShared: true` in the config accepts
`FAMILY_SHARED`; whether a family member's transaction carries its own
`originalTransactionId` or the purchaser's is **unverified** in Apple's docs,
so PR 6 tests both and the cap applies per `originalTransactionId` either way
(at worst a family shares 5 slots). Revoking Family Sharing arrives as
`REVOKE` (§5.6). Whether the ASC Family Sharing toggle can later be turned
off is **unverified** here; Orion to check ASC help before the owner enables it.

### 5.6 Expiry, refund and revocation

**Primary: App Store Server Notifications V2** at
`POST /api/appstore/notifications` (the owner sets this URL in ASC for
Production, and optionally Sandbox). Body `{ "signedPayload": "<JWS>" }`,
raw-byte cap 64 KB. The outer JWS and the inner `data.signedTransactionInfo`
and `data.signedRenewalInfo` are verified exactly as §5.3 (chain, ES256,
`data.bundleId`, `data.environment`). Idempotent:
`SET notif:<sha256(notificationUUID)> NX EX 30d` inside the script, only
after verification; a duplicate returns 200 with no change. Out-of-order
safe: changes apply only if the transaction's `signedDate` is newer than
`lastSignedMs`, except tombstones, which always apply.

| `notificationType` (`subtype`) | Effect |
| --- | --- |
| `SUBSCRIBED`, `DID_RENEW` (incl. `BILLING_RECOVERY`), `OFFER_REDEEMED`, `DID_CHANGE_RENEWAL_PREF`, `RENEWAL_EXTENDED` | Update `expiresMs` from the verified transaction |
| `DID_CHANGE_RENEWAL_STATUS` (`AUTO_RENEW_ENABLED`/`_DISABLED`) | Record auto-renew only; access unchanged until expiry |
| `DID_FAIL_TO_RENEW` with subtype `GRACE_PERIOD` | Keep access until `gracePeriodExpiresDate` from the verified renewal info |
| `DID_FAIL_TO_RENEW` with no subtype (billing retry, no grace) | Access ends at `expiresDate` |
| `GRACE_PERIOD_EXPIRED`, `EXPIRED` (any subtype) | End access now |
| `REFUND`, `REVOKE` | Write tombstone, end access, delete all `members`/`link` for that purchase |
| `REFUND_REVERSED` | Remove tombstone; access returns on the next verified entitlement post |
| `TEST`, everything else | 200, no change |

Note: `GRACE_PERIOD` is a **subtype** of `DID_FAIL_TO_RENEW` in Apple's
docs, not its own `notificationType`. Apple treats HTTP 200-206 as success
and retries 40x/50x five times (1, 12, 24, 48, 72 h after the previous
attempt) in Production only; Sandbox sends once. So: 200 on success or a
verified no-op, 400 on an unverifiable payload (not from Apple), 503 on a
store failure so Apple retries.

**Backstop: short-TTL re-check.** Each `ent` record is valid only until
`min(expiry or grace end, verifiedAt + AERODJ_TTS_ENTITLEMENT_TTL_HOURS)`
(proposal 24 h). After that `/api/tts` returns 403 `no_entitlement` and the
app re-posts its current transaction (§5.2 step 5). Combined with
tombstones, a refunded or expired purchase stops paid voice within the TTL
even if a notification is lost. Missed notifications can also be recovered
with the Get Notification History endpoint (needs the API key below).

**Optional: App Store Server API status lookup** (`AERODJ_TTS_STATUS_API_ENABLED`
exactly `true`). On each entitlement post the proxy calls
`GET https://api.storekit.apple.com/inApps/v1/subscriptions/{transactionId}`
(Get All Subscription Statuses; status 1 active, 2 expired, 3 billing retry,
4 grace, 5 revoked) and grants only for 1 or 4. Requests carry a per-request
ES256 JWT (`kid`, `iss`, `iat`, `exp` ≤ 60 min, `aud: appstoreconnect-v1`,
`bid`) signed with an **owner-created In-App Purchase API key**. The `.p8`,
key ID and issuer ID live **only in Vercel Production env**, never in the
app, repo, CI, logs or chat. Apple unreachable or non-2xx → 503 `apple`, no
grant (fail closed). Without the key, the design still works on
notifications + TTL.

**Grace period and billing retry:** if the owner enables Billing Grace
Period in ASC, access continues until `gracePeriodExpiresDate`; in billing
retry without grace, paid voice stops at `expiresDate` and resumes on
`DID_RENEW` (`BILLING_RECOVERY`). The grace length is the owner's ASC choice.

### 5.7 Sandbox policy

App Review and TestFlight purchases are not Production-environment
transactions (Sandbox; exact TestFlight behaviour to confirm against Apple's
TestFlight docs in PR 6). Refusing Sandbox outright on Production would leave
App Review unable to test Pro. Recommendation: on Production,
`allowSandboxInProduction: true` in the config accepts `Sandbox` transactions from a
**separate** small bucket, `chars:sandbox:<UTCday>` under
`AERODJ_TTS_SANDBOX_DAILY_CHAR_CAP` (proposal 1,500), still under the global
ceiling (429 `sandbox_daily`). Flag off → Sandbox is 403 `no_entitlement`
(tested as "sandbox-in-prod must fail"). Owner decision (§11).

### 5.8 Fail closed

Any verify error, unknown transaction, tombstone, Apple outage (when the
status API is on), store error or missing config → no paid render. The app
plays the on-device voice. No error path ever grants Pro, and none falls
back to the owner token.

### 5.9 No secrets in the app

The app holds no App Store Server API key, no shared secret and no HMAC key.
It only forwards Apple-signed JWS and App Attest assertions. Server-only
secrets: `AERODJ_TTS_CHALLENGE_HMAC_KEY`, `AERODJ_TTS_ID_HMAC_KEY`, and
optionally the IAP API `.p8`; all owner-created, Vercel Production env only.

### 5.10 Consent and paywall ordering

The consent sheet comes first. The paywall (Nova) never gates privacy
settings, consent withdrawal or the free on-device voice. The app shows the
paywall only from Nova's UI state (StoreKit entitlement), never in response
to a proxy 403.

### 5.11 Privacy (Pro)

- `originalTransactionId` and `appAccountToken` are pseudonymous
  identifiers. Stored only as keyed HMACs, never in plaintext, never logged,
  never in a URL. Raw values exist only in memory during a request (and in
  the outbound status-API URL when that option is on).
- Retention: `ent` until expiry + grace + 60 days; tombstones per §5.5;
  links 30 days idle; notification UUID marks 30 days.
- Logs: enums, bools and numbers only (`reason`, `env` enum, `ownership`
  enum, `notificationType` enum, `status` number). Never a JWS, transaction
  id, `appAccountToken` or notification UUID.
- Label additions (Sentinel to confirm in the #174 PR): **Purchases →
  Purchase History, App Functionality, Not Linked to You, not Tracking**,
  alongside Identifiers → Device ID.

## 6. Overlaps

- **Fry #234:** add the NEW rows of §4.4 (`no_entitlement`, `install_limit`,
  400/413, `owner_daily`, `sandbox_daily`, `apple`); never fall back to the
  owner token.
- **Nova (paywall, status UI):** product IDs from the shared config;
  `appAccountToken` per §5.4 on every purchase; restore purchases and the
  manage-subscription link; post to `/api/entitlement` per §5.2; consent
  first (§5.10).
- **Fry (StoreKit config + StoreKitTest):** the `.storekit` IDs must equal
  the config; tests for purchase/restore/expiry/refund drive the app's
  entitlement sync. StoreKitTest transactions are not Apple-chain signed, so
  they test the app, not the server verifier (which uses fixtures, §8).
- **Fry #237 (bundled clips):** clips are paid-voice audio, so they play only
  when the app-side paid route is configured, which PR 9 makes conditional on
  a current Pro entitlement. Free tier: zero clips, zero proxy calls.
- **App Review 3.1.1:** IAP is the only unlock; no external purchase path.
- **Sentinel:** reviews the verifier and entitlement path (§5) against the
  criteria in §10.

## 7. Endpoints summary

| Endpoint | Auth | Writes (only after verification) |
| --- | --- | --- |
| `POST /api/attest/challenge` | none (edge per-IP limit) | none |
| `POST /api/attest/register` | attestation | key NX, enroll counter, challenge mark |
| `POST /api/entitlement` | assertion (`ent`) + Apple JWS | counter, challenge mark, ent, link, members |
| `POST /api/tts` | assertion (`tts`) + entitlement, or the owner token | counter, challenge mark, char buckets |
| `POST /api/appstore/notifications` | Apple JWS | notif mark, ent, tombstone |

## 8. Test plan

**Proxy (`node:test`, CI job `tts-proxy`, no network, no real keys).**
- Stateless challenge: bad MAC, expired, wrong purpose, reused (second use
  401), and **no Redis call at issuance** (spy).
- Attestation verifier against a self-signed test chain plus a real-device
  fixture from the Duo: wrong root, wrong rpId, nonce mismatch,
  `counter != 0`, wrong `aaguid`, `keyId` mismatch, duplicate `keyId` (NX).
  Enrollment counter unchanged by failed attestations.
- Assertions: replay (same counter), lower counter, reused/expired
  challenge, body-hash mismatch (whitespace/key order), revoked key, counter
  committed when a cap refuses, refund never rolls back the counter.
- JWS verifier (Sentinel criterion 7), each must fail: forged signature,
  self-signed root, wrong intermediate/leaf OIDs, expired cert, wrong
  bundle, product not allowlisted, expired `expiresDate`, `revocationDate`
  present, `Sandbox` on Production with the flag off, `Xcode` environment,
  `FAMILY_SHARED` with the flag off, `ASSIGNED`, a pre-refund JWS replayed
  after a REFUND tombstone, the same JWS from a 6th install
  (`install_limit`), a client `isPro` field ignored.
- Notifications: each row of §5.6, duplicate `notificationUUID`
  idempotent, out-of-order `signedDate`, 503 on store failure.
- Quotas: two concurrent requests at the per-install edge; global
  exhaustion by N installs; `RESERVE2`/`RELEASE2` all-or-nothing against a
  fake EVAL; `durable !== true` → 503 `store` in every environment.
- Flags: `true` enables; unset, `TRUE`, `1`, `true ` do not.
- Contract: every row of §4.4, `Retry-After` on every 429/503.
- Logs: no keyId, text, challenge, assertion, header value, JWS,
  transaction id, `appAccountToken` or notification UUID in any line.
- Mutation checks for every guard above (each mutation must fail a test).

**iOS (`AeroDJCore`, Linux and iOS CI).** `AppAttesting` and an
`EntitlementSyncing` protocol with fakes: challenge-then-assert order,
clientData bytes matching the server fixture, §4.4 backoff (Fry #234), no
owner-token fallback, `appAccountToken` persisted and reused, re-sync once
on 403. StoreKitTest tests by Fry. A real-device run by Fry on the Duo
(#224 checklist) with a TestFlight build; nothing here claims a physical
test that has not happened.

## 9. PR breakdown (each with exact-head CI and Fry + Sentinel sign-off)

1. **Proxy: quota keys and 429 contract — shipped as #238 (head
   `ad4c081`).** Two-bucket reserve/release, `reason` enum including
   `owner_daily`, refusal body `{ error, requestId, reason, retryAfterSeconds }`
   plus `Retry-After`, rate `Retry-After` fixed at 60 s, global ceiling
   defaulting to 9,000 when unset. Adds **no flags**: the owner token keeps
   working unchanged, with its own `owner_daily` bucket defaulting to the
   global ceiling. Going live needs the owner's deploy OK.
2. **Proxy: stateless challenge endpoint** (HMAC, purpose tag, no Redis),
   kill switch checked before any store call, raw-body reader with caps.
3. **Proxy: App Attest verifier and `register`** (pinned root, in-house
   CBOR/ASN.1 on `node:crypto` under Sentinel's rec. 5 limits, SET NX +
   verified-only enroll counter).
4. **Proxy: assertion verification on `/api/tts`** (counter commit,
   challenge mark, `mixed_auth`), durable-only limiter on the verified path,
   and the exact-`true` `AERODJ_TTS_OWNER_TOKEN_ENABLED` flag (owner sets it
   before this PR deploys, §12.6). Still disabled by default.
5. **Proxy: `AppStoreJwsVerifier` with fixtures** (pinned Apple Root CA -
   G3, test-generated chains, every §8 failure case). No endpoint yet.
6. **Proxy: `POST /api/entitlement` + linking** (`ENTLINK`, install cap,
   tombstone check, sandbox/family flags, shared product config).
7. **Proxy: `POST /api/appstore/notifications`** (V2, idempotent,
   out-of-order safe, tombstones). Optional status-API client behind its flag
   (no key in CI; HTTP faked).
8. **Proxy: enforcement on `/api/tts` behind `AERODJ_TTS_ENTITLEMENT_REQUIRED`**
   (exact `true`; attested paid path refused otherwise).
9. **iOS: `AppAttesting` client, entitlement sync, `stationId` dropped**;
   it consumes Fry's app-side Pro gate (`fry/storekit-config`, read through
   Nova's paywall protocol, which gates on Pro plus consent). That gate covers
   the **paid-voice route config** and therefore also bundled clips (Fry's #237, which today play
   whenever the paid route is configured; Sentinel on #237). Required test:
   the free tier gets **zero bundled clips and zero proxy calls**. No bundled
   clips ship before this PR lands;
   App Attest capability in `AeroDJ.entitlements` (owner step); wired for
   A/B builds first. One backoff implementation (Fry #234).
10. **Retire the owner bearer** (server and app, Keychain field,
    `AERODJ_OWNER_AB`), release-check extended. **Hard gate before any public
    paid voice.**
11. (Phase 2, optional) DeviceCheck enrollment throttle. (Phase 3,
    optional) fraud-metric receipt refresh.

Nova's paywall PR and Fry's StoreKit PR run in parallel with 5-8 and must
merge before 9 ships to TestFlight. Docs (proxy README, `docs/privacy/*`) ride
with the PR that changes behaviour.

**Rollout.** (1) Merge 1-8 with every new flag unset; the owner path keeps
working unchanged through PR 1-3, and from PR 4 once the owner sets its
flag (§12.6). (2) Owner completes §12, then
enables attest and entitlement on Production only. (3) Owner A/B TestFlight
build on App Attest + a Sandbox purchase: validate quotas, the contract,
refund/expiry via Sandbox notifications, and on-device fallback on the Duo.
(4) PR 10 retires the owner token. (5) Public builds get the paid route only
after the consent gate and #176 merge and the owner approves the public spend.

## 10. Sign-off criteria mapping (Sentinel, entitlement)

| Criterion | Where |
| --- | --- |
| 1 Full x5c chain to Root G3, bundle, product from config, environment, expires/revocation, no client `isPro` | §5.3 |
| 2 Bound to attested key, `originalTransactionId` stored, installs-per-purchase cap, per-install cap stays | §5.5, §4.3 |
| 3 Verified, idempotent ASSN v2 or short-TTL re-check; refund/expiry stops within TTL | §5.6 |
| 4 No secret in the app; `.p8` only in Vercel Production env | §5.9, §5.6 |
| 5 Fail closed; paywall never gates privacy; consent first | §5.8, §5.10 |
| 6 No plaintext ids/JWS/token in logs; label Purchases, App Functionality, Not Linked | §5.11 |
| 7 Forged, wrong-bundle, expired, revoked, sandbox-in-prod, replayed must fail, with mutations | §8 |

## 11. Owner decisions (not ours to make)

- **Quota sizes:** per-install daily cap (proposal 1,500 chars), global
  ceiling (9,000 today), owner-bucket cap (= global until any public paid
  voice, then 1,500), sandbox cap (1,500), enrollment cap per day. A bigger
  ceiling means a bigger ElevenLabs plan.
- **Interim defaults (Orion) until the owner answers**, each one value in
  `config/storekit.json` (§5.1): 5 installs per subscription, Sandbox
  rejected on Production, no grace period, Family Sharing off.
- **Installs per subscription:** interim 5 active installs, 10 new links
  per 30 days.
- **Sandbox policy:** allow Sandbox on Production behind the flag with its
  own small bucket (recommended, for App Review/TestFlight), or refuse.
- **Billing Grace Period:** enable or not, and its length (ASC setting).
- **Family Sharing** for the Pro products: recommended off for v1.
- Whether to use the optional App Store Server API status lookup (needs an
  IAP API key).
- Kill switch and global cap in env only (change = redeploy) or also in Redis
  for an instant stop (recommended).
- Whether public users get paid voice at v1 launch (owner: v1 waits until the
  paid voice is public-ready), and the retirement date of the owner token
  (must be before any public paid route).
- Lower day-0 quota for brand-new keys (optional).
- Whether the Upstash plan's command quota covers attest/assert/entitlement
  traffic.
- Whether a DeviceCheck key (phase 2) is worth the extra secret.
- Final App Privacy answers (Device ID, Purchases; App Functionality; Not
  Linked) together with the ElevenLabs disclosure; ElevenLabs logging and
  training opt-out (#174 blocker 7).
- Final prices (placeholders $4.99/mo, $34.99/yr).

## 12. Owner actions (the owner does these; we never create keys)

1. **App Store Connect (Orion coordinates with the owner):** create the
   subscription group and the two Pro products with the IDs in the shared
   config; set Billing Grace Period and Family Sharing per §11.
2. **ASC → App Information → App Store Server Notifications** (waits on the
   owner accepting the **Paid Apps Agreement** in ASC): set the
   **Version 2** Production URL to
   `https://<aerodj-tts host>/api/appstore/notifications`, optionally the
   same for Sandbox. Then use Apple's Request a Test Notification endpoint
   (needs the IAP key) or a Sandbox purchase to confirm delivery.
3. Optional: **ASC → Users and Access → Integrations → In-App Purchase:**
   create an IAP API key; paste the `.p8`, key ID and issuer ID directly into
   Vercel **Production** env. Never through chat, the repo, CI or logs.
4. **Apple Developer → Identifiers → `com.aerodj.app`:** enable **App
   Attest**, regenerate profiles. The bundle ID stays unchanged through the
   OnAirly rename (the rename PR adds a CI guard on
   `PRODUCT_BUNDLE_IDENTIFIER`); `rpId` and the JWS `bundleId` check both
   depend on it.
5. **Vercel `aerodj-tts`:** confirm Upstash in Production
   (`KV_REST_API_URL`/`KV_REST_API_TOKEN`), `AERODJ_TTS_ACCEPT_BEST_EFFORT_LIMITS`
   unset; Preview has **no** `ELEVENLABS_API_KEY` or has Deployment
   Protection on (lesson of #232); add a Firewall per-IP rate rule for
   `/api/attest/*`, `/api/entitlement`, `/api/tts`.
6. **Before PR 4's deploy** (the PR that introduces the flag; PR 1 / #238
   adds none): set `AERODJ_TTS_OWNER_TOKEN_ENABLED=true` and
   `AERODJ_TTS_OWNER_DAILY_CHAR_CAP`, or the owner A/B build loses paid voice
   (fails closed, by design).
7. When enabling: generate and set `AERODJ_TTS_CHALLENGE_HMAC_KEY` and
   `AERODJ_TTS_ID_HMAC_KEY` (32 random bytes each, Production only); set the
   non-secret vars `AERODJ_TTS_APPLE_APP_ID_PREFIX`,
   `AERODJ_TTS_BUNDLE_ID=com.aerodj.app`, `AERODJ_TTS_APP_ATTEST_ENV=production`,
   the caps,
   `AERODJ_TTS_ENTITLEMENT_TTL_HOURS`, and the exact-`true` flags. Redeploy
   after each change.
8. Phase 2 only: DeviceCheck key into Vercel Production env.
9. Keep the ElevenLabs restricted key's own credit limit as the backstop.

## 13. Sources (developer.apple.com unless noted, fetched 2026-10-29)

- App Attest: "Validating apps that connect to your server";
  `DCAppAttestService`.
- `JWSTransactionDecodedPayload`, `JWSTransaction`, `JWSRenewalInfoDecodedPayload`,
  `inAppOwnershipType`, `environment`, `appAccountToken`, `revocationDate`,
  `gracePeriodExpiresDate`, `status` (App Store Server API docs).
- StoreKit: `Product.PurchaseOption.appAccountToken(_:)`,
  `Transaction.currentEntitlements`.
- App Store Server Notifications: `notificationType`, `subtype`,
  `responseBodyV2DecodedPayload`, `data`, "Responding to App Store Server
  Notifications", "Enabling App Store Server Notifications".
- App Store Server API: "Get All Subscription Statuses", "Generating JSON
  Web Tokens for API requests".
- App Review Guidelines 3.1.1 (developer.apple.com/app-store/review/guidelines).
- Apple Root CA - G3: apple.com/certificateauthority (Apple primary, not
  developer.apple.com).
- Marker OIDs `1.2.840.113635.100.6.11.1` / `.6.2.1`: Apple's
  app-store-server-library-node `jws_verification.ts` (github.com/apple).
- HTTP 402/403 semantics: RFC 9110 §15.5.3-15.5.4 (§4.4 choice below).

**Why 403 for `no_entitlement`:** RFC 9110 reserves 402 "for future use", so
clients and intermediaries attach no defined meaning to it. 401 already
means "re-attest / stop until next launch" in our contract and in #234;
reusing it would wipe a valid key. 403 says the credentials (a valid
assertion) were understood but are insufficient for this resource, which
is exactly an attested install without Pro. `Retry-After` does not apply;
the trigger to try again is a StoreKit entitlement change.

-Atlas
