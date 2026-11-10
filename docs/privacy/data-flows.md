# AeroDJ data-flow inventory

> Owner: Sentinel (AppSec & privacy). Status: **draft for owner review**, docs only.
> Audited at `integration/device-duo` @ `d834dec` on 2026-10-29. Line numbers refer to that commit.
> Anything not confirmed from code or a page fetched on 2026-10-29 is marked **unverified**.

## 1. Summary

The native iOS app (`ios/`) sends very little off the phone. At `d834dec`:

1. **Apple Music / MusicKit** (Apple): playback, catalog search and charts, under the listener's Apple ID. This is Apple's own service.
2. **Phonon voice model download** (GitHub release asset): one anonymous, pinned `GET` over Wi-Fi. No user data is sent; GitHub sees the IP address.
3. **DJ script text to `aerodj-tts`, then ElevenLabs**: **only** in an internal TestFlight build archived with `owner_ab: true` (`AERODJ_OWNER_AB`), with a voice selected and a proxy URL and owner token in the Keychain, **and** with the proxy host pinned in `PremiumVoiceRoutes.allowedHosts`. At `d834dec` that set is **empty** (`PremiumVoiceCatalog.swift:109`), so the ElevenLabs route is always omitted and **no DJ text leaves the device on this branch**. The pin to `aerodj-tts.vercel.app` is on the unmerged branch `cursor/tts-host-pin-7c43` (`7fdfb94`). Once that lands, flow 3 is live for owner A/B builds.

Everything else stays on the device: calendar (EventKit), picked Obsidian/Markdown notes, Share Extension inbox, station configuration, narration audio cache, on-device speech (AVSpeechSynthesizer and Phonon), and the unified system log (os `Logger`).

The app ships **no analytics, crash-reporting, advertising or tracking SDK**, never reads the IDFA, and doesn't use App Tracking Transparency. A grep for Firebase, Sentry, Crashlytics, MetricKit, `ASIdentifierManager`, AppTrackingTransparency, CloudKit, Supabase and Telegram under `ios/` found nothing.

The **legacy Next.js web app** (`app/`, `lib/`, Vercel project `ray-do`) is a separate product. The iOS app never calls it (no reference to its host or routes under `ios/`). It does, however, sit in the same repo and on a public deployment, so it is inventoried in section 4 and called out as a release blocker.

## 2. Inventory: iOS app and the services it calls

| # | Flow | Data | Destination | Linked to identity? | Used for tracking? | Retention | Gate | Code |
|---|---|---|---|---|---|---|---|---|
| 1 | Apple Music playback and library | Playback commands, queue, library reads; the account is the listener's Apple ID | Apple (MusicKit) | Yes, Apple ID (Apple's processing, not ours) | No | Apple's policy, not ours | `NSAppleMusicUsageDescription` (`ios/project.yml:47`), `MusicAuthorization` | `ios/AeroDJ/MusicKitService.swift` |
| 2 | Catalog seed search, charts, genres | Search terms typed for station seeds, the storefront country code | `api.music.apple.com` via `MusicDataRequest` (Apple adds the user token) | Yes, Apple ID (Apple-side) | No | Apple's policy | Station tuning | `ios/AeroDJ/MusicCatalogSeedSource.swift:263-268` |
| 3 | Library seeds | Library playlists, songs and artists the listener picks | **Stays on device** (`MusicLibraryRequest`) | n/a | n/a | Station file on device | Station tuning | `ios/AeroDJ/MusicCatalogSeedSource.swift:270+` ("Library lookups (on-device only)") |
| 4 | Phonon model download | No user data. One `GET` of a fixed URL with ephemeral session, no cookies or cache, no extra headers, Wi-Fi only, and redirects gated | `github.com/gradium-ai/xn-ptts` release asset (served from GitHub's CDN) | No; GitHub sees IP and the default User-Agent | No | GitHub's policy, **unverified** | Only when the Phonon route is in the voice chain | `ios/AeroDJCore/Sources/AeroDJCore/Voice/PhononSpeechSelection.swift:35,48-53`; `ios/AeroDJ/PhononModelStore.swift:124-145` |
| 5 | **DJ script text to the TTS proxy** | `POST` JSON `{upstream:"elevenlabs", voiceId, text, format, stationId}` plus `Authorization: Bearer <owner token>`. `text` is one narration cue: track titles and artists, the station name the listener typed, time-of-day lines, and (latent, see 3.2) personal briefing lines. `stationId` is the constant `"default"`. | `https://<pinned proxy host>/api/tts`, i.e. Vercel project `aerodj-tts` (`aerodj-tts.vercel.app`, pin unmerged) | The request carries the **owner's shared token**, not a per-user identity. Vercel sees the caller's IP and User-Agent. | No | Proxy app log (row 6) and Vercel platform logs (row 7) | `AERODJ_OWNER_AB` compile flag **and** `OwnerVoiceTrial.paidProvidersEnabled` **and** a selected voice **and** Keychain endpoint and token **and** an endpoint host in `allowedHosts` (empty at `d834dec`) **and** the station has no library seed | `ios/AeroDJCore/Sources/AeroDJCore/Voice/ProxyVoiceProvider.swift:60-69`; `.../Voice/PremiumVoiceCatalog.swift:60-67,109,134-157`; `ios/AeroDJ/OwnerVoiceTrial+App.swift:17-32` |
| 6 | Proxy application log | `{requestId, status, chars}`, plus `{upstreamStatus, upstreamCode}` on an upstream non-2xx only. `upstreamCode` is ElevenLabs' `detail.status` only if it matches `/^[a-z0-9_]{1,64}$/`, else `other`. **No text, voice ID, token or IP** is written by our code. | Vercel runtime logs (`console.log`) | No (random UUID per request) | No | Vercel runtime log retention for the team's plan (see 2.2) | Always on the proxy | `services/aerodj-tts/src/handler.ts:28-36,150-172,209-220,313` |
| 7 | Vercel platform request logs | Per request: method, path, status, host, region, User-Agent, timing. Vercel also matches IP address for the "logs from your browser" filter, so it records the IP. The request **body is not logged** by Vercel's runtime logs (only stdout/stderr lines). | Vercel | Linkable to an IP address | No (by us) | Hobby 1 h, Pro 1 day, Pro + Observability Plus 30 days, Enterprise 3 days (source 2.2). **Which plan the `aerodj-tts` team is on is an owner question.** | Always | Platform behavior, not in repo |
| 8 | Proxy usage counters | Keys `aerodj-tts:rate:owner:<minute>` and `aerodj-tts:chars:owner:<UTC day>`: integer counts only, single shared `owner` bucket | Upstash Redis REST (via Vercel integration) if configured, else in-memory | No | No | Minute keys 120 s TTL; day keys 2 days TTL | Always on the proxy | `services/aerodj-tts/src/limiter.ts:117-185`; `handler.ts:23-24,135-141` |
| 9 | **Proxy to ElevenLabs** | `POST https://api.elevenlabs.io/v1/text-to-speech/<voiceId>?output_format=pcm_22050` with body `{text, model_id}` and the server-side API key. SSML is stripped to plain text first. Text is trimmed and capped at `AERODJ_TTS_MAX_TEXT_CHARS` (default 600). No user identifier, IP or station ID is forwarded. `enable_logging` is **not** set, so ElevenLabs' default (`true`, history retained) applies. | ElevenLabs (US storage per its policy) | Not to the listener. All requests come from the owner's ElevenLabs account. | No (by us). ElevenLabs' own use: see 2.2. | ElevenLabs: "as long as necessary"; request history kept unless `enable_logging=false`, which is enterprise-only (source 2.2) | Proxy auth + rate limit + daily character cap (`AERODJ_TTS_DAILY_CHAR_CAP`, owner-confirmed 9,000 on prod) | `services/aerodj-tts/src/handler.ts:15,232-233,245-258,282-300` |
| 10 | Owner proxy credentials | Proxy endpoint URL and owner bearer token | iOS Keychain, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, service `com.aerodj.owner-ab.tts-proxy` (not synced, not backed up to other devices) | n/a | n/a | Until cleared in the owner sheet | `AERODJ_OWNER_AB` only | `ios/AeroDJ/OwnerVoiceTrial+App.swift:46-100` |
| 11 | Selected premium voice | Voice ID (catalog entry) | `UserDefaults` key `AeroDJ.premiumVoice.selectedID`, on device | n/a | n/a | Until changed | | `ios/AeroDJCore/Sources/AeroDJCore/Voice/PremiumVoiceCatalog.swift:70-88` |
| 12 | Calendar | Events from calendars the listener chooses (read-only) | **Stays on device** (EventKit) | n/a | n/a | In memory; narration audio cache at most 7 days, purged on revoke | `NSCalendarsFullAccessUsageDescription` (`ios/project.yml:49`) | `ios/AeroDJ/EventKitCalendarReader.swift`; `docs/PRIVACY_MATRIX.md` |
| 13 | Notes (Obsidian / Markdown) | Files the listener picks; security-scoped bookmarks | **Stays on device** | n/a | n/a | Until removed | Document picker | `ios/AeroDJ/SecurityScopedNoteReader.swift` |
| 14 | Share Extension inbox | Shared text or one URL, capped at 16 KB | **Stays on device**, App Group `group.com.aerodj` | n/a | n/a | 7 days, enforced on load | User shares | `ios/AeroDJCore/Sources/AeroDJCore/SharedInboxItem.swift`; `docs/PRIVACY_MATRIX.md` |
| 15 | On-device speech | Narration text | **Stays on device** (AVSpeechSynthesizer, Phonon) | n/a | n/a | Narration audio cache at most 7 days | Default voice chain | `ios/AeroDJ/OnDeviceSpeechProvider.swift`; `ios/AeroDJ/PhononSpeechProvider.swift` |
| 16 | System logging (`PlaybackLog`, `p0trace`, `speech`, `phonon`, `cache`, `search`) | Fixed tokens, indices, counts, booleans, error domain and code. No titles, cue text, catalog IDs or secrets by design (`PlaybackLog.swift:9-10`); the premium-route log writes catalog index and reason only (`OwnerVoiceTrial+App.swift:69-77`). | **Stays on device**: unified log. Apple only receives it if the user shares a sysdiagnose or, **unverified**, through "Share iPhone Analytics" | No | No | OS-managed | Always | `ios/AeroDJCore/Sources/AeroDJCore/Playback/PlaybackLog.swift`; `ios/AeroDJ/MusicKitService.swift:74,1071,1075`; `ios/AeroDJ/PlaybackActions.swift:226` |
| 17 | P0 diagnostics overlay (`p0_diag`) | On-screen trace rows (enums, booleans, counts, rounded seconds, codes) plus the same rows in the system log | **Stays on device** | No | No | In memory, plus OS log | `AERODJ_P0_DIAG`, internal TestFlight only; never in App Store builds | `ios/AeroDJ/DirectMode/P0EventTraceHost.swift:1-8,31,163` |

Not present in the iOS app at `d834dec`: weather, location, contacts, photos, microphone (planned and optional, per `docs/PRIVACY_MATRIX.md`), push notifications, Supabase, Telegram, Spotify, MiniMax, any LLM call, accounts or sign-in.

### 2.1 Library seeds stay on the device

- A station with **any** library seed speaks on the on-device, free routes only: `DJBreakSession.speaksOnDeviceOnly` (`ios/AeroDJCore/Sources/AeroDJCore/DJ/DJBreakSession.swift:243-245`), applied at `songStarted` (`:266`) through `DJBreakPreparer.prepare(_:deadline:onDeviceOnly:)` → `VoiceRenderer.onDeviceOnly` (`.../Voice/VoiceRendering.swift:557-561`). If no local route exists, the break is skipped and never sent.
- The over-cap re-render uses `lastRouteOnly`, which is nil unless the last route is local and free (`VoiceRendering.swift:548-551`).
- **Gap, see 3.1:** the seek re-arm path does not carry `onDeviceOnly`.

### 2.2 Third-party policy sources (fetched 2026-10-29)

- **Vercel, Runtime Logs** (<https://vercel.com/docs/logs/runtime>): runtime logs include `console.log` output from functions. Retention is Hobby 1 hour, Pro 1 day, Pro with Observability Plus 30 days, Enterprise 3 days, Enterprise with Observability Plus 30 days. The log details include request path, User-Agent, search params and region, and the "logs from your browser" filter matches on IP address and User-Agent. Vercel's general privacy policy and DPA were **not** fetched, so retention outside runtime logs (for example edge request logs or log drains) is an **owner question**.
- **ElevenLabs, Privacy Policy** (<https://elevenlabs.io/privacy-policy>, "Updated 9 October 2026"): API "Inputs & Outputs" (text sent and audio returned) are personal information under the policy. They may be used to "research, build, train and improve our AI models", with an account-level opt-out ("Data use" in "Terms and Privacy"). Retention is "as long as necessary to provide you with our Services". Data is transferred to and stored in the US. The policy covers ElevenLabs' own account holder, which here is the AeroDJ owner, not the listener.
- **ElevenLabs, Create speech API** (<https://elevenlabs.io/docs/api-reference/text-to-speech/convert>): `enable_logging` defaults to `true`. `false` gives "zero retention mode" and "may only be used by enterprise customers". The proxy doesn't set it.

## 3. Findings in the audited flows

### 3.1 Seek re-arm bypasses the library-seed on-device gate (privacy, latent until the host pin lands)

`DJBreakSession` re-arms a break after a seek with `await preparer.rearm(djBreak, deadline: deadline)` (`ios/AeroDJCore/Sources/AeroDJCore/DJ/DJBreakSession.swift:294`). `DJBreakPreparer.rearm` calls `prepare(djBreak, deadline: deadline)` (`.../DJ/DJBreakPreparation.swift:129`), so `onDeviceOnly` takes its default `false` (`:92`) and the **full** renderer is used.

On a library-seeded station in an owner A/B build with the ElevenLabs route active, a break that timed out, or never started, and is then re-armed by a scrub would send that break's text (library track titles and artists) to the proxy and ElevenLabs. That contradicts #154.

Fix direction (code PR, not this one): pass `onDeviceOnly` through `rearm`, or have the preparer derive it from the station, and add a test for a library-seeded re-arm. Sentinel's earlier sign-off on #156 missed this.

### 3.2 No per-cue guard keeps personal text off a route that leaves the device (defense in depth, latent)

`VoiceRoute.leavesDevice` is documented as "Such a route never speaks private text" (`.../Voice/VoiceRendering.swift:38-41`), but `VoiceRenderer.render(_ cue:)` tries every route in order (`:605-632`) without checking `cue.sourceItemID` against `route.leavesDevice`.

Briefing cues are built from calendar event titles, Obsidian notes and shared text (`.../MorningBriefingEngine.swift:250-262`).

Today this cannot fire in live mode, for two reasons:
- `LiveQueueBriefing` passes no sensitivity map, so every item defaults to `.blocked` and is not narratable (`.../DJ/LiveQueueBriefing.swift:25-28,146`).
- The ElevenLabs host isn't pinned yet.

As soon as sensitivity is wired, personal briefing lines would go to ElevenLabs in owner A/B builds unless the renderer filters off-device routes for cues with a `sourceItemID`. Recommended: enforce this in `render(_ cue:)`.

### 3.3 Stale comment

`ProxyVoiceProvider.swift:20-28` still says "No backend route is deployed" and describes a per-user session token. The deployed proxy uses one owner token and a single shared usage bucket (`handler.ts:23-24,224-228`).

## 4. Legacy web app (`app/`, `lib/`): Vercel project `ray-do`

Read-only Vercel lookup (2026-10-29): project `ray-do`, framework Next.js, domains `raydo.vercel.app` and two `*-rowerguy508s-projects.vercel.app` aliases, **password protection off, SSO protection off**. The latest deployment is a READY preview. Whether its production deployment currently has `SUPABASE_SERVICE_ROLE_KEY`, `MINIMAX_API_KEY` or `TELEGRAM_BOT_TOKEN` set is **unverified** (env values were deliberately not read).

| Route | Data | Destination | Auth | Code |
|---|---|---|---|---|
| `POST /api/voice` | Arbitrary `text` | MiniMax T2A (`api.minimaxi.chat`) with the server key | **None** (anyone can spend the MiniMax key) | `app/api/voice/route.ts:4-55` |
| `POST /api/commentary` | Station context | MiniMax LLM | **None** | `app/api/commentary/route.ts:4-15`; `lib/llm/commentary.ts:32` |
| `GET/POST/PATCH /api/messages` | Message queue rows for a caller-supplied `userId` or `messageId` | Supabase via the **service-role** client (bypasses RLS) | **None**: caller-chosen `userId`/`messageId` (IDOR) | `app/api/messages/route.ts:4-40,53-72,102-135`; `lib/database/supabase.ts:15-31` |
| `GET /api/stations` | Stations for a caller-supplied `userId` | Supabase, service role | **None** (IDOR) | `app/api/stations/route.ts:4-30` |
| `GET/POST/DELETE /api/voices` | Saved voices; DELETE by any `id` | Supabase, service role | **None** (IDOR, unauthenticated delete) | `app/api/voices/route.ts:4,51,134-165` |
| `POST /api/telegram/set-webhook` | Caller-supplied `webhookUrl` | Telegram `setWebhook` with the server bot token | **None**: anyone can repoint the bot's webhook to their own URL and receive its updates | `app/api/telegram/set-webhook/route.ts:7-40` |
| `POST /api/telegram`, `/api/webhooks/telegram` | Telegram updates into Supabase | Supabase | Secret header if `TELEGRAM_WEBHOOK_SECRET` is set | `app/api/telegram/route.ts:18-22`; `app/api/webhooks/telegram/route.ts:7-12,87` |

If the service-role key is configured on that deployment, any internet caller can read or modify other users' messages, stations and voices. `docs/LEGACY_AUDIT.md` marks most of these routes "Retire" or "Reuse", but they are still deployed.

## 5. Method

- Grep for outbound networking under `ios/` (`URLSession`, `URLRequest`, `MusicDataRequest`, `http(s)://`), plus logging (`Logger`, `privacy: .public`), Keychain, `UserDefaults` and SDK names. Then read each hit.
- Read `services/aerodj-tts/src/*.ts` and `api/tts.ts` in full. Read the legacy `app/api/**` routes.
- Run read-only Vercel project lookups for `aerodj-tts` and `ray-do`: domains and protection only, no env values.
- Fetch the public policy pages cited in 2.2.
- No device test was run. Runtime behavior is inferred from code.

## 6. Blockers for a public (App Store) release

Each of these must be fixed or explicitly waived by the owner before any non-owner can install a build that can send text off the device.

1. **Per-user auth instead of the owner bearer token.** The proxy accepts one shared owner token, and every caller shares one `owner` usage bucket (`services/aerodj-tts/src/handler.ts:23-24,224-228`). A public build cannot ship that token. Anyone who extracted it could spend the owner's ElevenLabs quota and exhaust the daily cap for everyone. Public use needs per-user identity (for example Sign in with Apple and a server-issued session, or App Attest plus DeviceCheck), per-user caps and revocation.
2. **Consent UI before any third-party TTS.** No screen today tells the listener that DJ text goes to Vercel and ElevenLabs. Show the disclosure in `disclosure-copy.md` before the first off-device render; default to on-device; make it revocable in Settings. Revoking it must also drop queued off-device renders.
3. **App Store privacy label.** Answer App Store Connect's App Privacy questionnaire using `app-store-privacy-label.md`, after the owner answers the open questions there.
4. **Privacy manifest (`PrivacyInfo.xcprivacy`).** None exists in `ios/`. The app uses required-reason APIs (`UserDefaults` in about 21 places, file timestamps for cache retention), so Apple requires a manifest with declared reasons. It should also declare `NSPrivacyTracking = false` and the collected data types. This needs a code and project PR.
5. **Close or retire the legacy `ray-do` deployment.** It is unprotected: unauthenticated MiniMax spend (`app/api/voice/route.ts`, `app/api/commentary/route.ts`), service-role Supabase IDOR (`app/api/messages`, `stations`, `voices`), and unauthenticated Telegram `set-webhook` (section 4). Retire it, protect it, or add auth before AeroDJ's privacy policy can claim "we don't store your data on our servers".
6. **Fix 3.1 (seek re-arm library-seed bypass)** and **3.2 (per-cue personal-text guard)** before the host pin and sensitivity wiring ship, even for owner A/B builds.
7. **ElevenLabs data use.** Confirm the ElevenLabs account has opted out of training ("Data use" setting), and decide whether non-enterprise history retention (`enable_logging` default `true`) is acceptable. If not, an enterprise zero-retention plan or a different provider is required.
8. **Privacy policy URL.** App Store Connect requires one. Publish the section in `disclosure-copy.md` together with the owner's contact details.
9. **Owner A/B code must stay out of App Store builds.** That is already enforced by `testflight.yml` and `check-release-disables-paid-voice.sh`. Keep that check required.
