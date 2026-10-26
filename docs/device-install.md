# Installing AeroDJ on the Duo iPhone

Milestone A owner checklist for a development install on the physical iPhone.
A signed install has not been run on that device. Steps that need the phone,
a cable, or the Apple portal are marked **Unverified on device** where this
audit did not perform them.

Follow this file. The commit you build is a different tree, and that tree
contains an older `docs/device-install.md`. Build the SHA below, and use
these steps.

## Audit basis

| Item | Value |
| --- | --- |
| Install commit | `5dbf6d910195c06f7d4a03993951b25212b335f5` (`5dbf6d9`) |
| Branch name at audit | `integration/device-duo` (PR #58). If the branch moves, install this SHA. |
| PR #65 | Merged into `integration/device-duo` on 2026-10-26 14:27 UTC. This merge commit is the install target. Its tree `aaacf0d78b964f86d9b6a4ca998deeb586752118` is identical to #65 head `aaff7e151c7b65738d67a99a6a6d47158e37f908`. |
| iOS workflow | No GitHub Actions run exists on the install commit. The iOS workflow runs for pull requests. Run [40327400994](https://github.com/Rowerguy508/ai-radio-dj/actions/runs/40327400994) on `aaff7e151c7b65738d67a99a6a6d47158e37f908` (identical tree) succeeded on every job: changes, AeroDJCore tests, iOS simulator build, iOS device build (unsigned), Runtime mode on simulator (Debug vs Release), and Studio UI tests and screenshots. |
| Xcode logged by run 40269782784 | 26.6 (`/Applications/Xcode_26.6.app`). That run is not a run of this install commit. The workflow does not pin this. |
| Apple Developer team | `S85APB73YV` (Individual). App IDs `com.aerodj.app` (MusicKit, App Groups) and `com.aerodj.app.share` (App Groups), and app group `group.com.aerodj`, were registered on this team on 2026-10-26. No keys, certificates, or profiles were created in the portal. |
| Generated Xcode project | Not produced in this audit. The agent host cannot run the macOS XcodeGen binary. Settings below are from `ios/project.yml` and `ios/Config/Signing.xcconfig`. |

`main` does not contain the iOS app. Installing `main` will not put AeroDJ on the phone.

## 1. Prerequisites

1. Use a Mac with Xcode **26.6**, the version `xcodebuild -version` logged in run 40269782784. That run is not a run of this install commit. Before you install, open that run and confirm the logged version is still 26.6. `.github/workflows/ios.yml` on the install commit selects `/Applications/Xcode.app` in the simulator job and does not name a version, so a later run can move.
2. Install XcodeGen **2.46.0**, the version pinned in that workflow and named in `ios/project.yml`.
3. Use a USB cable for the first install. Wireless install was not part of this audit. **Unverified on device.**
4. On the Duo, confirm the system is **iOS 17.0 or later** (Settings > General > About). `ios/project.yml` sets the deployment target to iOS 17.0. The Duo's actual version was not read. **Unverified on device.**
5. Use team `S85APB73YV`. The identifiers for this install are already registered there (section 4). Switching to another team means registering the App IDs again on that team.

## 2. Paid versus free Apple ID

Apple's current account page is the source for the free Personal Team limits. Fetched 2026-10-26 from [About your developer account](https://developer.apple.com/help/account/basics/about-your-developer-account/):

- A free Apple Account signed into Xcode is a Personal Team. Xcode manages its App IDs, devices, certificates, and provisioning profiles.
- You can register up to 10 App IDs, which expire after 7 days.
- You can register up to 3 devices, which expire after 7 days.
- You can install up to 3 apps per device. Provisioning profiles that enable apps to be installed on a device expire 7 days from issuance. After that, rebuild and reinstall.
- Certificates, Identifiers & Profiles is listed for Apple Developer Program members and Apple Developer Enterprise Program members. The free column does not include it. The same page says that portal is how an enrolled member registers identifiers and turns on services.

This audit did not find a published lifetime for a paid development profile, so this checklist does not state one.

**App Groups.** [Supported capabilities (iOS)](https://developer.apple.com/help/account/reference/supported-capabilities-ios/) marks App groups as available for ADP, ADEP, and the free Apple Developer column (all three checked on the page fetched 2026-10-26). This checklist does not say that App Groups require a paid membership. Registering a group by hand is described in Certificates, Identifiers & Profiles, which a free registration cannot open. Apple also says a group can be created when you enable App Groups in Xcode ([Register an app group](https://developer.apple.com/help/account/identifiers/register-an-app-group/)). Whether a Personal Team can sign `group.com.aerodj` for these two targets was not run. **Unverified on device.**

**MusicKit.** Use a paid Apple Developer Program membership if this install must play Apple Music.

- [MusicKit](https://developer.apple.com/help/account/services/musickit/) tells you to enable the MusicKit checkbox on the App Services tab while registering the App ID in Certificates, Identifiers & Profiles.
- [Using Automatic Developer Token Generation for Apple Music API](https://developer.apple.com/documentation/musickit/using-automatic-token-generation-for-apple-music-api) says MusicKit generates the developer token for the app once that App Service is enabled, and that the service associates with the app's bundle identifier. The iOS app does not get a token file, a `.p8`, or a JWT. Do not create one, and do not commit one.
- [Generating Developer Tokens](https://developer.apple.com/documentation/applemusicapi/generating-developer-tokens) says requests to the Apple Music API require you to be a member of the Apple Developer Program, and it points Apple-platform apps at the automatic MusicKit path above. Minting a token yourself is the path for other platforms.

A free Personal Team cannot open the portal page where that checkbox lives. A development install can still be signed for on-device testing inside the limits above, and catalog playback still depends on the App Service. **Unverified on device.**

The embedded share extension is part of the app bundle. Apple's "3 apps per device" sentence does not say whether an embedded extension counts separately. This checklist does not treat it as a second app.

## 3. Check out the install commit

From a clone that can see the integration branch:

```sh
git fetch origin 5dbf6d910195c06f7d4a03993951b25212b335f5
git worktree add ../aerodj-duo 5dbf6d910195c06f7d4a03993951b25212b335f5
cd ../aerodj-duo
git rev-parse HEAD
```

`git rev-parse HEAD` must print `5dbf6d910195c06f7d4a03993951b25212b335f5`. Record that output in the validation notes. Keep this checklist open beside that worktree.

## 4. Register the bundle IDs, the App Group, and MusicKit

These identifiers already exist on team `S85APB73YV` (registered 2026-10-26). Do not register them again. Use the steps below only to confirm them in the portal, or to repeat the setup on a different team.

Configured identifiers, from `ios/project.yml` on the install commit:

| Target | Bundle ID | Entitlements file |
| --- | --- | --- |
| AeroDJ (app) | `com.aerodj.app` | `ios/AeroDJ/AeroDJ.entitlements` |
| AeroDJShare (share extension) | `com.aerodj.app.share` | `ios/AeroDJShare/AeroDJShare.entitlements` |

`com.aerodj.app.share` is prefixed by `com.aerodj.app`. Leave both IDs as they are. The UI-test bundle `com.aerodj.app.uitests` is not installed by a Run of the AeroDJ scheme. Do not register it for this install.

Both entitlements files contain only the App Group `group.com.aerodj` (`com.apple.security.application-groups`). There is no second group, and the two files match.

Done on team `S85APB73YV`. For reference, or for a different paid team, in [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources) (Account Holder or Admin):

1. Register an App Group with identifier `group.com.aerodj` ([Register an app group](https://developer.apple.com/help/account/identifiers/register-an-app-group/)).
2. Register an explicit App ID whose bundle ID is `com.aerodj.app`.
3. On that App ID, enable App Groups and assign `group.com.aerodj` ([Enable app capabilities](https://developer.apple.com/help/account/identifiers/enable-app-capabilities/)).
4. On the App Services tab, enable MusicKit ([MusicKit](https://developer.apple.com/help/account/services/musickit/), and the automatic-token article linked above). Enable it on `com.aerodj.app`, the bundle ID the article says the service binds to. The share extension does not need the MusicKit service.
5. Register an explicit App ID `com.aerodj.app.share`. Enable App Groups and assign the same `group.com.aerodj`.
6. Save. If the portal warns that existing profiles are now invalid, let Xcode create new development profiles on the next build. This repo has no checked-in profile to update.

No provisioning profile was created in the portal. Xcode automatic signing creates the development profile for both App IDs at the first device build.

The Xcode project does not list a MusicKit entitlement. Automatic signing will not turn the App Service on by itself. The portal step is required, and it is done on `com.aerodj.app` for team `S85APB73YV`. Playback with it is **Unverified on device.**

## 5. Local signing setup

Committed signing is `ios/Config/Signing.xcconfig`, applied to Debug and Release from `ios/project.yml` `configFiles`. It sets:

```
CODE_SIGN_STYLE = Automatic
#include? "Signing.local.xcconfig"
```

`DEVELOPMENT_TEAM` is not set in any committed file. The comment in `Signing.xcconfig` shows a placeholder assignment. Leave that line as a comment.

1. In Xcode, Settings > Accounts, sign in with the Apple ID that belongs to team `S85APB73YV`. Let Xcode create the Apple Development certificate in that Mac's keychain. The private key stays on that Mac.
2. In the install worktree, create `ios/Config/Signing.local.xcconfig` with one assignment:

```
DEVELOPMENT_TEAM = S85APB73YV
```

3. Confirm Git will not pick the file up. From the worktree root:

```sh
git check-ignore -v ios/Config/Signing.local.xcconfig
git status --short
```

The ignore rule is the repo-root `.gitignore` entry `ios/Config/Signing.local.xcconfig`. `git status` must not list that file. Keep the Team ID in that local file, not in committed config. Do not commit a `.p12`, a `.mobileprovision`, a `.p8`, or any certificate. Those types are gitignored. None are in the install commit.
4. Generate the project and open it:

```sh
cd ios
xcodegen generate
open AeroDJ.xcodeproj
```

5. For the AeroDJ and AeroDJShare targets, Signing & Capabilities should show team `S85APB73YV` from the local file and Automatically manage signing. On the first device build, Xcode creates the development profiles. Leave the bundle IDs and the entitlements files unchanged. Do not add the Team ID to `Signing.xcconfig`, `project.yml`, or the target settings.

CI on the install commit builds with `CODE_SIGNING_ALLOWED=NO`. That flag is for CI only. A device Run needs the team file and signing allowed.

## 6. Developer Mode, and trusting the developer if the phone asks

Apple's steps: [Enabling Developer Mode on a device](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device). **Unverified on device.**

1. Connect the Duo with the cable and, if the phone asks, trust this computer.
2. Developer Mode appears in Settings after the device has been paired with the Mac. Open Settings > Privacy & Security > Developer Mode and turn it on.
3. Tap Restart in the alert. After the phone boots, confirm Enable and enter the passcode.
4. If the phone then says the developer is not trusted, open Settings > General > VPN & Device Management, select the developer app entry, and trust it. An Apple DTS engineer has written that an ordinary Xcode Run, with Developer Mode on, is often enough and that a leftover "untrusted developer" message can be stale ([forum thread 743125](https://developer.apple.com/forums/thread/743125)). Do this trust step when the phone asks for it. The enterprise-app trust flow is documented separately at [Install custom enterprise apps](https://support.apple.com/en-us/118254) and is not this install.

## 7. Release and Debug: what each build is for

Use the **AeroDJ** scheme. `ios/project.yml` does not set a Run build configuration for that scheme. Before either build, open Product > Scheme > Edit Scheme > Run > Info > Build Configuration and set it explicitly. Do not assume the popup already says the configuration you want.

**Debug** is for development.

- The test station is compiled only in Debug (`ios/AeroDJCore/Sources/AeroDJCore/TestStation/TestStation.swift` is wrapped in `#if DEBUG`).
- It turns on only when the launch argument is present. Edit Scheme > Run > Arguments > Arguments Passed On Launch, and add `-AeroDJTestStation` and `YES` as two entries.
- Debug with that argument uses synthetic context, on-device voice with a $0 paid cap, and fixture station configuration. It still uses the real `MusicKitService` session. Opening a station still requests Apple Music.
- Debug without that argument is live: the real calendar path and the live station configuration. The simulator check on this SHA expects the log line `runtime mode: live` for "Debug, no argument".

**Release** is the validation build.

- `AppDependencies.make` reads the flag only inside `#if DEBUG`. Release always composes the live dependencies. `AppRuntimeMode.resolve` returns `.live` when `allowsTestStation` is false.
- Leave `-AeroDJTestStation` `YES` in the scheme for the gate. The validation proof is that Release ignores it.
- The simulator job "Runtime mode on simulator (Debug vs Release)" succeeded on run [40327400994](https://github.com/Rowerguy508/ai-radio-dj/actions/runs/40327400994) (pull request head `aaff7e151c7b65738d67a99a6a6d47158e37f908`, the same tree as this install commit) and expects `runtime mode: live` when the Release app is launched with that argument (`ios/scripts/verify-runtime-mode.sh`). That job is a simulator. **Unverified on device.**

The station list in both configurations is still the two hardcoded stations in `Station.mockStations` (see the findings in the pull request). A Release install of this SHA is a signing and runtime-mode check, not a check of a real station catalog.

## 8. First-launch permission prompts

Nothing in this section was observed on hardware. **Unverified on device.**

**Apple Music.** The station list does not request it. Opening a station runs `PlayerView`'s `.task`, which calls `MusicKitService.authorize()` and `MusicAuthorization.request()`. The purpose string generated for the app target is:

> AeroDJ uses Apple Music to play your station.

That string is `INFOPLIST_KEY_NSAppleMusicUsageDescription` in `ios/project.yml`. The same call runs in the Debug test station, because that path still assigns `MusicKitService.shared`. A grant from the person using the phone is separate from the MusicKit App Service on the App ID. If the service is off, turning the prompt on is not enough for catalog requests. There is no developer token to paste in.

**Calendar.** Launch does not request it. In a live build, the calendar source offers **Allow access** (`ConnectionAction.allowAccess`). That action calls `requestFullAccessToEvents`. The purpose string is:

> AeroDJ reads today's events, read-only, to mention them in your briefing.

That string is `INFOPLIST_KEY_NSCalendarsFullAccessUsageDescription`. The deployment target is iOS 17.0, and the reader uses the iOS 17 full-access API. The Debug test station does not construct `EventKitCalendarReader`, so that prompt is not expected on the test-station path.

Microphone and notification prompts are not part of this install path.

## 9. Confirm the test station is off in Release

**Unverified on device.** Do this on the Duo after the Release Run.

1. Edit Scheme > Run > Build Configuration is Release.
2. Arguments Passed On Launch contains two entries, `-AeroDJTestStation` and `YES`. Add them if they are absent, and leave them there for this run. The proof is that Release ignores them.
3. Run on the Duo.
4. On the Mac, open Console.app, select the Duo, and filter subsystem `com.aerodj.app`, category `runtime`.
5. The launch line from `AeroDJApp` is a `notice` log: `runtime mode: live`, plus a context-source count. `testStation` in that line means this is not the validation build. Stop and check the scheme configuration.
6. Open a station. The navigation title area must not show the text `TEST STATION`. That label is shown when `isTestStation` is true (`PlaybackComponents.swift`), which follows `dependencies.mode == .testStation`.

This install commit includes the playback logs from PR #65, which is merged into `integration/device-duo`. Those lines are an index and a duration for a song start, and an index for a boundary. They do not include song titles or artists. Do not expect those.

## 10. Troubleshooting signing

**Unverified on device.** Match the Xcode error, then fix only the local machine or the portal. Do not commit the fix into `Signing.xcconfig` or `project.yml`.

1. **Signing for "AeroDJ" requires a development team.** `Signing.local.xcconfig` is missing, the `DEVELOPMENT_TEAM` line is missing, or Xcode is not signed into that team. Repeat section 5. The `#include?` in `Signing.xcconfig` skips a missing local file, so the project still opens and the device build then fails.
2. **Failed to register bundle identifier**, or the identifier is unavailable. `com.aerodj.app` or `com.aerodj.app.share` is already registered to another team. Stop and report it. Do not edit `PRODUCT_BUNDLE_IDENTIFIER` in this install. Changing either ID has to keep the extension ID prefixed by the app ID, and it has to be done in `ios/project.yml` by the person who owns that change.
3. **Your maximum App ID limit has been reached**, on a free team. The account page caps a Personal Team at 10 App IDs, expiring after 7 days. Wait for expiry or move the install to the paid team. A free team also stops at 3 registered devices.
4. **Provisioning profile doesn't support the App Group** or doesn't include `group.com.aerodj`. Assign `group.com.aerodj` to both App IDs, `com.aerodj.app` and `com.aerodj.app.share`, then build again so Xcode refreshes the profiles. On a free team, this is the unverified Personal Team case in section 2.
5. **Profile has expired**, about 7 days after a free-team install. Rebuild and reinstall. Apple's page says the provisioning profile expires 7 days from issuance.
6. **Developer Mode required**, or the app will not launch after install. Repeat section 6, including the restart and the passcode confirmation.
7. **Untrusted Developer.** If the phone asks, trust the developer under Settings > General > VPN & Device Management. If Developer Mode is already on and Xcode's Run is in progress, check the Xcode error before hunting for a profile entry. See section 6.
8. **Apple Music permission was granted and catalog requests still fail.** Confirm the MusicKit App Service is enabled on the explicit App ID `com.aerodj.app`. Do not add a developer token to the app.

## 11. Evidence to capture for the validation gate

Capture this from the Release Run. Keep certificates, provisioning profiles, and raw logs that contain calendar titles or song titles out of git, chat, and the pull request. **The capture itself is unverified on device;** the list is what to bring back.

1. `git rev-parse HEAD` printing `5dbf6d910195c06f7d4a03993951b25212b335f5`.
2. `xcodebuild -version` from the Mac that installed it.
3. The scheme name AeroDJ, Run configuration Release, and the Duo as the run destination.
4. `git check-ignore -v ios/Config/Signing.local.xcconfig` and a `git status --short` that does not list that file.
5. The Console `runtime` line showing `runtime mode: live` while `-AeroDJTestStation YES` is still in the scheme.
6. A note that the station screen did not show `TEST STATION`.
7. Which system prompts appeared, and whether the purpose text matched the two strings in section 8.
8. Any signing error from section 10, including the exact Xcode sentence.

Fold and unfold behavior of the Duo is not part of this gate. The install commit's integration notes already call that unverified, and this audit did not test it.

## 12. What this checklist does not prove

- No signed build was installed on the Duo, or on any other phone, during this audit.
- No GitHub Actions run exists on the install commit. Run [40327400994](https://github.com/Rowerguy508/ai-radio-dj/actions/runs/40327400994) on `aaff7e151c7b65738d67a99a6a6d47158e37f908` (identical tree) succeeded on every job, including Runtime mode on simulator (Debug vs Release), iOS device build (unsigned), and Studio UI tests and screenshots. The simulator job is not a device result. The unsigned device build is not a signature, a provisioning profile, or a launch.
- Apple Music playback, DJ speech, interruptions, and calendar narration were not run on hardware.
