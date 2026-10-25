# AeroDJ Native iOS Rebuild: Execution Backlog (2026-10-25)

## Product contract
Build a **native SwiftUI iOS app** targeting the latest stable iOS SDK with availability checks for iOS 27.2 and responsive folded/unfolded iPhone Duo layouts. Keep existing Next.js code functioning; treat it as a legacy/prototyping client, not the new app's UI. Do not rewrite/delete the web app or overwrite current migrations.

**User-approved settings:** calm human-sounding radio host; 5-minute **morning show total segment target** (not 5 minutes of TTS); short segments interleaved *between* Apple Music tracks; sources: Apple Calendar/EventKit, explicitly shared email, explicitly shared Messages, selected Obsidian Markdown via Files. Apple-native authorization and APIs first, external account providers later.

**Explicit limitations:** no unrestricted Apple Mail, Messages, or Notes inbox/history API. Share extension and user-imported content only. Apple Music playback must remain managed by MusicKit; do not capture/decrypt/mix protected streams. Do not claim gapless DJ speech-over-song mixing before testing technical and rights constraints. Dessa by Block has no confirmed public production API; implement a stub adapter without invented requests.

## Architecture
- `ios/AeroDJ/`: SwiftUI app; MVVM or observable domain services, async/await, dependency injection, no API secrets.
- `ios/AeroDJCore/`: pure Swift models + testable `BriefingPlanner`, `BroadcastScheduler`, `VoiceProvider`, `ContextSource`, `UsageMeter` protocols.
- `ios/AeroDJShare/`: Share Extension for plain text, URL, email/message excerpts; App Group inbox with bounded retention.
- `ios/AeroDJTests/`: unit tests with deterministic fixtures and mocked clock/providers.
- `app/api/v2/`: opt-in server endpoints for provider TTS and brief generation; auth, quotas, redaction, no implicit persistent personal text storage. Existing endpoints remain untouched.
- Backend may reuse existing Supabase carefully after schema/RLS/security audit. Avoid sending entire private documents to an LLM.

## Audio provider decision
1. **Cartesia Sonic 3.6** TTS candidate for narrated *pre-rendered* DJ segments. Provider's published Pro plan: $5/month, 100k credits (roughly 133 generated minutes at 750-800 credits/min); verify current credit use and commercialization before enabling billing.
2. **Apple AVSpeechSynthesizer** $0 network bill fallback, possibly insufficient quality; use for offline and testing.
3. **OpenAI real-time mini** optional later for *live interruption* only; separate session-based cost controls, never keep always-on sessions during music playback. Official pricing lists gpt-realtime-2.1-mini audio tokens and GPT-Live-1 at $0.05/min, plus backend/tool costs where applicable; do not mistake session prices for all-in costs.
4. **DessaVoiceProvider** disabled feature flag until published, licensed, documented endpoint or local deployment exists.
5. Compare with ElevenLabs (existing integration) in a blind human listening test. Avoid vendor-locked persisted audio format.

**Cost control:** script 90-150 seconds total spoken audio inside a 5-minute briefing experience; cache immutable generic introductions (no personal data); hash only safely reusable scripts; no speculative prefetch; cap per-user generated characters/minutes and calls/day; dry-run estimator and hard cutoff; never cache raw private messages in shared cache; record provider, characters, generated seconds, estimated billed units, and observed costs. Token charges for text planning are separate from TTS characters; track both.

## Sprint 0 (foundation and audit): 1 week
- Audit current Next.js, API routes, env vars, Supabase policy/migrations and Apple Music flow; document what is reusable. Verify no secrets leaked via NEXT_PUBLIC variables (developer tokens deserve short TTL/secure issuer), identify privacy exposure.
- Create compilable SwiftUI Xcode project with repo structure, app environment config, preview fixtures, SwiftLint or SwiftFormat as appropriate, test target, simulator build CI on macOS runner, and README.
- Specify privacy/permission matrix: EventKit read, MusicKit access, Files security-scoped bookmarks, Share Extension, microphone optional later, notifications optional.
- ADR decisions: no protected stream mixing, no Mail/Message scraping, native first, provider protocol, cost safeguards.

**Exit:** a fresh checkout builds in Xcode and on GitHub Actions, launches mock stations and mock briefing; legacy web unaffected.

## Sprint 1 (radio player and layout): 1 week
- SwiftUI station selection, calm DJ identity, compact vs expanded Duo layout, Dynamic Type, VoiceOver, reduced motion. Do not assume undocumented device dimensions; use adaptive container sizing.
- MusicKit authorization, search, queue playback, skip, pause/resume and now-playing; explicit subscription/degraded state; simulator/manual device testing.
- Audio state machine: `idle -> music -> transition -> voice -> music`, interruption/duck/resume policy verified with device tests. Initially voice ONLY between tracks or paused playback; never overlap DRM tracks through unsupported mixing.
- Lock Screen/Control Center remote controls and background audio behavior, where permitted.

**Exit:** real Apple Music track starts, pauses for a prebuilt DJ clip at a track boundary, resumes, and works during fold state changes/backgrounding.

## Sprint 2 (native personal context): 1 week
- EventKit read-only Calendar adapter (permission denied, no calendar, timezone, recurring/all-day events, dedupe and relevance filters).
- iOS Share Extension for selected Mail and Messages excerpts and URLs; identify source as `userShared`, never infer whole inbox access; explicit review/edit/delete before narration.
- Obsidian importer via document picker / Files with scoped document access; Markdown parser supporting YAML frontmatter, headings, checkboxes and links, ignore unsafe/private paths and binary files; robust revoked bookmark handling.
- Unified `ContextItem`: id, source, createdAt, eventAt?, title, summary, sensitivity, consent, expiresAt, provenance link. No broad automatic sync. Encrypted local persistence, user data deletion and retention choices.

**Exit:** user sees a review screen with four source types and can include/exclude individual items; no access after permission revoked.

## Sprint 3 (briefing engine and responsible AI): 1 week
- `BriefingPlanner` generates small, structured, attributable topics from allowed `ContextItem`s: date, urgency, source citation/attribution, 1-2 sentence fact summary, speakability flag. No fabricated messages/meetings.
- 5-minute *segment schedule* containing 90-150 seconds of narration broken into 3-6 spoken interruptions and remaining scheduled music portions; actual track length may stretch total time; UI must honestly show approximate duration.
- Warm, restrained host style guide, pronunciation dictionary for names, acronym formatting, non-sensitive opener/closer, interruptions and 'skip this' semantics.
- Model prompt/input minimization, prompt-injection defenses (email/note content untrusted), graceful offline and empty-source fallback.
- On-device rules-first version works with fixtures even without paid LLM.

**Exit:** deterministic planner tests; no fabricated facts, no disallowed item narrated, estimated plan duration bounded and labelled honestly.

## Sprint 4 (voice quality and unit economics): 1 week
- Define `VoiceProvider`: `synthesize(text: VoiceText, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact`. Artifact includes playable file URL/data, duration, billable units, provider, cache key/privacy scope. Extend for streaming later, not prematurely.
- Implement Cartesia adapter via secure backend, AVSpeechSynthesizer fallback, disabled Dessa adapter and existing ElevenLabs comparison adapter. Secrets server-side ONLY.
- Blind AB test using 20 scripts (names, NYC references, dry humor, pauses, questions, English and optional Spanish); rate 1-5 naturalness, intelligibility, emotional restraint, artifacts, cost.
- Set 95th percentile latency baseline, cold-start, retry-once, circuit-breaker, fallback, hard daily user cap. Support local cached reusable station IDs, not personal briefing caching across users.

**Exit:** chosen provider scores >=4/5 average naturalness by tester group, no raw API secrets in client, budget hard-stop verified, voice safely degrades offline.

## Sprint 5 (personal morning show integration): 1 week
- BroadcastDirector queues 3-6 interludes with user-selected inclusion; music transitions; play/pause/skip; elapsed/remaining approximate display.
- Morning setup: source permissions, calm personality, 5-minute target, interleaved delivery, privacy consent. On-demand 'Start Morning Show'.
- Optional Siri/App Intents and Shortcuts invocation, Live Activities only when the state fits Apple's policies; no always-on microphone or auto-reading sensitive content.
- Human QA across AirPods, speaker, incoming call, CarPlay later, background, permission revocation, network failure.

**Exit:** end-to-end show plays MusicKit tracks + spoken private events (only after explicit approval), recovers on failures.

## Sprint 6 (hardening/beta): 1 week
- In-app privacy center: source disconnect, delete imported data, audio cache purge, cost/budget view, provider opt-in, export of user-authored settings.
- Instruments profiling, app launch/reliability, accessibility, battery/thermal checks, TestFlight, clear subscriber/Apple Music requirements.
- Security review: threat modeling, auth/RLS, API quotas, rate limits, PII redaction, audit data retention, no secret exposures, no uploaded email datasets in logs.
- Feature-flag future Gmail/IMAP, messaging services, direct Obsidian bridge, and full-duplex Dessa when official APIs exist.

**Exit:** CI green, TestFlight ready, explicit known limitations and per-user usage/cost dashboard.

## Agent execution rules
- Work issue-by-issue; first inspect existing files, propose architecture impact, then create a feature branch and PR. Never force push to main.
- Every PR: tests, screenshots where UI changes, permissions/privacy impact, failure modes, manual device test notes, and cost impact.
- No fabricated Apple entitlements/APIs, iOS 27.2 or iPhone Duo capabilities; confirm against installed SDK and current official docs.
- Preserve web prototype and Supabase migrations until verified replacement. Never create production secrets or commit .env.
- Mock all paid services in tests/CI. Do not spend paid API credits without explicit enablement.
- Keep docs updated with issue links, decisions and completion checks.
- Priority order: functioning native app -> Apple Music -> native inputs -> safe briefing -> human TTS -> beta polish.
