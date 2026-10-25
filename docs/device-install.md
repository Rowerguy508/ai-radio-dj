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
