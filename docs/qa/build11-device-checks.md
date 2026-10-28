# Build 11 device checks (physical Duo)

> **On hold until Experiment A/B.** Per the owner's P0 Playback Recovery Directive, #125 is on
> hold. Run [p0-direct-mode-experiments.md](p0-direct-mode-experiments.md) first: Experiment A
> (MusicKit Direct Mode) and then the layer matrix B. This script runs only after both pass, and
> its strings will be re-verified on #125's final head before then. -Fry

Scope: [#125](https://github.com/Rowerguy508/ai-radio-dj/pull/125) at `cbd9fa2`, the build 10 no-audio P0 fix.
Every log string below was grepped from the code at `cbd9fa2` (see the appendix). The overlay
is TEMPORARY (`P0TapDiagnostics`, removal tracked by #121). "Fixed" is decided only by this run
on the physical Duo; simulator or CI results don't count. -Fry

## How to read the overlay

The yellow overlay sits bottom-left on the player screen, ignores touches, and is in TestFlight builds.

- Header: `TEMPORARY P0 diagnostics (remove: #121)`.
- Each ring line has the form `+<ms>ms a<attempt> <tag> <detail>`, for example
  `+849ms a1 play.returned status=paused`. `<ms>` is measured from the latest song tap in
  search results. Lines recorded before the first tap show `pre-tap`, and lines before any
  attempt show `a-`.
- The ring keeps only the **last 10 lines**. Take a screenshot as soon as the lines you need
  are on screen, and take more screenshots as new lines arrive. Don't wait for a step to finish.
- 3 s after a tap, a reading block appears with `transport=`, `player=`, `session=`,
  `refused/paused by:` and `play error:`. Before that it shows `reading at 3 s…`.
- An error line has the detail `error`, and the `play error:` row shows
  `<tag> a<N>: TEMPORARY <type> <domain> code <n>`.

Some lines get to the main actor through a `Task` hop: `session.interruption.began`,
`session.interruption.ended`, `session.routeChange`, `session.mediaServicesWereReset` and
`speech.render.begin`. They can land a line or two away from the matching
`interruption.*` line. Read the order of the `interruption.*` lines, not of the
`session.interruption.*` lines.

## Setup

1. Install build 11 from TestFlight. Check that the build number is 11 on the TestFlight page.
2. Make sure there's no other audio playing (no Music app or podcast), Bluetooth is off and
   the volume is up. Use the device speaker.
3. Have a second phone that can call the Duo (needed for step D).
4. Force-quit AeroDJ from the app switcher before step A.

## A. Cold launch, then tap a song (the P0)

1. Cold-launch AeroDJ and open a station. Turn commentary **off** for this step, so no DJ break can account for a pause.
2. Search for a song and tap a result. Take screenshots right away and again at the 3 s reading.

**Pass:**
- Sound from the speaker within about 2 s of the tap.
- `session.setCategory playback/default mix=true`, showing as `pre-tap` or early in the ring.
  It's recorded once per process, at authorization, so it's there only after a cold launch. If
  10 newer lines have already pushed it out, force-quit and repeat with a quicker screenshot.
- `session.setActive.skipped owner=musicKit` for the attempt.
- `play.returned status=<…>` for the same attempt. Any status is fine. On build 10 it read
  `status=paused`.
- If `interruption.deferred.selfStart call=false break=false` appears, a later line for the
  same attempt must be `interruption.discarded.musicPlaying`.
- The 3 s reading shows `transport=playing player=playing`.

**Fail (each one):**
- No sound, or sound only after a second tap.
- `session.setActive active=true`, which means the old activation path ran.
- `session.setCategory playback/default mix=false`.
- `pause.forBreakOrSystem` in this attempt (commentary is off, so nothing should pause the player).
- `interruption.applied call=false break=false` in this attempt with no real call or Siri.
- `interruption.deferred.selfStart` followed by `interruption.deferred.applied count=…`
  instead of `interruption.discarded.musicPlaying`.
- Any `error` line: `session.setCategory.threw`, `prepareToPlay.threw`, `play.threw`,
  `tapPlay.threw` or `tapResolve.threw`.
- `pause.playIfStillAllowed.held`, `pause.pollRemoteGate.held` or `confirm.reportedNoPause`.

Other expected lines: `playerView.appear station=<n>`, `tap station=<n> commentary=<name>`, `tap.station snapshotStation=<same|other|none>`,
`attempt.begin queueChange=true`, and `queue.loaded index=0 autoplay=true`.

## B. Commentary on: a song ends naturally into a DJ break

1. Turn commentary on and tap a song. Pick a short one, or skip to near the end of a song with
   the scrubber if the build allows it. Don't use Skip, because a skip never triggers a break.
2. Let the song end on its own. Listen through the DJ line and into the next song.
   Take screenshots during the break and right after the next song starts.

**Pass:**
- Exactly one DJ line, with no speech over music: the old song isn't playing under it, and the
  next song doesn't start under it.
- The break lines in order: `pause.forBreakOrSystem` (expected here, because the break pauses
  the player), then `break.audio.started`, then `session.releasedAfterBreak`.
- After that, `attempt.begin queueChange=false`, `queue.loaded index=<n> autoplay=true`,
  `session.setActive.skipped owner=musicKit` and `play.returned status=<…>` for the new attempt.
- The next song is audible.
- `djClip.stop.beforeRelease` appears only if the break timed out or its clip failed to decode.
  If you see it, note it. It's still a pass if the clip went quiet before the next song.

**Fail (each one):**
- `session.release.threw` (detail `error`). The session stayed active after the break.
- Two DJ lines for one song end, or speech overlapping either song.
- Silence after the break, or `startNextTrack.threw`, `resumeIfAllowed.refused` or
  `confirm.reportedNoPause` for the new attempt.
- `interruption.applied call=false break=…` around the break with no real call or Siri.

`speech.render.begin` (the line was being rendered) can show up before the break. It's not a fail.

## C. Lock-screen pause and play

1. With a song playing (after A), lock the Duo.
2. Press Pause on the lock screen. Wait 5 s. Press Play.
3. Unlock and take a screenshot.

**Pass:** audio stops on Pause and comes back on Play. The ring shows `remote.pause` and then
`pause.user`, and later `remote.play`, `attempt.begin queueChange=false` and
`play.returned status=<…>`. If the overlay was in the toggle path instead, it shows
`remote.toggle` followed by the same lines.

**Fail:** Play doesn't bring audio back, or `resume.refused`, `resume.threw` or
`pause.pollRemoteGate.held` appears after `remote.play`.

## D. Phone call: real call applied, lock-screen Play doesn't start audio

1. Play a song and let it run for at least 5 s, so it's past the start window.
2. Call the Duo from the second phone and answer it.
3. While the call is connected, lock the Duo and press Play on the lock screen, if the control
   is shown.
4. End the call. Unlock and take screenshots.

**Pass:**
- Music pauses when the call rings. The ring shows `interruption.applied call=true break=false`,
  followed by `pause.forBreakOrSystem`. `session.interruption.began shouldResume=false reason=<n>`
  shows up next to them.
- Lock-screen Play during the call gives no music audio while the call is connected. You'll see
  `remote.play`. If `play.threw` or `confirm.reportedNoPause` follows, that's expected here.

**Fail:**
- Music keeps playing under the ringtone or the call.
- Music is audible during the call after lock-screen Play.
- No `interruption.applied` line for the call.

**Note, report but not a playback fail:** `interruption.applied call=false` with the pause still
happening means `CXCallObserver` hadn't seen the call yet when `.began` arrived. Send the frame.

If the call lands during a start instead, inside the window, expect
`interruption.deferred.selfStart call=…` followed by `interruption.deferred.applied count=<n> call=true`.
That's also a pass, as long as music pauses.

## E. Siri during a start leaves audio paused

1. Pause playback. Tap a song, and within about half a second press and hold the side button
   to invoke Siri. Ask something short, for example "what time is it".
2. Dismiss Siri. Don't press Play. Wait 10 s and take screenshots.

**Pass:** no music plays while Siri is up. One of these shows for the attempt:
- `interruption.deferred.selfStart call=false break=false`, then by the 8 s report at the latest,
  `interruption.deferred.applied count=<n> call=false`, and `pause.forBreakOrSystem`.
  `confirm.reportedNoPause` is expected alongside it.
- Or, if Siri landed after the window: `interruption.applied call=false break=false`, then `pause.forBreakOrSystem`.

If Siri didn't actually interrupt playback and the song played, you'll see
`interruption.discarded.musicPlaying` or no interruption lines at all. That run is
**inconclusive**, not a pass or fail. Repeat it with Siri invoked sooner.

**Fail:** music plays while Siri is listening or speaking.

## F. Second tap during the spinner; Stop after 8 s

1. Tap a song. While the transport shows the spinner, tap the transport button again.
   **Pass:** nothing changes, no pause and no new attempt, and the ring shows
   `transport.tapIgnored.preparing` with the same attempt number and no new `attempt.begin`.
2. Stalled start. This only happens if the start stalls, for example on a weak network or in
   airplane mode right after the tap. **Pass:** about 8 s after the tap, the transport button
   becomes Stop and `confirm.reportedNoPause` appears. Tapping Stop logs
   `transport.cancelTimedOutStart`, then `pause.user`, and audio stays off.
   If the start doesn't stall, mark F2 as **not exercised**. Don't count it as a pass.

**Fail:** the second tap pauses or restarts the song, the spinner never turns into Stop after
8 s of a stalled start, or audio starts after you tap Stop.

## What to send back

For each step, A through F:
1. Pass, fail, inconclusive or not exercised, plus a one-line note on what you heard.
2. The **raw overlay screenshots**, every frame you took, in order. Don't retype the lines.
   Crop each one to the AeroDJ screen first, so no caller ID, notification, Siri text or status
   bar is shared. Keep the overlay lines and the attempt numbers whole.
3. The attempt numbers (`a<N>`) for the tap you're reporting. If you repeated a step, give the
   attempt number of each try.
4. The 3 s reading block for A, and the `play error:` row if it isn't `none`.

Don't send screen recordings with song titles, account details or notifications showing.
The overlay never shows titles, IDs or subscription details.

## Appendix: where each string comes from (at `cbd9fa2`)

Verified with `rg -n` on `cbd9fa2`. MKS is `ios/AeroDJ/MusicKitService.swift`, and IPA is
`ios/AeroDJ/InterludePlaybackAdapter.swift`.

| Overlay tag / detail | Call | file:line |
|---|---|---|
| `session.setCategory` `playback/default mix=<Bool>` | `record` | MKS:806 |
| `session.setCategory.threw` | `recordPlayError` | MKS:810 |
| `session.setActive.skipped` `owner=musicKit` | `record` | MKS:867 |
| `session.setActive` `active=true` | `record` | MKS:873 |
| `session.setActive.threw` | `recordPlayError` | MKS:876 |
| `session.releasedAfterBreak` | `record` | MKS:886 |
| `session.release.threw` | `recordPlayError` | MKS:889 |
| `prepareToPlay.threw` | `recordPlayError` | MKS:831 |
| `play.returned` `status=<playing\|paused\|stopped\|interrupted\|…>` | `record` | MKS:841 (names: `P0TapDiagnostics.swift` `statusName`) |
| `play.threw` | `recordPlayError` | MKS:844 |
| `pause.playIfStillAllowed.held` | `recordRefusal` | MKS:852 |
| `attempt.begin` `queueChange=<Bool>` | `record` | MKS:676 |
| `interruption.deferred.droppedByNewStart` | `record` | MKS:672 |
| `interruption.deferred.selfStart` `call=<Bool> break=<Bool>` | `record` | MKS:692 |
| `interruption.ignored.pairedEnd` | `record` | MKS:695 |
| `interruption.applied` `call=<Bool> break=<Bool>` (only for `.began`) | `record` | MKS:702 |
| `interruption.deferred.applied` `count=<n> call=<Bool>` | `record` | MKS:713 |
| `interruption.discarded.musicPlaying` | `record` | MKS:655 |
| `confirm.latePlaying` | `record` | MKS:662 |
| `confirm.reportedNoPause` | `recordRefusal` | MKS:1054 |
| `startFailure.stale` | `record` | MKS:640 |
| `boundary.noProgressEnd` | `recordRefusal` | MKS:629 |
| `pause.pollRemoteGate.held` | `recordRefusal` | MKS:567 |
| `pause.forBreakOrSystem` | `record` | MKS:322 |
| `pause.user` | `record` | MKS:230 |
| `transport.cancelTimedOutStart` | `record` | MKS:304 |
| `transport.tapIgnored.preparing` | `record` | MKS:316 |
| `tapPlay.superseded` | `record` | MKS:213 |
| `tapPlay.threw` | `recordPlayError` | MKS:216 |
| `resume.refused` | `recordRefusal` | MKS:263 |
| `resume.threw` | `recordPlayError` | MKS:275 |
| `resumeIfAllowed.notResuming` | `record` | MKS:337 |
| `resumeIfAllowed.startInFlight` | `record` | MKS:343 |
| `resumeIfAllowed.refused` | `recordRefusal` | MKS:352 |
| `resumeIfAllowed.threw` | `recordPlayError` | MKS:362 |
| `stop.skipPastEnd` | `record` | MKS:381 |
| `queue.loaded` `index=<n> autoplay=<Bool>` | `record` | MKS:413 |
| `startTrack.heldStart` | `recordRefusal` | MKS:428 |
| `startNextTrack.staleBoundary` | `record` | MKS:463 |
| `startNextTrack.threw` | `recordPlayError` | MKS:474 |
| `remote.play` | `record` | MKS:961 |
| `remote.pause` | `record` | MKS:970 |
| `remote.toggle` | `record` | MKS:978 |
| `session.mediaServicesWereReset` | `P0TapDiagnosticsBridge.record` | MKS:1103 |
| `session.interruption.began` / `.ended` `shouldResume=<Bool> reason=<n>` | `P0TapDiagnosticsBridge.record` | MKS:1123, MKS:1125 |
| `session.routeChange` `reason=<n>` | `P0TapDiagnosticsBridge.record` | MKS:1134 |
| `djClip.stop.activeBreak` | `record` | IPA:199 |
| `djClip.stop.halt` | `record` | IPA:268 |
| `break.audio.started` | `noteBreakStarted` | IPA:293 → `P0TapDiagnostics.swift:102` |
| `djClip.stop.beforeRelease` (timeout IPA:287, decode error IPA:376) | `record` | IPA:342 |
| `speech.render.begin` | `speechRenderBegan` | `ios/AeroDJ/OnDeviceSpeechProvider.swift:72` → `P0TapDiagnostics.swift:97` |
| `tap.station` `snapshotStation=<same\|other\|none>` | `record` | `ios/AeroDJ/PlaybackActions.swift:134` |
| `tapResolve.threw` | `recordPlayError` | `ios/AeroDJ/PlaybackActions.swift:141` |
| `playerView.appear` `station=<n>` | `record` | `ios/AeroDJ/PlayerView.swift:53` |
| `tap` `station=<n> commentary=<name>` | `record` in `markTap` | `P0TapDiagnostics.swift:62` |
| line format `+<ms>ms a<n> <tag> <detail>`, `pre-tap`, `a-` | overlay | `P0TapDiagnostics.swift:173` |
| ring capacity 10 | `TapDiagnosticsLog(capacity: 10)` | `P0TapDiagnostics.swift:38` |
| recordPlayError detail `error` | `recordPlayError` | `P0TapDiagnostics.swift:79` |
| gate window 500 ms after `play()` returns | `windowAfterPlayReturn` | `ios/AeroDJCore/Sources/AeroDJCore/Playback/SelfStartInterruptionGate.swift:29` |
