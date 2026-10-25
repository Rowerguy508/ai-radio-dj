# AeroDJ Privacy, Permission & Source Provenance Contracts

> **Issue:** [#14 — [S0] Define privacy, permission and source provenance contracts](https://github.com/Rowerguy508/ai-radio-dj/issues/14)
> **Date:** 2026-10-25
> **Branch:** `feat/s0-audit-ios-privacy`

## 1. Permission matrix

| Capability | Apple API | Info.plist / entitlement | When requested | Denied behavior |
|---|---|---|---|---|
| Calendar read | EventKit (`EKEventStore.requestFullAccessToEvents`) | `NSCalendarsFullAccessUsageDescription` (iOS 17+; write-only access cannot read events) | On first "add calendar" | Distinct states for `.denied`, `.restricted` and `.writeOnly`; show empty calendar source; no fallback to inbox |
| Apple Music | MusicKit (`MusicAuthorization.request()`) | `NSAppleMusicUsageDescription` | On first playback | Explicit degraded state; no silent fallback |
| Files / Obsidian | `UIDocumentPickerViewController` / `.fileImporter` + security-scoped bookmarks | **None** — access is granted by the user's selection | On import | Pair `startAccessingSecurityScopedResource()` / `stop…`; on `bookmarkDataIsStale` or a moved/deleted file, drop access and ask the user to re-select |
| Share Extension | `NSExtension` (`com.apple.share-services`) | `NSExtensionActivationRule` limited to text + 1 web URL; `com.apple.security.application-groups` entitlement on app **and** extension | When the user shares | Nothing stored; extension cancels with an error |
| Microphone | `AVAudioApplication.requestRecordPermission` | `NSMicrophoneUsageDescription` | **Optional, later** (live interruption) | Feature hidden |
| Notifications | `UNUserNotificationCenter.requestAuthorization` | **None** (runtime prompt, no purpose string) | **Optional** | Feature hidden |

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
| `eventAt` | Date? | When the event occurs or is due. Calendar: start of a timed event; `nil` for all-day. Obsidian: only frontmatter `due`/`scheduled` (never `date`/`created`, which record when a note was written) |
| `title` | String | Short label |
| `summary` | String | 1–2 sentence fact summary (never raw inbox text) |
| `sensitivity` | `Sensitivity` | `low` \| `medium` \| `high` \| `blocked` |
| `consent` | `ConsentState` | `notRequested` \| `granted` \| `denied` \| `revoked` |
| `expiresAt` | Date? | Hard expiry; item not narratable after |
| `provenance` | String | Opaque back-reference, never opened or narrated: `calendar-event:<id>@<occurrence>`, `obsidian-file:<relative path>` (not `obsidian://`, which would launch the app), `shared-inbox:<uuid>` |

### Shared inbox — `SharedInboxItem`

The Share Extension writes one JSON envelope per share to `group.com.aerodj/Inbox/` (`ios/AeroDJCore/Sources/AeroDJCore/SharedInboxItem.swift`): `id`, `source` (`userShared`), `kind` (`text` | `url`), `content`, `isTruncated`, `createdAt`, `expiresAt`.
- Content is trimmed and capped at 16 KB UTF-8, never split mid-character; longer shares are truncated and flagged.
- Files are written with `completeFileProtectionUntilFirstUserAuthentication`.
- Default retention is 7 days, enforced by the host on every load (#19): expired, invalid and forward-dated envelopes are purged. Excluded items are not narratable and expire with retention; **delete** removes the file immediately. A redaction **replaces** the envelope's content on disk (the original is not kept).
- Review decisions (include/exclude, label, redacted flag) persist in `group.com.aerodj/Review/state.json`, written atomically with `completeFileProtectionUntilFirstUserAuthentication` (same as the extension), and pruned to items still in the inbox.

**Invariants:**
- `isNarratable(at: now) == true` only when `consent == .granted` **and** `sensitivity != .blocked` **and** `expiresAt` is nil or later than `now` (an item expiring exactly at `now` is expired). Enforced in `ContextItem`, not by callers.
- Open decision (lead): whether `sensitivity == .high` needs per-item review beyond `consent == .granted`. Current behavior: `.granted` alone makes a `.high` item narratable.
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
5. **Cost safeguards** — `VoiceBudget` enforces a hard per-user daily cap with reserve → commit/release (a cancelled call releases its hold; a timed-out paid call is charged). Final beta default: **$0 paid spend, on-device voice only** (`VoiceRenderer.onDeviceDefault()`); a paid route at a $0 cap is refused before any request.
7. **Narration audio cache** — final beta default: retained **at most 7 days** (`AudioCacheRetention.maximum`; longer settings are clamped), expired clips are never served and are purged at launch. Each clip records the personal `sourceItemIDs` it was spoken from; deleting or revoking a source must call `AudioCache.purge(sourceItemIDs:)`, which removes that audio (and the narration text it encodes).
6. **No fabricated APIs/entitlements** — Dessa stub disabled until a real, documented endpoint exists.

**Consequences:** Privacy is enforced at the data model (`ContextItem`) and permission layer, not bolted on. Cost bounding is enforced by `VoiceBudget` (#53). External providers (Gmail/IMAP, messaging, direct Obsidian bridge, full-duplex Dessa) are feature-flagged until official APIs exist.

## 5. Completion check

- [x] Permission matrix defined (EventKit, MusicKit, Files, Share Extension, mic, notifications) with iOS-valid keys
- [x] Explicit limitations documented (no inbox scraping, no stream mixing, Dessa stub)
- [x] `ContextItem` provenance contract implemented in `AeroDJCore`
- [x] ADR decisions recorded
