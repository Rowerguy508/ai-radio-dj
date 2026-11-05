# Studio presentation contract

This is the **single** model that the Studio UI (Claudio, #52) binds to for the Station Tuner, station recipes, Connections and DJ status. It is the entry point and supersedes the UI sections of [`station-configuration.md`](station-configuration.md) (#57) and [`dj-presentation-state.md`](dj-presentation-state.md) (#55). Those docs remain the reference for the underlying rules and are linked below, not repeated.

- **Source:** `ios/AeroDJCore/Sources/AeroDJCore/Studio/`. It builds on the existing `Station/`, `DJ/`, consent and `ContextSource` code; it is not a second model.
- **Tests:** `Tests/AeroDJCoreTests/StudioPresentationContractTests.swift`.
- **Boundaries that don't move:**
  - Voice is on-device only, with a $0 paid cap (`VoiceRenderer.onDeviceDefault()`).
  - Nothing in this contract renders speech, reads a mailbox or grants consent.
  - The UI only displays this model and calls its intents. It never builds providers.

## One object to bind

`StudioPresentationModel` is `@MainActor @Observable`. Create it once in the composition root (`AppDependencies`, #58), never inside a view.

| Property | Type | What it covers |
|---|---|---|
| `station` | `StationConfigurationModel` | Station Tuner: values, pending vs active, intents |
| `recipes` | `StationRecipeLibrary` | Saved station recipes |
| `connections` | `ConnectionsModel` | Calendar, Obsidian, Mail/Messages via Share |
| `dj` | `DJPresentationStore` | DJ reducer state (#55). Use `djState` / `isOnAir` |
| `djState` | `DJStudioState` | Owner's five states: idle, preparing, ready, speaking, failed |

**Intents:**
- `start()` loads everything and forwards station changes to Connections, so a withdrawn integration is purged.
- `saveRecipe(named:)` and `applyRecipe(_:)`.
- The per-area intents below.

**Previews:** `await StudioPresentationModel.preview(dj:)`. It uses synthetic `[TEST]` data, in memory only, and drives the DJ store through the real reducer.

## Station Tuner

Controls: energy, mood (`moods`), genre (`genres`), discovery, station seeds ("Built from", `seeds`), reach (`reach`: "Only this", "Related", "Broad"), DJ talk (`commentary`), DJ personality and the morning briefing.

- **Rows:** `station.tunerRows` returns one `StationTunerRow` per control (`StationSetting.tuning`) with:
  - `activeSummary`: what is playing now
  - `displayedSummary`: what the control shows, which is the pending value if there is one
  - `pendingTiming`, `appliesCopy` and `status`
- **Control values:** bind them to `station.displayed.<field>`. Never bind them to `active`; `active` is for "Now using: …".
- **Intents** (`async`): `setEnergy`, `setMoods`, `setGenres`, `setDiscovery`, `setSeeds`, `setReach`, `setCommentary`, `setPersonality`, `setBriefing { … }` and `discardPendingChanges()`.

### When a change applies, and the exact copy

| `StationChangeTiming` | `appliesCopy` | Applies at |
|---|---|---|
| `nextSongBoundary` | "Applies after this song" | `songBoundary(afterTrack:)`: genres, mood, energy, discovery, seeds, reach, commentary up |
| `nextDJBreak` | "Applies at the next DJ break" | `djBreakWillPrepare`, or the song boundary if that comes first: personality |
| `nextBriefing` | "Applies to the next briefing" | `briefingWillPlan`, or the song boundary: briefing changes, requesting an integration |
| `immediate` | "Applied now" | Turning commentary off, turning the briefing off, withdrawing an integration |

An edit never restarts or changes the song that is playing. See `station-configuration.md` for every status case (`saving`, `consentRequired`, `error(...)`) and what each may show.

### Honest copy

- **Personality:** `DJPersonality.honestDescription`. A preset currently changes **only the maximum length of a plain DJ break**: 15 s for the main segment (plus a separate 4 s closing line), or 6 s for `minimal`. It doesn't change the voice or the words, so the UI must not describe presets as different voices or styles.
- **Talk:** `CommentaryFrequency.honestDescription`. The percentage is the share actually delivered (`DJCadence.expectedTalkShare`). The spacing rule caps it at 33%, so `frequent` (0.45) shows "about 33%". The beta default is `occasional` (30%).

### Station recipes

`StationRecipe` is a named snapshot of the **tuning only**. Its `requestedIntegrations` is always empty, so a recipe never turns a connection on or off.

- **Persistence:** versioned and Codable (`StationRecipeLibrarySnapshot.currentVersion = 1`).
  - Decoding is tolerant: one bad recipe is dropped, not the whole library.
  - A file written by a newer app version makes the library read-only.
  - The file store is `FileStationRecipeStore` in Application Support.
- **Intents:**
  - `save(name:configuration:)`. `StudioPresentationModel.saveRecipe(named:)` saves `station.displayed`.
  - `rename(_:to:)` and `delete(_:)`.
  - `apply(_:to:)`, which returns the pending timing for each control.
- **Name rules:**
  - Trimmed, 1–40 characters, unique (case-insensitive).
  - At most 50 recipes.
  - Errors carry `userMessage`.
- **Applying a recipe** follows exactly the same rules as editing each control:
  - Music settings show "Applies after this song".
  - Personality applies at the next DJ break.
  - Turning the briefing or talk off applies now.
- A failed save rolls back and reports `.saveFailed`.

### Creating a station (artists, a genre or a playlist)

A created station is an ordinary recipe whose seeds, reach and discovery come from a `StationCreationRequest`. Nothing new is persisted.

- **One entry point:** `studio.saveRecipe(named:from:applying:) -> Result<StationRecipe, StationRecipeError>`.
  - Same name rules and errors as `saveRecipe(named:)`, plus `.invalidStation(StationCreationError)`. Every error has `userMessage`.
  - Keeps the tuning the controls show (energy, personality, talk, briefing) unless the request sets talk or personality; never carries connections.
  - `applying: false` (default) leaves the live station alone. `applying: true` then applies it with the recipe rules above.
- **Request:** `StationCreationRequest(source:level:commentary:personality:)`.
  - `commentary: CommentaryFrequency?` (talk level) and `personality: DJPersonality?` (presenter preset) are optional; `nil` (the default) keeps the on-screen tuning. Saved in the recipe's existing `commentary` and `personality` keys; no new keys.
  - The voice is not part of a recipe (it is chosen in the voice settings), so a walkthrough voice step cannot be saved per station yet.
  - `StationCreationModel.commentary` / `.personality` (both `nil` by default) feed the request.
  - `source`: `.artists([StationSeed])` (1–5), `.genre(StationSeed)` (catalog, numeric ID), or `.playlist(StationSeed)` (catalog or library).
  - `suggestedName` prefills the name field. `reachRestriction` is set for a library pick.
- **Discovery level** (`StationDiscoveryLevel`): presets over `discovery` and `reach`.

  | Level | reach | discovery | Plays |
  | --- | --- | --- | --- |
  | `.familiar` | `.only` | 0.1 | The picks' own songs, hits first |
  | `.balanced` (default) | `.related` | 0.3 | Picks 60%, similar artists 40%; about 3 in 10 new |
  | `.adventurous` | `.broad` | 0.7 | Picks 40%, similar 30%, wider genre 30%; about 7 in 10 new |

  - A library pick always plays only itself (`.only`), at any level.
  - `StationDiscoveryLevel.matching(_:)` returns nil for a hand-tuned station ("Custom"). `closest(to:)` preselects a picker.
- **View model:** `studio.makeStationCreation(kind:) -> StationCreationModel?` (nil in previews and the Test Station).
  - Read: `kind`, `level` (settable), `selected`, `results`, `resultsSource`, `phase`, `validationError`, `canSave`, `canPickMore`, `suggestedName`, `reachRestriction`, `isSaving`, `saveError`.
  - Do: `setKind(_:)`, `search(_:)`, `loadLibraryPlaylists()`, `toggle(_:)`, `isSelected(_:)`, `save(named:applying:)` (defaults: suggested name, apply).
  - Search failures show fixed `SearchFailureCopy` text only. Library playlists stay on the device and are never logged.

### What a station plays

A station with seeds (a created station, a recipe, or seeds set in Tune) now decides what plays. `StationQueueFeed` (AeroDJCore) builds its queue ahead of time from the committed settings; `StationQueuePlayer` (app) hands it to the player. No UI call is needed.

- **When:** only where the existing rules apply a music change. Mid-song, a change waits for the song to end ("Applies after this song"); the next song comes from the new station, after any DJ break. Idle, Play starts the station.
- **Not replaced:** a queue the listener started by tapping a song belongs to the station committed at that moment. It is replaced only if the station's seeds, reach or discovery change after the tap. DJ-only edits (talk, personality, briefing) never rebuild the queue.
- **Fallback:** no seeds (tags only), an empty pool, a failed Apple Music lookup, no playable song, or a queue not ready yet keeps the current queue (or Play's existing message), and retries for the next boundary. Never an empty queue.
- **Order:** deterministic for a station and a day (`StationQueueKey.shuffleSeed(day:)`); songs already played in the current queue are left out.
- **Refill:** a queue (tapped or the station's own) does not run out. At the boundary before its last song, after any break and before that song starts, the station starts a new queue: that last song, then fresh station songs (none already in the queue). It starts like a tap, so the DJ plans the last song's break through the normal `queueStarted` replan and only ever names songs that are really queued. Building starts once three or fewer songs are left to load. If nothing is ready, the lookup failed, playback is held, or there are no seeds, the last song plays and the station stops after it, as before. A single tapped song has no boundary before it and still ends as before.
- **Library picks** play only their own songs.
- **Copy:** seeds, reach and discovery are now used for song picking. Genres, moods and energy are still not.

## Connections

`connections.sources` returns three `ConnectionSourceRow`s: Calendar, Markdown notes, and Shared from Mail & Messages. Each row has:

- `status`: the listener's request combined with consent, from `StationConfigurationModel.integrationStatus`
- `scope`: fixed privacy copy, always shown
- `description`
- `actions`
- `mayShowConnected`: true **only** when consent is granted **and** the source is actually readable

### Calendar (`CalendarConnectionState`)

Selection: `connections.selectCalendars(_:)`. Only IDs from `calendar.calendars` are kept, and nothing is read without `fullAccess` **and** at least one picked calendar.

| `access` | Description (abridged) | Actions |
|---|---|---|
| `notDetermined` | AeroDJ hasn't asked to read your calendar yet. | `allowAccess` (system prompt, user-initiated) |
| `denied` | Calendar access is off… turn it on in Settings. | `openSettings` |
| `restricted` | Restricted on this device (Screen Time / device management). | none |
| `writeOnly` | Can only add events, not read them; needs Full Access. | `openSettings` |
| `fullAccess`, none picked | No calendars chosen. AeroDJ reads only the calendars you pick. | `reselect` |
| `fullAccess`, picked | Reading today's events from N of M calendars. | `reselect`, `revoke` |

### Obsidian (`ObsidianSelectionState`)

AeroDJ reads only the Markdown files the user explicitly picked, through security-scoped bookmarks.

| State | Source | Actions |
|---|---|---|
| `notSelected` | No files picked yet | `reselect` |
| `valid(fileCount:)` | The bookmark resolves | `reselect`, `revoke` |
| `stale` | `MarkdownReadError.bookmarkStale` (moved or renamed) | `reselect`, `revoke` |
| `missing` | `.notFound` / `.accessDenied` | `reselect`, `revoke` |
| `notDownloaded` | iCloud placeholder | `reselect`, `revoke` |

### Mail and Messages (`SharedImportsState`)

AeroDJ uses **only** content the user shared to AeroDJ with the Share button. It never accesses the mailbox or Messages, so this source has no authorization state. It reports how many items are waiting for review and how many are approved.

### Item lifecycle (`ConnectionItemState`)

There is one precedence for every source: unavailable > expired > revoked > flagged > pending > approved (`ConnectionItemState.resolve`). Only `approved` has `mayBeNarrated`.

| State | Description | Share actions | Obsidian actions |
|---|---|---|---|
| `pendingApproval` | Waiting for your OK. The DJ won't mention it until you approve it. | approve, review, delete | approve, review |
| `flaggedForReview` | Held back: looks like instructions to the DJ. Review it before it can be read. | review, readAnyway, delete | review, readAnyway |
| `approved` | Approved. The DJ may mention it in a briefing. | review, revoke, delete | review, revoke |
| `expired` | Expired. It's no longer used. | delete | none |
| `revoked` | Not used. You turned this off. | approve, delete | approve |
| `unavailable(reason)` | The reason's text (calendar access, or file moved/missing/not downloaded/opted out…) | delete | reselect for moved or missing files |

Calendar events have no per-event actions: consent and selection apply to the whole source. An unavailable calendar item offers `allowAccess` or `openSettings`.

- `readAnyway` approves the item and records the persisted reconfirmation (`SharedInboxReview.reconfirm`).
- `review` and `reselect` are UI navigation: open the item, or the document or calendar picker, then call `refresh()`.

### Purging (privacy)

- `perform(.revoke | .delete, on:)` and `perform(.revoke, onSource:)` call `NarrationPurging.purge(sourceItemIDs:)` **before** the provider runs. A provider failure can therefore never leave narratable audio behind.
- `refresh()` purges items that became expired or revoked, once per item.
- `handle(StationConfigurationChange)` purges every item of a withdrawn integration. `start()` wires this up for you.
- In production, `NarrationPurger(cache:preparer:)` calls `DJBreakPreparer.purge(sourceItemIDs:)` and then `AudioCache.purge(sourceItemIDs:)`.
- Actions that aren't offered for the current state are rejected with `.notAllowed`, and nothing is called.

## DJ presentation

`DJStudioState` is a mapping over #55's `DJPresentationState`. It doesn't replace it, so #58 keeps feeding `DJPresentationStore` unchanged.

| `DJStudioState` | From | `title` | On Air? |
|---|---|---|---|
| `idle` | `.idle` | Music | no |
| `preparing` | `.preparing` | Preparing | no |
| `ready(seconds:)` | `.ready` | Ready | no: rendered audio is still waiting for the song to end |
| `speaking` | `.speaking`, which comes **only** from the player's `playbackStarted` | On Air | **yes** |
| `failed(reason)` | `.unavailable(reason)`: `voiceFailed`, `budgetReached`, `consentReviewRequired(n)` | DJ unavailable / Needs review | no |

**On Air rule:** use `isOnAir` / `onAirLabel` for any "On Air" or "LIVE" badge. Only `speaking` qualifies, and it starts only after the player confirms that real DJ audio started and ends on finished, failed or stopped.

**Never invent speech activity:**
- No waveform, level meter or caption animates outside `speaking`.
- The contract exposes no script text. The UI must not show captions unless it is given the exact text of the clip that is playing.

## Inputs the app must feed (Claude, #58)

Live playback talks to **one** object, `DJBreakSession` (`DJ/DJBreakSession.swift`). It owns the planning, preparation, boundary application and DJ status for prepared narration. The app doesn't call `DJBreakPreparer` or `StationConfigurationModel.handle` directly.

**Player calls:**

| When | Call | Result |
|---|---|---|
| A queue starts or is replaced | `await session.queueStarted(tracks, briefing:)` | Old breaks are cancelled. The queue is planned with the active cadence (about 30%, never back to back). |
| A song starts (index, time left) | `await session.songStarted(index:remaining:)` | The break after this song renders now, with a deadline of `remaining - 3 s`. If it's too late, nothing is prepared. |
| A song ends naturally | `await session.naturalBoundary(afterTrack:)` returns `PreparedDJBreak?` | Pending tuner edits apply here, then the session returns ready audio, or `nil` for music now. It never waits. |
| A user skip or queue change | `await session.songCut(afterTrack:)` | The break is dropped. The DJ never talks after a cut song. |
| DJ audio becomes audible / ends / fails | `session.playbackStarted/Finished/Failed(afterTrack:)` | These are the only inputs that turn On Air on or off. |
| Stop | `await session.stop()` | Everything prepared is dropped. |

**Caps:**
- A routine break's main segment is at most 15 s (6 s for `minimal`), and its closing line at most 4 s. A briefing break is at most 45 s.
- Measured audio over the cap is skipped (`overBreakBudget`). So are late renders (`timedOut` / `notReadyAtBoundary`) and failed or undecodable audio (the player calls `playbackFailed`).
- Music never waits for speech.

**Tuner:**
- Edits apply at `naturalBoundary` (`.songBoundary`), or when a break starts preparing (`.djBreakWillPrepare`, personality).
- Only breaks after the playing song are re-planned.
- Turning talk or the briefing off, or withdrawing an integration, drops prepared speech immediately.

**Purge:**
- Construct `NarrationPurger(cache: renderer.cache, preparer: preparer, session: session)` and pass it to `ConnectionsModel`.
- Revoke and delete then remove the item from the remaining briefing and planned breaks, from prepared breaks, and from cached audio, before the provider runs.

**Sources:**
- Shares: `SharedInboxConnectionProvider(review:)`.
- Calendar and Obsidian: the app implements `ConnectionSourceReading`.
- In the test station, use `StaticConnectionSourceReader` and `InMemoryConnectionItemProvider` with fixtures only.

**Queue presentation:** stays in Claude's `PlaybackSnapshot` (now playing, up next, transport). It is not duplicated here. The UI shows DJ activity from `studio.djState`, not `PlaybackSnapshot.dj`, which carries line text.

## Mapping from #52's placeholders (Claudio)

| #52 today | Bind to instead |
|---|---|
| `StationConfig.mood/energy` (mock `TunerCard`) | `station.tunerRows`, and `station.displayed` for controls |
| `Connection.isConnected` | `connections.sources[i].mayShowConnected`, `.description` and `.actions` |
| `PlaybackSnapshot.dj` `.speaking(line:)` badge | `studio.djState.onAirLabel`; drop the line text unless it is the exact clip text |
| `SettingsView` `@AppStorage djChatter / spokenBriefing / preferredVoice` | `setCommentary(.off …)`, `setBriefing { $0.enabled = … }`. There is no voice picker: one on-device voice in beta |
