# OnAirly v1: privacy manifest, App Store privacy label, ElevenLabs decisions

> **Status: proposal for the owner. Nothing is submitted and no service setting was changed.**
> Sentinel wrote this from `integration/device-duo` @ `ce6a529` on 2026-10-29, for the v1 plan in
> which the paid ElevenLabs voice (through the `aerodj-tts` proxy) ships to the public.
> It supersedes Proposal A ("Data Not Collected") in #174's `app-store-privacy-label.md` for
> that plan. The owner answers App Store Connect and is accountable for the answers.
> File and line references are at `ce6a529` unless noted.

## 1. What leaves the device when the paid voice is on

| Flow | What is sent | Evidence |
|---|---|---|
| App → `aerodj-tts` (Vercel) | JSON `{upstream, voiceId, text, format, stationId}` plus a bearer token. `stationId` is the constant `"default"`; the renderer's `userID` is `"listener"`. | `ios/AeroDJCore/Sources/AeroDJCore/Voice/ProxyVoiceProvider.swift:61-69`, `ios/AeroDJ/AppDependencies.swift:75` |
| `aerodj-tts` → ElevenLabs | `POST /v1/text-to-speech/{voiceId}?output_format=pcm_22050` with `{text, model_id, voice_settings}` and the owner's API key. **No `enable_logging=false`**, no user or device identifier. | `services/aerodj-tts/src/handler.ts:290-298` |
| Proxy log line | `requestId, status, chars, upstreamStatus, upstreamCode`. No text, no identifier. | `services/aerodj-tts/src/handler.ts:165-173` |

Which text may go off-device is decided per cue, fail-closed, inside the renderer (#176, fixed by #175/#177/#211):

- `VoiceRenderer.mayLeaveDevice` allows only `.presenter` lines and `.trackMetadata` whose every track is `.catalog`, and only for a plain DJ transition with no source item, source kind or provenance. Missing attribution, `.personalContext` (Calendar, Share, Obsidian), library or unknown-origin tracks are local-only (`ios/AeroDJCore/Sources/AeroDJCore/Voice/VoiceRendering.swift:640-648`, guard at `:666-673`).
- A station with any library seed renders on-device only, at song start and at seek re-arm (`ios/AeroDJCore/Sources/AeroDJCore/DJ/DJBreakSession.swift:310,340`; `DJBreakPreparation.swift:137,170`).
- Station IDs say the built-in name only (`DJNarration.swift:207,387-394`). On #227 a typed station name is its own `.stationName` attribution and is local-only (`VoiceRendering.swift:643` at `4301614`).

So the off-device text is: fixed presenter phrasing, the app's name, and **Apple Music catalog song titles and artist names of what the listener is hearing**. It never contains calendar, notes, shared items, library tracks or typed station names.

## 2. Is it "collected"? (Apple's definitions)

From <https://developer.apple.com/app-store/app-privacy-details/> (fetched 2026-10-29):

- "'Collect' refers to transmitting data off the device in a way that allows you and/or your third-party partners to access it for a period longer than what is necessary to service the transmitted request in real time."
- "If you derive anything from that data and send it off device, the resulting data should be considered separately."
- Product Interaction includes "music listening data". Other User Content is "any other user-generated content".
- Optional disclosure needs, among others, that collection is "only in infrequent cases that are not part of your app's primary functionality". DJ voice is the primary function, so this exemption does **not** apply.

ElevenLabs keeps TTS request history by default: `enable_logging` "default: true", and zero retention "may only be used by enterprise customers" (<https://elevenlabs.io/docs/api-reference/text-to-speech/convert>). Deleted items stay in backups up to 30 days (<https://elevenlabs.io/docs/eleven-api/resources/zero-retention-mode>). The proxy does not send `enable_logging=false` (`handler.ts:290`). The text is therefore retained longer than real time: **collected, by a third party**.

**Verdict: "Data Not Collected" is no longer accurate for a build with the public paid voice.**

If the owner gets Zero Retention Mode and the proxy sends `enable_logging=false`, ElevenLabs says no request content is stored ("Usage Analytics still records that a request was made, but no content from the request is stored"). Then the text would not be "collected" under Apple's definition and Product Interaction could be dropped. Keep it declared until ZRM is confirmed working on the account.

## 3. Recommended App Store Connect answers (v1 with the public paid voice)

| Data type | Collected? | Linked to the user? | Tracking? | Purpose | Reasoning and evidence |
|---|---|---|---|---|---|
| **Usage Data → Product Interaction** (catalog song titles and artists in DJ lines) | **Yes** (ElevenLabs history) | **No** | No | App Functionality | Music listening data sent for TTS and retained by default (§1, §2). No identifier reaches ElevenLabs (`handler.ts:293-297`); requests come from the proxy with the owner's key. Stays "not linked" only while the proxy never forwards or logs a per-user/per-install ID **together with text**. |
| **Identifiers → Device ID** | **Depends on Atlas's proxy-auth design** (App Attest / DeviceCheck, per-install quotas) | Yes, if stored | No | App Functionality (fraud prevention, quotas) | A per-install key or ID kept server-side for quotas or revocation is "other device-level ID" kept longer than one request. Declare it when that PR lands. If only an opaque, unlinkable token is checked and nothing per-install is stored, answer No. **Owner decision 7.** |
| **User Content → Other User Content** | **No** | — | — | — | No user-generated text leaves the device: typed station names, notes, calendar and shared items are local-only (§1). Re-check if any typed text becomes cloud-eligible. |
| **Diagnostics → Other Diagnostic Data** | **No** | — | — | — | The proxy log has no text and no identifier (`handler.ts:165-173`). Keep it that way. |
| IP address in Vercel platform logs | **Owner decision 8** | — | No | — | Apple: "Declare the relevant data types based on how you use IP address". If used only transiently by the platform and not for rate limiting or analytics, it is commonly treated as not collected. Unverified with Apple. |
| Contact Info, Health, Financial, Location, Sensitive Info, Contacts, Emails/Messages, Photos, Audio Data, Browsing/Search History, User ID, Purchases, Advertising Data, Crash Data, Performance Data | **No** | — | — | — | Not read, or used on-device only (EventKit, MusicKit, Share inbox, Obsidian). Apple: "You are not responsible for disclosing data collected by Apple" (MusicKit). |

**Tracking:** No. No ad SDK, no IDFA or ATT, no data broker (grep for `ASIdentifierManager`, `ATTrackingManager`, `AdSupport`, analytics SDKs: none).

**Resulting label:** "Data Not Linked to You: Usage Data (Product Interaction)". Add "Data Linked to You: Identifiers (Device ID)" if the per-install auth stores an ID.

The privacy policy and consent sheet (Nova) should say: song and artist names of what you are playing are sent to our server and to ElevenLabs to make the DJ voice; ElevenLabs may keep them (and, unless the account opts out, use them to improve its models).

## 4. Privacy manifests (this PR)

`ios/AeroDJ/PrivacyInfo.xcprivacy`:

- `NSPrivacyTracking = false`, no tracking domains.
- `NSPrivacyCollectedDataTypes`: Product Interaction, not linked, not tracking, App Functionality (§3).
- Required-reason APIs found in the app and `AeroDJCore`:

| Category | Reason | Why | Evidence |
|---|---|---|---|
| `UserDefaults` | `CA92.1` (app-only) | Settings read and written by the app only. Every use is `UserDefaults.standard`; no App Group suite. | e.g. `ios/AeroDJ/MusicKitService.swift:176`, `PlayingScreen.swift:218-219`, `TalkoverToggle+App.swift:21`, `AeroDJCore/.../Voice/PremiumVoiceCatalog.swift:74-76` |
| `SystemBootTime` | `35F9.1` (elapsed time between events in the app) | `ProcessInfo.systemUptime` for seek, self-start and talk-over timing. Never sent off-device. | `ios/AeroDJ/MusicKitService.swift:128,614,739`, `TalkoverCoordinator.swift:152,204`, `InterludePlaybackAdapter.swift:470` |
| `FileTimestamp` | `C617.1` (files in the app or App Group container) | `FileManager.attributesOfItem` reads file size of the Phonon model and shared-inbox items. Declared conservatively, since the returned dictionary includes dates. | `ios/AeroDJ/PhononModelStore.swift:104`, `AeroDJCore/.../SharedInboxReader.swift:80` |
| `DiskSpace`, `ActiveKeyboards` | — | Not used (no `volumeAvailableCapacity`, `statfs`, `activeInputModes`). | grep |

`URL.resourceValues` is used only for `isRegularFile`, `isSymbolicLink`, `fileSize` and iCloud download status, not for dates (`SecurityScopedNoteReader.swift:27`, `SharedInboxReader.swift:46`, `SpeechTempFiles.swift:45`, `VoiceRendering.swift:359`).

`ios/AeroDJShare/PrivacyInfo.xcprivacy`: no tracking, nothing collected, no required-reason API. The extension only writes the shared item to the App Group inbox (`AeroDJShareViewController.swift:72-81`).

Third-party SDKs: none in the app bundle. `xn-ptts` is resolved but not linked or embedded (`ios/project.yml:36-40`).

Bundling: XcodeGen 2.46.0 adds `.xcprivacy` files under a target's source path to its Resources phase by default. `ios.yml` now fails if either manifest is missing from the Debug or Release device build, does not parse, or declares tracking, and warns if the Release `AeroDJShare` binary starts referencing a required-reason API.

## 5. #174 §6 blockers for a public paid voice (status at `ce6a529`)

| # | Blocker | Status | Owner |
|---|---|---|---|
| 1 | Per-user proxy auth and quotas | Open | Atlas |
| 2 | Consent sheet before any third-party voice | Open | Nova |
| 3 | App Store privacy label | **Proposed here** (§3); owner answers ASC | Owner |
| 4 | `PrivacyInfo.xcprivacy` | **This PR** | Sentinel |
| 5 | Retire or lock down legacy `ray-do` (#178) | Open | Sentinel (next) |
| 6 | #176 findings 3.1 / 3.2 | **Fixed** (#175, #177, #211), mutation-checked 2026-10-29 | — |
| 7 | ElevenLabs data use and retention | **Owner decisions** (§6) | Owner |
| 8 | Privacy policy URL | Open (copy in #174 `disclosure-copy.md`, needs this update) | Owner |
| 9 | Owner A/B code out of App Store builds | Still enforced. Shipping the paid voice publicly means a deliberate PR that replaces this gate with the public consent and auth gates. Not done here. | Atlas / Nova |

## 6. What the owner must decide about ElevenLabs

Sentinel changed no ElevenLabs or Vercel setting. Facts fetched 2026-10-29.

1. **History retention.** By default ElevenLabs keeps each request's text and audio in history (`enable_logging` defaults to `true`). Any customer can delete items through the API, which removes them "immediately", but "debugging and moderation logs may still retain data" and backups keep deleted items up to 30 days. Account deletion removes everything. Decide: accept default retention, have the proxy delete each history item after rendering, or get zero retention. Sources: <https://elevenlabs.io/docs/eleven-api/resources/zero-retention-mode>, <https://elevenlabs.io/docs/api-reference/history/delete>.
2. **Zero Retention Mode.** Enterprise only, "available to select enterprise customers", and can be restricted at ElevenLabs' discretion. Turned on per request with `enable_logging=false`; it disables history features including request stitching. Decide whether to pursue an Enterprise plan. If yes, the proxy change is one query parameter, with a test (Atlas's area). Source: same ZRM page; <https://elevenlabs.io/docs/api-reference/text-to-speech/convert>.
3. **Training opt-out.** ElevenLabs uses non-Enterprise data to improve its models unless you opt out: profile → Terms and privacy → Data use → turn off "Improve the models for everyone". The opt-out applies only to data sent after it is processed. Enterprise data is not trained on by default. Decide and confirm it is off **before** the first public render. Sources: <https://elevenlabs.io/docs/help-center/legal/is-my-data-used-to-improve-eleven-labs-ai-models>, <https://elevenlabs.io/terms-of-use>.
4. **DPA.** The Terms say the Data Processing Addendum governs personal data in content you send when you agree "on behalf of an entity". The subprocessor list is at <https://compliance.elevenlabs.io>, with 30 days' notice of changes. For self-serve plans ElevenLabs "reserves the right, but has no obligation" to delete content after the agreement ends. Decide whether the account is held by a business entity and whether the DPA terms are acceptable. Sources: <https://elevenlabs.io/dpa>, <https://elevenlabs.io/terms-of-use>.
5. **Data region.** Data is stored in the US by default. EU, India and Singapore residency are Enterprise-only isolated workspaces with their own API host and key. Processing may still happen elsewhere unless EU residency is combined with ZRM. Decide whether US storage is acceptable for EU and UK listeners, and disclose it. Source: <https://elevenlabs.io/docs/overview/administration/data-residency>.
6. **Voice and commercial terms.** Free accounts are non-commercial only, so a public app needs a paid plan, and outputs must follow the Prohibited Use Policy. A Voice Library voice can be withdrawn by its owner with a notice period of 30 days to 2 years, or immediately if none was set. Check `disable_at_unix` on the chosen voice, or pick a voice ElevenLabs made. Decide the plan and confirm the licence of the voice picked from Echo's sheet. Sources: <https://elevenlabs.io/terms-of-use>, <https://elevenlabs.io/docs/help-center/product/voices/voice-library/what-is-a-notice-period>, <https://elevenlabs.io/vla>.
7. **Per-install identity (for the label).** With Atlas's App Attest or DeviceCheck design: will the proxy store any per-install ID, and for how long? This decides "Device ID, linked" in §3.
8. **Vercel logs and IP.** Which plan and log retention for `aerodj-tts`, any log drains, and is IP used for rate limiting? This decides the IP row in §3.
9. **Minimum age.** ElevenLabs' minimum user age is still **unverified** (carried over from #174). Check the Terms before choosing the app's age rating.

-Sentinel
