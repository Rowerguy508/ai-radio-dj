# Editorial narration

Contract for DJ copy. Playback stays with `DJBreakPreparer` / `DJBreakSession`. Voice bytes stay with `VoiceRenderer`. Consent UI and `NarrationPurger` stay with station settings.

## What a break is

`DJScriptWriter` still decides **whether** to talk (`DJCadence`, default about 30% of song boundaries, at least two songs between breaks). When it talks, the break is a **main segment** followed by one **closing line**:

| Part | When | Words it may use |
|---|---|---|
| Greeting (opener) | First talk break of the session | Fixed day-part line |
| Back-announce (opener) | Most later breaks | Previous title/artist |
| Artist focus (opener) | About 20% of later talk breaks | That artist and title only |
| Station ID (color) | About 20% | The usable display name only |
| Time of day (color) | About 25% | Fixed atmosphere line, no weather |
| Continuation | About two in three, if it fits | Fixed, fact-free line |
| Briefing | While approved cues remain | Cue text from the morning engine, a short lead-in and (if it fits) a sign-off. Item lines are host sentences built only from the title, time phrase, detail, and `From {source}` |
| Closing | Every talk break, last cue | Next title/artist only; one sentence of about 7 words or fewer |

Words come from an `EditorialTone` (default `.warm`). A different tone is a different `EditorialTone` value passed to `DJScriptWriter(tone:)`; the engine does not change and there is no settings UI. Pools never repeat a line until every line in that pool has been used. Text is plain: contractions and em dashes, no SSML (the on-device route adds its own pauses).

The closing line is its **own** `NarrationCue`, attributed `.trackMetadata([next.id])`, so `VoiceRenderer.mayLeaveDevice` gates it per cue exactly like the main segment. On a library-seeded station every cue, the closing included, is on-device only.

### Caps

- Ordinary break: the main segment (everything but the closing line) is capped at `maxTransitionSeconds` (15 estimated seconds). The closing line has its own cap, `maxClosingSeconds` (4 s). When the main segment is over, the continuation is dropped, then the color line; still over, the break is skipped. A closing line over 4 s is not talk-over and counts in the main segment.
- `DJBreakPreparer` applies the same split to measured audio: 15 + 4 s when the break has a talk-over closing line, 15 s otherwise.
- Briefing break: 45 s in total, closing line included. Deferral and drop rules are unchanged.

### Talk-over hook (for the player)

`DJBreak.talkOverCueID` / `PreparedDJBreak.talkOverCueID` mark the closing cue. `PreparedDJBreak` derives:

- `talkOverStartSeconds`: when the closing line's audio starts within the break, measured from the first clip's start: the rendered durations of every clip before it plus `PreparedDJBreak.talkOverGapSeconds` (0.3 s). The 0.3 s is a **speech gap** between two lines, not compensation for player latency.
- `talkOverSeconds`: the closing clip's rendered duration.

Both are nil when there is no closing cue. They are computed from the break's current `cues`/`clips`, so the `DJBreakSession.naturalBoundary` rebuild (stale up-next drop, consent/expiry drops) recomputes them, and clears them when the closing cue was dropped. Clips still play one at a time, back to back; the hook never overlaps two lines of speech. What the hook guarantees: the offset matches the clips as handed out, and the closing cue is the last cue. What it does not do: schedule anything. The main segment may start whenever the player begins the break, and letting the closing line run over the next song's intro (ducking, start timing) is the player's job (Fry). The player must not gate the closing line on a confirmed playback start.

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

Atlas: a break that `takeBreak` already returned is no longer in the preparer. If its cues' `sourceItemID`s were just revoked, stop that speech in the player. Narration cannot stop audio that has left the preparer. Cache expiry and purge stay with Fry.

Atlas: `MusicSearch.live` passes `briefing().forQueue()` into `queueStarted`. The `briefing` argument is required. `PlayerView` passes `LiveQueueBriefing.provider(studio:)`, which reads Connections and briefing preferences when play starts and asks `MorningBriefingEngine` for the handoff. `ApprovedShowHandoff` sends the approved handoff on a morning show and only `carryForward.eligibleNextShow` on a later show. Revoked or unapproved input is nil. A content cue is included only when its Connections row has `state.mayBeNarrated` (`.approved`). Every other `ConnectionItemState` stays in Connections and does not reach the briefing. `ConsentState.notRequested` is not its own item state. Mid-show expiry is not re-checked at `naturalBoundary`; that stays with Fry. `revokedOrUnapproved` only makes `forQueue()` return nil. It does not call `NarrationPurger`.
