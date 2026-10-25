# DJ presentation state

This file defines what the UI may truthfully show about the DJ. It is not a UI design.

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
3. Failure recovery:
   - A render that times out, fails, or hits the cost cap becomes a skip.
   - A clip that fails at playback reports `playbackFailed` and music resumes.
   - **No retry or live re-synthesis that delays the next song.**

## Defaults (configurable; pending owner sign-off)
| Setting | Default | Where |
|---|---|---|
| Voice | On-device only (`AVSpeechSynthesizer`); no paid provider enabled | `VoiceRenderer.onDeviceDefault()` |
| Talk cadence | ~30% of eligible song boundaries; at least 2 whole songs between breaks | `DJCadence(talkFraction: 0.3, minSongsBetweenBreaks: 2)` |
| Break caps | 12 s for a transition, 45 s for a break with the briefing | `DJCadence.maxTransitionSeconds` / `maxBriefingBreakSeconds` |
| Audio cache | On-device, protected files, 7 days | `FileAudioCache(maxAge:)` |
| Paid voice daily cap | $0 (paid routes off) | `VoiceBudget(dailyCapMicrodollars:)` |
