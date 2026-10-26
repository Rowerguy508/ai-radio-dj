# Station configuration

> The Studio UI binds to [`studio-presentation-contract.md`](studio-presentation-contract.md), which is the single entry point (tuner rows, recipes, connections, DJ status). This document stays the reference for configuration rules.

This document is the contract between the core and the UI for station settings. It isn't a UI design. DJ presentation state (idle, preparing, ready, speaking, unavailable) and the LIVE rules are defined in [`dj-presentation-state.md`](dj-presentation-state.md) (#55) and aren't repeated here.

Beta defaults are final: commentary is `occasional` (~30% of song boundaries).

Source: `ios/AeroDJCore/Sources/AeroDJCore/Station/`.

## What it covers

`StationConfiguration` is a pure value that is `Codable` and `Sendable`. Every field is clamped by `validated()`.

| Field | Range and default | When it applies |
|---|---|---|
| `genres`, `moods` | Free-form tags. Trimmed, lowercased and de-duplicated, with at most 8 tags of up to 32 characters each. Default `[]` | Next song boundary |
| `energy` | 0…1, default 0.5 | Next song boundary |
| `discovery` | 0 = familiar, 1 = new. Range 0…1, default 0.3 | Next song boundary |
| `personality` | `warm` (default), `upbeat`, `laidBack`, `minimal` | Next DJ break that starts preparing |
| `commentary` | `off` 0, `rare` 0.15, `occasional` 0.3 (default), `frequent` 0.45. Maps to `DJCadence.talkFraction`, max 0.5 | Next song boundary. Turning it **off** applies immediately |
| `briefing` | `enabled` (default on). `window` is a start minute plus 15–240 minutes and may wrap midnight; default 07:00 for 2 h. `targetSeconds` is 60–600, default 300, and is a flexible target where music comes first. `sections` are calendar, shared items and notes | Next briefing that's planned. Turning it **off** applies immediately |
| `requestedIntegrations` | `calendar`, `shareInbox`, `obsidian`. Default none | Requesting one applies at the next briefing. Withdrawing one applies **immediately** |

`configuration.cadence(base:)` returns the `DJCadence` the break planner uses. The `minimal` personality caps plain transitions at 6 s.

**Honesty note:** personality doesn't change the voice or the script lines yet; line selection by preset is a follow-up. Until it lands, the UI must not describe presets as different voices.

## Pending vs active

- `active` is what playback and the DJ use right now.
- `displayed` is the value the controls should show: the pending value if one exists, otherwise the active one.
- An edit never changes the song that's playing and never restarts playback. It becomes pending until a scheduler boundary event:
  - `songBoundary(afterTrack:)` applies **everything** that's pending. It's the latest point at which any change takes effect.
  - `djBreakWillPrepare(afterTrack:)` applies `nextDJBreak` changes early.
  - `briefingWillPlan` applies `nextBriefing` changes early.
- Privacy and silence reductions bypass the wait: withdrawing an integration, turning the briefing off, or turning commentary off. The emitted `StationConfigurationChange` has `boundary == nil`, and `invalidatesPreparedBreaks == true` tells the DJ preparer to discard breaks that are prepared but haven't played.
- A briefing or DJ break that was already prepared plays as prepared, unless it was invalidated as above.
- If an edit ends up equal to the active value, it's a no-op: no save and no event. Reverting a pending edit clears it.
- State is a pure value created at app or scene level, never inside a view, so it survives fold/unfold. Pending edits are persisted, so they also survive a relaunch.

## UI contract (Claudio)

`StationConfigurationModel` is `@MainActor @Observable`. Create it once, outside any view.

**Read:**
- `displayed`, `active`, `hasPendingChanges` and `loadState`
- `status(for: StationSetting) -> StationControlStatus`
- `integrationStatus(_:) -> StationIntegrationStatus`
- `usableIntegrations` and `plannableBriefingSections`

**Intents** (all `async`):
- `setGenres`, `setMoods`, `setEnergy`, `setDiscovery`, `setPersonality`, `setCommentary`
- `setBriefing { $0.targetSeconds = 240 }`
- `setIntegration(_:requested:)`
- `discardPendingChanges()`
- `load()` and `refreshConsent()`. Call `refreshConsent()` after the consent flow returns and when the app comes to the foreground.

**Previews:** use `await StationConfigurationModel.preview()`, `StationConfiguration.sampleMorningMix` / `.sampleLateNight`, and `StationConfigurationState.samplePendingEdit`.

### What each control may truthfully show

| `StationControlStatus` | May show | Must not show |
|---|---|---|
| `idle` | The value | — |
| `saving` | A subtle progress indicator | "Applied" |
| `pendingBoundary(.nextSongBoundary)` | The new value plus "Applies after this song" | That the current song or queue changed |
| `pendingBoundary(.nextDJBreak)` | "Applies at the next DJ break" | That the DJ has changed now |
| `pendingBoundary(.nextBriefing)` | "Applies to the next briefing" | That the briefing in progress changed |
| `consentRequired(state)` | "Needs your permission" with a link to the **existing** consent flow | "Connected" or "On" |
| `error(.saveFailed)` | "Couldn't save". The value has already been rolled back | The unsaved value |
| `error(.reductionNotSaved)` | The new (off) value is in effect, with "Will save with next change" | That the integration is back on |
| `error(.readOnlyNewerVersion)` | "Settings were saved by a newer AeroDJ" with the controls disabled | Editable controls |
| `error(.notLoaded)` | Disabled controls while `loadState` is `.loading` | — |

| `StationIntegrationStatus` | May show |
|---|---|
| `off` | Off |
| `checking` | "Checking…" (never "Connected") |
| `on` | Connected / in use. Only this case has `mayShowConnected == true` |
| `consentReviewRequired` | "Review permission", which opens the existing consent flow |
| `blocked(.denied / .revoked)` | "Permission off". Only the user can change this, in the consent flow or in Settings |

Rules:
1. Requesting an integration **never** grants access. Only the existing consent flow can grant it, and context items are still filtered by `ContextItem.isNarratable(at:)`.
2. Never show an integration as connected unless its status is `on`.
3. Every control renders `displayed`, and its status explains any gap between `displayed` and `active`.
4. A save failure rolls the value back. A privacy reduction is never rolled back.

## Boundary protocol (Claude, #34)

```swift
public protocol StationBoundaryEventSource: Sendable {
    func stationBoundaryEvents() -> AsyncStream<StationBoundaryEvent>
}
// .songBoundary(afterTrack:)        a song ended, the next has not started
// .djBreakWillPrepare(afterTrack:)  right before DJBreakPreparer.prepare for that boundary
// .briefingWillPlan                 right before the briefing is planned
```

1. The scheduler conforms to this protocol and the app calls `model.attach(to: scheduler)`.
2. Consumers read `model.active`, or subscribe to `model.changes()`, to retune upcoming selection or the cadence.
3. When `change.invalidatesPreparedBreaks` is true, they drop unplayed prepared breaks.
4. Emit `songBoundary` only when the playing song has really ended. Never emit it mid-song.
5. Queue, playback and station-state models stay with Claude. This module defines none of them.

## Persistence

- `StationConfigurationPersisting` is the persistence protocol. `FileStationConfigurationStore` writes atomic JSON with iOS file protection. `InMemoryStationConfigurationStore` serves tests and previews.
- The snapshot carries `version` (currently 1):
  - A snapshot with no version is read as v1.
  - Missing keys take their defaults.
  - Unknown enum values fall back to defaults, and unknown integrations are ignored.
  - A newer version on disk is never overwritten: the model runs on defaults, read-only.
  - A corrupt file falls back to defaults and stays editable.
- The file holds preferences only: no context items and no credentials.

-Fry
