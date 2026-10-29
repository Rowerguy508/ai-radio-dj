# Build 26 device QA checklist (owner's iPhone, "the Duo")

> **Nothing on this list has been run on a device yet.** Every expected result comes from
> reading the code and docs on `integration/device-duo`, plus the open PRs that are queued
> for build 26. CI cannot play Apple Music audio, so this run is the first real proof.

**Device:** the Duo, which is an iPhone. Everything below is about iPhone portrait and landscape.

**Before you start**
- [ ] **B-1 Build contents.** Build 26 must include **#211** (DJ lines that name a library or
      unknown-origin track stay on-device; only `.catalog` tracks may use the cloud voice) and
      **#218** (created-station follow-ups). If the TestFlight build notes show a commit without
      them, stop and report it before running S and C items. #215, #216 and #220 are CI or
      test-only and change nothing on the phone.
- [ ] **B-2 Build type.** On the Player screen, look at the top right for a **"DJ talk-over"**
      button (waveform icon). It exists only in an owner A/B build (`owner_ab: true`, which
      compiles `AERODJ_OWNER_AB`). If it is there, run every T item. If it isn't, talk-over is
      OFF in this build: run T-1 and T-15 and mark T-2 to T-14 "N/A (not A/B)".
- [ ] **B-3 DIAG.** If the build was dispatched with `p0_diag: true`, the Player screen shows the
      P0 trace panel ("rows · newest first"). Talk-over rows are tagged `talkover` and hold
      codes and numbers only.

**What to capture when something fails** (each item below says which):
- **Rec:** an iOS screen recording (Control Center). A screen recording may not pick up Apple
  Music audio, so for **sound** items also record the speaker with a second phone (Voice Memos).
- **Time:** the clock time of the failure in ET, to the minute, so it can be matched to logs.
- **Trace:** DIAG builds only. A screenshot of the P0 trace panel covering the failure, or the
  Console.app lines for subsystem `com.aerodj.app`.
- Always note the route (speaker, wired, AirPods) and the item ID.

---

## 1. Install and first launch

- [ ] **I-1 Build number.** Install build 26 from TestFlight.
  - Expected: TestFlight shows build **26** for AeroDJ. (The app itself doesn't display a build number.)
  - If it fails: a screenshot of the TestFlight page.
- [ ] **I-2 No prompts at launch.** Launch with Apple Music access never granted (delete and
      reinstall first if you want a clean run).
  - Expected: the station list ("AeroDJ") opens. No Apple Music, Calendar, microphone or
    notification prompt appears on its own. No music plays.
  - If it fails: Rec from the launch, Time.
- [ ] **I-3 Apple Music prompt only on a tap.** Tap a built-in station.
  - Expected: the system Apple Music prompt appears now, after your tap, not before. A tap on
    a built-in station opens it and never starts music: its hint is "Opens the station. Music
    starts only when you press Play."
  - If it fails: Rec, Time.
- [ ] **I-4 Allow from the player.** If you dismissed the prompt, the player shows "Allow Apple
      Music to play your station." with an **Allow Apple Music** button. Tap it.
  - Expected: the prompt appears only from that tap. After you allow it, the player shows
    "Nothing playing" and "Search Apple Music to start your station."
  - If it fails: Rec, Time.
- [ ] **I-5 Denied state.** (Optional) Deny Apple Music, then open a station.
  - Expected: "Apple Music access is off", "Allow Apple Music for AeroDJ in Settings to play your
    station." and an **Open Settings** button. No second system prompt.
  - If it fails: a screenshot, Time.

## 2. DJ talk-over (#210, with #209's radio-style breaks)

How it is meant to sound: the end of song A ducks (gets quieter) while the DJ's main line plays
(at most 15 s). After a ~0.3 s pause, a short closing line (at most 4 s, naming the next song)
plays over the start of song B. When it ends, song B rises back to full level. Song B's start is
called early by a learned lead-in (0.8 s default, adjusted per break, clamped to 0.3–2 s).
Breaks happen at roughly 30% of song ends, never in back-to-back songs, so you may need several
songs per item. Duck depth and ramp are set by iOS and can't be tuned in code.

- [ ] **T-1 Toggle off = today's break.** Tap **DJ talk-over** to off (icon shows waveform with a
      slash). Play through two DJ breaks. (In a normal build there's no button; just play two breaks.)
  - Expected: each break plays in a gap with the music stopped, exactly as in build 25. The
    toggle takes effect from the next break.
  - If it fails: Rec + sound, Time, Trace.
- [ ] **T-2 Duck happens (first and most important check).** Toggle on. Wait for a break.
  - Expected: as the DJ starts, the music gets clearly quieter but **keeps playing**. **If the
    song does not get quieter at all, stop the T section and report T-2 fail.** The design then
    needs another approach, and the toggle should stay off.
  - If it fails: sound recording, Time, Trace (`talkover kind=duckProbe` row: note `otherAudio`).
- [ ] **T-3 Duck depth and fade-down.** Same break.
  - Expected: you can still hear the song under the voice, and the voice is easy to follow.
    The drop takes well under a second. Note roughly how deep (a little, about half, very
    quiet) and whether there's a click when the voice starts.
  - If it fails: sound recording, Time.
- [ ] **T-4 Music never stops.** Through the whole break.
  - Expected: no silence between song A and song B. Song A's end runs under the main line and
    song B starts under the closing line. No dead air longer than a breath.
  - If it fails: sound recording, Time, Trace (`miss` rows, e.g. `nextStartLate`, `endedBeforeVoice`).
- [ ] **T-5 Lead-in timing.** Listen at the handover.
  - Expected: after the main line there's a short pause (~0.3 s), then the closing line, with
    song B starting just under it. Song B shouldn't start seconds before or after the closing line.
    One late start can happen; repeated ones are a fail.
  - If it fails: sound recording, Time, Trace (`latency measured` and `lat` rows).
- [ ] **T-6 Closing line lands before vocals.** Over 3–5 breaks.
  - Expected: the closing line ends before song B's singing starts in most songs. Songs with
    very short intros may overlap (the line is capped at 4 s): note the song if so.
  - If it fails: sound recording, Time, the song name in the room (not in the trace).
- [ ] **T-7 Swell back to full level.** When the closing line ends.
  - Expected: song B rises back to full level smoothly, not in a jump. Keep listening 10 s at a
    normal volume: song B must **never stay ducked** after the voice.
  - If it fails: sound recording, Time, Trace.
- [ ] **T-8 Hard-break fallback: long break or briefing.** Wait for a briefing break (or any break
      whose voice runs long), and a break after a very short song (under 60 s) if one comes up.
  - Expected: these play as a normal gap break, music stopped, voice, then song B. A briefing
    can run up to 45 s and is always a gap break (talk-over handles at most ~20 s of voice).
    Trace shows `decision mode=hardBreak`.
  - If it fails: Rec + sound, Time, Trace.
- [ ] **T-9 Phone call during the voice.** Have someone call you while the DJ is talking over music.
  - Expected: the voice stops (trace `cancel reason=interruption`). Music follows the usual call
    rules: paused during the call, resuming afterwards only if iOS allows it. Nothing stays
    ducked after the call.
  - If it fails: sound recording, Time, Trace.
- [ ] **T-10 Siri during the voice.** Same as T-9, using Siri.
  - Expected: same as T-9.
  - If it fails: sound recording, Time, Trace.
- [ ] **T-11 AirPods out / route loss.** Using AirPods (or wired), take them out or turn Bluetooth
      off while the DJ is talking. Repeat once during the closing line, while song B is starting.
  - Expected: the voice stops (`cancel reason=routeRemoved`) and never continues from the
    speaker. Music follows the usual route rules. Nothing stays ducked when you reconnect
    (check 10 s at normal volume), and a later break still happens.
  - If it fails: Rec + sound, Time, Trace.
- [ ] **T-12 Lock screen.** Start a break, then lock the phone. Also lock before a break and let
      one happen while locked.
  - Expected: no stuck duck after unlocking, and music keeps playing. Whether the voice keeps
    going while locked is not confirmed from code: note what you hear.
  - If it fails: sound recording, Time, Trace.
- [ ] **T-13 Pause during the voice.** Tap Pause while the DJ is talking over music.
  - Expected: voice and music both stop at once (`cancel reason=userStop`). Tap Play: music
    continues with nothing ducked, and the DJ doesn't start talking in the middle of the song.
  - If it fails: Rec + sound, Time, Trace.
- [ ] **T-14 Skip during the voice.** Tap Skip while the DJ is talking over music.
  - Expected: the voice stops (or fades out quickly) and the next song plays at full level. The
    DJ never talks after a song you cut. A seek during the voice behaves the same.
  - If it fails: Rec + sound, Time, Trace.
- [ ] **T-15 (Info) Toggle setting after switching builds.** Only if you ever had an owner A/B build
      on this phone and then install a normal build over it.
  - What the code does: the toggle is saved on the phone under `AeroDJTalkoverEnabled`.
    Installing another build over it keeps that saved value. The app has no iOS Settings page,
    so Settings → AeroDJ shows nothing about talk-over. A normal build has no button, and its
    default is OFF. **But a saved value wins over the default**, so if you touched the toggle
    in the A/B build and left it ON, a normal build will still talk over.
  - Check: in the normal build, play two breaks. Intended: gap breaks (OFF). If you hear
    talk-over, report T-15 "carried over". Deleting and reinstalling the app clears it.
  - Capture: sound recording, Time, which build was installed before.

## 3. Station create then play (#213, #218)

Create a station first: on the station list tap **Add station** (+), pick artists, a genre or
a playlist, and save. Expected confirmation: "“‹name›” is in your Stations list. Open it there
when you want it. Nothing that's playing changed." The new row's summary is fixed text, e.g.
"Your station from 2 artists", "Your artist station", "Your genre station" or "Your playlist
station". It never shows a seed's name.

- [ ] **S-1 Saving doesn't play.** Save a station while music plays, and once with nothing playing.
  - Expected: nothing starts or changes. The new row appears in the Stations list at once.
  - If it fails: Rec, Time.
- [ ] **S-2 Idle tap starts now.** With nothing queued, tap the created station.
  - Expected: it starts playing on its own within about 10 s. (Its VoiceOver hint: "Plays the
    station now if nothing is queued, otherwise after this song.")
  - If it fails: Rec, Time, Trace.
- [ ] **S-3 While playing, it switches at the song end.** Play a built-in station, then tap the
      created station.
  - Expected: the current song keeps playing to its end, then the created station takes over.
    Nothing is cut mid-song.
  - If it fails: Rec + sound, Time, Trace.
- [ ] **S-4 Re-tap keeps Tune edits.** Open the created station, then open **Tune station**,
      change something (e.g. energy) and don't save, so the "Unsaved changes" card shows. Go
      back and tap the same created station again.
  - Expected: the recipe is not applied again. Your edits are still there ("Unsaved changes"
    is still shown).
  - If it fails: Rec, Time.
- [ ] **S-5 Recipe applied in Tune, then re-tap.** Tap created station A. In Tune → "Station
      recipes", tap **Apply** on a different recipe B. Go back and tap station A again.
  - Expected: A is applied again. The station's settings are A's, not B's. (This was the #218
    blocker.)
  - If it fails: Rec, Time.
- [ ] **S-6 Built-in tap cancels a waiting start.** With nothing queued, tap a created station,
      then tap a built-in station immediately, before music starts.
  - Expected: the created station never starts later. Nothing plays until you press Play.
  - If it fails: Rec, Time, Trace.
- [ ] **S-7 Relaunch never auto-plays.** With a created station selected, close the app from the
      app switcher and reopen it. Also try backgrounding for a few minutes and reopening.
  - Expected: no music starts, no Apple Music prompt appears and no recipe is applied until you tap.
  - If it fails: Rec from launch, Time.

## 4. Created-station start on the Duo (#217 item 4 / #218, #220)

This is the physical-device check #217 asked for. #220 is tests only; the app behaviour comes
from #218.

- [ ] **C-1 One tap, one start.** With nothing queued, tap a created station once.
  - Expected: it starts **once** (one first song, no restart after a few seconds). Tap it again:
    it is not applied again and doesn't restart (S-4 rules).
  - If it fails: Rec + sound, Time, Trace.
- [ ] **C-2 Built-in tap during the Apple Music prompt.** Start with Apple Music not yet granted
      (fresh install). Tap a created station; when the system Apple Music prompt is up, allow
      it, then tap a built-in station right away.
  - Expected: the created station does not start later, even after its queue is ready. Nothing
    plays until you press Play.
  - If it fails: Rec, Time, Trace.
- [ ] **C-3 Built-in tap while the queue builds.** With access granted and nothing queued, tap a
      created station and, before music starts (it can take a few seconds), tap a built-in station.
  - Expected: the late queue never starts. No music, and no DJ intro.
  - If it fails: Rec + sound, Time, Trace.
- [ ] **C-4 Relaunch starts nothing.** After C-3, close the app from the app switcher and reopen.
  - Expected: nothing starts and nothing is prompted until you tap.
  - If it fails: Rec, Time.
- [ ] **C-5 A fresh tap starts exactly once.** Now tap the created station.
  - Expected: it starts exactly once (one queue, one first song).
  - If it fails: Rec + sound, Time, Trace.
- [ ] **C-6 (Build 27 only, #221) Generic failure toast.** Turn on Airplane Mode with Apple Music
      allowed and nothing queued, then tap a created station.
  - Expected: within about 10 s a toast at the top says "Couldn't start that station" and goes
    away after about 3 s. It doesn't cover the back button or the transport. Mark "N/A
    (build 26)" for now.
  - If it fails: Rec, Time.
- [ ] **C-7 (Build 27 only) Apple Music denied.** With Apple Music denied in Settings, tap a
      created station.
  - Requested copy: "Connect Apple Music to play this station". **That string isn't in the code
    on any branch yet** (checked up to #221 at 6627af3). As #221 is written, this case probably
    shows the generic "Couldn't start that station". Mark "N/A (build 26)". In build 27, report
    which text you see.
  - If it fails: a screenshot, Time.

## 5. Genre list (#214)

Genres appear in two places: Tune → Sound → Genres (suggestion chips) and the Add station
genre step ("Filter genres"). Both fetch once from Apple Music and filter on the phone.

- [ ] **G-1 With Apple Music access.** Open Tune station, then Genres.
  - Expected: "Loading Apple Music genres" briefly, then genre chips from Apple Music (no
    "Music" root genre). In Add station → Genre, "Loading genres", then the list.
  - If it fails: a screenshot, Time.
- [ ] **G-2 Without Apple Music access.** With access not granted (or denied), open Tune → Genres
      and Add station → Genre.
  - Expected: "Connect Apple Music to see genres." with **no** button and **no** system prompt.
    Typing your own genre in "Add your own" still works.
  - If it fails: Rec, Time.
- [ ] **G-3 Relaunch into Tune.** Leave Tune open, close the app from the app switcher and
      reopen; repeat once with access not granted.
  - Expected: no Apple Music prompt at launch. With access, genres load. Without, the
    "Connect Apple Music to see genres." line shows.
  - If it fails: Rec from launch, Time.
- [ ] **G-4 Offline, then Try again.** Turn on Airplane Mode on a fresh launch with access,
      then open Tune → Genres (or Add station → Genre).
  - Expected: a short error with a warning icon and a **Try again** button (offline wording:
    "You're offline. Connect to the internet and search again."; the Tune fallback is "Couldn't
    load genres from Apple Music."). Turn Airplane Mode off and tap **Try again**: genres load.
  - If it fails: a screenshot, Time.
- [ ] **G-5 Only "Try again" refetches.** While in the G-4 error state (still offline), close
      and reopen the Tune sheet and type in "Filter genres" / "Add your own".
  - Expected: nothing reloads by itself, and typing never refetches. It filters the loaded list
    ("No genres match. Try another word." when nothing matches). Only **Try again** fetches.
  - If it fails: Rec, Time.

## 6. Now Playing on the Duo (#207, #159)

- [ ] **N-1 Portrait.** Play a station in portrait.
  - Expected: artwork, title, artist and DJ status line, then the scrubber, Play/Pause and Skip,
    then the bottom bar ("Playing from ‹Station›" chip, Queue, Tune). Nothing clipped, no word
    split mid-word. Remaining time is signed (e.g. `-0:13`).
  - If it fails: a screenshot, Time.
- [ ] **N-2 Landscape.** Rotate to landscape while playing.
  - Expected: one centred column (title, artist and DJ status centred; Play/Pause on the centre
    line; **⋯** in a header row on the column instead of the nav bar). Music doesn't stop or
    restart when you rotate. On a Plus/Pro Max size iPhone, landscape may switch to the
    two-pane Studio (Queue | Tune | Connections) instead; note which you see.
  - If it fails: a screenshot of each orientation, Time.
- [ ] **N-3 Nav bar not covered.** In portrait and landscape, on the station list and the player
      (and with the DIAG trace panel or the talk-over button present, if your build has them).
  - Expected: no overlay, toast, glass panel or button covers the **back** button or the title,
    and both are tappable.
  - If it fails: a screenshot, Time.
- [ ] **N-4 Dynamic Type, large.** Settings → Accessibility → Larger Text, one step above default
      and at the largest non-accessibility size.
  - Expected: no clipped or overlapping text, and transport still reachable above the home indicator.
  - If it fails: a screenshot, Time.
- [ ] **N-5 Dynamic Type AX5.** Largest accessibility size, portrait and landscape.
  - Expected: you can reach all text (scroll if needed), and Play/Pause and Skip stay reachable
    and tappable. Note anything clipped or overlapping.
  - If it fails: a screenshot, Time.
- [ ] **N-6 Dark and light mode.** Switch system appearance while playing.
  - Expected: the player and station list stay dark either way (by design). The Queue and Tune
    sheets stay readable in both.
  - If it fails: a screenshot, Time.
- [ ] **N-7 DJ idle.** During a song with no break coming.
  - Expected: no DJ line and no ON AIR.
  - If it fails: a screenshot, Time.
- [ ] **N-8 DJ preparing / ready.** Before a break.
  - Expected: a quiet capsule, "Preparing the break after this song" (or "Preparing your
    briefing for after this song"), then "DJ break after this song" (or "Briefing after this
    song"). **No ON AIR**, no timer, nothing animating.
  - If it fails: Rec, Time, Trace.
- [ ] **N-9 DJ speaking.** During the voice (gap break or talk-over).
  - Expected: the amber **ON AIR** pill with a running timer appears only while the voice is
    audible, and disappears the moment the voice ends (for talk-over, when the closing line ends).
  - If it fails: Rec + sound, Time, Trace.
- [ ] **N-10 DJ failed.** If a break can't play, the line reads "DJ voice unavailable" (or "DJ
      voice limit reached"), with no error colour and no alert. Music continues.
  - Expected: as described; ON AIR never shows for a failed or skipped break.
  - If it fails: a screenshot, Time, Trace.
- [ ] **N-11 Queue sheet.** Tap Queue in the bottom bar.
  - Expected: a sheet with Queue | Tune | Connections and **Done**. Queue is read-only (no
    reorder or delete). It drags between half and full height. Music is unaffected.
  - If it fails: a screenshot, Time.
- [ ] **N-12 Short track end (#159).** Play a very short track (the owner's 2.4 s "Concert for
      You", Toby Fox) in a queue with more songs after it.
  - Expected: it plays, then the next song starts. No stall on that track.
  - If it fails: Rec + sound, Time, Trace.

## 7. Privacy quick checks

- [ ] **P-1 No personal data without consent.** Fresh install, play for a few songs with nothing
      connected. Then open ⋯ → **Connections**.
  - Expected: no Calendar prompt, and no DJ line mentions calendar events, notes or shared
    items. Calendar asks only after you tap **Allow access**; Obsidian reads only files you pick;
    shared items need your **Approve** before the DJ can mention them.
  - If it fails: Rec + sound, Time.
- [ ] **P-2 Revoking stops use and purges.** Approve one shared item (or connect Calendar), wait
      for it to be mentioned, then tap **Stop using** (or **Delete** for a shared item).
  - Expected: the row then says "You stopped using this. Nothing from here is used. Choose again
    to turn it back on." (or "Not used. You turned this off." for an item). It is never mentioned
    again, including a break that was already prepared. Deleting cached audio can't be seen on
    the phone; DIAG only can confirm the purge.
  - If it fails: Rec + sound, Time, Trace.
- [ ] **P-3 No paid voice by default.** In an A/B build open **Owner voice test** (bottom of the
      station list) and leave it on "On-device only" with no proxy token.
  - Expected: every DJ line uses the built-in iPhone voice. In a normal build there is no Owner
    voice test button and all lines are on-device.
  - If it fails: sound recording, Time.
- [ ] **P-4 Library tracks stay on-device (#211).** Only if a cloud voice is set up in Owner
      voice test. Play a catalog station where a song from your own library comes up next.
  - Expected: a line that names a library track (including the closing line) is in the on-device
    voice, even when the rest of the break uses the cloud voice.
  - If it fails: sound recording, Time.

## 8. Not in build 26

- "Couldn't start that station" toast (#221) and any Apple-Music-denied station copy: build 27 (C-6, C-7).
- Self-hosted Mac CI runner (#216) and gate-script fix (#215): CI only.
- Talk-over ON for everyone: stays owner A/B only until T-2 to T-7 pass on this phone.
- Intro-only fallback if ducking doesn't work: not built.
- The Test Station is Debug-only and isn't in TestFlight builds.
- Queue editing (reorder or delete) in the Queue sheet: read-only by design.

## How to report

Post in the AeroDJ room, one line per item: **item ID, pass/fail, recording**. For example:
"S-3 fail, recording attached, 9:42 PM ET, AirPods". Group passes: "T-1, T-3 to T-7 pass".
Keep song titles, calendar items and shared text out of the trace screenshots you post.
