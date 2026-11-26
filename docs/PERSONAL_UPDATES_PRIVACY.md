# Personal updates: calendar and location privacy and permission requirements

> Owner: Sentinel (AppSec and privacy). Status: draft requirements, 2026-10-27.
> Extends [PRIVACY_MATRIX.md](PRIVACY_MATRIX.md). Applies to any break segment that speaks calendar events,
> weather, or alerts. Every requirement carries an ID; a PR that implements one cites the ID and adds the
> listed test or device check. "MUST" items gate merge; "SHOULD" items need a written reason to skip.

## 0. Scope and current state

- Calendar reading exists today: `EventKitCalendarReader` (read-only, `requestFullAccessToEvents`) feeding
  `CalendarContextSource` with per-calendar opt-in, private-event redaction, consent and expiry
  (`ContextItem.isNarratable`).
- Location, weather and alerts do not exist in the code. There is no `NSLocation*` key, no WeatherKit
  entitlement and no `PrivacyInfo.xcprivacy`. Everything in sections 3 and 4 is new work.
- Voice is on-device only at a $0 cap (ADR decision 5). Personal text never leaves the device today. Section 5
  keeps it that way.
- The whole feature ships behind a flag that stays off in TestFlight and App Store builds until Sentinel signs
  off this document's MUST items against code.

## 1. Rules for every personal source

| ID | Requirement | Verified by |
|---|---|---|
| P1 | Ask for each permission lazily, when the user turns that personal update on. Never at launch, during onboarding before the user picks the feature, or as a side effect of playback. | UI test: fresh install, play a song, no system permission prompt appears. |
| P2 | Off by default. A new station, a restored backup and a reinstall all start with every personal source off and consent `.notRequested`. | Unit test on `StationConfiguration` defaults and decoding of a config with no personal keys. |
| P3 | A denial, restriction or revocation is a visible state in the UI with a path to Settings. It is never a silent empty briefing, and it never falls back to another source. | Unit test per access state, plus Studio UI screenshot. |
| P4 | Revocation takes effect before the next spoken word. On `.denied`/`.restricted` (checked on foreground and on `EKEventStoreChanged` / `locationManagerDidChangeAuthorization`), the app drops that source's `ContextItem`s, calls `AudioCache.purge(sourceItemIDs:)`, and cancels or strips any prepared break that contains them (same path as `pendingWithdrawnIntegrations`). A break already speaking stops within 1 s (#118 behavior). | Unit test: revoke mid-preparation, prepared break has no personal cue. Device check: revoke in Settings while a personal break plays. |
| P5 | Spoken text only. Personal content never appears in Now Playing / `MPNowPlayingInfoCenter`, the Lock Screen, notifications, Live Activities, widgets, Spotlight, Handoff or the share sheet. | Unit test on the Now Playing metadata builder; device check of the Lock Screen during a personal break. |
| P6 | Logs and diagnostics carry IDs, counts, enum states and error type/domain/code only. Never an event title, time, place name, coordinates or narration text, at any `os_log` privacy level, including TEMPORARY overlays. | Grep check in review; unit test on any log-line builder. |
| P7 | Storage: personal `ContextItem`s live in memory or in files with `.completeUntilFirstUserAuthentication`, excluded from iCloud backup (`isExcludedFromBackup`). Spoken clips follow ADR decision 6 (7-day maximum, purged at launch, purge on revoke). | Unit test on file attributes; carries the open #77 follow-up (Application Support not excluded from backup). |
| P8 | High-sensitivity items (`sensitivity == .high`) need per-item approval in addition to source consent before they are spoken. This closes the open decision in PRIVACY_MATRIX §3. | Unit test: `.high` with consent `.granted` but no item approval is not narratable. |
| P9 | SHOULD: personal updates speak only on a private route (wired or Bluetooth headphones) unless the user turns on "Also on speakers, AirPlay and car". On a shared route, the break uses non-personal content. | Unit test on the route policy; device check with AirPlay. |

## 2. Calendar

| ID | Requirement | Verified by |
|---|---|---|
| C1 | Read only. Never request or use write access; no `EKEventStore.save`/`remove`. The purpose string stays accurate: "reads today's events, read-only". | Review grep for write APIs; existing purpose string in `project.yml`. |
| C2 | Only these fields leave the EventKit bridge: occurrence ID, title, start, end, all-day, status, availability, calendar ID. Never notes, location, URL, attendees, organizer, alarms, attachments or structured location. `CalendarEventSnapshot` must not grow those fields without a new review. | Unit test that fails if `CalendarEventSnapshot` gains a property (mirror-based field list). |
| C3 | Per-calendar opt-in; no calendar is read until the user picks it (current default). Shared, subscribed and delegate calendars default to private (`privateCalendarIDs`) when the user opts them in. | Unit test on the picker defaults. |
| C4 | Private events: `.unavailable` and any private calendar are redacted to "Private event" with its time, or excluded when the user picks exclude. Titles are whitespace-collapsed and capped at 80 characters (current). | Existing `CalendarContextSource` tests plus one for a shared calendar. |
| C5 | Time window is today in the device time zone; nothing older than today and nothing past tomorrow 00:00 is read. | Existing source test; add a DST-boundary case. |
| C6 | No attendee names, email addresses or phone numbers are spoken, even if they appear in a title. Titles that look like they contain an email address or phone number are treated as private (redacted). | Unit test with such titles. |

## 3. Location (for weather and local alerts)

| ID | Requirement | Verified by |
|---|---|---|
| L1 | When-in-use only. Never request Always authorization, never add the `location` background mode, and never use significant-change, region, visit or continuous updates. One `requestLocation()` per briefing refresh, at most once per 30 minutes. | Review of `Info.plist`, `project.yml` background modes and `CLLocationManager` calls. |
| L2 | Approximate by default: set `NSLocationDefaultAccuracyReduced = YES` and never call `requestTemporaryFullAccuracyAuthorization`. City-level is enough for weather. | `project.yml` check in review. |
| L3 | A manual city or ZIP entry is offered as an equal choice to device location and is the fallback when location is denied. Choosing it never prompts for location. | UI test. |
| L4 | Coordinates are rounded to 2 decimal places (about 1 km) before they reach any API, and to 1 decimal place (about 11 km) before they are stored. Raw coordinates are never persisted. The stored value expires after 24 hours. | Unit test on the rounding and expiry helper. |
| L5 | Narration never speaks more precision than the city or neighborhood the weather service returns. Never a street, address or "you're near …". | Unit test on the weather line builder. |
| L6 | Purpose string names the feature and the precision, for example: "AeroDJ uses your approximate location to tell you the local weather during breaks." | `project.yml` review. |

## 4. Weather and alerts

| ID | Requirement | Verified by |
|---|---|---|
| W1 | Use WeatherKit (Apple) with the WeatherKit capability and the required Apple Weather attribution in the app. A third-party weather API needs a separate review because it receives the user's IP address and coordinates, and it needs an owner cost decision. | Review of entitlements and the attribution view. |
| W2 | No AeroDJ server sits in the location path. If one is ever added, it must not log coordinates or IP addresses, and it needs a new review. | Review. |
| W3 | Alerts come only from WeatherKit `weatherAlerts`. The app must not claim to be an emergency alert service, must not imitate Wireless Emergency Alert sounds or wording, and speaks an alert's headline and issuing agency only, with "check official sources". | Unit test on the alert line builder; copy review. |
| W4 | The weather request carries no user identifier beyond what WeatherKit requires (its JWT). No personal calendar data is ever sent with it. | Review. |

## 5. Third parties, disclosure and App Store

| ID | Requirement | Verified by |
|---|---|---|
| T1 | Personal text (calendar, weather-with-place, shared items) is rendered by the on-device voice only. A paid or proxy voice provider may receive personal text only after a separate owner decision, a new explicit in-app consent naming the provider, and an App Privacy update. Until then the renderer refuses personal lines on any non-on-device route. | Unit test: a personal line routed to a non-on-device provider is refused before any request. |
| T2 | Add `PrivacyInfo.xcprivacy` declaring the data types and required-reason APIs actually used, and update the App Store privacy details for location (approximate) and calendar before the first build that ships this feature to testers. | Review before the TestFlight build. |
| T3 | `ITSAppUsesNonExemptEncryption: NO` stays correct; adding WeatherKit does not change it. Re-check if any custom crypto is added. | Review. |

## 6. Release gate

Personal updates stay off in shipped builds until all of these hold:

1. Every MUST item above has its test merged, green on the exact head.
2. Device checks pass on the physical Duo: no prompt at launch (P1), revoke mid-break (P4), Lock Screen shows no personal text (P5), and approximate-only location (L2).
3. Sentinel signs off against this document. Green CI alone is not enough.
