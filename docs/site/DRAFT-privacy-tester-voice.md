# DRAFT for owner review — do not publish

**Draft for owner review — do not publish.** This page is not under `site/`, so it is never served. `site/render-copy.py` reads only `docs/site/privacy.md` and `docs/site/support.md`. The live page, `docs/site/privacy.md` (onairly.app/privacy), is **unchanged** by this PR.

- Source of the change: #378 (owner decisions 2026-11-02: internal TestFlight testers only, 1,500 chars per device per day) and the server PR #380.
- Owner action: read it and pick the open choices marked **[owner]**. Nothing here goes live until the owner says so **and** the feature ships, meaning the consent sheet exists and the flags are on.

---

## 1. Plain-language summary of the change

Today the policy says: *"Apart from Apple Music itself, nothing leaves your device"* and *"OnAirly doesn't collect any data."* Both stay true for everyone who doesn't turn on cloud voice. Cloud voice is offered only to internal TestFlight testers and the owner.

| | Before | After (only for opted-in TestFlight testers, and the owner) |
| --- | --- | --- |
| What leaves the device | Nothing (Apple Music aside) | The **words of each DJ break**. These can include the Apple Music catalog title and artist of the song that just played or is coming next, plus the neighbouring lines of the same break as context so the voice flows. It goes to our voice server, which forwards it to ElevenLabs to turn into audio. To set up cloud voice, the app also asks Apple to confirm it's a genuine copy of OnAirly (App Attest). |
| What never leaves | Everything | Still: your music and audio, the songs from your own library (non-catalog tracks), ratings, playlists, your library as a whole, calendar, notes, shared items, the station names you type, Apple ID and account info, contacts, location. |
| Our server keeps | Nothing | No script text. It keeps a pseudonymous device key record (up to 90 days after the last token it issued), daily usage counters (2 days) and, only if the owner blocks an install, a revocation entry (90 days). These records are held in Upstash, a Redis database service, connected through Vercel. |
| ElevenLabs keeps | Nothing | By default, ElevenLabs keeps the text (including any song titles and artists in it) and the generated audio in its request history, with no fixed deletion period (details in section 3). |
| Device identifier | None | A random App Attest key ID made for this app install. We don't link it to your name or Apple ID (section 4). |

## 2. Proposed text for `docs/site/privacy.md`

This is the replacement or new copy. Insert it when the feature ships.

### Replace in "The short version"

> Apart from Apple Music itself, nothing leaves your device, unless you're a TestFlight tester who turns on cloud voice (below).

### New section, after "What stays on your device"

> ## Cloud voice (TestFlight beta testers only, off until you turn it on)
>
> Some TestFlight testers can try a cloud voice for the DJ. It's off unless you turn it on, and OnAirly asks you before any text leaves your device.
>
> **What is sent:** the words of each DJ break (the short script the DJ is about to say). Like a radio DJ, the script can name the song that just played or the one coming next, so the Apple Music catalog title and artist of those songs can be in it. Each line is also sent with up to 300 characters of the lines just before and after it in the same break, so the voice sounds like one flowing thought. Those neighbouring lines follow the same rules as everything else here. The script can also mention the time of day. It goes over an encrypted connection to our voice server, which passes it to ElevenLabs to turn into audio, and the audio comes back to your device.
>
> **What is never sent:** your music or any audio; songs from your own library that aren't in the Apple Music catalog (the DJ uses the on-device voice for those); your ratings, playlists or your library as a whole; your calendar, Markdown notes or shared items; the station names you type; your name, Apple ID or any account information; contacts or location.
>
> **What our server keeps:** no script text, song titles or artists. Each request leaves a request ID, the result, a character count and, if something went wrong, an error code. To prove requests come from a genuine copy of OnAirly, our server also stores a device key for your app install (see "Device identifier"). It keeps a count of how many characters your install used today, so each device stays within its daily limit. These counters are deleted after 2 days. If we ever have to block a misbehaving install, we keep a note of its key ID for 90 days. Our server is hosted by Vercel, and these records are stored in Upstash, a database service we use through Vercel.
>
> **What ElevenLabs keeps:** ElevenLabs processes the text and returns audio under [its privacy policy](https://elevenlabs.io/privacy-policy). By default ElevenLabs keeps the text, including any song titles and artists in it, and the generated audio in its request history. ElevenLabs doesn't state a fixed period for this. [owner: pick one, see section 3: (a) "…and may keep them as long as needed to provide its service." (b) "We delete them from ElevenLabs within N days." (c) "We use ElevenLabs' Zero Retention Mode, so ElevenLabs doesn't store them." Note: (c) needs an ElevenLabs Enterprise plan and turns off the neighbouring-line context; we don't use it today.]
>
> **Device identifier:** when you turn cloud voice on, your iPhone's Secure Enclave creates a key just for this copy of OnAirly, and the app asks Apple's App Attest service to confirm the key belongs to a genuine copy of OnAirly. Our server stores that key's ID and public half, plus a counter. They aren't your device's serial number or advertising ID, and we don't link them to your name, Apple ID or email. They work like a pseudonym for this install: they let us apply the daily limit to it. The key is deleted from our server 90 days after the last time your app used it to sign in to the voice server. Deleting OnAirly removes it from your device, and a reinstall gets a new one.
>
> **Hosting logs:** Vercel keeps standard request logs, which include IP address and app identifier, for up to [owner: N] days. To limit how many times a device can register each day, our server doesn't store your network address in plain form. It keeps a day-specific code made from it with a secret key, which we don't use to look up your address and don't link to your name or Apple ID. It's deleted after 2 days.

### Replace "Data we collect"

> OnAirly doesn't collect any data unless you turn on cloud voice as a TestFlight tester. Then we process the DJ script text (which can name catalog songs and artists), the device identifier and the usage counters described above, only to make the DJ's voice and keep it within daily limits. We don't use them for tracking, ads or analytics, and we don't sell them. We share them only with the services that run the feature: ElevenLabs (the script text, to make the audio), Vercel (hosting) and Upstash (storing the device key and counters). Apple confirms the app is genuine through App Attest.

### "Your choices": add

> You can turn cloud voice off at any time in the app; the DJ then uses the on-device voice and nothing more is sent.

## 3. Retention: what's confirmed vs unknown

Checked on 2026-11-02 against ElevenLabs' public pages:

- [Zero Retention Mode](https://elevenlabs.io/docs/eleven-api/resources/zero-retention-mode)
- [Create speech API](https://elevenlabs.io/docs/api-reference/text-to-speech/convert)
- [Privacy Policy §6](https://elevenlabs.io/privacy-policy)
- [DPA §9](https://elevenlabs.io/dpa)

| Item | Status | Source |
| --- | --- | --- |
| Text-to-Speech **text input and audio output are retained by default** (request history) | **Confirmed** | ZRM page, "Default Retention: Enabled" table |
| Zero Retention Mode (`enable_logging=false`) deletes TTS inputs and outputs right after the request | **Confirmed**, but **Enterprise customers only**, at ElevenLabs' discretion | ZRM page; API reference: "Zero retention mode may only be used by enterprise customers" |
| Our server sends `enable_logging=false` | **No.** The proxy doesn't send it, and it uses request stitching (`previousRequestIds`), which ZRM turns off | `services/aerodj-tts/src/handler.ts` |
| Our ElevenLabs plan is Enterprise / ZRM-eligible | **Unknown** [owner] | — |
| Deleting a generation via the API removes text and audio from ElevenLabs' database right away; backups are kept up to 30 days; debugging and moderation logs may still hold related data | **Confirmed** (docs wording) | ZRM page FAQ |
| How long ElevenLabs keeps history if nobody deletes it | **Unknown: no fixed period.** "As long as necessary to provide the Services or as required or permitted by law." For self-serve plans the DPA says ElevenLabs *may* delete after 180 days of inactivity | Privacy Policy §6; DPA §9.2.2 |
| Whether ElevenLabs uses API text inputs to train models | **Unknown / not confirmed** by the pages read (the ZRM page only covers third-party LLM providers) | [owner: check the ElevenLabs account's terms and data settings] |
| What the script can contain | **Confirmed (code).** `VoiceRenderer.mayLeaveDevice` lets only two kinds of line leave the device: `.presenter` lines (fixed phrasing: greetings by time of day, time check, the built-in station brand) and `.trackMetadata` lines whose every track is `.catalog` (title + artist of the previous/next song). `.personalContext` (Calendar, Share, Obsidian/notes), `.stationName` (a listener-named station), library or unknown-origin tracks, and any cue without attribution stay on-device | `ios/AeroDJCore/Sources/AeroDJCore/Voice/VoiceRendering.swift` `mayLeaveDevice`; `DJ/DJNarration.swift` (template fills are only title/artist/time/brand) |
| Neighbouring-line context | **Server: confirmed (merged).** The proxy accepts `previousText`/`nextText`, strips brackets, caps each at 300 chars and forwards them to ElevenLabs with up to 3 `previous_request_ids`. **Client: in #366 (open).** Context is sent only if every neighbouring line also passes `mayLeaveDevice`, and only on routes that leave the device | `services/aerodj-tts/src/handler.ts` `MAX_CONTEXT_CHARS`, `upstreamBody`; #366 `ProxyVoiceProvider.swift`, `VoiceRenderer.neighbours` |
| Other request fields | **Confirmed (code).** `upstream`, `voiceId`, `format` and `stationId` (a fixed `"default"` in the app; the proxy ignores it and doesn't log it) | `ProxyVoiceProvider.swift`; `AppDependencies.swift` |
| Our server keeps no script text in logs | **Confirmed in code and tests.** The log line is `{requestId, status, chars}` plus an enum `reason` and, on upstream errors, `upstreamStatus`/`upstreamCode`. No text, context, title, voice, keyId or token | `README.md` "Logging and privacy"; `src/handler.ts`; `test/context-logs.test.ts` (#371); `test/install-token.test.ts` |
| Where our records live | **Confirmed (code).** Upstash Redis over its REST API (`KV_REST_API_URL` / `UPSTASH_REDIS_REST_URL`, i.e. the Vercel storage integration). There's no in-memory fallback | `src/limiter.ts` `redisRestConfig`; `src/attest-store.ts` |
| Redis key records | **Confirmed (code).** 90 days, set at registration and refreshed on each successful token mint, for the key record (public key, counter, env, created day, tier) and its `ctr:` counter key. A revocation entry (owner tool only) is set for a fixed 90 days from revocation | `src/attest-store.ts` (`KEY_RECORD_TTL_SECONDS`, `MINT_TOKEN_SCRIPT`, `REVOKE_KEY_SCRIPT`) |
| Redis daily counters | **Confirmed (code).** 2 days for: per-install chars (keyed by a SHA-256 of the key ID), tester pool, owner, global, refund markers, token mints per key, and the enroll counters (global, per keyed network hash, per keyed install-ID hash). Per-minute rate counters last 2 minutes; single-use challenge marks last 5 minutes | `src/limiter.ts` (`DAY_TTL_SECONDS`, `MINUTE_TTL_MS`, `REFUND_MARKER_TTL_SECONDS`), `src/attest-store.ts` (`ENROLL_TTL_SECONDS`, `TOKEN_MINT_TTL_SECONDS`, `USED_TTL_FOR_MINT`) |
| Network-address code | **Confirmed (code).** An HMAC of the client address and the UTC day, keyed with a server secret; stored only as part of a 2-day counter key. Outsiders can't reverse it; whoever holds the secret could in principle test candidate addresses, so the copy says "not stored in plain form" rather than "can't be reversed" | `src/enroll-device.ts` |
| Apple App Attest | **Confirmed (design + code).** The iOS client (Atlas, not yet pushed) generates the key with Apple's App Attest API and Apple's servers attest it; our server verifies Apple's certificate chain. Apple's own handling of that request is under Apple's terms | `src/app-attest-verify.ts`; #378 design |
| Vercel request-log retention | **Unknown for our plan** [owner]. The held copy says "up to 30 days" | `docs/site/HOLD-pro.md` |

## 4. The device identifier, in detail

- **What it is:**
  - App Attest makes a P-256 key pair inside the Secure Enclave for this app install.
  - The **key ID** is a SHA-256 of the public key.
  - The app also sends a random **install ID** (a UUID it generates) at registration. The server stores only a keyed, day-specific hash of it, for 2 days, to cap registrations.
- **Pseudonymous, not anonymous:** it is a stable per-install identifier for up to 90 days, so the server can tell one install's requests apart from another's. We don't link it to a person:
  - It is not the UDID, serial number or advertising identifier.
  - The server never receives a name, Apple ID, email or account.
  - Apple's attestation proves the app is genuine; it doesn't identify the user.
  - The same person on two devices, or after a reinstall, gets unrelated IDs.
- **What it's used for:** proving requests come from a genuine OnAirly install, the 1,500-character daily limit per device, and blocking (revoking) a misbehaving install.
- **How long it's kept:**
  - The key record lasts up to 90 days after the last token was issued.
  - Daily counters (keyed by a SHA-256 of the key ID) last 2 days.
  - A revocation entry lasts 90 days from when the owner revokes the install.
  - All of these are stored in Upstash Redis.
  - Nothing is kept with script text.

## 5. Open questions for the owner

1. **Song titles and artists: resolved as disclosed.** Fry's review (#381 B1) confirmed from code that catalog titles and artists, and the #366 neighbouring-line context, do reach ElevenLabs. The copy now says so plainly and no longer says listening history is never sent. Nothing for the owner to pick, but please read the "What is sent" paragraph.
2. **ElevenLabs retention and training** (section 2, [owner] a/b/c): we're not on ZRM today, as far as the code shows, and ZRM is Enterprise-only and would turn off the neighbouring-line context. Separately, please check in the ElevenLabs account whether API inputs can be used for training (section 3).
3. **Vercel log retention** for the plan in use.
4. **Consent sheet.** The text promises "OnAirly asks you before any text leaves your device". Per #378 §4 that sheet doesn't exist yet, and it must ship first.
5. **App Store privacy label.** The live App Store build sends nothing, so the label doesn't change for it. For TestFlight, decide whether to update the label now or at public release (#378 §4.2).
6. **Planned weather line.** Not built. If it ever ships on cloud voice, the "location is never sent" line needs another look first.

-Sentinel
