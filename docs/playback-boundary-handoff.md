# Song-boundary handoff for DJ breaks (#51)

Status: **design decided, device gate open.** Nothing here is verified on hardware.

## The problem

`PlaybackBoundaryDetector` reports a natural end only after the next queue entry is already current. The poll runs once a second. So today:

1. Song N ends and song N+1 starts on its own.
2. Up to about one second later the app sees the entry change and starts the DJ break.
3. The break plays over the opening of song N+1, and music pauses only after that.

This is the overlap the Lead flagged. Fixing it needs the next song to be held until the break is ready. MusicKit gives no signal before a song changes, so the hold has to come from how the queue is built.

## What the SDK gives us (from public references, not yet device-tested)

- `ApplicationMusicPlayer.Queue.Entry` exposes `item`, which is the `Song` with `duration`. Read duration from the song, not from the entry.
- `Queue.Entry.endTime` (and `startTime`) reportedly do not reliably stop playback at a set point, so **do not use them** to end a song early.
- The only boundary signal is the entry changing identity. It arrives after the change, never before.

## Options considered

| Option | Keeps the full song | Next song's opening intact | Silent gap at boundary | Risk |
|---|---|---|---|---|
| A. Status quo: whole queue, react on change | yes | **no**, break overlaps about 1 s of song N+1 | none audible, but overlap | known P1 |
| B. Pause near the end of song N | yes | yes, if the pause lands | none | race with the queue advancing; not reliable |
| C. One-track queue per song (chosen) | yes | yes, nothing starts until we load it | DJ start latency, then next-song start latency | song end must be reported as a planned handoff |

## Decision: option C, one-track queue per song

- The player queue holds **only the current song**. The rest of the station's order lives in the app.
- At the end of song N the player stops on its own. The app treats that stop as a **planned handoff**, not `queueFinished`, when the app's own queue still has tracks.
- The DJ break starts from the handoff. Its audio is already prepared (`AVAudioPlayer.prepareToPlay()`), so the only silence is the player's start time.
- After the break ends (or is skipped), the app loads song N+1 alone and plays it.
- Next-song startup latency falls *after* the DJ line, where the listener expects a transition, not in the middle of a song.

### Contract

- `PlaybackEvent.naturalBoundary(nextIndex:)` is emitted for the handoff, not `queueFinished`.
- The handoff is only "planned" when the app set the queue to a single song and the app's queue has more tracks. Otherwise the stop is `queueFinished` as today.
- Skip and station change still call `userRequestedChange()` before touching the queue, so they never look like handoffs.
- If the break is skipped (no prepared clip, decode failure, timeout), the next song still loads and plays. No fallback speech, no hold.
- `resumeIfAllowed()` is the only path that starts music after a break, and it still respects `PlaybackIntent`.

### Known costs

- The player's queue is rebuilt once per song. This adds one queue write per boundary, which must be measured.
- A one-track queue end may show a brief `stopped` status before the next load. The detector must not count that as a user pause.

## Physical-iPhone test plan (gate for this change)

Simulator CI cannot prove audible behavior. Each run records timestamps from a screen recording and from `os_log` signposts: `handoff.songEnd`, `handoff.breakStart`, `handoff.breakEnd`, `handoff.nextSongStart`. Use a device with the Music app closed and a second device or audio analyzer to capture the output.

1. Two songs in a station, DJ clip prepared for the boundary. Record the audible gap between the last note of song N and the first DJ sample, and between the last DJ sample and the first sample of song N+1. Target: no sample of song N+1 before the break; gap under the agreed budget (set on device, not guessed).
2. Song N played to the end with no DJ line planned. Confirm there is no gap beyond the normal queue transition, and that `naturalBoundary` fires once.
3. Pause during song N, then let it end. Confirm no break, no next-song start while paused.
4. Phone call during a break. Break stops, music does not resume until the call ends and `shouldResume` allows it.
5. Unreadable clip. Break is skipped, a speech error is shown, and song N+1 starts on time.
6. Skip during a break. Break stops, song N+1 loads once, no duplicate boundary.
7. Repeat 1 and 2 at least 20 times per device with a timer log. Record the 95th percentile of each gap.

Evidence to attach to #51 for each run: device model, iOS build, route (speaker or headphones), clip id, the four signpost timestamps, and the measured gaps. A run without audio capture is not evidence.

## What stays open

- Whether a single-song queue ends with `entry == nil` or keeps the last entry is unverified. The handoff code must handle both.
- Startup latency of the next song after a stop is unmeasured.
- Prepared clips are not yet wired (see #55 and the skipped-line behavior), so step 1 needs a clip.
