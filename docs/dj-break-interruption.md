# DJ break: system interruptions (Siri, calls, alarms)

-Fry. NOT device-validated. Linux/simulator green is not device evidence; needs owner check on the Duo.

## The bug (owner, Duo iPhone)

A Siri interruption in the middle of a DJ break left the DJ voice and Siri talking over each other.

## What the break does now

Core's pure `BreakInterruptionState` (`AeroDJCore/DJ/BreakInterruption.swift`) decides; the app's
`InterludePlaybackAdapter` executes. Tests: `BreakInterruptionStateTests`, `BreakResumePlanTests`
and the `breakInterruption` rows in `P0EventTraceTests` (Linux).

| Notice | Gap break (between songs) | Talk-over (over the outro) |
| --- | --- | --- |
| `.began` | Voice AND break timeline pause: the clip pauses, the timeout, voice ramps and level meter stop, no next line starts. The interrupted line is recorded. | The voice stops (break ends as cancelled, never replayed: the outro moved on). |
| `.ended` + `shouldResume` | One short acknowledgement (`BreakInterruptionAcknowledgement.line`, "Sorry, little interruption there."), then the script again FROM THE INTERRUPTED LINE (that line restarts from its beginning). No acknowledgement ready, an interruption shorter than 2 s, or one already said in this break: the script resumes at once with none. A time check no longer true when it would air is dropped (see below); nothing still true left: the break ends with no acknowledgement and music follows. | nothing |
| `.ended` without `shouldResume` | Stays held: nothing restarts. The rest of the break is dropped (cancelled) so no break stays open; music stays held and the listener's Play resumes it as for any held break. | nothing |
| no `.ended` within 45 s (`maxPausedSeconds`) | As without `shouldResume` (Apple does not promise an `.ended`). | n/a |
| `.began` while acknowledging | Pauses; the interrupted script line is still owed. The acknowledgement counts as said: not played again. | n/a |
| Second `.began` / `.ended`, or any notice with no break on air | No-op. | No-op. |
| Listener pressed Play during the interruption | `.ended` never talks over music: treated as no `shouldResume`. | n/a |

User pause, skip, a new queue, a route removal and a consent revoke still stop a paused break
exactly as before (`stop()`, tagged stops, `haltAudio`).

## Apology rules (#379 N3, Echo)

- No apology for a very short interruption: `BreakInterruptionAcknowledgement.minInterruptionSeconds`
  = 2 s, measured `.began` to `.ended` on the monotonic uptime clock. Under 2 s (a notification
  blip, a Siri press cancelled at once) the script just resumes; 2 s or longer is apologized for.
- At most ONE apology per break (`BreakInterruptionState.apologized`, reset by a new break). A
  second interruption in the same break, or one during the apology itself, resumes without it.
  A short interruption does not spend the break's apology.
- Copy: still the single existing line. A pool of apology lines needs the owner's words; none
  were added.

## Time-sensitive lines on resume (#379 N1, Echo)

A break can stay paused up to 45 s, so a resumed time check could air almost a minute late and
name a time that has passed. On resume, `BreakResumePlan` checks every line from the interrupted
one on at the moment it would START airing (now, plus the kept lines before it), with the SAME
rule the take uses (`DJBreakPreparer.timeCheckStillTrue`: within `timeCheckTolerance` = 90 s of
the air time it was written for, and its "almost / it's / just after" claim about the rounded
time still true). A time check that fails is dropped rather than spoken; the rest of the break
airs. Every line left fails: the break ends (`.finished`, no apology) and music follows. Only
time checks are time-sensitive today; every other line always airs. The plan, the words and the
air time travel with the break (`PreparedDJBreak.timeCheck`, `BreakResumeLine.lines(for:)`),
including through `DJBreakSession`'s consent re-check rebuild.

## P0 diag trace (#379 N2)

`breakInterruption` rows (P0 DIAG builds), counts and codes only, no text:
`kind=resumeDrop|breakDropped reason=stale|allStale|noResume|musicPlaying|pauseExpired after=K
line=L dropped=N timeChecks=T otherCues=O`. `resumeDrop`: lines skipped on resume, the rest aired.
`breakDropped`: everything from line L on did not air (ended without `shouldResume`, the listener
already playing music, no `.ended` within 45 s, or nothing still true).

## Two sources of `.began`

The adapter observes `AVAudioSession.interruptionNotification` itself (applied on the main actor
before the observer returns), and `MusicKitService` still sends its untagged
`stopCurrentInterlude(reason: .interruption)` through its stream. The adapter counts the
notices it saw: a copy it already counted while the interruption is ongoing is idempotent; one
that arrives after the `.ended` (stale) is ignored, so it cannot pause a resumed break; one that
arrives first pauses the break. `DJBreakSession`'s queue-change stop is tagged and keeps the
existing halt. `MusicKitService` (Claude's file) is unchanged.

## The acknowledgement voice

Rendered through the existing `VoiceRenderer` and its fallback order, with NO attribution, so
`VoiceRenderer.mayLeaveDevice` is false and only on-device, free routes are used ($0). It may
sound different from the cloud DJ voice; a voice-matched line would need a paid route and the
owner's OK through Orion. Rendered once per launch at the first break (and cached by the renderer).

## #373 (Echo's lock-screen Skip): Siri is not a user skip

`PlaybackBoundaryDetector` (#373 head 892e386) flags a remote skip only when MusicKit CLEARS the
queue mid-song (`consume`, `remoteSkip = finished != nil && !neverProgressed &&
endedMidSongWithoutCause`, lines 349-366) or REWINDS the entry below the minimum progress after
mid-song progress (`rewoundMidSong`, lines 419-422, set at 468), and `endedMidSongWithoutCause`
(line 227) also refuses any stop after `pausedByApp(.systemInterruption)` (line 198). A Siri duck
keeps the song playing; a Siri system pause keeps the entry loaded and the playhead held, which
is neither shape. This change pauses and resumes only our own AVAudioPlayer and never touches
MusicKit. `InterludePlaybackAdapter.isHeldByInterruption` is a read-only `@Published` flag Echo
can consume if a future shape needs it.

## Why Siri may not have stopped the voice before (hypothesis, not device evidence)

The app's session is `.playback` with `.mixWithOthers` (`AppAudioSessionConfig.mixesWithOthers`);
the talk-over duck is mixable too. Apple says a session is interrupted when a competing session
is not mixable with it; a mixable session may get no `.began` at all. If the Duo trace (P0 DIAG,
`interruption` rows) shows no `.began` for Siri, this fix will not fire for Siri and the category
question goes to Orion (out of scope here).

## Device checklist (owner, Duo)

1. Mid gap break, line 2+: hold the side button for Siri. Voice stops at once; Siri is alone.
2. Dismiss Siri (after 2 s or more): "Sorry, little interruption there.", then the interrupted line from its start, then the rest.
   A Siri press cancelled in under 2 s: no apology, the line just resumes.
3. Repeat with a phone call declined/ended: same; a call that ends without resume: break stays silent, music held until Play.
4. Siri during the acknowledgement: pauses; after Siri, NO second acknowledgement, the owed line. A second Siri later in the same break: no apology either.
5. Siri during a talk-over: the voice stops and does not come back; music continues.
6. P0 trace: `interruption` rows present for Siri (if not: the mixWithOthers hypothesis above).
7. Siri over a time-check line, held ~45-60 s: the time check is not spoken on resume (P0 row `kind=resumeDrop reason=stale timeChecks=1`).
