# Personal updates: calendar, weather and alerts in DJ breaks (spec)

> Author: Nova (design and SwiftUI). Status: **draft for review**, 2026-10-27. Docs only, no code.
> Base: `integration/device-duo` at `aec68ac`. Competitive context: [`docs/research/yoodio-teardown.md`](../research/yoodio-teardown.md).
> Privacy and permission requirements: Sentinel's [`docs/PERSONAL_UPDATES_PRIVACY.md`](https://github.com/Rowerguy508/ai-radio-dj/pull/126)
> (draft PR #126). Requirement IDs in brackets, like **[P4]** or **[L2]**, refer to that document. Where this spec
> and #126 disagree, #126 wins.
>
> Conventions: `Existing` names a type or file on `integration/device-duo` today. **Proposed** marks a new type,
> case or file that doesn't exist yet. Nothing proposed here has been built.

## 0. Goals and non-goals

**Goal.** Between songs, at a natural boundary, the DJ can say a short, attributable personal update:
- your next calendar event today,
- the local weather, and
- an official WeatherKit weather alert, if there is one.

It's spoken by the on-device voice and grounded only in data the user turned on in Connections.

**Hard constraints** (from the owner and PM, restated so reviewers can check against them):
1. **$0 voice.** On-device only (`VoiceRenderer.onDeviceDefault()`, `AVSpeechSynthesizer`, or Echo's Phonon
   on-device prototype). No paid TTS, no server LLM. Copy is templated, as in `MorningBriefingEngine` and
   `DJScriptWriter` today. **[T1]**
2. **Every permission prompt follows a named tap.** Onboarding asks only for Apple Music. Calendar,
   location/weather and notifications are optional and live in Connections. Onboarding never sets integration
   consent, and no `StationRecipe` carries consent (`StationRecipe.requestedIntegrations` is always empty
   today). **[P1] [P2]**
3. **Nothing auto-plays.** Personal updates only ride on playback the user started with a tap. No notification,
   widget, Live Activity or background refresh starts audio.
4. **Diagnostics carry only IDs, counts and enums.** Never titles, times, place names, coordinates or narration
   text, including in TEMPORARY overlays such as `P0TapDiagnostics`. **[P6]**
5. **Spoken only.** Personal text never appears in Now Playing, the Lock Screen, notifications, Live Activities,
   widgets, Spotlight, Handoff or the share sheet. **[P5]**
6. **Ships dark.** It stays behind a flag that's off in TestFlight and App Store builds until #126 §6 (the
   release gate) passes.

**Non-goals (v1):** news, traffic, route awareness (Yoodio claims route traffic, see teardown §3; we can't
source it within $0), sports, an LLM rewrite of copy, server-side anything, background location, and
notifications that speak.

## 1. What exists today, and what we build on

| Concern | Existing type and file | Notes |
|---|---|---|
| Break placement | `DJBreakSession` (`AeroDJCore/DJ/DJBreakSession.swift`). `queueStarted`, `songStarted(index:remaining:)`, `naturalBoundary(afterTrack:)`, `songCut(afterTrack:)` | Breaks only at natural song ends. Music never waits. Late, failed, over-cap or revoked breaks are skipped. |
| Cadence and caps | `DJCadence` (`DJ/DJNarration.swift`). `talkFraction` 0.3, `minSongsBetweenBreaks` 2, `maxTransitionSeconds` 12, `maxBriefingBreakSeconds` 45 | `DJScriptWriter.plan(...)` sets `wantsBriefing = !pending.isEmpty` and forces a talk break at the next eligible boundary while approved cues remain. |
| Briefing content | `MorningBriefingEngine` (`MorningBriefingEngine.swift`) to `NarrationHandoff` / `NarrationCue` (`NarrationHandoff.swift`). `LiveQueueBriefing.provider(studio:)` (`DJ/LiveQueueBriefing.swift`) | Rules-first templates. `MorningBriefingConfiguration` caps: 6 item segments, 150 s spoken, 12 h event horizon. |
| Briefing preferences | `BriefingPreferences`, `BriefingWindow` (07:00 for 120 min), `BriefingSection` (`calendar`, `sharedItems`, `notes`) in `Station/StationConfiguration.swift` | `plannableSections(grantedIntegrations:)` gates sections by consent. |
| Integrations and consent | `StationIntegration` (`calendar`, `shareInbox`, `obsidian`), `StationConfigurationModel.integrationStatus(_:)`, `usableIntegrations`, `IntegrationConsentReading` | `StationIntegrationStatus.mayShowConnected` is true only when `.on`. |
| Personal item | `ContextItem` (`ContextItem.swift`), `ContextSourceKind`, `Sensitivity`, `ConsentState`, `isNarratable(at:)` | Provenance, expiry and consent are enforced in the type. |
| Calendar | `EventKitCalendarReader` (`AeroDJ/EventKitCalendarReader.swift`, read-only, `requestFullAccessToEvents`), `CalendarContextSource`, `CalendarSourcePolicy` (`privateCalendarIDs`, `.redact`), `ChosenCalendarContextSource`, `CalendarConnectionProvider` (`Studio/LiveConnections.swift`) | Already satisfies most of C1–C5. Purpose string in `ios/project.yml`. |
| Connections UI | `ConnectionsModel`, `ConnectionSourceRow`, `CalendarConnectionState`, `ConnectionItemState` (`Studio/ConnectionsPresentation.swift`). View: `AeroDJ/ConnectionsList.swift` | Contract: `docs/studio-presentation-contract.md` §Connections. |
| Purge on revoke | `NarrationPurger.purge(sourceItemIDs:)` / `purgeAllPersonalNarration()`, `AudioCache.purge(sourceItemIDs:)` (`Voice/VoiceRendering.swift`), `DJBreakPreparer.purge`, `DJBreakSession.purge` / `purgeAllPersonal()`, `onBreakMustStop` to `InterludePlaybackAdapter.stopCurrentInterlude(reason:)` | This is the path [P4] reuses. |
| DJ status UI | `DJPresentationState` (`preparing/ready/speaking(includesBriefing:)`), `DJStatusLine` (`AeroDJ/PlaybackComponents.swift`), which already has the headline "Briefing after this song" | Generic text only. That's already compatible with [P5]. |
| Weather, location, alerts | **None.** No `CoreLocation`, no WeatherKit, no `NSLocation*` key, no WeatherKit entitlement (`AeroDJ.entitlements` has only the app group), no `PrivacyInfo.xcprivacy` | All new. |
| Onboarding | There's no dedicated onboarding view in `ios/AeroDJ` today. MusicKit authorization happens at authorize or launch (`MusicKitService`). | The rule is "only Apple Music" before Connections. Keep it that way. |

## 2. Break placement

Personal updates are **briefing cues**, not a new kind of break. They reuse the existing boundary planning with
no change to playback:

1. **Content is gathered when a queue starts.** When the user taps play, `LiveQueueBriefing.provider(studio:)`
   already reads Connections and `BriefingPreferences`. The new weather and alert sources add their
   `ContextItem`s to the same `MorningBriefingEngine.collect(from:)` input. There's no new trigger and no timer.
   Weather is fetched at most once per 30 min **[L1]**, so a cached `WeatherSnapshot` (**proposed**, see §3.2) is
   reused across queue starts.
2. **Where it goes.** `DJScriptWriter.plan` already puts briefing cues in the first eligible boundary (after the
   minimum spacing) and caps the break at `maxBriefingBreakSeconds` (45 s). Order inside a break follows
   `BriefingScriptSegment.Kind` priority. **Proposed** additions to `Kind`: `.weatherAlert` (spoken first), then
   `.weather`, then the existing `.upcomingEvent`. One break carries at most one weather line and one alert line.
3. **Time sensitivity.** Weather and alerts are time-sensitive like calendar events. They aren't carried forward
   (`DJSessionPlan.carryForward.omittedTimeSensitive`). If a cue doesn't fit, it's dropped, never deferred to a
   later show.
4. **The window.** The briefing window (`BriefingWindow`, default 07:00 to 09:00) still bounds the full "morning
   show". **Proposed:** outside the window, allow **one** short "update" break per listening session that holds
   only a weather alert (if any) or the next calendar event starting within 60 min. It's capped at
   `maxTransitionSeconds` plus one item line, and governed by the same consent and section toggles. *Open
   question Q1.*
5. **Never mid-song, never after a cut.** `naturalBoundary` only, as today. `songCut` (skip) drops the break.
   Nothing changes in `InterludePlaybackAdapter` or `MusicKitService`.
6. **Shared route.** **[P9] (SHOULD)** On AirPlay, speaker or CarPlay routes, personal cues are filtered out
   before planning unless the user turned on "Also on speakers, AirPlay and car". The route check is
   **proposed** (`PersonalRoutePolicy`, owner Atlas, because it reads `AVAudioSession.currentRoute`). Weather
   without a place name may still play on a shared route. *Q4.*

## 3. Content sources

All three sources produce `ContextItem`s with provenance, consent, sensitivity and `expiresAt`, so every existing
gate (`isNarratable`, `ConnectionItemState.resolve`, `NarrationPurger`) applies unchanged.

### 3.1 Calendar (EventKit): existing, hardened

- **Source:** the existing `ChosenCalendarContextSource` → `CalendarContextSource` → `EventKitCalendarReader`.
  No new EventKit calls.
- **Fields:** only the `CalendarEventSnapshot` fields leave EventKit (occurrence ID, title, start, end, all-day,
  status, availability, calendar ID) **[C2]**. Spoken line: `"{timePhrase}: {title}. From your calendar."`,
  built by the existing `MorningBriefingEngine` templates.
- **Work needed against #126:**
  - Add a mirror test that fails if `CalendarEventSnapshot` gains a field **[C2]**.
  - Default shared, subscribed and delegate calendars into `CalendarSourcePolicy.privateCalendarIDs` when picked
    **[C3]**. Needs `EKCalendar.type`, `allowsContentModifications` or the source type exposed through
    `CalendarDescriptor` (**proposed** field `isShared: Bool`).
  - Redact titles that look like an email address or phone number **[C6]** (**proposed** helper in
    `CalendarContextSource`).
  - Add a DST case for the today window **[C5]**.
  - Read only, unchanged **[C1]**. Per-calendar opt-in, unchanged **[C3]**. Private-event redaction, unchanged
    **[C4]**.
- **Sensitivity:** private events are already `.high` (`CalendarContextSource.swift:167`). How those are
  handled is settled in §3.1.1 (Q2, resolved by Sentinel).

#### 3.1.1 P8 for private `.high` calendar events (MUST, resolved Q2, per Sentinel on #130)

Calendar rows have no per-event actions today. Sentinel's ruling: private `.high` events are **excluded**, and
an explicit, single-occurrence Approve is the only way one gets narrated. Each part below is a MUST with its own
named test (proposed names, owner Fry unless noted).

| ID | MUST | Named test |
|---|---|---|
| **P8-a: Excluded by default** | A calendar `ContextItem` with `sensitivity == .high` (private event, or an event on a calendar in `privateCalendarIDs`) is never plannable or narratable unless it has a valid approval. That includes no redacted "Private event at 3" line. There's no setting, recipe, onboarding step or restored config that pre-approves. A missing approval means excluded. **[P2] [P8]** | `testPrivateHighCalendarEventExcludedByDefault`. A `.high` event with no approval yields zero `NarrationCue`s and zero `BriefingScriptSegment`s, and `ConnectionItemState` is `.pendingApproval` (existing case). Covers fresh, restored and recipe-applied configs. |
| **P8-b: Single occurrence, today only** | Approve is an explicit named tap ("Approve for today") on that item in Connections. The approval (**proposed** `CalendarOccurrenceApproval { occurrenceID, calendarDayStart }`) covers exactly one occurrence ID on the current local calendar day. It's never applied to other occurrences of a recurring series, never carried to the next day, and expires at local midnight (including the DST case, **[C5]**). It's stored only alongside the item, with the same protection and backup exclusion as other personal state **[P7]**. Approvals aren't remembered for the series, the calendar, or the next day. | `testCalendarApprovalCoversSingleOccurrenceTodayOnly`. Approving occurrence A today narrates A only. Sibling occurrence B in the same series stays excluded, A is excluded again after local midnight (DST-transition day included), and a relaunch on the next day restores no approval. |
| **P8-c: Revoke purges before the next spoken word** | Unapprove (the named tap "Remove approval"), turning Calendar off, or deleting the item calls `NarrationPurger.purge(sourceItemIDs:)` for that item **before** the approval is cleared. That strips any prepared break (`DJBreakSession.purge`, `DJBreakPreparer.purge`) and cached clip (`AudioCache.purge`), and stops an on-air break within 1 s via `onBreakMustStop` **[P4]**. Midnight expiry runs the same purge. | `testRevokingCalendarApprovalPurgesBeforeNextSpokenWord`. With a prepared break that contains the approved event, revoking leaves `naturalBoundary` returning nil or a break without that cue, and the audio cache holds no clip for that item ID. A companion test with a break in `speaking` asserts `onBreakMustStop` fires. (Fry state, Echo voice, Atlas stop path.) |
| **P8-d: Never on Lock Screen or Now Playing** | Even an approved event's title, time or calendar name never appears in `MPNowPlayingInfoCenter`, on the Lock Screen, or in notifications, Live Activities, widgets, Spotlight, Handoff, captions or logs. The most anything shows is the generic "Briefing" (§6). **[P5] [P6]** | `testApprovedPrivateEventNeverInNowPlayingOrLockScreen`. With an approved private event speaking, the presentation state, Now Playing info and caption output contain no item text; plus a Duo device check of the Lock Screen during that break (M7). (Nova UI, Atlas Now Playing.) |

### 3.2 Weather (WeatherKit): new

- **Provider: WeatherKit**, Apple's native Swift `WeatherService` **[W1]**. Cost: the Apple Developer Program
  includes 500,000 calls a month. Paid tiers start at US$49.99 for 1M a month
  ([Apple](https://developer.apple.com/weatherkit/get-started/)). At one call per user per 30 min while listening
  **[L1]**, the included quota covers roughly 500k listening-half-hours a month, which is $0 for the beta. It
  needs the WeatherKit capability on the `com.aerodj.app` App ID, which Orion enables after build 11 clears the
  P0 and the owner gives the go-ahead (Q10, gates M3), plus Apple Weather attribution (the logo and legal link)
  in the app **[W1]**. Weather stays behind the off flag until then.
- **Alternatives considered:** Open-Meteo, NWS (US only), and OpenWeather. Each one receives the user's IP and
  coordinates and needs a separate privacy review and an owner cost decision **[W1]**. Rejected for v1. No AeroDJ
  server goes in the location path **[W2]**.
- **Location input**, two equal choices **[L3]**:
  - **"Use my approximate location"**: `CLLocationManager.requestWhenInUseAuthorization()`, then a single
    `requestLocation()` per refresh **[L1]**, with `NSLocationDefaultAccuracyReduced = YES` and no temporary full
    accuracy **[L2]**. The purpose string names the feature and the precision **[L6]**: "AeroDJ uses your
    approximate location to tell you the local weather during breaks."
  - **"Enter a city or ZIP"**: geocoded with `CLGeocoder` (an Apple service, $0). This never prompts for location
    **[L3]**. It's also the fallback when location is denied.
  - Coordinates are rounded to 2 decimals before `WeatherService` and to 1 decimal before storage, and expire
    after 24 h **[L4]**. Raw coordinates are never persisted.
- **Proposed types** (owner Fry for state, Echo for copy):
  - `WeatherLocationChoice`: `.off | .approximateDevice | .manual(placeName, roundedCoord)`.
  - `WeatherSnapshot`: condition enum, current temperature, high/low, precipitation chance, `placeName` from the
    service's or geocoder's locality, `fetchedAt`, `expiresAt = fetchedAt + 30 min`.
  - `WeatherContextSource: ContextSource` (`source = .weather`). It produces one `ContextItem`,
    `sensitivity: .low`, provenance `weather:<fetchedAt-epoch>`, no coordinates.
  - `WeatherReading` protocol: wraps `WeatherService` so Core stays testable on Linux, the same pattern as
    `CalendarEventReading`.
- **Spoken line** (templated, no LLM, place no finer than city or neighborhood **[L5]**):
  `"In {placeName}, {condition} and {temp} right now, with a high of {high}. From Apple Weather."`
  The `{placeName}` is omitted on shared routes (§2.6).

### 3.3 Alerts (WeatherKit `weatherAlerts`): new

- **Source:** WeatherKit's `weatherAlerts` only, from the same `WeatherService` request (no extra call where the
  API allows) **[W3]**. Alert coverage depends on the region; WeatherKit returns none for unsupported regions
  *(unverified per region, Q5)*.
- **Proposed:** `WeatherAlertContextSource` (`source = .weatherAlert`), one `ContextItem` per active alert,
  capped at 1 per break, `expiresAt` from the alert's expiry, provenance `weather-alert:<alert id>`.
- **Spoken line:** headline and issuing agency only, plus "check official sources" **[W3]**:
  `"A weather alert from {agency}: {summary}. Check official sources for details."`
  No WEA tones, no "Emergency Alert" framing, no siren-like sounds, no notifications **[W3]**. We don't claim to be
  an alert service, in copy or in App Store text.
- **Not in v1:** news and traffic alerts. Teardown §3 found no sourceable equivalent at $0.

### 3.4 Proposed enum additions (all **proposed**)

| Enum (existing) | New case | Mapping |
|---|---|---|
| `ContextSourceKind` | `.weather`, `.weatherAlert` | |
| `StationIntegration` | `.weather` | `contextSources = [.weather, .weatherAlert]` |
| `BriefingSection` | `.weather`, `.weatherAlerts` | `requiredIntegration = .weather` |
| `BriefingScriptSegment.Kind` | `.weatherAlert`, `.weather` | Priority before `.upcomingEvent` |

Decoding must stay tolerant. `StationConfiguration` already uses `compactMap(StationIntegration.init(rawValue:))`,
so an older build drops the unknown case. New cases default **off**, and decoding a config with no personal keys
gives every personal source off and consent `.notRequested` **[P2]**. Caveat: `BriefingPreferences.sections`
defaults to `allCases`, and that's still safe because `plannableSections` requires granted consent. *Q3.*

## 4. Where rendering happens

- **On device, during the song before the boundary,** exactly as today: `DJBreakSession` → `DJBreakPreparer.prepare(_:deadline:)`
  (remaining time minus a 3 s margin) → `VoiceRenderer` → `OnDeviceSpeechProvider` (`AVSpeechSynthesizer`, its
  own session, `usesApplicationAudioSession = false`). Playback goes through `InterludePlaybackAdapter`.
- **[T1] gate (proposed, owner Echo):** the renderer refuses any cue with
  `SpokenAttribution.personalContext` on a non-on-device provider before any request is made. Today
  `BetaVoicePolicy` already disables `cartesia`, `dessa` and `elevenlabs` with a $0 cap. This adds a
  per-cue check so a future provider flip can't leak personal text.
- **Phonon:** if Echo's on-device Phonon prototype becomes the voice, it plugs in behind the same
  `VoiceProvider`. Personal lines are rendered live, never pre-rendered or cached across days. Cached clips follow
  ADR 6 (7-day maximum, purge on revoke) **[P7]**.
- **Copy is templated** in Core (`MorningBriefingEngine` / `EditorialPhrasing`), with no server and no LLM. Every
  weather and alert cue passes `PromptInjectionSanitizer`, like other personal cues. Alert text comes from a third
  party, so it gets the sanitizer too.

## 5. Consent UI in Connections (Nova)

Connections gains a fourth row, **Weather and alerts**, beside Calendar, Obsidian notes and Shared from Mail &
Messages. It uses the existing `ConnectionSourceRow` (`status`, `scope`, `description`, `actions`,
`mayShowConnected`) and adds a `WeatherConnectionState` (**proposed**). There's no new screen and no onboarding
step.

**Weather row states (proposed copy):**

| State | Description | Actions (each is a named tap) |
|---|---|---|
| Off | "Local weather and official weather alerts between songs. Off." | `Turn on…` (opens the choice sheet) |
| Choice sheet | Two equal buttons: **Use approximate location** · **Enter city or ZIP**. Scope copy: "Approximate, about 10 km. Checked at most every 30 minutes while you listen. Never stored precisely." | Only **Use approximate location** triggers the system prompt **[P1] [L3]** |
| On, device location | "Weather for {city}, from Apple Weather." | `Change location`, `Turn off` |
| On, manual | "Weather for {city} (entered)." | `Change`, `Turn off` |
| Location denied | "Location is off for AeroDJ. Enter a city instead, or turn it on in Settings." | `Enter city or ZIP`, `Open Settings` **[P3]** |
| Restricted | "Location is restricted on this device." | `Enter city or ZIP` |
| Weather unavailable | "Weather isn't available right now. The DJ will skip it." | none (it retries on the next queue start) |

- The Apple Weather attribution sits at the row's footer and on the item detail **[W1]**.
- Section toggles live under Tune → Briefing: Calendar, Weather, Alerts. They map onto `BriefingPreferences.sections`.
  A toggle can only be on when its integration status is `.on` (`mayShowConnected`).
- **Calendar row:** unchanged (`CalendarConnectionState` table in the studio contract), plus:
  - A "Shared calendar, private by default" badge in `CalendarPickerSheet` **[C3]**.
  - A private `.high` item shows "Private event, not narrated" plus a named **Approve for today** action. Once
    approved, it shows "Approved for today only" plus **Remove approval** (§3.1.1, P8-a to P8-d). Approval text
    never leaves the app (P8-d).
- **Notifications:** not needed for v1. If a later phase adds them, they get their own Connections row and named
  tap, and never carry personal text **[P5]**.
- **Revoke:** `Turn off` calls `NarrationPurger.purge(sourceItemIDs:)` before clearing the choice (the existing
  order). The footer copy in `ConnectionsList.swift:45` ("Turning a source off… removes any DJ speech prepared from
  it.") already covers it.
- **Recipes:** `StationRecipe.requestedIntegrations` stays empty. Applying a recipe never turns weather on.

## 6. Now Playing presentation

Per **[P5]**, no personal text appears anywhere outside speech.

- **In app (Studio and compact player):** keep the existing `DJStatusLine` headlines, "Briefing after this song"
  (`preparing` / `ready(includesBriefing: true)`), and LIVE only in `speaking`, per `docs/dj-presentation-state.md`.
  **Proposed:** when `speaking(includesBriefing: true)`, show the generic label **"Briefing"** next to LIVE, with
  no item text, count or source name. Captions (allowed by the presentation contract for the clip playing) are
  **off for personal cues**, and the caption view shows "Briefing" instead. *Q6 for Sentinel: is the
  "Calendar · Weather" source-kind list acceptable in-app, or only "Briefing"?*
- **System Now Playing and Lock Screen:** `ApplicationMusicPlayer` owns `MPNowPlayingInfoCenter` (we don't set
  it anywhere in `ios/AeroDJ` today). During a break we write nothing. At most, a later phase could set the
  generic "AeroDJ · Briefing", only after Sentinel review. Device check: Lock Screen during a personal break
  **[P5]**.
- **VoiceOver:** "DJ briefing playing" is generic. It never reads the cue.
- **Accessibility for hard-of-hearing users** (captions without personal text on the Lock Screen) is an open
  design question, Q7.

## 7. Failure and empty states

Music never waits. Every failure becomes a skip or a smaller break, using existing skip reasons where possible.

| Situation | Behavior | UI |
|---|---|---|
| No integrations on | Personal sections aren't plannable. The DJ does ordinary transitions. | Nothing. Briefing toggles are disabled with "Turn on in Connections". |
| Calendar on, no events today | No calendar cue. **Not** a spoken "nothing today" line in v1 *(Q8)*. | Calendar row: "No events today in N calendars". |
| Calendar denied, restricted or write-only | Source drops out. Items purged **[P4]**. | Existing `CalendarConnectionState` copy and `openSettings` **[P3]** |
| Location denied mid-use | Device choice falls back to "needs a city". Weather items purged **[P4]**. | Row: "Location is off…" with `Enter city or ZIP` |
| WeatherKit error, timeout or quota | No weather cue this queue. Retry on the next queue start, no faster than 30 min. | Row: "Weather isn't available right now". Log `weather.fetch.failed type= domain= code=` only **[P6]**. |
| No alerts | No alert cue. Never "no alerts". | None |
| Stale snapshot (past `expiresAt`) | `isNarratable` is false, so it isn't spoken. | None |
| Render late, failed or over cap | Existing `DJBreakSkipReason` (`timedOut`, `renderFailed`, `overDuration`) | Existing `unavailable(voiceFailed)` (low-key) |
| Revoke while preparing or speaking | `DJBreakSession.purge` strips the break; the on-air clip stops within 1 s via `onBreakMustStop` **[P4]** | Row updates. LIVE drops on `playbackFinished/Failed`. |
| Shared route (AirPlay or speaker) | Personal cues filtered **[P9]**. Weather without place may play. | None. Optional row hint: "Personal updates play on headphones." |
| Feature flag off (shipped builds) | The weather row is hidden. Calendar behaves exactly as today. | None |

**Logging [P6]:** new log lines carry only enums and counts, for example `personal.collect calendar=2 weather=1 alert=0`,
`weather.location choice=manual|device|off`, `personal.purge source=weather items=1`. A unit test on each
log-line builder asserts that no `ContextItem.title` or `summary`, coordinate or place name appears.

## 8. Phased milestones

Nothing starts until the playback P0 (build 11 on the Duo) clears. Every phase ships behind the flag
(**proposed** `PersonalUpdatesFlag`, Debug on, Release off) and opens a draft PR that cites #126 IDs.

| Phase | Scope | Owners | Exit criteria (#126 IDs) |
|---|---|---|---|
| **M0: Spec sign-off** | This doc plus #126 agreed. Q1–Q8 answered. | Nova (doc), Sentinel (privacy), Orion (scope) | Sentinel, Fry, Echo and Atlas sign off on the doc |
| **M1: Calendar hardening** | C2 mirror test, C3 shared-calendar default, C5 DST, C6 contact redaction, P6 log-builder tests. **P8 Approve state:** proposed `CalendarOccurrenceApproval` (single occurrence, today only, midnight expiry), exclusion of `.high` by default, and purge on revoke or expiry (§3.1.1) | Fry (state, source), Sentinel (review) | C1–C6, P2, P6 tests green; P8-a `testPrivateHighCalendarEventExcludedByDefault`, P8-b `testCalendarApprovalCoversSingleOccurrenceTodayOnly`, P8-c `testRevokingCalendarApprovalPurgesBeforeNextSpokenWord` green |
| **M2: Weather core** | Proposed enums, `WeatherReading`, `WeatherSnapshot`, `WeatherContextSource`, L4 rounding and expiry helper, templates, T1 renderer refusal | Fry (state, source), Echo (copy, T1), Sentinel | L4, L5, T1, P2, P6 unit tests, Linux green |
| **M3: Location and WeatherKit wiring** | `CLLocationManager` one-shot, `CLGeocoder` manual entry, WeatherKit capability, entitlement, attribution, `NSLocationDefaultAccuracyReduced`, purpose string, `PrivacyInfo.xcprivacy`. **Blocked on:** Orion enabling WeatherKit on the `com.aerodj.app` App ID plus the matching App Store Connect step, which happens only after build 11 clears the P0 on the Duo and only with the owner's go-ahead, because it regenerates provisioning profiles (Q10). No WeatherKit entitlement lands before that. | Atlas (app wiring, entitlements), Fry, Sentinel. Orion (portal and App Store Connect, after owner go-ahead). | L1, L2, L3, L6, W1, W2, W4, T2, T3 |
| **M4: Connections and briefing UI** | Weather row and choice sheet, Tune section toggles, the "Briefing" label, captions suppressed for personal cues, empty and failure states. **P8 Approve UI:** "Approve for today" and "Remove approval" named taps on private `.high` calendar items, with the copy "Private event, not narrated" / "Approved for today only" (§3.1.1, §5) | Nova (UI), Fry (model), Sentinel | P1 UI test (no prompt at launch), P3 screenshots, P5 metadata test, P8-d `testApprovedPrivateEventNeverInNowPlayingOrLockScreen` |
| **M5: Alerts** | `WeatherAlertContextSource`, alert template, copy review | Echo (copy), Fry, Sentinel | W3 unit test and copy review |
| **M6: Placement and route** | Kind priority, the optional out-of-window update break (Q1), `PersonalRoutePolicy` (P9), revoke-before-next-word wiring for weather (P4) | Echo (narration placement), Atlas (route, stop path), Fry (purge) | P4 unit test, P9 test |
| **M7: Device gate** | Duo checks: no prompt at launch (P1), revoke mid-break (P4), Lock Screen shows no personal text (P5), approximate-only location (L2), AirPlay route (P9) | Owner on the Duo, Atlas (script), Sentinel (sign-off) | #126 §6. Only then may the flag turn on for TestFlight. |

## 9. Open questions

- **Q1 (Orion, Echo):** Outside the morning window, should there be one short "update" break per session
  (alert, or a meeting within 60 min), or nothing personal at all? Today `LiveQueueBriefing` gives no personal
  speech outside the window.
- **Q2: Resolved (Sentinel, on #130).** Private `.high` calendar events are excluded by default. An explicit
  Approve is the only way one gets narrated. It covers one occurrence, today only, and isn't remembered for the
  series or the next day. Revoking purges it before the next spoken word (P4). Even approved, it never shows on
  the Lock Screen or in Now Playing (P5). Specced as MUSTs P8-a to P8-d in §3.1.1.
- **Q3 (Fry):** `BriefingPreferences.enabled` defaults to `true` and `sections` to `allCases`. That's safe
  because consent gates it, but does [P2] want new sections (`.weather`, `.weatherAlerts`) to default off
  explicitly?
- **Q4 (Sentinel, Atlas):** [P9] is a SHOULD. On a shared route, may non-place weather ("Sunny, 72") still play?
  How do we classify CarPlay versus a Bluetooth car head unit?
- **Q5 (Atlas):** Confirm on device which regions return WeatherKit alerts, and whether alerts and the current
  weather can come from one request (call budget).
- **Q6 (Sentinel):** In app, is a source-kind label ("Calendar · Weather") acceptable during `speaking`, or only
  "Briefing"?
- **Q7 (Nova, Sentinel):** Accessibility. Can personal captions appear in app while it's unlocked and foreground,
  never on the Lock Screen, for hard-of-hearing users? Today they're suppressed.
- **Q8 (Echo):** Should an empty day ever be spoken ("Your calendar's clear today")? It isn't fabrication, but it
  does reveal calendar state on a shared route.
- **Q9 (Orion):** Should a manual city also cover users who never grant location (the default for privacy-minded
  users), and should it be the first option in the sheet?
- **Q10: Resolved (Orion).** Orion will enable WeatherKit on the `com.aerodj.app` App ID in the Apple developer
  portal, plus the matching App Store Connect step, but only after build 11 clears the P0 on the Duo and only
  with the owner's go-ahead, because it regenerates provisioning profiles. M3 depends on this. Until then, weather
  stays behind the off `PersonalUpdatesFlag` and no WeatherKit entitlement is added.

## 10. Privacy requirements

See Sentinel's **[`docs/PERSONAL_UPDATES_PRIVACY.md` in draft PR #126](https://github.com/Rowerguy508/ai-radio-dj/pull/126)**
(branch `sentinel/personal-updates-privacy`). This spec cites its IDs (P1–P9, C1–C6, L1–L6, W1–W4, T1–T3)
inline. The release gate in #126 §6 governs when the flag may turn on.

-Nova
