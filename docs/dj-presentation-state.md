# DJ presentation state

This file defines what the UI may truthfully show about the DJ. It is not a UI design.

**Contract status: stable for beta.** Cases are only added, never renamed or removed, without a note on the UI PR. Station settings (what the user edits, pending vs active, when edits apply) are defined in [`station-configuration.md`](station-configuration.md) (#57) and are not repeated here.

Source: `AeroDJCore/DJ/DJPresentationState.swift`. Observe `DJPresentationStore.state` (`@Observable`, main actor) or `updates()` (an `AsyncStream`). The store changes **only** on real events:
- consent review: `consentReviewPending`
- `DJBreakPreparer`: preparing, ready, skipped
- the audio player: `playbackStarted`, `playbackFinished` and `playbackFailed`, which map to Claude's `djStarted`, `djFinished`/`djCancelled` and `djFailed`

## States and what the UI may show

| State | Meaning | May show | Must not show |
|---|---|---|---|
| `idle` | Music only; no break pending | Nothing DJ-specific | LIVE, "DJ talking", waveform |
| `preparing(afterTrack, includesBriefing)` | Speech is rendering for the break after this song | A quiet "DJ up after this song" hint. If `includesBriefing`, "Briefing after this song" | LIVE, on-air, waveform, captions |
| `ready(afterTrack, includesBriefing, seconds)` | Audio is rendered and will play at the end of the song | Same as preparing. May show the length ("~9 s") | LIVE, on-air, waveform, captions |
| `speaking(afterTrack, includesBriefing)` | The player confirmed speech audio is playing now | **LIVE / on-air**, captions of the line being played, a level meter **only if driven by real audio levels** | Anything once the state leaves `speaking` |
| `unavailable(reason)` | The DJ can't talk right now; music continues | `consentReviewRequired(n)`: "n items to review", linking to review. `voiceFailed`: "DJ voice unavailable". `budgetReached`: "DJ voice paused for today". All optional and low-key | LIVE, error alerts that interrupt music |

### LIVE indicator rules
1. LIVE and on-air appear **only** in `speaking` (`state.isLive == true`). The player must have reported that audio started, and must not yet have reported finished or failed.
2. Never show LIVE during `preparing`, `ready` or `unavailable`, or when a break was planned but not played.
3. No fake waveform or animated "voice" graphic. Any meter must come from the real audio output level.
4. On `playbackFinished` or `playbackFailed`, LIVE goes away immediately. There's no linger animation that implies speech is still playing.
5. Captions come only from the cue text of the clip that is playing.

### Precedence
`speaking` > `ready`/`preparing` (earliest boundary) > `unavailable(consentReviewRequired)` > `unavailable(voiceFailed | budgetReached)` > `idle`.

A failure reason clears on the next successful `ready` or `finished`. `sessionStopped` clears everything except pending consent.

## Audio handoff contract (core ↔ player)
1. While song *k* plays: `prepare(break, deadline: DJBreakPreparer.deadline(remainingInSong:))`, which is the remaining time minus a 3 s margin. No deadline means no break.
2. At the end of song *k*, `takeBreak(afterTrack: k, natural:)` never waits:
   - `.ready(b)`: the player plays `b.clips` (`Data`, measured `audio.seconds`) and reports started, then finished or failed.
   - `.skipped(reason)`: the next song starts immediately.
   - A user skip or queue change passes `natural: false`, so the DJ never talks over or after a cut song.
   - Call it on Claude's `PlaybackEvent.naturalBoundary(nextIndex:)` (#51, `docs/playback-boundary-handoff.md`, which is also #57's `StationBoundaryEvent.songBoundary(afterTrack:)`): only when the song really ended, never mid-song.
3. Failure recovery:
   - A render that times out, fails, or hits the cost cap becomes a skip.
   - A clip that fails at playback reports `playbackFailed` and music resumes.
   - **No retry or live re-synthesis that delays the next song.** A missing, late or undecodable prepared clip means the break is skipped at once and the next song starts.
4. Invalidation:
   - `cancelAll()`: station change, queue replaced, stop, or a #57 change with `invalidatesPreparedBreaks == true`. In-flight renders are cancelled (cost reservations released, nothing cached), prepared audio is discarded, and each dropped break emits `skipped(.cancelled)`. A late finish is ignored.
   - `purge(sourceItemIDs:)`: a personal item was deleted or its consent revoked. Breaks built from it emit `skipped(.sourceRevoked)` and never play; call `AudioCache.purge(sourceItemIDs:)` alongside to delete its cached audio.
   - Neither ever stops or restarts the song that is playing.

### Skip reasons → UI
| `DJBreakSkipReason` | UI effect |
|---|---|
| `costCap` | `unavailable(budgetReached)` |
| `renderFailed`, `overDuration`, `timedOut`, `overBreakBudget` | `unavailable(voiceFailed)` (low-key, clears on next success) |
| `notReadyAtBoundary`, `notPlanned`, `notNaturalBoundary`, `cancelled`, `sourceRevoked` | Nothing: back to `idle`; music simply continues. Never an error. |

## Beta defaults (final, owner-approved)
| Setting | Default | Where |
|---|---|---|
| Voice | On-device only (`AVSpeechSynthesizer`); no paid provider enabled | `VoiceRenderer.onDeviceDefault()` |
| Talk cadence | ~30% of all song boundaries over a session (`expectedTalkShare`); at least 2 whole songs between breaks | `DJCadence(talkFraction: 0.3, minSongsBetweenBreaks: 2)` |
| Break caps | 15 s for a transition's main segment plus 4 s for its talk-over closing line; 45 s in total for a break with the briefing | `DJCadence.maxTransitionSeconds` / `maxClosingSeconds` / `maxBriefingBreakSeconds` |
| Audio cache | On-device, protected files, at most 7 days (longer values are clamped); purged by source on delete/revoke | `FileAudioCache(maxAge:)`, `AudioCacheRetention.maximum` |
| Paid voice daily cap | $0 (paid routes off) | `VoiceBudget(dailyCapMicrodollars:)` |

## Speech level (on-air orb)
`DJPresentationStore.speechLevel: Float` is the DJ voice level, 0...1, smoothed (fast attack, slower release), about 30 updates a second while a clip plays. It is exactly 0 unless `state` is `.speaking`, and it drops to 0 in the same update that leaves `.speaking`. A sample for another break, or one that arrives after the break ended, is ignored.
- Source: `InterludePlaybackAdapter` reads AVAudioPlayer metering (`averagePower`) on the main actor. No audio tap, no audio-thread work, and no change to the audio session, route or ducking.
- Mapping and smoothing are in `DJSpeechLevel.swift` (`DJSpeechLevelMapping`, `DJSpeechLevelSmoother`, `DJSpeechLevelMeter`): -50 dBFS or lower is 0, 0 dBFS is 1.
- The player publishes with `updateSpeechLevel(_:afterTrack:)` and clears it with 0 as soon as a break stops, before the state event arrives.
