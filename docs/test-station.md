# Safe test station (development builds only)

Source: `ios/AeroDJCore/Sources/AeroDJCore/TestStation/TestStation.swift`.

The whole file is wrapped in `#if DEBUG`, so it doesn't exist in Release builds. CI checks this with `ios/scripts/check-release-excludes-test-station.sh`, which builds Release and looks for the code. It also looks for it in Debug, so the check can't pass vacuously.

## What it guarantees

| | Test station |
|---|---|
| Voice | On-device `AVSpeechSynthesizer` only (`OnDeviceSpeechProvider`). `TestStation.makeRenderer` drops every paid route, and the budget is `$0` (`VoiceBudget(dailyCapMicrodollars: 0)`), so a paid reservation can never succeed |
| Briefing content | Synthetic fixtures only (`TestStation.fixtureSources`): 2 calendar items, 1 shared item and 1 note. Every title starts with `[TEST]`, and provenance is `fixture:synthetic/...`. They contain no PII and read no EventKit, files or share inbox. They expire at the end of the day |
| Consent | `TestStation.fixtureConsent` grants consent **for the fixture sources only**. Never pair it with a real context source |
| Settings | `TestStation.configuration` and `TestStation.cadence` use the final beta defaults: 30% talk cadence, 12 s plain breaks, 45 s briefing cap, briefing on with a 5-minute flexible target |
| Cache | 7-day retention (`AudioCacheRetention.maximum`) |

## Enabling it

1. In Xcode, open **Product → Scheme → Edit Scheme → Run → Arguments**.
2. Add the launch argument `-AeroDJTestStation YES`. A launch argument populates `UserDefaults`, so a debug setting can also set the bool under `AeroDJTestStation`.
3. Build and run the **Debug** configuration on the device.

App wiring is done on the integration branch (#58):

```swift
#if DEBUG
if TestStation.isEnabled() {
    let renderer = TestStation.makeRenderer(
        routes: [VoiceRoute(providerID: OnDeviceSpeechProvider.providerID,
                            provider: OnDeviceSpeechProvider(), voice: deviceVoice)],
        cache: FileAudioCache(directory: cachesDir, maxAge: TestStation.cacheRetention))
    let sources = TestStation.fixtureSources()   // instead of EventKit / Obsidian / share inbox
    let station = StationConfigurationModel(store: InMemoryStationConfigurationStore(
        snapshot: .init(state: .init(active: TestStation.configuration))), consent: TestStation.fixtureConsent)
    // cadence: TestStation.cadence; userID/stationID: TestStation.userID / .stationID
}
#endif
```

In test-station mode, don't construct the real calendar, Obsidian or share-inbox sources.

## Acceptance test (owner's iPhone Duo)

Run these with the test station enabled:

1. **Apple Music:** authorize on first launch. This uses real MusicKit with your own subscription. Fixtures replace only the personal context, never the music.
2. **Two full songs:** let two complete songs play without touching anything.
3. **DJ break:**
   - A short break may follow a natural song end. It happens at about 30% of eligible boundaries and never two in a row, so you may need a few songs.
   - The first break inside the briefing window carries the `[TEST]` briefing items, within the 45 s cap.
   - LIVE appears only while speech audio is actually playing (see `dj-presentation-state.md`).
4. **Pause and skip:**
   - Pausing stops music and speech.
   - Skipping a song cancels any break for that boundary (`notNaturalBoundary`), so the DJ never talks after a cut song.
5. **Background and interruptions:** background the app, lock the phone, and take or simulate a call or Siri. Music should resume per the interruption rules, and a break that misses its moment is skipped, not delayed.
6. **Fold and unfold:** repeat several times during a song and during a break. The song must not restart, and station settings, pending edits and the queue must survive.
7. **Settings change:** change energy mid-song. The control shows "Applies after this song", and the change takes effect only at the next boundary.

Expected spend: $0. If any paid voice provider appears in logs, that's a bug: stop and report it.

-Fry
