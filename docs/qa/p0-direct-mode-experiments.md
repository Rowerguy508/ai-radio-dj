# P0 device experiments: Direct Mode (A) and the layer matrix (B)

Physical Duo only. Simulator and CI results don't decide anything here. Per the owner's P0
Playback Recovery Directive, we first prove that plain MusicKit plays on the Duo (Experiment A),
then add our layers back one at a time (Experiment B). [#125](https://github.com/Rowerguy508/ai-radio-dj/pull/125)
is on hold, and its build 11 script in [build11-device-checks.md](build11-device-checks.md)
runs only after A and B. -Fry

**Log and toggle names are PENDING.** Atlas's Direct Mode draft isn't up yet. Every name below
written as `<pending: …>` is a placeholder for the real string in that draft. I'll replace each
one with the exact string, verified with `rg` on the Direct Mode head, before this script is
used. Don't invent strings to match against.

Code references in this doc were verified with `git grep` on `origin/integration/device-duo` at
`aec68ac`, unless marked as #125-only.

## Ground rules

- **Build:** an internal TestFlight build compiled with `AERODJ_P0_DIAG`. That condition is set
  only by the internal TestFlight workflow and must never reach an App Store build. Its removal is
  tracked with #121 and #133.
- **One player, one owner:** `ApplicationMusicPlayer.shared`, driven by a single Direct Mode type.
  No DJ prep, watchdogs, auto-skip, auto-resume or queue observers that issue commands.
- **Legacy service off:** while `AERODJ_P0_DIAG` is on, `MusicKitService` (`MusicKitService.swift:15`,
  `static let shared`) must never be started. That means `authorize()` (`:94`) and
  `configureAudioSession()` (`:740`) never run and no `AudioSessionMonitor` (`:816`) is created.
- **Audio session:** Direct Mode calls no `setCategory`, no `setActive` and installs no
  `AVAudioSession` notification observers. It relies only on what MusicKit does itself plus
  `UIBackgroundModes: audio` (`ios/project.yml:34`).
- **Privacy:** crop every screenshot to the AeroDJ screen. No caller ID, notifications, Siri text
  or status bar. Don't send screen recordings with song titles or account details showing.

## Experiment A: Direct Mode on the Duo

### Setup

1. Install the internal TestFlight build. Note the build number from the TestFlight page.
2. No other audio playing (Music app, podcasts). Bluetooth **off**, volume up, device speaker.
3. Have a Bluetooth headset or speaker paired but disconnected (A9) and a second phone that can
   call the Duo (A10).
4. Force-quit AeroDJ from the app switcher.

Each step is **pass**, **fail** or **inconclusive**. Report-only steps (A8 to A10) are never a
playback fail; they record behavior for B. Take screenshots of the Direct Mode screen and its
transition log as soon as the lines you need are on screen.

| Step | Do | Pass | Fail | Inconclusive |
|---|---|---|---|---|
| A1 Cold launch | Launch AeroDJ from the home screen after the force-quit. | The Direct Mode screen shows, with no crash. | Crash, hang, or the normal player screen shows instead. | — |
| A2 Diagnostics build, legacy off | Read the screen header and the top of the log. | The screen identifies the `AERODJ_P0_DIAG` build, and the log shows `<pending: legacy service not started>`. There's no line from the legacy service and no session line of any kind. | No diagnostics marker, or any sign `MusicKitService` started (its overlay, `session.setCategory …`, `session.setActive …`). | The marker is ambiguous. Send the frame. |
| A3 Status | Read authorization status, `canPlayCatalogContent` and route. | `<pending: auth status>` reads authorized, `<pending: canPlayCatalogContent>` reads true, and the route reads the speaker. | Not authorized, or `canPlayCatalogContent` false. Stop and triage (below). Don't continue to A4. | Any value shows unknown after 10 s. |
| A4 Play song 1 | Tap Play. Start a 10 s count. | Audible from the speaker within about 3 s. Position moves past 0:00 and keeps advancing over 10 s. The "ever reached `.playing`" indicator turns on. Log: `<pending: play requested>`, then `<pending: state → playing>`. | No sound by 10 s, the position stuck at 0:00, the indicator never on, or an error line (domain and code). | Sound but the position doesn't move, or the indicator is on with no sound. Send frames, repeat once. |
| A5 Pause | Tap Pause after A4 has run 10 s. Wait 5 s. | Audio stops within about 1 s. The position freezes and stays frozen for 5 s. Log: `<pending: state → paused>`. | Audio keeps playing, or the position keeps advancing. | Audio stops but the position drifts by under 1 s. Note it. |
| A6 Resume | Tap Resume. Wait 10 s. | Audio returns within about 2 s, at the frozen position, not from 0:00. The position advances again. Log: `<pending: state → playing>`. | No audio, or it restarts song 1 from 0:00. | — |
| A7 Next song | Tap "Next song". Wait 10 s. | Song 2 is audible within about 3 s, song 1 stops, and the position restarts and advances. The log shows exactly one `<pending: queue set>` for this tap and no `<pending: queue replaced>` that nobody asked for. | Song 1 continues, silence, a second queue change with no tap, or playback jumps to a third song. | — |
| A8 Lock screen (report only) | With song 2 playing, lock the Duo. Pause on the lock screen, wait 5 s, Play. Unlock. | Report what you heard on each press, plus the log lines around them (`<pending: external state change>`). | — | — |
| A9 Route change (report only) | Connect the Bluetooth device while playing. Wait 10 s. Disconnect it. Wait 10 s. | Report where audio went each time and what the route field showed. iOS normally pauses on the disconnect; that's expected. | — | — |
| A10 Phone call (report only) | Play, then call the Duo from the second phone and answer. Talk 10 s, end the call. | Report whether music paused for the call, whether it resumed on its own (Direct Mode has no auto-resume, so it shouldn't), and whether Resume works afterwards. | — | — |

A **passes** when A1 to A7 all pass: audible sound, position moving past 0:00, pause and resume
working, the song change working, and no unexpected queue replacement. Repeat A1 to A7 three
times from a cold launch (force-quit between runs). All three must pass.

### Failure triage order

If any of A3 to A7 fails, check in this order. Don't touch the DJ engine until each of these is
ruled out:

1. **Authorization:** the auth status reads authorized. Settings › AeroDJ › Media & Apple Music is on.
2. **Subscription:** `canPlayCatalogContent` is true. The Apple ID on the Duo has an active Apple Music
   subscription, and the Music app plays the same song.
3. **Entitlements:** the build is signed with the MusicKit App Service for `com.aerodj.app` (Orion
   checks the developer portal; the app's entitlements file is `ios/AeroDJ/AeroDJ.entitlements`).
4. **Audio route:** the route field shows the speaker, the ringer and volume are up, and no
   Bluetooth device or AirPlay target has the audio.
5. **Native player:** the Music app plays on the Duo, and the error domain/code from the log, if any.

## Experiment B: layer matrix (only after A passes)

Atlas adds our layers back one at a time behind debug toggles, in the owner's order. Turn on
**only** the layers up to and including the one under test. If a layer fails, stop: don't test
later layers on top of it.

For every layer, rerun **A core** (A1, A3 to A7), then the layer's own steps. Reproducibility:
**3 cold-launch repeats per layer**, each one force-quit first. A layer passes only if all 3
pass. Report steps (A8 to A10) are rerun only where a layer lists them.

| # | Layer | Toggle | Layer-specific steps | Pass criteria | Audio session expectation |
|---|---|---|---|---|---|
| B1 | Coordinator | `<pending: coordinator toggle>` | A core only. | Same as A. All commands still come from one owner; the log shows commands routed through `<pending: coordinator line>`. | Untouched. No `setCategory`, `setActive` or observers. |
| B2 | Queue / boundary | `<pending: queue toggle>` | Let song 1 **end naturally** (pick a short song or scrub near the end). Don't tap Skip. | The next song starts once, within about 3 s of the end, with exactly one queue change at the boundary and no replay of the old song. | Untouched. |
| B3 | Confirmation / timeout | `<pending: confirm toggle>` | Force an **8 s stall**: airplane mode right after Play (then off). Also a normal Play. | A normal Play confirms with no timeout line. On the stall, the 8 s deadline is reported on screen and the player is **not** paused or skipped by the timeout (matches `PlaybackConfirmPolicy`, AeroDJCore). If the start doesn't stall, mark it **not exercised**. | Untouched. |
| B4 | Interruption / route | `<pending: interruption toggle>` | Rerun A9 and A10, now graded. Add a Siri invocation during a play start. | The call pauses music and it doesn't auto-resume unless the system says `shouldResume` and the user had been playing. Route loss (BT disconnect) pauses, no auto-play. Siri during a start leaves audio paused. A normal Play is never paused by a self-start interruption. | **First layer allowed to touch `AVAudioSession`, and only to observe**: interruption and route-change notifications. Still no `setCategory`/`setActive` unless Atlas's draft says it's needed and that's reviewed first. |
| B5 | DJ-break scheduling | `<pending: break toggle>` | Commentary **on**. Let a song end naturally into a break (use a placeholder clip if speech prep is still off). | One break per song end, no audio over music: the old song is paused before the clip and the next song starts only after it. | The interlude `AVAudioPlayer` (`InterludePlaybackAdapter.swift:18`) may activate the session implicitly when it plays. After the break, the session is released (`session.releasedAfterBreak` exists only on #125, not integration) and the next song plays. |
| B6 | Speech prep | `<pending: speech toggle>` | Commentary on. Tap Play and listen for the first 10 s while a line renders. Then a natural end into a spoken break. | Rendering during a song never pauses or ducks the music. The break plays the rendered line. | The synthesizer uses its own session: `usesApplicationAudioSession = false` (`OnDeviceSpeechProvider.swift:58`). Rendering must never touch the app session. |
| B7 | Personalized narration | `<pending: narration toggle>` | Commentary on with one consented personal source. Natural end into a break. Then withdraw consent mid-song and let it end again. | The break narrates the consented item. After withdrawal, the next break never mentions it. Nothing personal shows on the Lock Screen or Now Playing. | Same as B6. No new session use. |

### What to send back, per layer

1. The layer, the toggle state screenshot, and pass / fail / inconclusive / not exercised for each
   step, in each of the 3 repeats, with a one-line note on what you heard.
2. The **raw** screenshots of the transition log, in order. Don't retype lines.
3. For any fail: the first log line that differs from the A run, and its error domain/code if shown.
4. For B4 to B7: whether music ever played under speech, or paused with nothing to explain it.

## What to send back for A

For each of A1 to A10: the result, a one-line note on what you heard, and the raw cropped
screenshots in order. For A3, the auth status, `canPlayCatalogContent` and route values. For any
error, the domain and code exactly as shown (the log never shows titles, IDs or account details).

Crop every screenshot to the AeroDJ screen first, so no caller ID, notification, Siri text or
status bar is shared.
