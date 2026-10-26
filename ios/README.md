# AeroDJ Native iOS

Native SwiftUI rebuild of AeroDJ. The existing Next.js web app is preserved as a
legacy/prototyping client — this is the new product UI.

## Structure

```
ios/
├── project.yml       XcodeGen spec (source of truth for AeroDJ.xcodeproj)
├── AeroDJ/            SwiftUI app shell (no API secrets)
│   ├── AeroDJApp.swift
│   ├── StationListView.swift
│   ├── PlayerView.swift            # UI mock: toggles a local Bool, plays nothing (MusicKit = #15)
│   └── AeroDJ.entitlements         # App Group group.com.aerodj
├── AeroDJCore/        Pure Swift package: models + protocols (buildable/testable standalone)
│   ├── Sources/AeroDJCore/
│   │   ├── ContextItem.swift          # provenance-tracked, consent-gated context
│   │   ├── BriefingPlan.swift         # segment schedule
│   │   ├── Protocols.swift            # BriefingPlanner, BroadcastScheduler, VoiceProvider, ContextSource, UsageMeter
│   │   ├── DefaultBriefingPlanner.swift
│   │   ├── InMemoryUsageMeter.swift
│   │   └── SharedInboxItem.swift      # bounded, expiring Share Extension envelope
│   └── Tests/AeroDJCoreTests/         # unit tests with an injected clock
└── AeroDJShare/       Share Extension (shared text or one web URL → App Group inbox), embedded in AeroDJ.app
```

## Build & test

Core package (no Xcode needed; also runs on Linux with a Swift 6 toolchain):
```sh
cd ios/AeroDJCore
swift test
```

Full app: generate the project with [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.46.0 (the version CI pins), then open it:
```sh
cd ios
xcodegen generate
open AeroDJ.xcodeproj
```
`AeroDJ.xcodeproj` is generated and not committed; edit `project.yml` instead. CI (`.github/workflows/ios.yml`) generates the project, builds the app with the embedded share extension for the simulator, checks the `.appex` is embedded, and runs the core tests on an iPhone simulator. All targets build in Swift 6 language mode.

## Architecture principles

- **Native first:** Apple APIs (EventKit, MusicKit, Files, Share Extension) before external providers.
- **Pluggable voice:** `VoiceProvider` protocol; Cartesia (server-side), AVSpeechSynthesizer fallback, Dessa stub (disabled until a real API exists), ElevenLabs comparison.
- **No secrets in client:** all provider keys server-side only.
- **No protected-stream mixing:** Apple Music playback stays managed by MusicKit; no capture/decrypt/mix of DRM streams.
- **No inbox scraping:** Share Extension + user-imported content only. `ContextItem` is provenance-tracked and consent-gated.
- **Cost safeguards:** `UsageMeter` records per-user usage; budget enforcement is not implemented yet (#22). No speculative prefetch; cache only reusable generic audio.

## Privacy / permissions matrix

See `docs/PRIVACY_MATRIX.md` (issue #14).
