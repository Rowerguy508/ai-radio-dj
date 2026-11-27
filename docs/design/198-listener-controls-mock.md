# #198 listener controls: mock for owner review

Status: **MOCK ONLY, not in the app.** Debug-only Studio capture (`ios/AeroDJ/Mockups/ListenerControlsMock.swift`, all `#if DEBUG`) for the owner to react to before any production code. Nothing reads or writes station settings, UserDefaults, Connections, consent, or playback. Release builds don't compile it. -Nova

## Screens and shots
Shots are saved by `ListenerControlsMockTests` into the `studio-screenshots` artifact as `<name>_<device>.png`. They aren't required in ios.yml.

| Shot | Frame | What it shows |
|---|---|---|
| `mock-198-iphone` | iPhone window, compact | One column: Personality, Language and Spanglish, What the DJ talks about, Sources (last 2 lines plus "All sources") |
| `mock-198-iphone-dark` | same, dark | Same as above |
| `mock-198-iphone-large-text` | same, Accessibility L text | The segmented choices stack instead of clipping |
| `mock-198-iphone-sources` | iPhone, pushed | Sources: every DJ line this session with its source label and the provider link |
| `mock-198-duo-open-portrait` (+ `-dark`) | 640 × 820 pt container, compact | The same single column at the open Duo's width |
| `mock-198-duo-open-landscape` | 820 × 640 pt container, regular | Two columns with a 28 pt side inset: Personality and Language on the left, Topics and all Sources on the right |
| `mock-198-ipad` (+ `-dark`) | iPad window, regular | Two columns, the same as Duo landscape |

Layout uses size classes and the window's safe area only. Every control is at least 44 pt tall (the tests check this), and the monochrome style uses SF Symbols with no emoji.

## Controls mapped to integration (4425e9b5)

| Control in the mock | Real today? | Backing |
|---|---|---|
| Personality: Warm, Upbeat, Laid-back, Minimal | **Yes** | `DJPersonality` (per station, `StationConfiguration.personality`). Picks the phrase bank (`EditorialTone.forPersonality`, #346/#356). The voice is unchanged. |
| Language: English / Español | **No** | Nothing in integration. Belongs to #196 (Echo, open). |
| Spanglish: Off / Light / Conversational | **No** | Spec §2 wording. Belongs to #196. |
| Song facts switch, source "Apple Music" | Facts yes, switch **no** | `MusicKitCatalogFactsSource` (#199, catalog only). No listener switch exists today. |
| Weather switch, source "Apple Weather · approximate location" | **Yes** | `LocalFactsToggleCard` (Tune > Local weather & news, #410), off by default. Attribution comes from `FactAttribution.appleWeather`. |
| News switch, source "The GDELT Project · outlet named on air" | **Tester builds only** | `TesterLocalNews` (GDELT, owner decision Nov 3). Release builds have no news. |
| Personal briefing switch, source "Calendar, shared items, notes · from Connections" | **Yes** | `BriefingPreferences.enabled` plus `StationIntegration` (Calendar, Shared from Mail & Messages, Markdown notes) |
| Web lookups switch (shown off and disabled) | **No** | Not built. #199 was narrowed to Apple Music catalog facts. Spec §6 lists it. |
| Sources list | Data yes, UI **no** | `BroadcastFact.attribution` / `FactProvenance` exist. No listener-facing Sources screen exists. |

DJ talk (`CommentaryFrequency`) and talk-over stay where they are (Tune, Settings) and are not repeated here.

## MOCK COPY (new, pending owner OK)
- Header: "Listener controls" / "Changes apply from the next DJ break. The music keeps playing."
- Personality descriptions: "The house style. Relaxed and friendly." / "Brighter and more forward, never hype." / "Softer, slower words." / "Names only. The shortest breaks." / footer "Changes the words, not the voice or the facts." These are adapted from docs/dj-persona.md. The shipped `honestDescription` copy differs.
- Language footer: "Spanish uses a Spanish voice installed on this device. The accent depends on the voices you have."
- Spanglish details: "One language only." / "A short phrase now and then, like “mi gente” or “up next”." / "Switches naturally between English and Spanish."
- Topic details: all five, plus the footer "Each source has its own switch. Off means the DJ never mentions it."
- Sources: "What the DJ said this session and where each fact came from." / "Lines without a source are just the DJ talking."
- Sample lines in Sources are fixtures that use the test-station songs. "Example Outlet" is a placeholder.

## Owner decisions needed
1. Where should this live: a "DJ" sheet of its own (as mocked), or folded into Tune > DJ next to DJ talk?
2. Language model: should it be Language (English/Español) plus a separate Spanglish level (as mocked), or one three-way choice, English / Español / Spanglish, with the Light/Conversational level only under Spanglish (spec §2 lists both)?
3. Latin Radio Host: should it be a fifth personality (spec §2), or does Español/Spanglish on any personality cover it? Today there are four personalities.
4. Scope: should personality and language be per station (personality already is) or app-wide (the voice is app-wide)?
5. Web lookups: should the switch show as "not available" (as mocked) or be hidden until it's built?
6. Sources retention: should it cover this session only (as mocked) or a longer period? Should it appear in Release, where news isn't available?
7. Should song facts get a listener switch at all, or stay tied to DJ talk?
