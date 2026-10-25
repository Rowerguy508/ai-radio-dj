# Legacy Web App Audit — AeroDJ

> **Issue:** [#12 — [S0] Audit existing web app, APIs and Supabase security](https://github.com/Rowerguy508/ai-radio-dj/issues/12)
> **Date:** 2026-10-25
> **Branch:** `feat/s0-audit-ios-privacy`
> **Scope:** Read-only inventory + documentation. No breaking changes. Legacy web app preserved.

## 1. Baseline

| Check | Result |
|---|---|
| `npm run typecheck` | ✅ PASS (0 errors) |
| `npm run build` | ✅ PASS (Next.js 15.5.14, all routes compiled) |
| `npm run lint` | Not run (no `next lint` config baseline; ESLint 9 present) |

## 2. Application inventory

**Stack:** Next.js 15.5.14 (App Router) + React 18 + TypeScript + Tailwind + Zustand + Supabase.

### Routes (`app/`)
| Route | Method | Purpose | Reuse |
|---|---|---|---|
| `/` (`page.tsx`) | GET | Main radio UI (station picker, player) | **Retire** — replaced by native iOS |
| `/api/stations` | GET | Fetch user's stations (Supabase) | **Reuse** — server API pattern |
| `/api/messages` | GET | Fetch pending message queue | **Reuse** — pattern for ContextSource |
| `/api/commentary` | POST | Generate DJ commentary (MiniMax) | **Reuse** — BriefingPlanner analog |
| `/api/voice` | POST | TTS via MiniMax T2A v2 | **Reuse** — VoiceProvider analog |
| `/api/voices` | GET | List saved voices | **Reuse** |
| `/api/spotify/callback` | GET | OAuth redirect (PKCE) | **Retire** — Apple Music native |
| `/api/spotify/disconnect` | POST | Revoke Spotify | **Retire** |
| `/api/telegram` | POST | Telegram bot control | **Retire** — not in iOS scope |
| `/api/telegram/set-webhook` | POST | Configure webhook | **Retire** |
| `/api/webhooks/telegram` | POST | Inbound message queue | **Retire** — replaced by Share Extension |

### Libraries (`lib/`)
| File | Purpose | Reuse |
|---|---|---|
| `lib/llm/commentary.ts` | MiniMax commentary gen + fallback | **Reuse** — logic → `BriefingPlanner` |
| `lib/database/supabase.ts` | Admin + browser clients, types | **Reuse** — types → `AeroDJCore` models |
| `lib/apple-music/client.ts` | MusicKit JS client | **Reuse** — logic → native MusicKit |
| `lib/apple-music/player.tsx` | MusicKit player component | **Reuse** — state machine logic |
| `lib/spotify/player.tsx` | Spotify player | **Retire** |
| `lib/elevenlabs/client.ts` | ElevenLabs TTS | **Reuse** — comparison VoiceProvider |
| `lib/hooks/useCommentary.ts` | Commentary hook | **Retire** — React-specific |
| `lib/store/radio.ts` | Zustand store (Station/Track types) | **Reuse** — types → Core |

## 3. Secrets classification

| Env var | Exposure | Risk |
|---|---|---|
| `NEXT_PUBLIC_APPLE_MUSIC_DEVELOPER_TOKEN` | **Client** (NEXT_PUBLIC) | 🟡 MEDIUM — public by design: MusicKit JS requires the developer token in the browser, so it cannot be removed from the web client. Risk is a long-lived, origin-unrestricted token reused against our quota. **Remediation (#36):** mint server-side with short `exp` + `origin` claim, then rotate. The native app ships no developer token (MusicKit framework auth). |
| `NEXT_PUBLIC_SPOTIFY_CLIENT_ID` | Client | 🟡 MEDIUM — public by design (OAuth client ID), low risk |
| `SPOTIFY_CLIENT_SECRET` | Server | 🟢 OK — server-only |
| `MINIMAX_API_KEY` | Server | 🟢 OK — server-only |
| `ELEVENLABS_API_KEY` | Server | 🟢 OK — server-only |
| `NEXT_PUBLIC_SUPABASE_URL` | Client | 🟢 OK — public by design |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | Client | 🟡 MEDIUM — anon key is public by design, but **must** be RLS-gated (see §5) |
| `SUPABASE_SERVICE_ROLE_KEY` | Server | 🔴 **HIGH** — full admin. Must never reach client. Confirmed server-only in `createAdminClient()`. |
| `TELEGRAM_WEBHOOK_SECRET` | Server | 🟢 OK — server-only |

**Key finding:** the service-role key is server-only, but the routes that use it have no authentication (§5), so its isolation provides no protection in practice. The MusicKit developer token is public by design; the roadmap's "short TTL/secure issuer" guidance applies (#36). In the native app, **no developer token is shipped** — MusicKit framework handles auth.

## 4. Private data logging

- `app/api/webhooks/telegram/route.ts:63` logs `content: textContent` — the **raw Telegram message body**. ❌ Remove (#31).
- `app/api/voice/route.ts:59` logs the upstream MiniMax error body (`errText`); `:68` logs a 500-char slice of the upstream response. ❌ Log status and request ID only (#32).
- `app/api/stations/route.ts:54` logs the user-supplied station name (`body.name`). ⚠️ Remove.
- `app/api/commentary/route.ts` logs `{ requestId, error }` only. ✅
- `lib/llm/commentary.ts` and `app/api/voice/route.ts` send station/track context and narration text to MiniMax server-side; neither is logged on success. ✅

**Finding:** logging is mostly request-ID + error, but three call sites log user or upstream content. The native app must never log `ContextItem` content.

## 5. Supabase RLS audit

All tables have RLS **enabled** with `auth.uid() = user_id` policies:

| Table | RLS | Policy | Verdict |
|---|---|---|---|
| `users` | ✅ | view/insert/update own | ✅ Correct |
| `voices` | ✅ | view own, manage own | ✅ Correct |
| `stations` | ✅ | view own, manage own | ✅ Correct |
| `user_preferences` | ✅ | view own, manage own | ✅ Correct |
| `listening_logs` | ✅ | view own, insert own | ✅ Correct |
| `message_queue` | ✅ | view own, manage own | ✅ Correct |
| `calendar_events` | ✅ | view own, manage own | ✅ Correct |

**Finding: the policies are correct, but no request ever runs under them. Cross-user access is possible.**

- Every Supabase route uses `createAdminClient()` (service role), which **bypasses RLS**.
- The web app has **no authentication**: no `auth.getUser`/`getSession`, no `Authorization` handling, and `createBrowserClient()` is never called. There is no session to validate `userId` against.
- Identity therefore comes from the request:

| Route | Op | Identity source | Exposure |
|---|---|---|---|
| `/api/messages` | GET | `?userId` | read any user's queue |
| `/api/messages` | POST | body `userId` | insert into any user's queue (content is later narrated) |
| `/api/messages` | PATCH | none (`messageId` only) | update any message |
| `/api/stations` | GET | `?userId` | read any user's stations |
| `/api/voices` | GET / POST | `userId` | read or create voices for any user |
| `/api/voices` | DELETE | none (`id` only) | delete any voice |

No client code calls `/api/messages`, `/api/stations` or `/api/voices`. **Remediation (#28):** remove or disable these handlers now; reintroduce user-scoped routes only with verified Supabase JWTs and a per-request anon-key client so RLS is the enforcement point.

Related unauthenticated routes outside RLS scope: `POST /api/telegram/set-webhook` can repoint the production bot (#31); `POST /api/voice` and `/api/commentary` allow unbounded paid inference (#32).

Exploitability in production depends on Supabase being configured on the deployment; this audit is static analysis only and did not exercise any deployment.

## 6. Reuse vs retirement summary

**Reuse into native iOS:**
- `lib/store/radio.ts` types (Station, Track) → `AeroDJCore` models
- `lib/database/supabase.ts` types (User, Voice, Station, MessageQueue, ListeningLog) → Core models
- `lib/llm/commentary.ts` prompt-building + fallback logic → `BriefingPlanner`
- `lib/apple-music/client.ts` + `player.tsx` state machine → native MusicKit
- `lib/elevenlabs/client.ts` → comparison `VoiceProvider`

**Retire (web-only, not in iOS scope):**
- Spotify integration (native uses MusicKit)
- Telegram bot + webhooks (replaced by Share Extension)
- React hooks, Zustand store, Tailwind UI

**Preserve untouched:** `supabase-migration.sql`, all existing API routes, the web app itself.

## 7. ADR — Legacy Web App

**Status:** Accepted
**Context:** Web app is a working prototype; native iOS is the product.
**Decision:** Keep the web app as a legacy/prototyping client. Do not delete or rewrite it. Reuse its domain logic and types in `AeroDJCore`; retire only web-specific integrations (Spotify, Telegram) from the iOS scope.
**Consequences:** Two clients coexist during transition. Web remains the reference for behavior. No breaking changes to existing routes or migrations.

## 8. Remediation issues

- **#28** (P0) — Cross-user reads/writes/deletes via unauthenticated service-role routes (§5).
- **#31** (P0) — Unauthenticated `set-webhook` can repoint the production Telegram bot; receivers fail open; message bodies logged.
- **#32** (P1) — Unauthenticated paid TTS/LLM routes with unbounded input.
- **#36** — Short-lived, origin-restricted MusicKit JS developer token.

## 9. Completion check

- [x] Concrete endpoints inventoried
- [x] All secrets classified (1 HIGH, 3 MEDIUM, rest OK)
- [x] Risks have remediation issues (#28, #31, #32, #36)
- [x] npm build/typecheck baseline recorded (both PASS)
- [x] No breaking changes; web app + migrations preserved
