# App Store privacy label: PROPOSAL

> **Status: proposal for the owner. Not submitted.** Sentinel drafted this from the code at `integration/device-duo` @ `d834dec` (see `data-flows.md`). The owner answers the questionnaire in App Store Connect and is accountable for it.

## Apple's rules this relies on

Fetched 2026-10-29 from <https://developer.apple.com/app-store/app-privacy-details/>:

- **"Collect"** means "transmitting data off the device in a way that allows you and/or your third-party partners to access it for a period longer than what is necessary to service the transmitted request in real time."
- "Data that is processed only on device is not 'collected' and does not need to be disclosed."
- "You are not responsible for disclosing data collected by Apple." This covers MusicKit, the Apple Music catalog and library, and EventKit.
- Data-type examples: **Product Interaction** includes "music listening data". **Other User Content** is "any other user-generated content".

## Proposal A: App Store build as the code stands (recommended for the first public release)

App Store builds compile the `#else` branch of `OwnerVoiceTrial` (`paidProvidersEnabled = false`, `ios/AeroDJCore/Sources/AeroDJCore/Voice/PremiumVoiceCatalog.swift:65-67`), enforced by `ios/scripts/check-release-disables-paid-voice.sh` in `ios.yml` and `testflight.yml`. The p0 diagnostics overlay is also compiled out (`AERODJ_P0_DIAG`).

In that build, the only off-device traffic is:
- Apple (MusicKit), which Apple discloses itself.
- An anonymous, fixed-URL download of the Phonon voice model from GitHub. It sends no user data; GitHub sees an IP address as part of any download.

**Proposed answer: "No, we do not collect data from this app"**, giving the label **"Data Not Collected"**.

| Question | Proposed answer | Justification |
|---|---|---|
| Do you or your third-party partners collect data from this app? | **No** | No first- or third-party server receives user data. Calendar, notes, shared items, library seeds, station settings, narration audio and logs stay on the device (`data-flows.md` rows 3, 11-17). |
| Tracking (ATT) | **No tracking** | No ad SDK, no IDFA, no data broker, no cross-app linking. |
| Phonon model download | Not "collection" | No user data sent; IP address only as an inherent part of any download. **Owner question 5** confirms this reading. |

Preconditions for Proposal A:
- The legacy `ray-do` web app is not shipped in or linked from the iOS app. It isn't today.
- `PrivacyInfo.xcprivacy` is added with `NSPrivacyTracking = false`, an empty collected-types list, and the required-reason API declarations (`data-flows.md` §6 item 4).

## Proposal B: if a third-party voice (ElevenLabs via `aerodj-tts`) ships to the public

Applies only once the release blockers in `data-flows.md` §6 are fixed: per-user auth, consent UI and the 3.1/3.2 fixes.

| Data type (Apple category) | Collected? | Linked to user? | Tracking? | Purpose | Justification and evidence |
|---|---|---|---|---|---|
| **Other User Content** (DJ script text that includes the station name the listener typed and, if sensitivity wiring ships, approved briefing lines from calendar, notes or shared items) | **Yes**, by ElevenLabs (third party) | **No** today. **Yes** once per-user auth exists *and* the proxy logs or forwards a user ID. Proposed design: don't forward or log it. | No | App Functionality | ElevenLabs keeps request history by default (`enable_logging` defaults to `true`; zero retention is enterprise-only) and may use Inputs for model training unless the account opts out (`data-flows.md` §2.2). That is longer than real time, so it counts as collected. |
| **Product Interaction** (track titles and artists in back-announce lines = "music listening data") | **Yes**, by ElevenLabs | No (same caveat) | No | App Functionality | Same text payload (`ios/AeroDJCore/Sources/AeroDJCore/DJ/DJNarration.swift:240,318`). Library-seed stations are excluded once 3.1 is fixed. |
| **User ID** | Only if per-user auth is added | **Yes** | No | App Functionality (auth, per-user caps) | Depends on the auth design, e.g. a Sign in with Apple subject held by the proxy. **Owner question 1.** |
| **Other Diagnostic Data** (proxy log: requestId, status, character count, upstream status/code) | Proposed **No** | No | No | — | Contains no user data or identifier (`services/aerodj-tts/src/handler.ts:150-172`). Keep it that way. |
| **IP address / User-Agent in Vercel platform logs** | **Owner question 4** | — | No | — | Vercel retains runtime logs for 1 hour to 30 days depending on plan (`data-flows.md` §2.2). Apple's label has no IP-address type. Many apps treat IP addresses that are only in short-lived hosting logs as not collected. That reading is not confirmed by Apple text Sentinel fetched. |
| Location, Contacts, Health, Financial, Browsing History, Search History, Purchases, Sensitive Info, Contact Info, Device ID, Advertising Data, Crash Data, Performance Data | **No** | — | — | — | Not read, or read on device only (calendar via EventKit, Apple Music search via Apple). |

If Proposal B ships, the label changes from "Data Not Collected" to **"Data Not Linked to You": Other User Content, Usage Data (Product Interaction)**, plus User ID under "Data Linked to You" if per-user auth stores one.

## Open questions for the owner

1. **Per-user identity:** which mechanism (Sign in with Apple, App Attest + DeviceCheck, other), and does the proxy store any per-user ID beyond the request? This decides whether "User ID" and "Linked to you" apply.
2. **ElevenLabs training opt-out:** is the "Data use" opt-out set on the ElevenLabs account? If not, the disclosure must say text may be used to train ElevenLabs models.
3. **ElevenLabs retention:** is non-enterprise history retention acceptable for listener text, or should public TTS wait for zero retention or a different provider?
4. **Vercel plan and log retention for `aerodj-tts`:** Hobby (1 h), Pro (1 day), or Observability Plus (30 days)? Any log drains? Do you want IP addresses treated as collected?
5. **Phonon download:** OK to treat the anonymous GitHub model download as not collection? Or should the model be hosted elsewhere or bundled?
6. **Legacy `ray-do`:** retire it before the App Store release (recommended), or keep it and write a separate policy? It is unprotected today (`data-flows.md` §4).
7. **Age rating and children:** ElevenLabs' minimum age is **unverified**; Sentinel did not confirm it from the fetched policy. Check it. If ElevenLabs excludes minors and the app's age rating allows them, third-party TTS should stay off for them or be gated.
