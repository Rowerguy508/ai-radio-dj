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
| `NEXT_PUBLIC_APPLE_MUSIC_DEVELOPER_TOKEN` | **Client** (NEXT_PUBLIC) | 🔴 **HIGH** — MusicKit developer JWT shipped to browser. If long-TTL, a leaked token is reusable. **Remediation:** short TTL + secure issuer; never in native app (use MusicKit framework auth). |
| `NEXT_PUBLIC_SPOTIFY_CLIENT_ID` | Client | 🟡 MEDIUM — public by design (OAuth client ID), low risk |
| `SPOTIFY_CLIENT_SECRET` | Server | 🟢 OK — server-only |
| `MINIMAX_API_KEY` | Server | 🟢 OK — server-only |
| `ELEVENLABS_API_KEY` | Server | 🟢 OK — server-only |
| `NEXT_PUBLIC_SUPABASE_URL` | Client | 🟢 OK — public by design |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | Client | 🟡 MEDIUM — anon key is public by design, but **must** be RLS-gated (see §5) |
| `SUPABASE_SERVICE_ROLE_KEY` | Server | 🔴 **HIGH** — full admin. Must never reach client. Confirmed server-only in `createAdminClient()`. |
| `TELEGRAM_WEBHOOK_SECRET` | Server | 🟢 OK — server-only |

**Key finding:** `NEXT_PUBLIC_APPLE_MUSIC_DEVELOPER_TOKEN` is the main public-token risk. The roadmap's "developer tokens deserve short TTL/secure issuer" applies directly. In the native app, **no developer token is shipped** — MusicKit framework handles auth.

## 4. Private data logging

- `app/api/commentary/route.ts` logs `{ requestId, error }` — **no user content logged**. ✅
- `lib/llm/commentary.ts` sends station/track context to MiniMax — **server-side, not logged**. ✅
- `app/api/voice/route.ts` sends `text` to MiniMax T2A — server-side. ✅
- `app/api/messages/route.ts` reads `message_queue` — content stays in DB, not logged. ✅
- **No `console.log` of message bodies or user PII found.** ✅

**Finding:** current logging is request-ID + error only. Good baseline. Native app must maintain this (never log `ContextItem` content).

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

**Finding:** RLS is correctly scoped to `auth.uid()`. No cross-user leakage. **One caution:** `createAdminClient()` uses `SUPABASE_SERVICE_ROLE_KEY` which **bypasses RLS** — it's used in `messages`/`stations` routes with a `userId` query param. **Risk:** if `userId` is attacker-controlled, the service-role client could return another user's data. **Remediation:** validate `userId` against the authenticated session (or drop service-role for these reads and use the anon/RLS path). → **Remediation issue #27.**

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

- **#30** — Validate authenticated identity server-side before service-role Supabase reads (messages/stations routes). P0.
- **#31** — Replace long-TTL `NEXT_PUBLIC_APPLE_MUSIC_DEVELOPER_TOKEN` with short-TTL/secure-issuer token (or remove from client).

## 9. Completion check

- [x] Concrete endpoints inventoried
- [x] All secrets classified (2 HIGH, 2 MEDIUM, rest OK)
- [x] Risks have remediation issues (#30, #31)
- [x] npm build/typecheck baseline recorded (both PASS)
- [x] No breaking changes; web app + migrations preserved
