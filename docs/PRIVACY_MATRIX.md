# AeroDJ Privacy, Permission & Source Provenance Contracts

> **Issue:** [#14 — [S0] Define privacy, permission and source provenance contracts](https://github.com/Rowerguy508/ai-radio-dj/issues/14)
> **Date:** 2026-10-25
> **Branch:** `feat/s0-audit-ios-privacy`

## 1. Permission matrix

| Capability | Apple API | Permission | When requested | Denied behavior |
|---|---|---|---|---|
| Calendar read | EventKit (`EKEventStore`) | `NSCalendarsFullAccessUsageDescription` | On first "add calendar" | Show empty calendar source; no fallback to inbox |
| Apple Music | MusicKit | `NSAppleMusicUsageDescription` | On first playback | Explicit degraded state; no silent fallback |
| Files / Obsidian | Document picker + security-scoped bookmarks | `NSDocumentsFolderUsageDescription` | On import | No access after bookmark revoked |
| Share Extension | `NSExtension` | App Group container | On first share | Inbox empty; bounded retention |
| Microphone | `AVAudioSession` | `NSMicrophoneUsageDescription` | **Optional, later** (live interruption) | Feature hidden |
| Notifications | `UNUserNotificationCenter` | `NSUserNotificationUsageDescription` | **Optional** | Feature hidden |

**Rules:**
- Request each permission **lazily**, at the moment the feature needs it — never all at once on launch.
- Every denial is a first-class state, not a silent no-op.
- No permission implies access to anything beyond its declared scope (e.g. Calendar ≠ Mail).

## 2. Explicit limitations (no fabrication)

- **No unrestricted Apple Mail, Messages, or Notes inbox/history API.** Share Extension + user-imported content only.
- **No protected-stream mixing.** Apple Music playback stays managed by MusicKit; do not capture/decrypt/mix DRM streams.
- **No gapless DJ speech-over-song mixing** until technical + rights constraints are tested.
- **Dessa by Block:** no confirmed public production API → stub adapter, disabled feature flag, no invented requests.

## 3. Source provenance contract — `ContextItem`

Defined in `ios/AeroDJCore/Sources/AeroDJCore/ContextItem.swift`:

| Field | Type | Meaning |
|---|---|---|
| `id` | UUID | Stable identity |
| `source` | `ContextSourceKind` | `calendar` \| `emailShared` \| `messagesShared` \| `obsidian` \| `userShared` |
| `createdAt` | Date | When captured |
| `eventAt` | Date? | When the event occurs (calendar) |
| `title` | String | Short label |
| `summary` | String | 1–2 sentence fact summary (never raw inbox text) |
| `sensitivity` | `Sensitivity` | `low` \| `medium` \| `high` \| `blocked` |
| `consent` | `ConsentState` | `notRequested` \| `granted` \| `denied` \| `revoked` |
| `expiresAt` | Date? | Hard expiry; item not narratable after |
| `provenance` | String | Link back to the source (e.g. `calendar://id`) |

**Invariants:**
- `isNarratable == true` only when `consent == .granted` **and** `sensitivity != .blocked` **and** not expired.
- No broad automatic sync. No raw private message content in `summary`.
- User can include/exclude individual items; deletion removes data; revocation stops access.

## 4. ADR — Privacy & Native-First

**Status:** Accepted
**Context:** AeroDJ narrates personal context (calendar, shared messages, Obsidian) between music tracks.
**Decisions:**
1. **Native first** — Apple APIs before external account providers.
2. **No inbox scraping** — Share Extension + user-imported content only; `ContextItem` is provenance-tracked.
3. **No protected-stream mixing** — MusicKit owns playback; no DRM capture/mix.
4. **Provider protocol** — `VoiceProvider` pluggable; secrets server-side only.
5. **Cost safeguards** — `UsageMeter` caps per-user spend; no speculative prefetch; cache only reusable generic audio.
6. **No fabricated APIs/entitlements** — Dessa stub disabled until a real, documented endpoint exists.

**Consequences:** Privacy is enforced at the data model (`ContextItem`) and permission layer, not bolted on. Cost is bounded by design. External providers (Gmail/IMAP, messaging, direct Obsidian bridge, full-duplex Dessa) are feature-flagged until official APIs exist.

## 5. Completion check

- [x] Permission matrix defined (EventKit, MusicKit, Files, Share Extension, mic, notifications)
- [x] Explicit limitations documented (no inbox scraping, no stream mixing, Dessa stub)
- [x] `ContextItem` provenance contract implemented in `AeroDJCore`
- [x] ADR decisions recorded
