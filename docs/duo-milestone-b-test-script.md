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

There is no single SHA that has both the pause guard (`b69581b`) and the interlude-stop log (`3a66085`). The phone build is the rule in **Build and install**, not `3a66085`. On an installed SHA that does not contain `b69581b`, a break that starts after a pause, call, or unplug in the last 1.5 s is a fail of that step. `939c34e` does not contain that guard. A green merge of #65 does, because that branch merges `b69581b`.

Fingerprint while other audio is playing (Music, a podcast):

- The other audio keeps playing through the Apple Music prompt and stops only when a station starts. That is `activateAudioSessionForPlayback()` on #64 and #67.
- The other audio stops as soon as authorization succeeds. That is `setActive(true)` inside `configureAudioSession()` on `939c34e`.

## Prerequisites

Do these before the numbered steps. If one is missing, stop and record which one. Do not invent a pass.

1. **Mac and device.** Xcode with XcodeGen 2.46.0 (the version CI pins). The iPhone Duo, unlocked, Developer Mode on (Settings → Privacy & Security → Developer Mode), trusted by this Mac. Deployment target in `ios/project.yml` is iOS 17.0.
2. **Signing.** Follow section 5 of the install checklist, PR #74 at `0c1da5ba1fb43bf874e1aeb2c75f2aaeadcd5f87` (`docs/device-install.md`). That copy is the one to use. The `docs/device-install.md` inside the install commit is older. Do not retype those steps here. The team ID goes only in git-ignored `ios/Config/Signing.local.xcconfig` as `DEVELOPMENT_TEAM = S85APB73YV`. Committed `ios/Config/Signing.xcconfig` sets `CODE_SIGN_STYLE = Automatic` and includes that local file. It does not set `DEVELOPMENT_TEAM`. Do not add the team to `Signing.xcconfig`, `project.yml`, or the target settings. Identifiers and the portal MusicKit App Service are checklist section 4. The old App ID `Com.technostrada.aerodj` is unused. Do not select it.
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

Install the final `integration/device-duo` tip after the owner merges tonight's batch (Orion's order: #67, #85, #86, Fry's `isBreakPrepared`, Nova's hybrid, #73 if ready). The exact SHA is filled in here at merge. Whatever is not green by the 6:00pm ET cutoff is not in it.

- **Fallback: `0e37e3033d015700dee5f5ce50384ab935bdd75b` (`0e37e30`)**, the tip after #75 merged. It is a merge commit with tree `e6aeb3b`, identical to `7d202ad` (#75 `57a2cb8` merged into `5dbf6d9`), which passed every job in iOS run 40340171304. Use it if nothing from the batch merges in time.
- `0e37e30` contains #63 `129d0c6` and #64 `b69581b` (pause guard) and #75 (briefing call site, `LiveQueueBriefing`, empty sensitivity table). It does not contain #67, #73, #77 or #86: no `InterludePlaybackAdapter`, no interlude-stop log line, no `didFinish` / `signal=… frames=…` line, no dark-mode fixes.
- The iOS workflow runs on pull requests only. The green result for the final tip is the gating run of the last PR merged, at the head that merged, on the base it merged into.
- Fall back to `5dbf6d910195c06f7d4a03993951b25212b335f5` (tree equals #65 `aaff7e1`, iOS run 40327400994) only if `0e37e30` will not build or sign, and to `939c34e8da505ca91d26b30b52f696974b06c1c5` only if neither will.

**Tonight's briefing rule (Echo).** On the post-#86 build, starting a station plays music with **no briefing speech**: every Connections row fails closed until #73 and Echo's wiring follow-up land. **Any briefing speech on this build is a failure, not a pass.** Record it with the time, the headline shown, and the log lines around it.

Checklist section 3 may still name `939c34e`. Use this section when the two disagree. Signing still comes from checklist section 5.

```sh
git fetch origin integration/device-duo
git rev-parse origin/integration/device-duo
git checkout <SHA>
git rev-parse HEAD
```

`git rev-parse HEAD` is the SHA you install. Write it in the results sheet on **Git SHA installed**. A branch name is not enough.

Generate and open from that checkout. The team file from checklist section 5 is already in place. `xcodegen` is the last step of that section.

In Xcode: scheme **AeroDJ**, destination your iPhone, Run configuration **Debug**, argument `-AeroDJTestStation YES`.

**Pre-flight.** On AeroDJ and AeroDJShare, Signing & Capabilities shows team `S85APB73YV` from `Signing.local.xcconfig` and Automatically manage signing. App Groups is `group.com.aerodj` with no errors. Bundle identifiers stay `com.aerodj.app` and `com.aerodj.app.share`. Do not select `Com.technostrada.aerodj`. Do not type the team into the target. MusicKit is the App Service on `com.aerodj.app` from checklist section 4. `AeroDJ.entitlements` has no MusicKit key, so a missing MusicKit row matches the tree. Then Run. Automatic signing creates the development profile on that first device build.

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

**Personal briefing speech.** Two steps below expect a morning briefing of Connections rows: step 2, when the headline is "Briefing", and step 9. Read the installed SHA in the results sheet and use one label for both.

On #75 at `14c907eed0b9d5cfea73c39a9527f36538de5303` (still true at the branch tip `3f1d919`), `PlayerView` passes `LiveQueueBriefing.provider`. `StudioPresentationModel.liveQueueBriefing` passes an empty sensitivity table (`LiveQueueBriefing.swift:28`, `sensitivityByItemID: [:]`). A missing id is `.blocked` (line 109). Every live Connections row fails closed, so the morning briefing says nothing.

Fry's privacy PR is #73, `fix/consent-purge-demotion-race`, head `b83cbd747a1f193c867e77bb6a05445a4a81d1a7`. Commit `fffa6747952d512b107e4654df72fe568cc4a654` fills `ConnectionItem.sensitivity` and adds `ConnectionsModel.sensitivityByItemID`. That commit does not change `LiveQueueBriefing.swift`. This script depends on that PR for the values. Speech of approved rows also needs the installed `LiveQueueBriefing.swift` to pass `connections.sensitivityByItemID` instead of `[:]`.

- The installed SHA does not contain `fffa674`: **expected: silence (no personal briefing)**. A silent briefing is a pass, not a defect. Any briefing speech on such a build is a failure.
- The installed SHA contains `fffa674` and the Studio connection passes that table: **expected: briefing speaks approved rows only**.
- The installed SHA contains `fffa674` but line 28 is still `[:]`: the live path still says nothing. Silence is a pass. Do not apply the speaks label.

A routine DJ break, headline "DJ", is not this briefing. Steps 6 and 8 can use that break.

### 1. A full song plays to its natural end

**Action.** Start the four-song queue. Do not pause, skip, lock the screen, or switch apps. Let song 0 play until it ends on its own.

**Expected result.** Song 0 is heard through its last note. The Play/Pause control stays "Pause" for the whole song. No DJ speech starts in the middle of the song. When it ends, the next thing is either a DJ break (step 2) or song 1. Song 0 does not restart.

**Evidence.** Recording from the first chorus through the end. On a build with category `playback`: one `song started index=0 durationSeconds=…` near the start, and no `boundary` line until the song is over. If `durationSeconds=-1`, MusicKit did not report a duration. The app then does not plan a break (`onSongStarted` returns without calling `songStarted`). Record that and keep going; step 2 will not be available on that song.

**If the log cannot prove it.** `939c34e` has no `song started` line. The recording is the only evidence on that build. No build logs the playback position, so the log cannot prove the song reached its last sample. Missing line: `playback position index=<Int> seconds=<Int>` emitted at most once every few seconds, integers only, no title.

### 2. A prepared DJ break starts only after a verified natural end

**Action.** Before the song ends, watch the DJ status. Wait until a song shows "Preparing a DJ break" or "DJ break after this song" (or the briefing forms of those sentences). Let that song finish without touching transport. If a song ends with the DJ still idle, that boundary was not planned. Let the queue continue until one song shows the ready or preparing sentence, then score this step on that song.

**Expected result.** Speech starts only after that song's last note. No audio from the next song is heard before the speech. While speech is audible the status line shows the badge "On Air" and the headline "DJ", or "Briefing" when the break includes a briefing. VoiceOver says "The DJ is speaking now." or "The DJ is reading your briefing now." Those longer sentences are the accessibility label (`DJStudioState.detail`), not the on-screen headline. On Air is gone when the speech ends. The break is one pass, not two.

The "DJ" headline is a routine break and is unchanged. The "Briefing" headline is personal briefing speech. On a build without `fffa674`: **expected: silence (no personal briefing)**. Depends on Fry's privacy PR #73. A silent briefing is a pass. On a build that includes `fffa674` and whose `LiveQueueBriefing.swift` passes the row sensitivity table: **expected: briefing speaks approved rows only**. Write the installed SHA and the label you used.

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

On a build without `fffa674`: **expected: silence (no personal briefing)**. Depends on Fry's privacy PR #73. Do not revoke, because there is no personal speech to stop. A silent briefing is a pass, not a defect. Write that label and the installed SHA. The revoke action below applies only under the other label.

On a build that includes `fffa674` and whose `LiveQueueBriefing.swift` passes the row sensitivity table: **expected: briefing speaks approved rows only**. Then revoke while that speech is audible.

**Expected result.** Under the speaks label, speech stops in that same moment, before the next poll. On Air clears. The revoked item is not spoken for the rest of the clip. The status does not say the voice failed. Music continues only under the normal break-end rule, and only if you still want playback. Under the silence label, no personal briefing is heard, and that is the pass.

**Evidence.** Recording of the revoke control and of the speech cutting off, with timestamps. On `3a66085`, a real stop through the new method logs exactly:

```text
interlude stop reason=sourceRevoked
```

Silence on that recording does not prove the rendered-voice files are gone. A count of only `*.json` does not prove it either. `purge` deletes the files `entries()` returns, and `entries()` keeps `pathExtension == "json"` (`VoiceRendering.swift` lines 252–254 on `939c34e`; lines 259–261 on #63 `129d0c6`). Deleted JSON can pass while an orphaned audio file stays in the same folder. Record every regular file in that folder, grouped by extension, three times: before the revoke (baseline), right after the revoke while the app is still running, and again after a relaunch. The two samples Sentinel asked for are the last two. The baseline is what makes a drop visible. A baseline with no files means nothing was cached, and the file half of this step cannot be scored.

**Where the cache actually is.** `VoiceRendering.swift` has two caches and no logger.

- Live mode, the launch line `runtime mode: live`. `VoiceRenderer.onDeviceDefault()` (`OnDeviceSpeechProvider.swift`) builds a `FileAudioCache` at Application Support `Voice/Cache`. The only extension that cache writes is `.json`. On `939c34e`, `url(_:)` is `directory.appendingPathComponent("\(key).json")` (line 236). `store` JSON-encodes the `CachedAudio` and `ProtectedFile.write`s those bytes to that URL (lines 272–276). On #63 `129d0c6` the same two statements are lines 243 and 279–283. `ProtectedFile.write` (`SharedInboxReader.swift` lines 101–103) writes that URL with `.atomic`. It does not add a second file. The key is `VoiceRenderer.cacheKey` (a SHA-256). The rendered samples are the `data` field inside that JSON (`CachedAudio`, lines 144–151 on `939c34e`), together with duration, provider id, voice id, source-item UUIDs, and `createdAt`. There is no `.caf`, `.m4a`, `.wav`, or `.aac` beside it.
- The `.caf` in on-device speech is not in `Voice/Cache`. On `939c34e`, `OnDeviceSpeechProvider.swift` line 44 writes `temporaryDirectory`/`aerodj-tts-<UUID>.caf`. Line 48 removes it with `defer` only when `run()` returns, and those bytes become `CachedAudio.data`. A kill during synthesis does not run that `defer`. `onDeviceDefault()` calls `cache.purgeExpired()` (line 126), which touches `Voice/Cache` only. `Voice/budget.json` sits next to the cache directory (line 129), not inside it. Do not count it.
- Fry's speech-provider PR #77 (`6ca1b3c0495fb40f248f4dde5b7d7d6b4d93f789`) moves that scratch file. `SpeechTempFiles` (`SpeechTempFiles.swift` lines 13–14 and 21) writes `aerodj-tts-<UUID>.caf` under `temporaryDirectory`/`aerodj-speech/`. `withFile` deletes that file on success, error, and cancellation (lines 32–35). `OnDeviceSpeechProvider.init` runs `SpeechTempFiles.shared.sweep()` once (lines 15–18), and `sweep()` removes every entry in the folder (lines 26–28). `AppDependencies.make()` builds that provider (`AppDependencies.swift` lines 59 and 95) before the `runtime mode` log, so a relaunch that has logged `runtime mode: live` has already swept.
- `purge(sourceItemIDs:)` deletes a `.json` whose `sourceItemIDs` intersect the revoked set, and also deletes a `.json` it cannot decode. It never looks at another extension, so an orphaned audio file would survive. Files for a source you did not revoke stay. The next launch calls `purgeExpired()`, which removes `.json` clips older than 7 days. It does not write deleted files back, and it does not remove a non-JSON file.
- Test station, the launch line `runtime mode: testStation`. `AppDependencies.testStation()` passes an `InMemoryAudioCache`. There is no directory. Downloading the container cannot show a count, and a relaunch drops process memory, which is not a purge. If the log says `testStation`, write "no files: in-memory cache" and leave the file-count half unscored. The rest of this script can stay on the test station. This file count is the live-mode check.

**How to count, on a live-mode install.** Unlock the Duo first. The files are written with complete-until-first-unlock protection, so a download from a locked phone can hide them. Xcode → Window → Devices and Simulators → your Duo → Installed Apps → AeroDJ → the gear menu → Download Container. Show Package Contents on the `.xcappdata`. List every regular file (not a directory) one level down in:

```text
AppData/Library/Application Support/Voice/Cache
```

That is `applicationSupportDirectory` plus `Voice/Cache`, which is the URL `onDeviceDefault()` passes to `FileAudioCache`. Group those files by extension and write the counts. Do not stop at `*.json`. Do not open a JSON: the body is a `CachedAudio` (audio bytes, voice id, source-item UUIDs). Do not paste filenames into the notes or a PR. They are hashes of the spoken text. A notes line names the extension and the integer only:

```text
baseline: json=4
after revoke: json=2
after relaunch: json=2
```

If any other extension is present, add it on the same line (`caf=1`). Write `json=0` when the folder has no JSON.

Download the container right after the revoke, before you force-quit, so you see the purge that ran in the still-living process. Then force-quit, relaunch, wait until Console shows `runtime mode: live`, and download again.

On that relaunch download only, count every regular file in Fry's speech folder:

```text
AppData/tmp/aerodj-speech/
```

That is `temporaryDirectory`/`aerodj-speech/`, the directory `SpeechTempFiles` uses on #77. The required count is 0. A missing folder is 0. Count regular files only. Do not open one: it is spoken audio. Do not paste a filename into the notes or a PR. Write `speech dir=<Int>`.

For a build older than #77, that folder is not in the tree. Count the loose files instead, directly in `tmp` and not inside `aerodj-speech/`:

```text
AppData/tmp/aerodj-tts-*.caf
```

Write `tmp caf=<Int>`. The required count is still 0. Do not open those files either.

**Expected file result.** The `json` count right after the revoke is lower than the baseline by the clips that cited the revoked source. Every other extension is 0 at all three samples, because `FileAudioCache` writes `.json` only. A regular file with any other extension after the revoke fails this step even when the `json` count dropped. The breakdown after relaunch equals the post-revoke breakdown. `json` is 0 only when every cached clip cited the revoked source.

**Temp synthesis files (pending until #77 is installed).** After relaunch, `speech dir` must be 0 on a build that contains `6ca1b3c0495fb40f248f4dde5b7d7d6b4d93f789`. On an older build, record `tmp caf` instead. This check stays **pending** until the installed SHA includes that commit. Record the count that applies, and write "pending: speech temp PR not installed" in the step 9 notes. Do not score this check pass or fail before that SHA is the one you installed. The `Voice/Cache` counts above are separate and are not pending on #77.

**What the source does today.** `stopCurrentInterlude(reason: .sourceRevoked)` stops `AVAudioPlayer` before it returns, on the main thread in that turn (`MainActorImmediate`). Nothing calls it. `PlayerView` wires `onBreakMustStop` to `interlude.stop()` for pause, calls, and route removal only. `NarrationPurger.purge` drops future plans, prepared breaks, and cached audio. `takeBreak` has already cleared the playing break out of the preparer, so a purge cannot see it. `DJBreakSession.purge` replans later breaks and does not stop the player. Routine transitions are built with `sourceItemID: nil`. On builds before #75, `MusicSearch.live` calls `queueStarted` without a `briefing`, the headline stays "DJ", and there is no personal source in the clip. On #75 at `14c907e`, the briefing is passed and then emptied by the sensitivity table, so the morning briefing is silent. That is **expected: silence (no personal briefing)**, a pass, until the installed SHA includes Fry's `fffa674` and line 28 passes the row table. The live cache directory stays empty while the briefing says nothing, so a baseline of 0 still cannot score the file half.

**If the log cannot prove it.** If you revoke and the `sourceRevoked` line is absent, the stop method was not called. That is the current wiring, so a continue-to-the-end-of-the-clip result on `3a66085` matches the source and fails the product bar. Missing line from the purge path, with a count and no item ids:

```text
narration purge count=<Int> speaking=<true or false> stopRequested=<true or false>
```

No log line reports how many rendered-voice files remain. `VoiceRendering.swift` does not use `Logger`. `InMemoryAudioCache.count` exists and is not logged. This gap belongs to Fry, who owns that file. Proposed line, one integer, marked public, and nothing else:

```text
narration cache count=\(count, privacy: .public)
```

`count` is an `Int` of every regular file left in the cache directory, including extensions other than `.json`. `privacy: .public` applies to that integer. The message is the static label and that integer. No file name, path, extension, cache key, title, cue text, or source id.

Until that line exists, the container breakdown above is the evidence. Do not treat a missing log as a count of zero. Do not invent the line.

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
| Rendered-voice file count (Fry) | `VoiceRendering.swift` has no `Logger`. Hearing speech stop does not show that every regular file in `Voice/Cache` was deleted. `entries()` only sees `.json`, so a JSON count can pass while another extension remains. `InMemoryAudioCache.count` is not logged. The test station has no files at all. | `narration cache count=\(count, privacy: .public)` after a purge and again after launch `purgeExpired`. `count` is one `Int` of every regular file in the directory. No file name, title, or id |
| Leftover speech temp files (Fry, #77) | On `939c34e`, removal is the `defer` at `OnDeviceSpeechProvider.swift:48` when `run()` returns. A kill mid-synthesis leaves `tmp/aerodj-tts-*.caf`. #77 `6ca1b3c` writes under `tmp/aerodj-speech/`, deletes the file on success, error, and cancel, and sweeps the folder when the provider is created. | Not a log line. Step 9, after relaunch: every regular file in `AppData/tmp/aerodj-speech/` must be 0. Older builds count `AppData/tmp/aerodj-tts-*.caf` instead. Pending until the installed SHA includes `6ca1b3c` |
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
| Revoke deletes cached voice files | `VoiceRenderingTests.testDeletingOrRevokingASourcePurgesDerivedAudio` purges an `InMemoryAudioCache` and a temp `FileAudioCache`. It does not read the app container. `FileAudioCache` writes `.json` only (`VoiceRendering.swift:236` on `939c34e`) and `entries()` ignores every other extension | Step 9 file counts. Live mode only: every regular file in `Library/Application Support/Voice/Cache`, by extension, before, right after revoke, and after relaunch |
| Leftover synthesis audio after a kill | On #77 `6ca1b3c`: `SpeechTempFilesTests.testLeftoverFromACrashIsRemovedAtStartup`, `testSuccessPathLeavesNoFile`, `testErrorPathLeavesNoFile`, `testCancelPathLeavesNoFile`. `939c34e` has none of these. There, `OnDeviceSpeechProvider.swift:48` deletes `aerodj-tts-*.caf` only when `run()` returns | Step 9, relaunch container: every regular file in `tmp/aerodj-speech/` must be 0. Older builds: `tmp/aerodj-tts-*.caf`. Pending until the installed SHA includes `6ca1b3c` |

## Results

Copy this table into your notes. Leave it blank in git. One link per step can be a private recording or a redacted Console export. Do not commit the media.

| | |
|---|---|
| Date | |
| Tester | |
| Device / iOS | |
| Git SHA installed | `git rev-parse HEAD` from Build and install. Expected the final `integration/device-duo` tip after tonight's batch (SHA filled in at merge); record `0e37e30` if nothing merged by the cutoff, `5dbf6d9` or `939c34e` only if the later SHAs would not build or sign |
| Personal briefing expectation | `silence (no personal briefing)` or `briefing speaks approved rows only` |
| Route for steps 1–6 | speaker or AirPods |
| Test station log seen | `runtime mode: testStation` yes / no |
| Other audio stopped at | authorization / first play |
| Executed | **no** (this file has not been run) |

| Step | Pass / Fail | Notes | Evidence |
|---|---|---|---|
| 1. Full song to its end | | | |
| 2. Break only after a natural end | | Personal briefing label from the installed SHA. Silence of a briefing is a pass without `fffa674` | |
| 3. Next song once, finished song not replayed | | | |
| 4. Pause in the last ~1.5 s | | | |
| 5. Call mid-song | | | |
| 6. Call during a break | | | |
| 7. AirPods disconnect mid-song | | | |
| 8. AirPods disconnect during a break | | | |
| 9. Revoke consent during a break | | Personal briefing label from the installed SHA. Silence is a pass without `fffa674`. Extension counts (baseline / after revoke / after relaunch), or "no files: in-memory cache". After relaunch: `speech dir=<Int>` (`tmp/aerodj-speech/`), or `tmp caf=<Int>` on a build older than #77. Pending until the installed SHA includes `6ca1b3c` | |

-Atlas
