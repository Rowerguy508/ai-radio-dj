# DJ talk-over (flagged prototype)

Owner: Fry (Studio UI and Privacy). Status: **prototype, flag OFF by default, not validated on a
physical device.** Everything below about how it sounds on an iPhone or the Duo is a prediction to
be checked in the owner's TestFlight A/B run (checklist at the end).

Depends on Echo's talk-over hook, PR #209 at `d2b1933`: `PreparedDJBreak.talkOverStartSeconds`,
`talkOverSeconds` and `talkOverCueID`. This branch is stacked on that commit and does not edit
Echo's files or `VoiceRendering.swift`.

## What it does

A radio-style break. The outro of song k ducks under the DJ's MAIN line (up to 15 s). The closing
line (up to 4 s, its own cue, attributed to song k+1) plays over the start of song k+1. As the
closing line ends, the duck releases and the new song swells to full level.

If any precondition fails, the break plays exactly as today: in the gap, with the music stopped.
Talk-over never makes a break that would have played *not* play, except when a seek or skip
cancels a voice that has already started (as a skip does today).

## Platform findings (Apple docs)

| Fact | Consequence | Source |
|---|---|---|
| `ApplicationMusicPlayer` has no volume or gain API. | No custom duck curve on the song. The only lever is the audio session. | [ApplicationMusicPlayer](https://developer.apple.com/documentation/musickit/applicationmusicplayer), [MusicPlayer](https://developer.apple.com/documentation/musickit/musicplayer) |
| `.duckOthers` lowers *other* audio while our session is active. It implies `.mixWithOthers`. Apple frames ducking as brief ("a few seconds"). | Depth and ramp are system-fixed (about −15 dB, a short ramp, not measured here). Ducking starts on `setActive(true)` and ends on deactivation. | [duckOthers](https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/duckothers), [mixWithOthers](https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/mixwithothers) |
| `setActive(false, options: .notifyOthersOnDeactivation)` unducks others. | The swell is the system's unduck ramp, triggered when the closing line ends (`completeNarration` → `releaseSessionAfterBreak`). | [notifyOthersOnDeactivation](https://developer.apple.com/documentation/avfaudio/avaudiosession/setactiveoptions/notifyothersondeactivation) |
| `ApplicationMusicPlayer` plays through the system music process, outside our app's session (repo evidence: Build 10 P0 on the Duo, where our non-mixable `setActive(true)` was interrupted 1 ms after music started). | `.duckOthers` *may* duck our own music player. **Evidence is mixed; see "Does `.duckOthers` duck our own music?". This is the first device check.** | [ApplicationMusicPlayer](https://developer.apple.com/documentation/musickit/applicationmusicplayer) |
| `AVAudioPlayer.play(atTime:)` with `deviceCurrentTime` schedules a clip precisely. `setVolume(_:fadeDuration:)` ramps a clip. | The 0.3 s speech gap before the closing line is scheduled by the player. A seek mid-voice fades the voice out over 0.25 s. Per-clip `volume` matches mixed voices. | [play(atTime:)](https://developer.apple.com/documentation/avfaudio/avaudioplayer/play(attime:)), [deviceCurrentTime](https://developer.apple.com/documentation/avfaudio/avaudioplayer/devicecurrenttime), [setVolume(_:fadeDuration:)](https://developer.apple.com/documentation/avfaudio/avaudioplayer/setvolume(_:fadeduration:)) |
| `MusicPlayer.Transition` (`.crossfade`, iOS 18+) applies between queue entries. | Our queue is one song at a time (MusicKitService), so it does not apply today. It is a possible future lever for Atlas's queue; it is not used here. | [MusicPlayer.Transition](https://developer.apple.com/documentation/musickit/musicplayer/transition) |
| `play()` start latency is variable. `prepareToPlay()` exists, but the repo's queue swap makes it per-song. | Song k+1's `play()` is called early by a measured latency L. | [prepareToPlay()](https://developer.apple.com/documentation/musickit/musicplayer/preparetoplay()) |
| Interruptions and route changes arrive as session notifications. | Existing handlers already stop the break with reason tags; talk-over listens to the same stop path. | [Handling audio interruptions](https://developer.apple.com/documentation/avfaudio/handling-audio-interruptions), [Responding to route changes](https://developer.apple.com/documentation/avfaudio/responding-to-audio-route-changes) |
| `MusicKit.Song` carries `duration` but no intro, outro or cue points. | The outro overlap is capped by a share of the duration. Intro length is unknown, so the closing line is capped at 4 s. | [Song](https://developer.apple.com/documentation/musickit/song) |

## Does `.duckOthers` duck our own music? (evidence, not proof)

**Short answer: unknown until the owner listens. Confidence that it works: about 40% (low to
medium).** Nothing here has run on a device.

What we found (Oct 2026):

| Source | What it says | Weight |
|---|---|---|
| Apple, [`duckOthers`](https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/duckothers) | Ducking reduces the volume of other audio sessions while our session plays. No word on `ApplicationMusicPlayer`. | Defines the lever, not the case. |
| Apple, [`ApplicationMusicPlayer`](https://developer.apple.com/documentation/musickit/applicationmusicplayer), [WWDC26 "Integrate MusicKit into your app"](https://developer.apple.com/videos/play/wwdc2026/254/) | App player vs system player. No volume API, no word on ducking. | Neutral. |
| Apple DTS on [rdar://28431676](https://openradar.appspot.com/28431676) (MPMusicPlayerController.applicationMusicPlayer) | Calls it "remote playback" that interrupts the app's own session unless the session mixes. | **For:** the music is a *separate* session from ours, so "other" can include it. |
| Repo, Build 10 P0 (`AudioSessionActivation`, -Atlas, Duo) | Our non-mixable `setActive(true)` was interrupted 1 ms after `ApplicationMusicPlayer` started. | **For:** same conclusion, on our own device. |
| Apple Developer Forums, MusicKit thread "Ducking MusicKit output when playing another sound" ([tag page](https://developer.apple.com/forums/tags/musickit?page=6), May 2025, no answer) | `.playback`/`.spokenAudio` with `[.duckOthers, .mixWithOthers]` then `setActive(true)` and `AVAudioPlayer`: "`.duckOthers` is not ducking the Application Music Player output". | **Against.** |
| Stack Overflow 78212018 (2024, [mirror](https://devhide.com/how-do-you-control-the-volume-of-ios-applicationmusicplayer-78212018)) | `.duckOthers` "doesn't have any effect on the music player's volume". | **Against.** |
| [Stack Overflow 76907591](https://stackoverflow.com/questions/76907591) (Aug 2023, the asker's own answer) | `setActive(false)` → `.playback` with `[.duckOthers]` → `setActive(true)`, then `AVSpeechSynthesizer`: "It lowers music played using MusicKit played in the same program." | **For.** The one positive report. |
| Apple Forums, Mac Catalyst | The audio "plays in com.apple.MediaPlayer.RemotePlayerService, not in our process". | Explains why there is no volume API. |

How to read this:
- The negative reports change the category and call `setActive(true)` on a session that was most
  likely **already active**. Ducking starts on an activation, so that may be a no-op.
- The positive report deactivates first, so its `setActive(true)` really activates.
- Our path is the positive one: since Build 10 the app never activates its session while music
  plays, so `TalkoverAudioSession.duck` makes a real activation.
- That is a plausible explanation, not a proof. iOS versions differ, and there may be no Apple
  statement either way.

**What CI cannot prove.** The simulator cannot play catalog audio: it needs an Apple Music
subscription and a signed-in account, and CI has neither. A simulator test with an `AVAudioPlayer`
stand-in for the music would only show that ducking works between two of our own sessions, which
is not the question. Ducking depth is also not observable through any API. So there is no CI probe;
the proof is the owner's ears.

**On-device probe (DIAG `talkover kind=duckProbe`).** Around the duck activation we log the
session's own report, as codes only:
- `otherAudio` and `secondaryHint` (`isOtherAudioPlaying` and
  `secondaryAudioShouldBeSilencedHint`) **before** `setActive(true)`;
- `activated`;
- `otherAfter` and `hintAfter` right after.

If `otherAudio=true` while only our music is playing, the system counts `ApplicationMusicPlayer`
as another session. That is the precondition for `.duckOthers` to reach it. It does not show the
level. `otherAudio=false` makes a duck very unlikely.

**If it does not duck (fallback, nothing new built).**
- Detection: the owner's A/B listen (checklist step 2), plus `duckProbe otherAudio=false`.
- Action 1, today: the owner turns the toggle OFF. That is exactly today's gap break.
- Action 2, a later PR if wanted: keep only the intro half. Play MAIN in the gap with the music
  paused, as today, and the closing line over the next intro. With no duck, the closing line
  competes with the intro at full level, so this needs its own listen. There is no volume API to
  do better.
- Auto-detecting "no duck" in code is not possible. The level is not observable, and the probe is
  a hint, not a measurement. So there is no automatic switch: a flag default stays the decision.

## Duck depth and curves

- **Song:** system `.duckOthers` depth and ramp, both fixed. We control only *when* the duck starts
  (voice start) and *when* it ends (closing-line end).
- **Voice:** unity gain for a single voice, the same as today. With mixed voices (cloud MAIN plus
  on-device closing line), the gains are attenuate-only toward the quieter clip (target ≤ −20 dBFS
  RMS, max cut 9 dB). Unknown or silent clips stay at unity. `TalkoverLoudness`.
- **Seek cancel:** 0.25 s linear fade on the voice, then halt.

## Timing model (Echo #209 hook)

Echo's numbers, per break:
- `talkOverStartSeconds` = all clips before the closing line + 0.3 s gap.
- `talkOverSeconds` = the closing clip's length.
- Both are nil when there is no closing line → gap break, today's behaviour.

Fry's planner (`TalkoverPlanner.decide`, pure, in AeroDJCore):

```
S = talkOverStartSeconds   C = talkOverSeconds   V = S + C   L = start latency (EMA)
outro overlap O = min(6 s, 10% of song, V, remaining − 1.5 s arm lead, S − L)   need O ≥ 2 s
voice starts at songDuration − O
song k ends at voice + O            → next play() called at voice + (S − L)
next song audible ≈ voice + S       → the closing line starts at voice + S (after the 0.3 s gap)
closing line ends at voice + S + C  → completeNarration → unduck → swell
```

- If the closing line cannot fit (C > 4 s, song k+1 is shorter than 60 s or has an unknown
  duration, or `S − L` would push O under 2 s), the plan drops to **outroOnly**: MAIN over the outro,
  and the next song follows the voice as today.
- If the outro cannot fit (song k is shorter than 60 s, the duration is unknown, V > 20 s, it is too
  late to arm, or O < 2 s), the plan is a **hard break**: the gap break, as today.

### Echo latency question: is the fixed 0.3 s right?

Yes, **as a speech gap**. It is the silence between MAIN and the closing line, and it should stay
0.3 s. It is *not* the player start latency, so it must not try to absorb that. Traces show
`play.returned` at about 232–849 ms, with one 7.2 s outlier. Proposal:

- Call song k+1's `play()` early by **L**. The default is **0.8 s**.
- Measure L per break as the time from `startNextTrack` to `onSongStarted`, and smooth it with an
  EMA (weight 0.3), clamped to 0.3–2.0 s.
- A start more than 1 s late logs `nextStartLate`, and a start too early logs `nextStartEarly`.
- An outlier (7 s) only means the closing line plays over silence and the swell comes late. No
  speech is lost.

Echo does not need to change anything. Keeping 0.3 s inside `talkOverStartSeconds` is fine, because
the planner inserts the gap with `play(atTime:)` rather than expecting it in the audio.

## Fallbacks (all end in today's gap break or today's skip)

| Situation | Result |
|---|---|
| Flag off | Today's code path, unchanged (the coordinator never claims a boundary). |
| Break not rendered at the arm point | Not claimed. The boundary path is unchanged. |
| `talkOverStartSeconds` or `talkOverSeconds` nil | outroOnly or hard break by plan. Nil plus a short song gives a gap break. |
| Closing clip fails to decode | MAIN only (outroOnly). If MAIN fails, the break is skipped, as today. |
| Duck or voice start fails, or the song ends before the voice | The held break plays in the gap. |
| Seek back before the voice | The held break plays in the gap at the end. |
| Seek while speaking, or a skip | The voice fades or stops. The break is dropped (`breakSkipped .cancelled`). |
| Revoke (`sourceRevoked`) | The voice stops and the held break is dropped, never replayed. |
| Interruption (call, Siri) or route removal | The existing reason-tagged stop. A held break that has not been spoken is admitted at the boundary by today's policy. |

## MusicKit interaction

- MusicKitService is untouched.
- The coordinator uses existing API only: `playbackTime`, `isPlaying`, `queue[k+1].duration`,
  `beginInterlude`, `skipInterlude`, `startNextTrack(after:)`, `djStarted`, `completeNarration`,
  and `logBreakSkipped`.
- At the natural end of song k while still speaking, it calls `beginInterlude` (transition → voice),
  so playback state matches what the user hears. It then calls `startNextTrack` at the play cue.
- The adapter never pauses or resumes the music for a talk-over.

## Seek, skip, pause, fold

- Pause, a new queue, or a skip goes through the existing `interlude.stop()` → `userStop` / `skip`.
- Fold on the Duo: the existing fold-safe pause path is a stop like any other. The music is paused
  by the user or system, so `playTalkover` refuses to start (`pausedBySystem`/`mayAutoResume`
  guard).
- Seeks are wired in `AppDependencies.wireSongSeek`.

## Privacy and truthful speaking state

- The same `DJBreakSession.naturalBoundary` admission runs: consent, stale-next and on-device voice
  gates, unchanged.
- The closing line is Echo's own cue with `.trackMetadata([next.id])`, gated per cue through
  `mayLeaveDevice`, so MAIN can be cloud while the closing line is on-device.
- A failed closing line falls back to MAIN only (with a gap break when nothing fits).
- `.speaking` in DJPresentationState is reported only from a real `AVAudioPlayer` start
  (`onPlayback(.started)`). It ends on the real end or stop.
- Caveat: the break is taken up to ~7.5 s before the natural end, so the station's boundary
  bookkeeping runs that much earlier than today.
- DIAG rows carry codes and numbers only: no track names, no text.

## Flag

- `DJTalkoverFlag`. The key is `AeroDJTalkoverEnabled` (UserDefaults); a stored value overrides the
  build default.
- The build default is **ON only when `AERODJ_OWNER_AB` is defined**. That happens only in a
  TestFlight workflow_dispatch with `owner_ab: true`; see
  `ios/scripts/testflight-swift-conditions.sh`.
- It is **OFF** everywhere else, including Debug, fixture mode, the test station
  (`buildDefault: false`) and unit tests.
- The on-device toggle "DJ talk-over" is a toolbar button on the Player screen (top right, waveform
  icon, id `owner.talkoverToggle`). It exists **only in an `AERODJ_OWNER_AB` build**
  (`ios/AeroDJ/TalkoverToggle+App.swift`), with or without `p0_diag`. A normal owner build
  (`owner_ab: true`) has it. Every other build compiles `talkoverToggleEntry()` to a no-op.
- `p0_diag: true` is optional. It adds only the trace rows below.
- Flipping it ON for everyone after the device test is a one-line change: make
  `DJTalkoverFlag.buildDefault` return `true`. The owner wants it ON once it is device-tested.

## DIAG fields (P0 trace, event `talkover`)

| kind | fields |
|---|---|
| `decision` | `mode` (outroAndIntro/outroOnly/hardBreak), `intro` (skip reason), `outro` (s), `voice` (s), `play` (s after voice start), `unduck` (s), `lat` (L used, s); or `reason` for hard breaks |
| `miss` | `reason` (voiceStartLate, endedBeforeVoice, nextStartLate, nextStartEarly, endAfterPlayCue, voiceEndedFirst), `ms` |
| `cancel` | `reason` (seekOutOfWindow, seekWhileSpeaking, skip, userStop, interruption, routeRemoved, revoked, voiceFailed) |
| `latency` | `measured` (ms), `lat` (new L, ms) |
| `duckProbe` | `otherAudio`, `secondaryHint` (before activation), `activated`, `otherAfter`, `hintAfter` (booleans) |

The same lines go to the unified log (subsystem AeroDJ, category talkover) as `.public`. They hold
numbers and codes only.

## On-device checklist (owner TestFlight A/B; NOT yet run)

Build: workflow_dispatch with `owner_ab: true` (`p0_diag: true` is optional and adds the trace).
Use the iPhone, then the Duo.

1. **Flag**
   - On the Player screen, confirm the "DJ talk-over" toolbar button (waveform icon, top right) is ON by
     default in this build.
   - Turn it OFF and play two boundaries: they must sound exactly like today (gap break, music
     stopped).
   - Turn it back ON.
2. **Duck**
   - At a break, the outro should drop in level as MAIN starts. **If the song does not duck, stop
     here and report it**: `.duckOthers` does not reach `ApplicationMusicPlayer`, and the design
     needs another lever.
   - Note the rough depth and how quickly it drops.
3. **Handover**
   - The outro ends under MAIN. After MAIN there is a short pause (~0.3 s), then the closing line
     plays as song k+1 starts underneath.
   - Listen for: the next song starting well before or after the closing line (DIAG `miss
     nextStartLate`/`nextStartEarly` and `latency measured`), and dead air between songs.
4. **Swell**
   - When the closing line ends, song k+1 rises to full level. Note whether it is smooth or a jump.
   - Song k+1 must never stay ducked after the voice: check at full volume for 10 s.
5. **Mixed voices**
   - With a cloud MAIN and an on-device closing line, the two voices should sound about equally
     loud.
6. **Fallbacks**
   - A short song (< 60 s) or a long MAIN → `decision hardBreak` and a gap break.
   - Seek back before the voice → gap break at the end.
   - Seek during the voice → the voice fades out quickly and the next song plays normally.
   - Skip during the voice → the voice stops and the next song plays.
7. **Interruptions**
   - Siri during the voice, and a phone call during the voice: the voice stops (DIAG `cancel
     interruption`), and the music behaves as today afterwards.
   - Unplug the headphones or turn off Bluetooth during the voice → `cancel routeRemoved`, with no
     voice from the speaker.
   - **Route loss in the intro window (Echo).** Unplug, or lose the Bluetooth route, between
     S − L (the next song's `play()`) and the end of the closing line, while song k+1 is starting
     under the voice. Expected:
     - the voice stops through the tagged route-change stop (`cancel routeRemoved`);
     - the duck is released (session deactivated with notify);
     - song k+1 continues or pauses per the existing route policy, and nothing stays ducked
       (check for 10 s at full volume);
     - the next boundary still arms.
     - Modelled on Linux by `DJTalkoverBookTests.testRouteLossDuringTheIntroWindowStopsTheVoiceAndRetires`
       (bookkeeping only; the audio is unproven).
8. **Duo fold** during the voice and during the outro: no stuck duck, and the state is consistent
   on unfold.
9. **Studio UI**
   - "Speaking" shows only while the voice is audible, and clears when the closing line ends.
10. **Privacy**
    - Revoke a source used in the upcoming break during the outro → `cancel revoked`, and the break
      never plays later.
11. **Export the trace.** Confirm the `talkover` rows contain only codes and numbers.

## Bookkeeping fixes (#210 review)

- **Atlas, blocker:** the run was never reset, so talk-over fired once per launch. `TalkoverBook`
  (AeroDJCore) now retires the run on every terminal path: done, fallback, cancel, miss, and a next
  song that never starts.
  - Tests: `DJTalkoverBookTests.testThreeConsecutiveTalkoversEachArmAndComplete`,
    `testFallbackToGapBreakThenTheNextBoundaryStillArms`, `testEveryCancelRetiresTheRun`,
    `testSeekCancelsRetireAndTheNextBoundaryArms`, `testTimingMissStillRetires`,
    `testNextSongThatNeverStartsDoesNotBlockLaterBoundaries`.
- **Atlas, should fix:** owned boundaries are keyed by (index, track id). A skip releases its key.
  A queue replacement (index goes back, or the same index holds another track) clears them all.
  - Tests: `testSkipReleasesTheSkippedBoundary`,
    `testQueueReplacementClearsOwnedSoIndexZeroOfTheNewQueueArms`,
    `testSameIndexWithAnotherTrackIsAReplacement`,
    `testTheSameSongStartingAgainFreshensItsBoundary`.
- **Sentinel, spending:** after the early take, a duplicate `onSongStarted(k)` re-ran prepare and
  rendered a second cloud break. `DJBreakPreparer` now marks k as taken, and only a new queue
  (`cancelAll()`) clears it.
  - Test: `DJBreakSessionTests.testDuplicateSongStartAfterEarlyTakeNeverPreparesASecondBreak`
    (prepare count 1; it fails with 2 without the fix).

- **Atlas, blocker (refill during the closing line):** a refill reloads the queue and starts index 0
  while the closing line speaks. That run's latency sample can never be taken, so it used to block
  arming for n − 2 songs. A run that outlives its queue is now marked (`runFromOldQueue`) and
  retires as soon as its voice ends, without a sample (L unchanged) and without an index match.
  The coordinator takes no latency sample across a replacement (`isReplacement`). A voice that
  fails mid-line now ends the run too (`voiceFailed`), so it never stays `.speaking`.
  - Tests: `DJTalkoverBookTests.testRefillDuringTheClosingLineRetiresWhenTheVoiceEndsAndTheNewQueueArms`,
    `testRefillDuringTheClosingLineThenTheVoiceFailsOrIsCancelledStillRetires`,
    `testANewRunAfterAnOldQueueRunIsNotMarkedStale`.
- **Sentinel, non-blocking (station change):** `cancelAll(except:)` now clears stale taken marks as
  a new queue does, but keeps the mark on a kept boundary. That one is the playing song's and may
  already have been taken early, so clearing it would re-open the duplicate render.
  - Test: `DJBreakSessionTests.testStationChangeAfterATakeClearsStaleMarksAndTheNewStationPreparesOnce`.

## Risks and unknowns

- Whether `.duckOthers` ducks our own `ApplicationMusicPlayer` (the critical check; about 40%,
  see the evidence section).
- Changing the session category while music plays may glitch the music; listen for a click at
  voice start or end.
- Apple's guidance frames ducking as brief, and our voice can last up to ~19 s.
- Start latency varies (one 7 s outlier). The EMA adapts but does not prevent a single late start.
- Catalog `duration` can differ from the real end. A real end earlier than planned gives
  `endedBeforeVoice` and a gap break; a later one gives `endAfterPlayCue`.
- The intro length is unknown, so the closing line may cover vocals in songs with short intros.
  This is capped at 4 s.
- The interruption policy sees `breakActive` during the intro overlap, which is slightly different
  from today.
- A fade that finishes naturally reports `.finished` (minor).
- The owner-only toggle (`#if AERODJ_OWNER_AB`) is compiled only by the TestFlight owner_ab
  build. CI checks the build settings for that flag, not an app build with it.
- App-target code is compiled only by iOS CI. Linux `swift test` covers only the AeroDJCore planner,
  state machine, loudness, seam and logs.
