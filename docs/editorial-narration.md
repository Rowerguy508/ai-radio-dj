# Editorial narration

Contract for DJ copy. Playback stays with `DJBreakPreparer` / `DJBreakSession`. Voice bytes stay with `VoiceRenderer`. Consent UI and `NarrationPurger` stay with station settings.

## What a break is

`DJScriptWriter` still decides **whether** to talk (`DJCadence`, default about 30% of song boundaries, at least two songs between breaks). When it talks, the break is one short shape:

| Shape | When | Words it may use |
|---|---|---|
| Greeting | First talk break of the session | Fixed day-part line |
| Transition | Most later breaks | Previous and next title/artist |
| Artist focus | About 20% of later talk breaks | That artist and title only |
| Station ID | About 12% | The usable station name only |
| Time of day | About 13% | Fixed atmosphere line, no weather |
| Briefing | While approved cues remain | The cue text, unchanged, plus a short lead-in |

Ordinary breaks are capped at 12 estimated seconds. A briefing break is capped at 45. The five-minute morning show is `NarrationHandoff.experienceSeconds` (300): a label for the plan, not a playback cutoff. Music is never trimmed to hit it.

Durations in this layer are `SpokenDurationEstimate` (150 words per minute, rounded up per line). They are not synthesized-audio measurements.

## Carry-forward

`DJSessionPlan.carryForward` lists every content cue that did not air:

- `eligibleNextShow` — notes and follow-ups deferred with `.noTrackBoundary`. A later show may be given these cues and no others.
- `omittedTimeSensitive` — calendar events and due tasks. They do not roll forward, including when the reason is `.notCarriedForward` or another drop.
- `omittedOther` — instruction-shaped text, missing provenance, and other drops. Reported, not spoken.

`NarrationScheduleReport.withoutRollingTimeSensitiveCuesForward()` is the same rule for a scheduler other than `DJScriptWriter`. `BroadcastSchedulerAdapter` does not apply it yet.

## Injection

Briefing cues are data. `DJScriptWriter` drops a cue whose text `PromptInjectionSanitizer` flags (`.rejectedAsInstruction`) and does not let that cue force a talk break. Station names that are empty, braced, or instruction-shaped are not used in a station ID.

## Beta voice

Paid providers stay off. `BetaVoicePolicy.paidSpendAllowedMicrodollars` is 0. `disabledProviderIDs` are `cartesia`, `dessa`, and `elevenlabs`. Cache retention is `AudioCacheRetention.maximum` (7 days). The app's `VoiceRenderer.onDeviceDefault()` remains the production factory.

## Revocation (proposal, not wired here)

Fry already clears cached and prepared speech from consent withdrawal via `NarrationPurger` (`cache.purge`, `DJBreakPreparer.purge`, `DJBreakSession.purge`). This branch does not edit that path.

Claude: a break that `takeBreak` already returned is no longer in the preparer. If its cues' `sourceItemID`s were just revoked, stop that speech in the player. Narration cannot stop audio that has left the preparer.

Claude: `PlaybackActions` calls `queueStarted` without a briefing. Pass the approved `NarrationHandoff` when a morning show should talk about the user's sources. On a later show, pass `carryForward.eligibleNextShow` only.
