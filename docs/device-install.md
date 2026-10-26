# Installing a development build on a physical iPhone

Audience: the product owner, installing AeroDJ on their iPhone for testing.
Status: the unsigned device build is checked in CI. A signed install has not
been run yet, because it needs the owner's Apple Developer account.

## What only the owner can do (Apple credentials)

These need the owner's Apple ID and Developer account. Nobody else should
perform them, and no signing key, certificate or password goes into GitHub,
chat or this repository.

1. **Team and certificates.** In Xcode, Settings → Accounts, sign in with the
   Apple ID that belongs to the Developer team. Xcode creates the development
   certificate on that machine. The private key stays in that Mac's keychain.
2. **App IDs.** Xcode registers two App IDs on the team when the target is
   signed:
   - `com.aerodj.app` (the app)
   - `com.aerodj.app.share` (the Share Extension)
   If those IDs are taken by another team, change `PRODUCT_BUNDLE_IDENTIFIER`
   in `ios/project.yml` (both targets) and keep the share ID prefixed by the app ID.
3. **App Group.** `group.com.aerodj` is used by both targets
   (`AeroDJ.entitlements`, `AeroDJShare.entitlements`). Xcode registers it
   automatically when the team signs the app. Without it the Share Extension
   cannot hand items to the app.
4. **MusicKit.** The App ID needs MusicKit enabled in the Developer portal
   (Identifiers → `com.aerodj.app`). Verify this against current Apple
   documentation before the first install; it is not checked by CI.
5. **Device registration.** Connect the iPhone, enable Developer Mode on it
   (Settings → Privacy & Security → Developer Mode), and trust the Mac. With a
   free Apple ID the install expires after 7 days; a paid program lasts a year.

## Build configuration

- `ios/Config/Signing.xcconfig` holds shared, non-secret signing settings.
- Put your Team ID in `ios/Config/Signing.local.xcconfig`. That file is
  git-ignored:
  ```
  DEVELOPMENT_TEAM = YOURTEAMID
  ```
- Generate the project, as CI does:
  ```sh
  cd ios
  xcodegen generate          # XcodeGen 2.46.0
  open AeroDJ.xcodeproj
  ```
- Select the `AeroDJ` scheme and your iPhone as the run destination, then Run.

## Verify before installing

Each check is runnable without a device:

```sh
# Unsigned device build (same as CI's device-build job)
xcodebuild build -project ios/AeroDJ.xcodeproj -scheme AeroDJ \
  -sdk iphoneos -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
```

## Known gaps

- Deployment target is iOS 17.0 in `project.yml`. The UI branch (#52) may
  require a different target; reconcile before the device install.
- Apple Music playback, the DJ break and interruptions are not verified on
  hardware. The acceptance steps are in `docs/playback-boundary-handoff.md`.
- Paid voice providers stay disabled ($0 budget). Narration uses on-device
  speech only.

## Test station (Debug builds only)

The test station replaces real data with synthetic fixtures, so a device run
does not read the owner's calendar or shares, and does not spend money.

1. In Xcode, set the `AeroDJ` scheme's **Run** build configuration to **Debug**.
2. Edit the scheme → Run → Arguments → add `-AeroDJTestStation YES`.
3. Run on the iPhone. The Console log shows `runtime mode: testStation`.

Without the argument, or in a Release build, the same app logs `runtime mode: live`
and uses the real calendar and an empty station configuration.

What the test station guarantees: synthetic `[TEST]` context only; on-device
voice only, with a $0 budget that refuses any paid reservation; fixture station
configuration with fixture consent only.

## Install the integration head (owner's Mac)

1. Confirm the commit. Use the head SHA that #58 reports at the time of the
   install, and check it out:
   ```sh
   git fetch origin integration/device-duo
   git checkout <SHA reported on #58>
   ```
   Do not install from a branch name alone. Note the SHA in your install notes.
2. Generate the project and open it (see **Build configuration** above).
3. In Xcode, select the **AeroDJ** scheme, set the Run configuration to **Debug**,
   and choose your iPhone as the destination.
4. Add the test-station argument to **Run → Arguments** (see **Test station**).
   Without it the app runs in live mode and reads the real calendar.
5. Press Run. The first launch asks for Apple Music access. Grant it.

Expected first-launch log line: `runtime mode: testStation` (with the argument)
or `runtime mode: live` (without it).

## Collect sanitized logs

The app logs with the subsystem `com.aerodj.app`. The `playback` category records
song starts (index and duration in seconds) and natural boundaries (index only). It
never records song titles, artists or identifiers.

1. Connect the iPhone to the Mac. In Console.app, select the iPhone under Devices.
2. Filter the stream: `subsystem:com.aerodj.app`.
3. Start a station, let at least two songs play through, and let one DJ break run.
4. Export the matching lines (File → Save) and check them before sharing: they should
   contain only `runtime mode`, `song started` and `boundary` lines with indices
   and durations.

Command-line alternative. Check the flags with `xcrun devicectl device process launch --help`
on your Xcode version first; this form has not been run here:
```sh
xcrun devicectl device process launch --console --device <DEVICE_ID> com.aerodj.app
```
Keep the output file private. Do not paste raw device output into the repository or a
PR; describe the timings instead.

## Known limitations

- **Physical-device validation has not happened.** Nothing in this guide proves
  audible behavior, interruptions, or Duo fold/unfold on hardware.
- **Narration is wired but unverified on hardware.** `PlayerView` sends song
  starts, natural boundaries and break outcomes to `DJBreakSession`, and plays
  prepared multi-clip breaks at song boundaries. Whether speech starts and stops
  inside the real gap is unmeasured; see the log steps below.
- **Some context is not consumed by any screen.** `AppDependencies` builds the
  context sources and station configuration. Calendar and Notes readers are not
  yet reviewed for security before a real note is read.
- **Obsidian is not wired** in live mode: no app-side reader exists.
- **Station configuration is not persisted for live mode** beyond a JSON file;
  integration consent is `notRequested` for every integration until a consent
  flow exists.
- **Playback at the song boundary** is not validated on device. See
  `docs/playback-boundary-handoff.md`.
- **Apple Music on device** requires the owner's subscription and the MusicKit
  setting on the App ID (see the signing steps above).
- **Signing** needs the owner's Team ID in `ios/Config/Signing.local.xcconfig`.
  CI signs nothing.
