# DJ persona per station (lane 4 design)

Status: design for agreement between Echo (copy) and Fry (session wiring) before any code. Owner-approved scope: "a DJ persona per station (voice, energy, vocabulary)", 2026-10-30.

## The persona already exists. Reuse it, don't add a second one.
- `StationConfiguration.personality: DJPersonality` (`warm`, `upbeat`, `laidBack`, `minimal`) is already per station. It's persisted in recipes, picked in `TuneForm` and `AddStationWalkthrough`, and edited through `StationConfigurationModel.setPersonality`.
- Today it only bounds `maxTransitionSeconds`. `DJBreakSession` always builds `DJScriptWriter` with the default `EditorialTone.warm`, so every station *sounds* the same.
- Lane 4 makes the existing `DJPersonality` choose the phrasing bank. There's **no new enum, no new setting, no new settings UI and no new raw values**, because recipes persist the existing ones.

## What a persona controls
| | warm (default) | upbeat | laidBack | minimal |
|---|---|---|---|---|
| Vocabulary | the house style as it is now (#339/#341) | brighter verbs, more forward-sell ("Here comes…", "Let's go, {nextArtist}.") | softer, slower words ("Easy one from {artist}.") | names only ("{artist}. {title}.", "{nextTitle}.") |
| Energy | medium | higher, but **no hype**: `forbiddenHype` and the lint apply to every bank | low | flat, informational |
| Break shape | unchanged (Fry's lane 2 owns shapes) | unchanged | unchanged | unchanged (already short via `maxTransitionSeconds` 6) |
| Voice | the global voice choice | same | same | same |

**Voice stays global for now.** `PremiumVoiceSelectionStore` and on-device selection are app-wide. A per-station voice would mean a new persisted field and new UI, which goes beyond this lane, so I've left it out unless the owner asks. The persona changes *what* is said, not *who* says it.

## Code split (no simultaneous edits)
1. **Echo, in `DJ/EditorialNarration.swift` only:**
   - Add `EditorialTone.upbeat`, `.laidBack` and `.minimal`, each meeting the same contract as `.warm`: 8–12 lines per pool, closing lines of seven words or fewer, contractions, no facts of our own, no clock claims.
   - Add `EditorialTone.forPersonality(_: DJPersonality) -> EditorialTone`.
   - `SpokenScriptLintTests` runs every pool and the 600 planned sessions **for each tone**.
2. **Fry, in `DJBreakSession` (single writer), a one-line handoff:** `DJScriptWriter(cadence:…, seed: seed, tone: .forPersonality(station.active.personality))`. A personality edit applies when the next break starts preparing, as it already does for cadence (line ~331). Fry decides whether that needs a writer rebuild or a tone swap.
3. **The AI path (lane 5, Fry leads):** the server request carries only `personality.rawValue` as a style preset. It never includes the station name the listener typed (Sentinel C2), and personal-item text is never sent. Each preset maps to the same vocabulary and energy rules above in the server-side prompt. AI output goes through the same lint, and the templates for that persona are the fallback.

## Guardrails (all personas)
- Never invent facts. Lines use only the title, artist, station name and day part.
- No overlapping speech. Every persona goes through the same scheduler, VoiceRenderer and caps (12s ordinary, 45s briefing).
- Deferred or omitted cues are still reported.
- Personal-update frames (`briefingLead`/`briefingOutro`) may change wording per persona, but never facts. `BriefingRewriter` keeps facts verbatim.
- Naturalness and pronunciation are NOT TESTED until someone listens on the Duo.

## Open questions
- Should a `minimal` station skip `atmosphere` and `stationID` color entirely? That's a shape question for Fry's lane 2, not a copy one.
- Does the owner want per-station voices later? If so, it's a separate, owner-approved feature.

-Echo
