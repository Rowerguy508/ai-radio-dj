# DRAFT for owner review — do not publish

**Draft for owner review — do not publish.** This page is not under `site/`, so it is never served. `site/render-copy.py` reads only `docs/site/privacy.md` and `docs/site/support.md`. The live page, `docs/site/privacy.md` (onairly.app/privacy), is **unchanged** by this PR.

- Source of the change: #378 (owner decisions 2026-11-02: internal TestFlight testers only, 1,500 chars per device per day) and the server PR #380.
- Owner action: read it and pick the open choices marked **[owner]**. Nothing here goes live until the owner says so **and** the feature ships, meaning the consent sheet exists and the flags are on.

---

## 1. Plain-language summary of the change

Today the policy says: *"Apart from Apple Music itself, nothing leaves your device"* and *"OnAirly doesn't collect any data."* Both stay true for everyone who doesn't turn on cloud voice. Cloud voice is offered only to internal TestFlight testers and the owner.

| | Before | After (only for opted-in TestFlight testers, and the owner) |
| --- | --- | --- |
| What leaves the device | Nothing (Apple Music aside) | The **text of each DJ break**, nothing else. It goes to our voice server, which forwards it to ElevenLabs to turn into audio. |
| What never leaves | Everything | Still: your music and audio, listening history, ratings, library, calendar, notes, shared items, station names, Apple ID and account info, contacts, location. |
| Our server keeps | Nothing | No script text. It keeps an anonymous device key record (up to 90 days after last use) and daily usage counters (2 days). |
| ElevenLabs keeps | Nothing | By default, ElevenLabs keeps the text and the generated audio in its request history (details in section 3). |
| Device identifier | None | A random App Attest key ID made for this app install. It is not linked to you (section 4). |

## 2. Proposed text for `docs/site/privacy.md`

This is the replacement or new copy. Insert it when the feature ships.

### Replace in "The short version"

> Apart from Apple Music itself, nothing leaves your device, unless you're a TestFlight tester who turns on cloud voice (below).

### New section, after "What stays on your device"

> ## Cloud voice (TestFlight beta testers only, off until you turn it on)
>
> Some TestFlight testers can try a cloud voice for the DJ. It's off unless you turn it on, and OnAirly asks you before any text leaves your device.
>
> **What is sent:** only the written words of each DJ break (the short script the DJ is about to say). It goes over an encrypted connection to our voice server, which passes it to ElevenLabs to turn into audio, and the audio comes back to your device.
>
> **What is never sent:** your music or any audio, your listening history, your ratings, your music library, your calendar, Markdown notes, shared items, the station names you type, your name, Apple ID or any account information, contacts or location.
>
> **What our server keeps:** no script text. Each request leaves a request ID, the result and a character count. To prove requests come from a genuine copy of OnAirly, our server also stores a device key for your app install (see "Device identifier"). It keeps a count of how many characters your install used today, so each device stays within its daily limit. These counters are deleted after 2 days.
>
> **What ElevenLabs keeps:** ElevenLabs processes the text and returns audio under [its privacy policy](https://elevenlabs.io/privacy-policy). By default ElevenLabs keeps the text and the generated audio in its request history. [owner: pick one, see section 3: (a) "…and may keep them as long as needed to provide its service." (b) "We delete them from ElevenLabs within N days." (c) "We use ElevenLabs' Zero Retention Mode, so ElevenLabs doesn't store them."]
>
> **Device identifier:** when cloud voice is on, your iPhone's Secure Enclave creates a key just for this copy of OnAirly (Apple's App Attest). Our server stores that key's ID and public half. They aren't your device's serial number or advertising ID, and they aren't linked to your name, Apple ID, email or anything else about you. The key is deleted from our server after 90 days without use. Deleting OnAirly removes it from your device, and a reinstall gets a new one.
>
> **Hosting logs:** Vercel keeps standard request logs, which include IP address and app identifier, for up to [owner: N] days. To limit how many times a device can register each day, our server keeps only a scrambled, day-specific code made from your network address. That code can't be turned back into your address, and it's deleted after 2 days.

### Replace "Data we collect"

> OnAirly doesn't collect any data unless you turn on cloud voice as a TestFlight tester. Then we process the DJ script text, the device identifier and the usage counters described above, only to make the DJ's voice and keep it within daily limits. We don't use them for tracking, ads or analytics, and we don't sell or share them, apart from sending the script text to ElevenLabs to make the audio.

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
| Our server keeps no script text in logs | **Confirmed in code and tests.** The log line is `{requestId, status, chars}` plus enum reasons | `README.md` "Logging and privacy"; `test/install-token.test.ts` |
| Redis key records | **Confirmed (code).** About 90 days after last use (sliding) for the key record (public key, counter, env, created day, tier) and its counter. Revocation entries are also 90 days | `src/attest-store.ts` |
| Redis daily counters | **Confirmed (code).** 2 days for: per-install chars (keyed by a SHA-256 of the key ID), tester pool, global, token mints per key and enroll counters. Per-minute rate counters are short-lived | `src/limiter.ts`, `src/attest-store.ts` |
| Vercel request-log retention | **Unknown for our plan** [owner]. The held copy says "up to 30 days" | `docs/site/HOLD-pro.md` |

## 4. The device identifier, in detail

- **What it is:**
  - App Attest makes a P-256 key pair inside the Secure Enclave for this app install.
  - The **key ID** is a SHA-256 of the public key.
  - The app also sends a random **install ID** (a UUID it generates) at registration. The server stores only a keyed, day-specific hash of it, for 2 days, to cap registrations.
- **Not linked to the person:**
  - It is not the UDID, serial number or advertising identifier.
  - The server never receives a name, Apple ID, email or account.
  - Apple's attestation proves the app is genuine; it doesn't identify the user.
  - The same person on two devices, or after a reinstall, gets unrelated IDs.
- **What it's used for:** proving requests come from a genuine OnAirly install, the 1,500-character daily limit per device, and blocking (revoking) a misbehaving install.
- **How long it's kept:**
  - The key record lasts up to 90 days after the last token was issued.
  - Daily counters last 2 days.
  - A revocation entry lasts 90 days.
  - Nothing is kept with script text.

## 5. Open questions for the owner

1. **Song titles and artists.** A DJ break can name the song that's playing or just played, using Apple Music catalog titles and artist names, like a radio DJ does. That is script text, so it *is* sent. The draft says "listening history is never sent"; that holds for the history itself, but individual titles can appear in a break. Should the policy say so explicitly? (The held #378 §4.1 copy did: "the Apple Music catalog song titles and artist names of what's playing".) The iOS client (Atlas) should confirm exactly what goes into the script.
2. **ElevenLabs retention choice** (section 2, [owner] a/b/c): we're not on ZRM today, as far as the code shows.
3. **Vercel log retention** for the plan in use.
4. **Consent sheet.** The text promises "OnAirly asks you before any text leaves your device". Per #378 §4 that sheet doesn't exist yet, and it must ship first.
5. **App Store privacy label.** The live App Store build sends nothing, so the label doesn't change for it. For TestFlight, decide whether to update the label now or at public release (#378 §4.2).

-Sentinel
