# Milestone B device test script (iPhone Duo)

**Nothing in this document has been executed on a device, in Simulator, or in Console.** It was written by reading the source. This VM has no Xcode and no iPhone. A row in the results table stays empty until the owner fills it in from a run they performed.

This is the owner's procedure for the Milestone B audio gate: one full song, a DJ break only after a real end, the next song once, a pause in the last 1.5 seconds, a call, AirPods, and a consent revoke during speech. Simulator tests named below do not replace these steps. `docs/playback-boundary-handoff.md` already says audible behavior is a device gate. `docs/ENGINEERING_STANDARDS.md` is **not** on `integration/device-duo` (it is also absent from `main`). The copy on `chore/github-engineering-standards` (`33b5a76`) requires manual device evidence for hardware and audio features. That is the rule this script is for.

## Build under test

Record the exact SHA you install. A branch name is not enough. Three heads existed when this script was written, and they do not behave the same way.

| Tree | SHA | What that build actually logs and does |
|---|---|---|
| `integration/device-duo` (PR #58) | `939c34e8da505ca91d26b30b52f696974b06c1c5` | One logger: subsystem `com.aerodj.app`, category `runtime`. `setActive(true)` runs at MusicKit authorization. The boundary detector has no position signal and no `pausedByApp()`. |
| PR #64 `fix/audio-observer-isolation` | `b69581bb48b06b9b39220a36bd19bd8f04aaa5d1` | Category `playback` on `MusicKitService`. `setActive` runs on the play path. `pausedByApp()` runs before a user pause and before `pausePlayerForBreak()` (calls and AirPods use that pause). A pending song start calls `onSongStarted` and does **not** log `song started`. |
| PR #67 `atlas/audio-reliability-tests` | `3a6608529807bef2286077aef779b30ba127ba15` | Same tree as `216c53f` (`3a66085` only re-queues CI). Category `playback` on `MusicKitService` and `InterludePlaybackAdapter`. Deferred starts log `song started`. `stopCurrentInterlude(reason:)` exists and logs `interlude stop reason=sourceRevoked`. This SHA does **not** contain `b69581b`. A pause, call, or AirPods removal inside the last 1.5 s of a song is still reported as a natural end. |

There is no single SHA that has both the pause guard (`b69581b`) and the interlude-stop log (`3a66085`). Until those are on one build, install `3a66085` for the log lines below, and treat a break that starts after a pause, call, or unplug in the last 1.5 s as a fail of that step, not as a bad procedure.

Fingerprint while other audio is playing (Music, a podcast):

- The other audio keeps playing through the Apple Music prompt and stops only when a station starts. That is `activateAudioSessionForPlayback()` on #64 and #67.
- The other audio stops as soon as authorization succeeds. That is `setActive(true)` inside `configureAudioSession()` on `939c34e`.

## Prerequisites

Do these before the numbered steps. If one is missing, stop and record which one. Do not invent a pass.

1. **Mac and device.** Xcode with XcodeGen 2.46.0 (the version CI pins). The iPhone Duo, unlocked, Developer Mode on (Settings → Privacy & Security → Developer Mode), trusted by this Mac. Deployment target in `ios/project.yml` is iOS 17.0.
2. **Signing.** Team ID only in `ios/Config/Signing.local.xcconfig` (`DEVELOPMENT_TEAM = …`). That file is git-ignored. No certificate, profile, or password goes into git, chat, or the log export. App IDs `com.aerodj.app` and `com.aerodj.app.share`. App Group `group.com.aerodj`. MusicKit enabled on `com.aerodj.app` in the developer portal. Details are in `docs/device-install.md`.
3. **Build configuration.** Scheme `AeroDJ`. Run configuration **Debug**. Launch argument `-AeroDJTestStation YES` (Product → Scheme → Edit Scheme → Run → Arguments). Release builds cannot enter the test station.
4. **Apple Music.** The Apple ID on the Duo has an active Apple Music subscription that can play the catalog. Deny the system prompt on purpose only if you are checking the banner, then grant it before step 1. The banner strings are fixed: "Allow Apple Music to play your station." and "An Apple Music subscription is required."
5. **Consent.** With the test-station argument, fixture consent is granted for fixture sources only. Live mode (no argument) starts every integration at `notRequested` and will read the real calendar. Use the test station for this script. Paid voice stays off (`VoiceBudget` daily cap is $0).
6. **Network.** Catalog search and playback need a working network. Airplane mode is out of scope.
7. **AirPods.** Paired, and the Duo's output route, before steps 7 and 8. A second phone that can call the Duo, for steps 5 and 6. A second recording device, because an iPhone screen recording does not capture speaker or AirPods audio. Point it at the Duo's speaker. For AirPods steps, pull one pod out so the speaker is audible to that recorder, or record the disconnect itself and say so in the notes.
8. **Songs.** In the app, search Apple Music and play a queue of **four** catalog songs. The player loads one song at a time. Talk cadence is 0.3 with at least two songs between breaks, so an eligible boundary is spoken with probability 0.75 (`DJCadence.eligibleBoundaryProbability`). The first miss does not block the later boundaries. Four songs give three chances before the spacing rule matters.

Confirm the launch log before searching (category `runtime`, level `notice`):

```text
runtime mode: testStation, context sources: <count>
```

Without the argument the same line says `runtime mode: live`. `info` is not used for this line because `info` is not persisted.

## Build and install

From a clean checkout of the SHA you recorded:

```sh
git fetch origin
git checkout <SHA>
cd ios
xcodegen generate
open AeroDJ.xcodeproj
```

In Xcode: scheme **AeroDJ**, destination your iPhone, Run configuration **Debug**, argument `-AeroDJTestStation YES`, then Run.

The unsigned device build CI uses is not an install:

```sh
xcodebuild build -project ios/AeroDJ.xcodeproj -scheme AeroDJ \
  -sdk iphoneos -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
```

## How to capture evidence

Start the log and the recording **before** you tap play, and leave both running through the step. Write the device clock time at the start of the recording into the notes so Console timestamps can be lined up with the picture.

**Console.app**

1. Connect the Duo. Select it under Devices.
2. Filter on the subsystem that exists in code: `subsystem:com.aerodj.app`.
3. Categories that exist:
   - `runtime` — `AeroDJApp.swift`, every build in the table above.
   - `playback` — `MusicKitService` on #64 and #67, and `InterludePlaybackAdapter` on #67 only. **`939c34e` has no `playback` category.** Filtering on it there shows nothing, which is expected.
4. There is no category named `handoff`, `audio`, or `interruption`. The signposts named in `docs/playback-boundary-handoff.md` (`handoff.songEnd`, `handoff.breakStart`, `handoff.breakEnd`, `handoff.nextSongStart`) are **not implemented**. Do not search for them and do not treat their absence as a failed filter.

**Lines the playback category actually emits** (quoted as written; values are public numbers):

```text
song started index=<Int> durationSeconds=<seconds or -1>
boundary naturalEnd finished=<Int>
boundary queueEnd finished=<Int>
interlude stop reason=sourceRevoked
```

The last line exists only on `3a66085`, and only if `stopCurrentInterlude(reason: .sourceRevoked)` runs. `939c34e` emits none of the four. #64 `b69581b` emits the first three only when `startTrack` plays immediately; a song that was loaded paused and later resumed does not log `song started` on that SHA.

**Screen recording.** Use the Duo's screen recording plus a second device for the sound. Keep the DJ status and the Play/Pause button in frame. The button label is "Pause" while `transport` is `.playing` and "Play" while it is `.paused` or `.stopped`. On Air is the badge text "On Air". It is allowed only while speech is audible.

**What you may keep.** Indices, durations, the words `true`/`false`, and the fixed UI sentences below. Do not put song titles, artist names, cue text, catalog ids, account names, or tokens into the results table or a PR. If an export contains them, delete those lines before you link it. Describe timings in the notes.

The player polls MusicKit once a second (`Timer` interval `1.0`). A boundary log can trail the last audible sample by about that long. That delay is the poll, not by itself a second song.

## Steps

Score each step against the **expected result**. The "If the log cannot prove it" line is a gap in the current source, not a pass.

### 1. A full song plays to its natural end

**Action.** Start the four-song queue. Do not pause, skip, lock the screen, or switch apps. Let song 0 play until it ends on its own.

**Expected result.** Song 0 is heard through its last note. The Play/Pause control stays "Pause" for the whole song. No DJ speech starts in the middle of the song. When it ends, the next thing is either a DJ break (step 2) or song 1. Song 0 does not restart.

**Evidence.** Recording from the first chorus through the end. On a build with category `playback`: one `song started index=0 durationSeconds=…` near the start, and no `boundary` line until the song is over. If `durationSeconds=-1`, MusicKit did not report a duration. The app then does not plan a break (`onSongStarted` returns without calling `songStarted`). Record that and keep going; step 2 will not be available on that song.

**If the log cannot prove it.** `939c34e` has no `song started` line. The recording is the only evidence on that build. No build logs the playback position, so the log cannot prove the song reached its last sample. Missing line: `playback position index=<Int> seconds=<Int>` emitted at most once every few seconds, integers only, no title.

### 2. A prepared DJ break starts only after a verified natural end

**Action.** Before the song ends, watch the DJ status. Wait until a song shows "Preparing a DJ break" or "DJ break after this song" (or the briefing forms of those sentences). Let that song finish without touching transport. If a song ends with the DJ still idle, that boundary was not planned. Let the queue continue until one song shows the ready or preparing sentence, then score this step on that song.

**Expected result.** Speech starts only after that song's last note. No audio from the next song is heard before the speech. While speech is audible the status line shows the badge "On Air" and the headline "DJ", or "Briefing" when the break includes a briefing. VoiceOver says "The DJ is speaking now." or "The DJ is reading your briefing now." Those longer sentences are the accessibility label (`DJStudioState.detail`), not the on-screen headline. On Air is gone when the speech ends. The break is one pass, not two.

**Which existing lines prove the end.** On #64 / #67, a one-song queue ends as:

```text
boundary queueEnd finished=<K>
```

That line is both "the entry became nil" and "playback stopped within 1.5 s of the duration." The source uses one string for both (`BoundaryInterpreter.plannedHandoff`). An entry-identity change, which a one-song queue is not supposed to do, is:

```text
boundary naturalEnd finished=<K>
```

The break is verified only if the recording shows speech **after** that line's timestamp and the next `song started` line is **after** the speech. The poll can place the boundary line up to about one second after the last note. Speech that starts before the last note fails the step.

**If the log cannot prove it.** Nothing logs that a break started, ended, or was skipped. `djStarted` updates the snapshot and does not call `Logger`. Missing lines, with no cue text:

```text
break start after=<K>
break end after=<K> result=finished
break skipped after=<K> reason=<DJBreakSkipReason raw value>
```

`reason` may be `notPlanned`, `notReadyAtBoundary`, `timedOut`, `renderFailed`, `sourceRevoked`, or another existing `DJBreakSkipReason` case. It must not be the spoken words.

### 3. The next full song starts, and the finished song is never replayed

**Action.** Let the break finish, or let the boundary pass if no break was prepared. Do not press play, pause, or skip.

**Expected result.** The next song starts once, from its beginning, and plays forward. The song that just finished does not play again. Its title does not return as now playing. The queue advances by one index.

**Evidence.** Recording of the transition. On #67, the next line is `song started index=<K+1> durationSeconds=…` and index `<K>` does not appear again. On #64, that line is present only if the next song was allowed to play immediately. A song armed while paused is started later without a `song started` line (see deferred-start in the gap list).

**If the log cannot prove it.** The log has no title, which is correct. It also has no entry id, so a replay of the same catalog song in a later queue would look like a new index. For this run, the index plus the recording is the proof. Missing on #64 only: the deferred path does not log. #67 already logs it from `noteSongStarted`.

### 4. A user pause in the last ~1.5 seconds does not start a break

**Action.** On a later song, wait until well under two seconds remain (use the song's duration from the `song started` line and the recording). Press Pause once. Leave it paused for at least three seconds, longer than one poll.

**Expected result.** Music stops on that song and stays on that song. No DJ break starts. On Air stays off. The button reads "Play". No `boundary queueEnd` or `boundary naturalEnd` line is written for that pause. Pressing Play continues the same song. The break, if one was prepared, waits for a real end.

**Evidence.** Recording of the pause and the following three seconds, plus the Console range. The status must not change to "On Air".

**What the source will do.** On `3a66085`, `pause()` does not tell the detector. The next poll sees "was playing, now stopped, position within 1.5 s of duration" and returns `queueFinished`. That becomes `boundary queueEnd` and can start the break, including during the pause. `testUserStopNearTheEndIsNotAFinish` passes only when the caller has already called `userRequestedChange()`. `pause()` does not. `testPauseMidSongIsNotAnEnd` is a pause far from the end. **A fail on `3a66085` matches the source.** On `b69581b`, `pause()` calls `pausedByApp()` first, and `testAPauseTheAppMadeInTheLastSecondsIsNotAFinish` covers a pause at 199.5 s of a 200 s song. That commit is not in `3a66085`.

**If the log cannot prove it.** No line says the pause was the user's. Missing line:

```text
user pause index=<K> nearEnd=<true or false>
```

`nearEnd` is the detector's 1.5 s check. No title.

### 5. An incoming call mid-song

**Action.** During a song, with more than five seconds left (so this is not step 4), call the Duo from the second phone. Let the interruption begin. Then end it two ways on two different songs: hang up after answering, and decline or let the system end it without granting resume. Do not press Play until you have seen whether music returns on its own.

**Expected result.** When the call begins, music pauses and stays on the same song. Speech does not start. When the call ends, music resumes on its own only if iOS grants resume. If iOS does not, the song stays paused until you press Play. The UI reason matches that:

- Held: the button says "Play". On Air is off. The screen does not say you paused, and it does not say the DJ failed.
- Resumed without a tap: the button says "Pause" and the same song continues.
- The headline "DJ voice unavailable" is absent. VoiceOver must not say "The last DJ break couldn't play. Music continues." A mid-song call does not fail a DJ clip. That headline is `DJStatusPresentation` for `.failed(.voiceFailed)`.

**Evidence.** Recording of the call banner, the Play/Pause button, and the DJ status, for both endings. Note whether music returned with no tap.

**If the log cannot prove it.** No line records the interruption or `shouldResume`. The button has no reason string. `send(.userPaused)` is the same event a finger-press uses, so the snapshot cannot tell a call from a user pause. Missing lines:

```text
session interruption began
session interruption ended shouldResume=<true or false> breakActive=<true or false> directive=<suspendPlayback, resumeIfPermitted, or none>
```

Those tokens are the `AudioSessionNotice` / `AudioSessionDirective` values. No phone number, contact name, or title.

**Known UI miss if a break was already speaking.** This step is mid-song. If On Air was up, you are in step 6 instead.

### 6. An incoming call during a DJ break

**Action.** Wait until On Air is visible and speech is audible. Call the Duo. End the call the same two ways as step 5.

**Expected result.** Speech stops when the interruption begins, within the one-second poll and in practice on that turn (`onBreakMustStop` → `stop()`). On Air clears. Music does not talk over the call. After the call, music resumes only if iOS granted resume and the user had not pressed Pause. The next song does not start under the call. The status does not claim a voice failure.

**Evidence.** Recording of On Air going away while the call banner is up, and of whether music returns after you hang up.

**If the log cannot prove it.** Same missing interruption lines as step 5. `stop()` from a call does not log `interlude stop reason=sourceRevoked` (that string is only for consent). Missing line for this path:

```text
interlude stop reason=interruption
```

Use a fixed reason token, not the caller's identity. **Do not treat a missing `sourceRevoked` line as a pass or a fail of this step.**

**Known untruthful copy on #64 and #67.** A cancelled break is reported as `onPlayback(.failed)`. The on-screen headline becomes "DJ voice unavailable". VoiceOver says "The last DJ break couldn't play. Music continues." If either appears after a call, the UI reason fails this step even if the audio itself paused correctly.

### 7. AirPods disconnect mid-song

**Action.** Play a song to the AirPods, with more than five seconds left. Disconnect them by putting both in the case or turning Bluetooth off. Do not pick iPhone Speaker in Control Center. A manual route pick is `routeChanged(.other)`, and the policy returns `.none`, so playback is supposed to continue. That is a different test. Wait five seconds. Do not press Play.

**Expected result.** Music pauses on the same song and does not resume on the speaker. No break starts. On Air stays off. The button says "Play". Pressing Play is what starts audio again, and it may then use the speaker. That press is the end of the step, after you have recorded the hold.

**Evidence.** Recording of the disconnect and the silent five seconds, plus the route you used (case or Bluetooth off).

**If the log cannot prove it.** No line records a route change. Missing line:

```text
session route removed
```

No device name, no Bluetooth identifier.

**Same 1.5 s hole on `3a66085`.** `pausePlayerForBreak()` is what the route handler calls, and on that SHA it does not call `pausedByApp()`. A disconnect in the last 1.5 s can log `boundary queueEnd` and start a break. Score that as a fail. `b69581b` calls `pausedByApp()` from `pausePlayerForBreak()`.

### 8. AirPods disconnect during a break

**Action.** During On Air speech on the AirPods, disconnect them the same way as step 7. Wait five seconds.

**Expected result.** Speech stops. Music does not resume on the speaker. On Air clears. The button says "Play" and stays there until you press it. A later phone call ending with permission to resume must also leave the song paused: a route hold is cleared only by Play (`PlaybackIntent.routeHeld`). The headline "DJ voice unavailable" stays off.

**Evidence.** Recording of speech cutting off and of silence afterward. If you can place a short call after the disconnect without pressing Play, record that music stays paused when the call ends.

**If the log cannot prove it.** Missing `session route removed` and `interlude stop reason=routeRemoved`. If the headline "DJ voice unavailable" appears, the UI reason fails the same way as step 6.

### 9. Revoking consent during a break stops narration within a tick

A tick here is the player's one-second poll. The bar is: speech is silent before that timer fires again.

**Action.** This step needs a break that is actually a briefing. The on-screen headline must be "Briefing" with the "On Air" badge (VoiceOver: "The DJ is reading your briefing now."). Unfold the Duo so Connections is on screen, and revoke the source that briefing cites (the Connections revoke control) while speech is audible. Leave the song paused-for-break; do not skip.

**Expected result.** Speech stops in that same moment, before the next poll. On Air clears. The revoked item is not spoken for the rest of the clip. The status does not say the voice failed. Music continues only under the normal break-end rule, and only if you still want playback.

**Evidence.** Recording of the revoke control and of the speech cutting off, with timestamps. On `3a66085`, a real stop through the new method logs exactly:

```text
interlude stop reason=sourceRevoked
```

Silence on that recording does not prove the rendered-voice files are gone. Record the cache file count three times: before the revoke (baseline), right after the revoke while the app is still running, and again after a relaunch. The two counts Sentinel asked for are the last two. The baseline is what makes a drop visible. A baseline of 0 means nothing was cached, and the file half of this step cannot be scored.

**Where the cache actually is.** `VoiceRendering.swift` has two caches and no logger.

- Live mode, the launch line `runtime mode: live`. `VoiceRenderer.onDeviceDefault()` (`OnDeviceSpeechProvider.swift`) builds a `FileAudioCache` at Application Support `Voice/Cache`. Each clip is one file, `<cache key>.json`. The key is `VoiceRenderer.cacheKey` (a SHA-256). `FileAudioCache.entries()` counts files with extension `json`. `purge(sourceItemIDs:)` deletes a file whose `sourceItemIDs` intersect the revoked set, and also deletes a file it cannot decode. Files for a source you did not revoke stay. The next launch calls `purgeExpired()`, which removes clips older than 7 days. It does not write deleted files back.
- Test station, the launch line `runtime mode: testStation`. `AppDependencies.testStation()` passes an `InMemoryAudioCache`. There is no directory. Downloading the container cannot show a count, and a relaunch drops process memory, which is not a purge. If the log says `testStation`, write "no files: in-memory cache" and leave the file-count half unscored. The rest of this script can stay on the test station. This file count is the live-mode check.

**How to count, on a live-mode install.** Unlock the Duo first. The files are written with complete-until-first-unlock protection, so a download from a locked phone can hide them. Xcode → Window → Devices and Simulators → your Duo → Installed Apps → AeroDJ → the gear menu → Download Container. Show Package Contents on the `.xcappdata`. Count the files in:

```text
AppData/Library/Application Support/Voice/Cache/*.json
```

That is `applicationSupportDirectory` plus `Voice/Cache`, which is the URL `onDeviceDefault()` passes to `FileAudioCache`. Count only. Do not open a JSON: the body is a `CachedAudio` (audio bytes, voice id, source-item UUIDs). Do not paste filenames into the notes or a PR. They are hashes of the spoken text. Write three integers in the step 9 notes: baseline, right after revoke, after relaunch.

Download the container right after the revoke, before you force-quit, so you see the purge that ran in the still-living process. Then force-quit, relaunch, wait until Console shows `runtime mode: live`, and download again.

**Expected file result.** The count right after the revoke is lower than the baseline by the clips that cited the revoked source. The count after relaunch equals that post-revoke count. Those files are still absent. The count is 0 only when every cached clip cited the revoked source.

**What the source does today.** `stopCurrentInterlude(reason: .sourceRevoked)` stops `AVAudioPlayer` before it returns, on the main thread in that turn (`MainActorImmediate`). Nothing calls it. `PlayerView` wires `onBreakMustStop` to `interlude.stop()` for pause, calls, and route removal only. `NarrationPurger.purge` drops future plans, prepared breaks, and cached audio. `takeBreak` has already cleared the playing break out of the preparer, so a purge cannot see it. `DJBreakSession.purge` replans later breaks and does not stop the player. Routine transitions are built with `sourceItemID: nil`, and `MusicSearch.live` calls `queueStarted` without a `briefing`. Until that handoff exists, the on-screen headline is "DJ" and this step **cannot be scored**: there is no personal source in the clip to revoke, and the live cache directory stays empty.

**If the log cannot prove it.** If you revoke and the `sourceRevoked` line is absent, the stop method was not called. That is the current wiring, so a continue-to-the-end-of-the-clip result on `3a66085` matches the source and fails the product bar. Missing line from the purge path, with a count and no item ids:

```text
narration purge count=<Int> speaking=<true or false> stopRequested=<true or false>
```

No log line reports how many rendered-voice files remain. `VoiceRendering.swift` does not use `Logger`. `InMemoryAudioCache.count` exists and is not logged. This gap belongs to Fry, who owns that file. Proposed line, a public integer and nothing else:

```text
narration cache count=<Int>
```

Until that line exists, the container count above is the evidence. Do not treat a missing log as a count of zero.

## Logging gaps (proposed lines only)

These strings are **not** in the tree. They are proposals. Each one is a static label plus public numbers or a fixed token. None of them may include a title, artist, cue text, catalog id, user id, token, or phone number.

| Gap | Why the current lines are not enough | Proposed line |
|---|---|---|
| Break start, end, skip | Boundary lines prove the detector. They do not prove speech. | `break start after=<K>` / `break end after=<K> result=<finished\|cancelled\|failed>` / `break skipped after=<K> reason=<raw skip reason>` |
| Which end signal | `boundary queueEnd` is both a nil `currentEntry` and a position near the duration. | Extend that line with `signal=entryCleared` or `signal=position` |
| Last song of the queue | `.stopped` sends `queueFinished` and logs nothing. | `boundary stationFinished finished=<K>` |
| User pause vs system pause | Both use `userPaused`. | `user pause index=<K> nearEnd=<true\|false>` |
| Call | No session log at all. | `session interruption began` and `session interruption ended shouldResume=<bool> breakActive=<bool> directive=<directive>` |
| AirPods | No route log. `.other` must not use the removed-device line. | `session route removed` |
| Stop reason other than consent | `interlude stop reason=sourceRevoked` exists on `3a66085` and is the only stop line. | `interlude stop reason=interruption` and `interlude stop reason=routeRemoved` |
| Deferred song | #67 logs `song started` when play really begins. Nothing logs the hold. #64 does not log the deferred start at all. | `song deferred index=<K>` when the song is armed and not played |
| Purge vs player | The consent stop log exists only inside a method the purge path does not call. | `narration purge count=<Int> speaking=<bool> stopRequested=<bool>` |
| Rendered-voice file count (Fry) | `VoiceRendering.swift` has no `Logger`. Hearing speech stop does not show that `Voice/Cache/*.json` was deleted. `InMemoryAudioCache.count` is not logged. The test station has no files at all. | `narration cache count=<Int>` after a purge and again after launch `purgeExpired` |
| Position | A natural end cannot be tied to the last sample. | `playback position index=<Int> seconds=<Int>` at a low rate |

Do not add the unimplemented `handoff.*` signpost names beside these. One set of lines is enough.

## Simulator versus device

CI here is Linux Swift tests plus the macOS GitHub Actions jobs. Those tests do not play Apple Music, receive a call, or see AirPods. Names below are on PR #67 at `3a66085` unless the row says otherwise. `InFlightRenderRevocationTests` is on PR #65 (`5171c37`), not on #67.

| Behavior | Covered by CI (not by sound) | Needs the Duo |
|---|---|---|
| One natural end when the entry changes | `PlaybackBoundaryDetectorTests.testNaturalAdvanceReportsOnce`, `testNaturalEndAfterInterruptionReportsOnce`, `CatalogPlaybackLifecycleTests.testEntryAdvanceIsOneNaturalEnd`, `testNaturalTrackCompletionIsReportedOnce` | Whether MusicKit actually changes the entry, and that the last note is the song's own last note |
| One end when the entry is kept and playback stops near the duration | `testEndByPositionIsReportedOnce`, `testSingleEntryQueueKeptAfterItsEndReportsQueueFinished`, `testKeptEntryStoppedNearItsDurationIsOneHandoff` | Which of the two signals a one-song queue emits. The log cannot say which |
| Pause in the middle is not an end | `testPauseMidSongIsNotAnEnd`, `testPhoneCallPauseIsNotAnEnd`, `testPauseAndHeadphoneSamplesAreNotTrackEnds` | Audible hold |
| Pause in the last 1.5 s is not an end | `testAPauseTheAppMadeInTheLastSecondsIsNotAFinish` on #64 `b69581b` only. On #67, `testUserStopNearTheEndIsNotAFinish` requires `userRequestedChange()`, which `pause()` does not call | Step 4. Required on whatever SHA you install |
| A prepared break is handed over once | `CatalogPlaybackLifecycleTests.testDJTransitionIsExactlyOnce`, `DJBreakSessionTests.testBreakIsPreparedDuringTheSongAndHandedOverAtTheBoundary` | Speech after the end, and not over the next song |
| Failed or missing speech returns to music | `testFailedNarrationReturnsToMusicImmediately`, `testCancellationBeforeTheBreakIsReadyDoesNotPlayIt` | A real undecodable clip, if you hit one. Not one of the nine steps |
| Call begins and ends with permission | `AudioReliabilityTests.testIncomingCallBeginsAndEndsWithPermission`, `testPlaybackResumesOnlyWhenPermitted` | Real `shouldResume`, and the on-screen words |
| Call ends without permission | `testInterruptionEndedWithoutShouldResumeDoesNotResume` | Decline / no-resume ending |
| Call while speech is up does not resume early | `testNarrationFailureWhileSuspendedStaysPaused` | Speech actually stops, and the headline is not a voice failure |
| User pause during a break | `testUserPauseDuringADJBreakDoesNotResume`, `PlaybackIntentTests.testUserPauseDuringABreakBlocksResume` | Audible |
| AirPods hold until Play | `testHeadphonesDisconnectHoldsUntilUserPlay`, `PlaybackIntentTests.testRouteRemovalHoldsUntilTheUserPlays` | A real `oldDeviceUnavailable`. Control Center speaker is a different reason |
| Call end does not clear an AirPods hold | `testCallEndingCannotClearALaterHeadphoneRemoval`, `testHeadphonesUnpluggedDuringACallStillHoldAfterTheCallEnds` | Step 8's optional follow-up call |
| Rapid notices stay in order | `testRapidNoticesApplyInArrivalOrder` | Only if you can overlap a call and a disconnect |
| Observers register once | `testObserverRegistrationIsOnceEvenIfActivationFailed` | No device step |
| Deferred start reported once | `testDeferredSongStartIsReportedOnceWhenResumeIsPermitted` | A song loaded during a call or a pause, then started. #64 will not log it |
| Consent stop of a speaking player | `InterludeStopTests.testStopDuringPlayRetiresTheBreak`, `testStopFromANonMainContextStopsBeforeReturning`, `testStopWhenIdleIsANoOp`, `testLateDelegateAfterStopIsIgnored` | These drive a test double. They do not revoke a Connection. Step 9 is still a Duo step, and the app does not call the method |
| Prepared audio dropped on revoke | `DJNarrationTests` asserts `.sourceRevoked` for a break that has not started | Does not stop a clip that has already started |
| In-flight render dropped on purge | `InFlightRenderRevocationTests` on PR #65 | Synthesis, not the speaker |
| Revoke deletes cached voice files | `VoiceRenderingTests.testDeletingOrRevokingASourcePurgesDerivedAudio` purges an `InMemoryAudioCache` and a temp `FileAudioCache`. It does not read the app container | Step 9 file counts. Live mode only: `Library/Application Support/Voice/Cache/*.json`, before, right after revoke, and after relaunch |

## Results

Copy this table into your notes. Leave it blank in git. One link per step can be a private recording or a redacted Console export. Do not commit the media.

| | |
|---|---|
| Date | |
| Tester | |
| Device / iOS | |
| Git SHA installed | |
| Route for steps 1–6 | speaker or AirPods |
| Test station log seen | `runtime mode: testStation` yes / no |
| Other audio stopped at | authorization / first play |
| Executed | **no** (this file has not been run) |

| Step | Pass / Fail | Notes | Evidence |
|---|---|---|---|
| 1. Full song to its end | | | |
| 2. Break only after a natural end | | | |
| 3. Next song once, finished song not replayed | | | |
| 4. Pause in the last ~1.5 s | | | |
| 5. Call mid-song | | | |
| 6. Call during a break | | | |
| 7. AirPods disconnect mid-song | | | |
| 8. AirPods disconnect during a break | | | |
| 9. Revoke consent during a break | | Cache counts (baseline / after revoke / after relaunch), or "no files: in-memory cache" | |

-Atlas
