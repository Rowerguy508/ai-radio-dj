# AeroDJ native UI contract: compact player and Duo Studio

Owner of this contract: Claude (technical ownership of native UI architecture).
Implementer: Claudio (SwiftUI views). Reviewer of screenshots: Claude, against this document.
Status: **specification**. No screenshot has been accepted against it yet.

This is the single source for layout, state and component boundaries. Do not
add a second UI architecture or a parallel UI PR. Changes to this document go
through the integration branch.

---

## 1. Principles

1. **Views render values and send intents.** A view receives a `PlaybackSnapshot`,
   a `PlaybackActions`, a `DJPresentationState` and station values. It never
   constructs `MusicKitService`, `MockPlaybackService`, the station model or any
   engine. Previews pass fixtures.
2. **Layout follows the container, not the device.** Choose compact or Studio from
   the width of the view that contains them. Never branch on a device model, a
   fixed point size, or `horizontalSizeClass` alone.
3. **Nothing truthful is hidden, and nothing untruthful is shown.** A LIVE badge
   appears only while `DJPresentationState.isLive`. Connected appears only when
   `StationIntegrationStatus.mayShowConnected`. Editing controls appear only when
   the action exists.
4. **Text never breaks mid-word.** Lines wrap at word boundaries or truncate with
   an ellipsis. Controls never wrap their labels.

---

## 2. Current contracts (read these, do not redefine them)

### 2.1 Playback (`AeroDJCore.PlaybackSnapshot`, published by `MusicKitService.snapshot`)

```swift
public struct PlaybackSnapshot: Equatable, Sendable {
    public var station: StationRef?        // id, name
    public var nowPlaying: TrackInfo?      // id, title, artistName, artworkURL
    public var upNext: [TrackInfo]
    public var transport: TransportState   // .stopped / .playing / .paused
    public var dj: DJActivity              // .idle / .speaking(line:)  — engine record, see 2.3
    public var error: PlaybackError?       // kind, message, isRecoverable
}
```

**Not in the snapshot yet:** playback position and duration. The UI therefore
**shows no progress bar and no scrubber**. Adding them is a playback task, not a
UI task (it blocks the boundary handoff work in `docs/playback-boundary-handoff.md`).

### 2.2 Actions (`PlaybackActions`)

```swift
struct PlaybackActions {
    let pause: () -> Void
    let resume: () async -> Void
    let skip: () async -> Void
    let dismissError: () -> Void
    var editUpNext: ((UpNextEdit) -> Void)?   // nil in live: hide every edit control
}
```

- `.live(music)` is the only live binding. `editUpNext` is `nil` there, so **Up Next
  is read-only in live playback**. Show it as a list, with no reorder, delete or
  add affordances.
- `.preview` accepts edits and does nothing, for layouts and previews only.

### 2.3 DJ presentation (`AeroDJCore.DJPresentationState`, from `DJPresentationStore`)

```swift
public enum DJPresentationState: Equatable, Sendable {
    case idle
    case preparing(afterTrack: Int, includesBriefing: Bool)
    case ready(afterTrack: Int, includesBriefing: Bool, seconds: Double)
    case speaking(afterTrack: Int, includesBriefing: Bool)   // the only LIVE state
    case unavailable(DJUnavailableReason)                    // consentReviewRequired(pendingCount:), voiceFailed, budgetReached
    public var isLive: Bool
}
```

**Decision (from the owner's signed defaults, #45):** the UI reads DJ status from
`DJPresentationStore`. `PlaybackSnapshot.dj` is the engine's own record and is not
rendered as a second status. Music status (track, transport, queue) comes from
the snapshot. Rules are in `docs/dj-presentation-state.md`.

### 2.4 Station configuration (`StationConfigurationModel`, Fry, #57)

One instance, created in `AppDependencies` (app scope). Never created in a view.

- Values: `displayed` (what controls show), `active` (what is playing now),
  `hasPendingChanges`.
- Control status: `status(for: StationSetting) -> StationControlStatus`, with
  `.idle`, `.saving`, `.pendingBoundary(StationChangeTiming)`,
  `.consentRequired(ConsentState)`, `.error(StationControlError)`.
  `StationChangeTiming` maps to copy:
  - `nextSongBoundary` → "Applies after this song"
  - `nextDJBreak` → "Applies at the next DJ break"
  - `nextBriefing` → "Applies to the next briefing"
- Integrations: `integrationStatus(_:) -> StationIntegrationStatus`, one of `off`,
  `checking`, `on`, `consentReviewRequired`, `blocked(ConsentState)`. Show
  "Connected" only when `mayShowConnected`. Requesting an integration never grants
  access; route to the consent flow.
- Intents (all `async`): `setGenres`, `setMoods`, `setEnergy`, `setDiscovery`,
  `setPersonality`, `setCommentary`, `setBriefing { … }`, `setIntegration(_:requested:)`,
  `discardPendingChanges()`.
- Load state: `StationControlError.notLoaded` and `.readOnlyNewerVersion` disable
  every control and show the reason.

---

## 3. Compact Now Playing

**Use when the container width is below the Studio threshold (section 5).**

Hierarchy, top to bottom:

1. **Station identity row.** Station name (`.subheadline`, one line, truncates) and
   a station-level DJ identity line, e.g. "DJ on air" when `.speaking`.
2. **Artwork.** Square, centered. Size = `min(containerWidth − 2·16, 360, 0.45·containerHeight)`.
   It is a scaled frame, not a fixed number. Corner radius 12. Placeholder: a
   system-tinted rounded rectangle with the `music.note` symbol, never a spinner.
3. **Track block.** Title (`.title2.weight(.semibold)`, up to 2 lines, then
   truncate), artist (`.subheadline`, 1 line, truncate), then the DJ status line.
4. **DJ status line** (from `DJPresentationState`, section 2.3). Copy:
   - `.speaking` → LIVE badge, then the spoken line from `snapshot.dj` if present
   - `.preparing` → "DJ is getting ready" (secondary)
   - `.ready` → "Up next: DJ after this song" or "Briefing after this song"
   - `.unavailable(.consentReviewRequired(n))` → "\(n) to review" (a button)
   - `.unavailable(.voiceFailed)`, `.unavailable(.budgetReached)` → "DJ voice unavailable" (low-key, no error color)
   - `.idle` → no line
   The LIVE badge is the only red element. It appears only for `.speaking`.
5. **Transport row.** Previous is not offered (no queue previous in the contract). Skip
   and Play/Pause are shown:
   - Play/Pause: 64 pt minimum target, symbol `play.fill` / `pause.fill`, label "Play" / "Pause".
   - Skip: 44 pt minimum target, symbol `forward.fill`, label "Skip".
   - Hit targets never below 44 pt. Spacing 32 pt between buttons.
6. **Queue affordance.** A single row below the transport: "Up next: \(upNext.first?.title ?? "nothing queued")"
   plus a chevron. Tapping it opens the queue as a sheet (compact) or the Queue
   workspace (Studio). It never shows a count alone.

Compact is a `ScrollView` only if the content does not fit the container height at
the current Dynamic Type size. Otherwise it is a fixed `VStack`. Never clip.

---

## 4. Unfolded Studio: two zones, persistent playback

**Use when the container width is at least the Studio threshold.**

```
┌──────────────────────┬──────────────────────────────────────┐
│ Zone A: Now Playing   │ Zone B: workspace                    │
│ station, artwork,     │ [ Queue | Tune | Connections ]       │
│ track, DJ line,       │                                      │
│ transport (persistent)│ scrolling content for the segment    │
└──────────────────────┴──────────────────────────────────────┘
```

- **Zone A is persistent.** It shows the same Now Playing and transport in every
  workspace segment. Switching segments never resets playback or scroll position
  of Zone A.
- **Zone B has three segments**, chosen with a segmented control at the top of Zone B:
  - **Queue:** `upNext` as a read-only list (live). Each row: title, artist. A
    "Now playing" row sits above it.
  - **Tune:** the station configuration controls (section 2.4): genres, moods,
    energy, discovery, personality, commentary, briefing. Each control shows its
    status from `status(for:)`.
  - **Connections:** one row per `StationIntegration` with `integrationStatus(_:)`.
    Requesting an integration routes to the consent flow.
- Segment selection is local UI state, held in the Studio view, not in the playback
  session.

---

## 5. Explicit widths and layout switching

All numbers are **points of the container**, not the device. They are constants in code.

| Constant | Value | Why |
|---|---|---|
| `studioMinWidth` | 684 | 320 (Zone A min) + 24 (gutter) + 340 (Zone B min) |
| `zoneAMinWidth` | 320 | the artwork is at least 280 and the transport row fits |
| `zoneBMinWidth` | 340 | a segmented control and one list row with its controls |
| `gutter` | 24 | between zones |
| `edgeInset` | 16 | from the container edge; 16 pt side gutter on phone |
| `touchTargetMin` | 44 | every interactive element |

- **Switch rule:** `GeometryReader` on the root of the playing screen. If
  `width >= studioMinWidth` → Studio; else → compact. The switch is the only
  layout decision. Nothing else reads size class to pick a layout.
- **No `ViewThatFits` at the top level.** Use it inside a zone, for example to pick
  between icon+label and icon-only transport buttons at large text sizes.
- **Height:** if the container height is below 480 pt in Studio, Zone A keeps the
  transport and drops artwork to 120 pt. Do not hide transport.
- **Rotation and fold:** they change the container only. No `onChange` of size
  class starts or stops anything (see the fold rules in `docs/device-install.md`
  and PR #52's review).

---

## 6. Typography, truncation and Dynamic Type

- Use **semantic text styles only** (`.largeTitle` … `.caption2`). No
  `.system(size:)` for text. Icons in controls use `.font(.title2)` or the
  scaled-metric equivalent (`@ScaledMetric`).
- Lines:
  - Track title: 2 lines compact, 2 lines Studio. Then truncate.
  - Artist: 1 line, truncate.
  - Station name: 1 line, truncate.
  - DJ line: up to 3 lines, then truncate. Full text is in the accessibility label.
  - Button labels: 1 line. At accessibility sizes, icon-only with the label as the
    accessibility label. Never wrap a button label.
- **Dynamic Type:** every layout must work at `.xxxLarge` and at the accessibility
  sizes. At accessibility sizes, Zone A and Zone B stack vertically inside a
  `ScrollView`, and the transport row moves to a full-width `VStack`.
- Word wrapping is only for body copy. Track titles and artist names never break a
  word mid-line.

## 7. Safe areas and scrolling

- Respect the safe area for every control and text.
- Artwork and the background may ignore the safe area.
- Compact: transport and queue affordance sit in `.safeAreaInset(edge: .bottom)`,
  so the home indicator never covers them.
- Scroll only where content can exceed the container: the queue list, the Tune and
  Connections segments, and the whole layout at accessibility sizes. Zone A itself
  does not scroll in Studio.

## 8. Reduced motion, haptics and accessibility

- **Reduced motion:** when `accessibilityReduceMotion` is on, the matched zoom
  transition is replaced by a plain push or fade. No animation on the LIVE badge.
- **Haptics:** only on user actions (play, pause, skip). None when the DJ starts or
  ends, and none on the snapshot changing.
- **VoiceOver order:** station, track title, artist, DJ status line (the spoken line
  is the label when speaking), transport (Play/Pause, Skip), queue affordance.
  Group Zone A's Now Playing as one element with a combined label.
- **Labels:** every button has a text label. Symbols are decorative.
- **Contrast:** LIVE uses the system red with an accompanying text label ("LIVE"),
  never color alone.

---

## 9. Empty, loading, failure, permission and disconnected states

| State | Source | What the user sees |
|---|---|---|
| **Stations empty** | no stations | "No stations yet." One primary button, to create one (when that flow exists); until then, the sample list with a note |
| **Loading (authorizing)** | `authorize()` in progress | Artwork placeholder, "Connecting to Apple Music", no transport buttons |
| **Nothing playing** | `snapshot.nowPlaying == nil`, `transport == .stopped` | "Nothing playing" plus a Start button for the selected station |
| **Not authorized** | `PlaybackError.Kind.notAuthorized` | "Allow Apple Music to play your station." Button → system prompt. No transport |
| **Subscription required** | `.subscriptionRequired` | "An Apple Music subscription is required." No retry button; say what is needed |
| **Playback failed (recoverable)** | `.playbackFailed`, `isRecoverable: true` | Inline message above the transport, "Try again" and Dismiss. Transport stays |
| **Playback failed (not recoverable)** | `isRecoverable: false` | Message and Dismiss. No retry |
| **Resume failed** | `.resumeFailed` | Message, "Try again" |
| **Speech failed** | `.speechFailed` | Subtle caption, not an error banner. Music continues. Never a modal |
| **DJ unavailable** | `DJPresentationState.unavailable(.voiceFailed / .budgetReached)` | "DJ voice unavailable" in the DJ line. Music continues |
| **Consent review pending** | `.unavailable(.consentReviewRequired(n))` | "\(n) to review" → opens review. No narration of those items |
| **Station settings not loaded** | `StationControlError.notLoaded` | Tune controls disabled with "Loading your station settings" |
| **Settings newer version** | `.readOnlyNewerVersion` | Tune controls read-only with "Update AeroDJ to change these settings" |
| **Permission denied (calendar)** | integration `.blocked(.denied)` | "Calendar access is off." Link to Settings |
| **Disconnected** | Not modeled. `PlaybackError` has no network kind | **Gap.** Do not show a "Disconnected" state until playback reports it. Track it as a playback task |

Error text is short, names what happened and what to do, and never blames the user.

---

## 10. One playback session, app scope

- `MusicKitService.shared` is created once, in `AppDependencies`, and held by the
  app. Its `snapshot` and `PlaybackActions.live(music)` are passed to the playing screen.
- Station navigation changes the *queue* (`play(_:station:)`), never the session.
  Opening another station shows that station's context without starting a second player.
- Layouts do not own playback. There is no `@StateObject MockPlaybackService` in
  any view. The current `PlayerView` default argument must be removed.
- DJ state: `DJPresentationStore` is created once in `AppDependencies`, next to the
  station model. Views read it; they never write to it.

## 11. Component map (SwiftUI)

```
AeroDJApp
└─ AppDependencies  (playback: MusicKitService, dj: DJPresentationStore, station: StationConfigurationModel)
   └─ StationListView  (stations, no playback)
      └─ PlayingScreen(station, snapshot, actions, dj, station model)    [GeometryReader → switch]
         ├─ CompactPlayer
         │  ├─ StationHeader(station: StationRef?, dj: DJPresentationState)
         │  ├─ ArtworkView(url: URL?, size: CGFloat)
         │  ├─ TrackBlock(track: TrackInfo?, djLine: DJLine?)
         │  ├─ DJStatusLine(state: DJPresentationState)
         │  ├─ TransportRow(transport: TransportState, actions: PlaybackActions)
         │  └─ QueueAffordance(upNext: [TrackInfo])          → QueueSheet
         ├─ StudioLayout
         │  ├─ ZoneA: NowPlayingPanel (same children as CompactPlayer, shared views)
         │  └─ ZoneB: WorkspaceView
         │     ├─ Picker(segment: Queue | Tune | Connections)
         │     ├─ QueueList(upNext:)          read-only in live
         │     ├─ TuneForm(station model)     status per control
         │     └─ ConnectionsList(station model)
         └─ PlaybackErrorBanner(error: PlaybackError?, actions)
```

Shared views are used by both layouts. Do not copy them.

## 12. Implementation order (for Claudio)

1. **Shared leaf views** with previews for every state in section 9:
   `ArtworkView`, `DJStatusLine`, `TransportRow`, `QueueAffordance`, `PlaybackErrorBanner`.
   Use `PlaybackFixtures` and `DJPresentationState` values for previews.
2. **`CompactPlayer`** composed from those views, checked at compact width and at
   `.xxxLarge` and accessibility sizes.
3. **`StudioLayout`** with `NowPlayingPanel` as Zone A and the segmented
   `WorkspaceView`. Check the width switch at 684 and at 683 (the boundary).
4. **`TuneForm`** and **`ConnectionsList`** against the station model, with
   fixtures for each status.
5. **Root wiring:** remove the view-owned `MusicKitService` and mock defaults;
   pass `snapshot` and `actions` from `AppDependencies`. Keep previews on fixtures.

Do not start 5 before 1–4 are reviewed.

## 13. Acceptance: screenshots and checks

A screenshot is accepted only when it shows, for the stated container:
- compact at the default and one accessibility size: no clipped text, no
  mid-word wrap, transport reachable above the home indicator
- Studio at 684 pt and above: both zones visible, Zone A transport visible in every
  segment, no overlap, no horizontal page scroll
- Studio below 684 pt: compact layout, not a squeezed Studio
- each state in section 9 has its own screenshot; none is an empty placeholder by accident

**Not yet accepted:** no screenshot has been reviewed against this document. The
screenshots Claudio has shared before this contract are not acceptance evidence.

## 14. Remaining gaps (owned, not in the UI)

- Playback position and duration (blocks any progress display)
- Live Up Next edits (blocked until the MusicKit queue is verified)
- Network or disconnected state from playback
- DJ narration wiring (see the #58 review and `docs/device-install.md`)
- Physical-device validation of every interaction above
