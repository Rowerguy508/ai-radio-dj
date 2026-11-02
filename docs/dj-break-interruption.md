# DJ break: system interruptions (Siri, calls, alarms)

-Fry. NOT device-validated. Linux/simulator green is not device evidence; needs owner check on the Duo.

## The bug (owner, Duo iPhone)

A Siri interruption in the middle of a DJ break left the DJ voice and Siri talking over each other.

## What the break does now

Core's pure `BreakInterruptionState` (`AeroDJCore/DJ/BreakInterruption.swift`) decides; the app's
`InterludePlaybackAdapter` executes. Tests: `BreakInterruptionStateTests` (Linux).

| Notice | Gap break (between songs) | Talk-over (over the outro) |
| --- | --- | --- |
| `.began` | Voice AND break timeline pause: the clip pauses, the timeout, voice ramps and level meter stop, no next line starts. The interrupted line is recorded. | The voice stops (break ends as cancelled, never replayed: the outro moved on). |
| `.ended` + `shouldResume` | One short acknowledgement (`BreakInterruptionAcknowledgement.line`, "Sorry, little interruption there."), then the script again FROM THE INTERRUPTED LINE (that line restarts from its beginning). No acknowledgement ready: the script resumes at once. | nothing |
| `.ended` without `shouldResume` | Stays held: nothing restarts. The rest of the break is dropped (cancelled) so no break stays open; music stays held and the listener's Play resumes it as for any held break. | nothing |
| no `.ended` within 45 s (`maxPausedSeconds`) | As without `shouldResume` (Apple does not promise an `.ended`). | n/a |
| `.began` while acknowledging | Pauses; the interrupted script line is still owed. | n/a |
| Second `.began` / `.ended`, or any notice with no break on air | No-op. | No-op. |
| Listener pressed Play during the interruption | `.ended` never talks over music: treated as no `shouldResume`. | n/a |

User pause, skip, a new queue, a route removal and a consent revoke still stop a paused break
exactly as before (`stop()`, tagged stops, `haltAudio`).

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
2. Dismiss Siri: "Sorry, little interruption there.", then the interrupted line from its start, then the rest.
3. Repeat with a phone call declined/ended: same; a call that ends without resume: break stays silent, music held until Play.
4. Siri during the acknowledgement: pauses; after Siri, acknowledgement again, then the owed line.
5. Siri during a talk-over: the voice stops and does not come back; music continues.
6. P0 trace: `interruption` rows present for Siri (if not: the mixWithOthers hypothesis above).
