# Durable paid-inference quota store options

Part of [#80](https://github.com/Rowerguy508/ai-radio-dj/issues/80). Written against `integration/device-duo` at `5a57269f`. This file is a design note only: no code, config, env, package, or service is changed or provisioned here, and no paid API was called.

The owner picks one of the options in §3. Atlas's recommendation is in §5; it is not a decision.

## 1. What is still in memory today

#80 is about the legacy web app (`ray-do`) paid-inference meter, not the iOS TTS proxy.

`lib/llm/paid-inference.ts` still keeps the daily budget in module memory: `usedDay` and `usedChars` (`:28–29`). `reservePaidCharacters` (`:45–54`) rolls the counter over on a UTC date change and admits a request when `usedChars + chars` is at most `dailyCap()`. The default cap is **`DEFAULT_DAILY_CHAR_BUDGET = 6,000`** characters per UTC day (`:6`). `PAID_INFERENCE_DAILY_CHAR_BUDGET` can override it (`:36–41`); a missing or empty value keeps 6,000, and a non-finite or negative value becomes 0.

That meter is used by:

- `POST /api/voice` — MiniMax T2A, after `RAY_DO_ADMIN_TOKEN` is accepted (`app/api/voice/route.ts:17–20, 42–43`). Max request size is `PAID_TEXT_MAX_CHARS = 600` (`paid-inference.ts:1`).
- `POST /api/commentary` — MiniMax chat, via `generateCommentary` (`lib/llm/commentary.ts:37–41`). Input is capped at `COMMENTARY_PROMPT_MAX_CHARS = 4,000` (`paid-inference.ts:3`).

Production stays 404 unless `ENABLE_PAID_INFERENCE` is exactly `"true"` (`paid-inference.ts:20–24`). Anonymous spend from the original #80 write-up is no longer the open hole: both routes require the admin token (middleware plus a second check next to the spend). The remaining hole is the budget itself. The reserve is not released when MiniMax fails (`app/api/voice/route.ts:79–81` returns 500 after a successful reserve; commentary falls back after a failed call and still keeps the reserve). Tests in `tests/paid-inference.test.ts` only cover one process, as #80 said.

### 1.1 The TTS proxy is a different picture

The iOS app's paid path is `services/aerodj-tts`. Its defaults, in `limiter.ts:245–249` and `handler.ts:415–435`, are:

| Bucket | Default | Env override |
| --- | --- | --- |
| Global daily ceiling | **9,000** (`DEFAULT_GLOBAL_DAILY_CHAR_CAP`) | `AERODJ_TTS_GLOBAL_DAILY_CHAR_CAP`, else legacy `AERODJ_TTS_DAILY_CHAR_CAP` |
| Owner share (when tester voice is on) | **3,000** (`DEFAULT_OWNER_SHARE_DAILY_CHAR_CAP`) | `AERODJ_TTS_OWNER_DAILY_CHAR_CAP`; when tester voice is off, the owner cap is the global ceiling |
| Tester pool (when tester voice is on) | **6,000** (`DEFAULT_TESTER_POOL_DAILY_CHAR_CAP`) | `AERODJ_TTS_TESTER_POOL_DAILY_CHAR_CAP`, clamped to global − owner |
| Per install | **1,500** (`DEFAULT_INSTALL_DAILY_CHAR_CAP`) | `AERODJ_TTS_INSTALL_DAILY_CHAR_CAP` |
| Preview / Development sub-cap | **1,000** (`DEFAULT_NONPROD_DAILY_CHAR_CAP`) | `AERODJ_TTS_NONPROD_DAILY_CHAR_CAP`, configurable only downward |
| Per request | **600** (`handler.ts:35`) | `AERODJ_TTS_MAX_TEXT_CHARS` |
| Per-minute rate | **12** (`DEFAULT_REQUESTS_PER_MINUTE`) | `AERODJ_TTS_RATE_PER_MINUTE` |

`selectLimiter` (`handler.ts:441–463`) already chooses a durable `RedisUsageLimiter` when `KV_REST_API_URL` + `KV_REST_API_TOKEN` or `UPSTASH_REDIS_REST_URL` + `UPSTASH_REDIS_REST_TOKEN` are set (`limiter.ts:623–624`). If an `ELEVENLABS_API_KEY` is set and those store credentials are not, it returns null and every request is 500 `misconfig` — including Production. `InMemoryUsageLimiter` is only for tests, local dev, or a Production deployment with **no** upstream key (so nothing can be billed) and an explicit `AERODJ_TTS_ACCEPT_BEST_EFFORT_LIMITS=true`. The in-memory N×-cap problem does **not** currently apply to paid TTS spend. Whether the deployed `aerodj-tts` project actually has the Upstash integration is **unverified, owner to confirm** (this note reads no env).

#80's remaining work is therefore the `ray-do` paid-inference meter. A durable store chosen here can follow the same fail-closed rules the TTS proxy already uses.

## 2. The problem, quantified

`usedChars` lives in one Node isolate. A Vercel cold start, a new instance, or a scale-out creates a fresh `usedChars = 0` (`paid-inference.ts:28–33, 48–50`). Concurrent requests on different isolates each see their own 6,000-character budget. There is no shared increment and no cross-instance lock.

Worst case, using only repo numbers:

- Configured cap, one isolate, one day: **6,000 characters** (or the override).
- `C` concurrent isolates: up to **C × 6,000** characters that same UTC day.
- Isolates that recycle mid-day reset again, so spend is not bounded by any fixed `C`. The configured "daily cap" is not a hard global cap.

A 600-character voice request costs one reserve of 600. Ten such requests fill one isolate's default budget; two 4,000-character commentary measurements can fill it sooner. Because there is no refund on upstream failure, a failed MiniMax call still consumes the local counter, but that does not cap the other isolates.

The `#80` acceptance bar still holds: do not treat a closed related issue, or this note, as permission to set `ENABLE_PAID_INFERENCE=true`. Paid iOS voice stays at a $0 cap (`VoiceBetaDefaults.paidDailyCapMicrodollars = 0`, `BetaVoicePolicy`).

## 3. Options

Expected request volume, derived from the caps, not from production traffic (none was measured):

- TTS global ceiling: 9,000 characters/day. At the 600-character request cap that is **15 requests/day**, about 465/month, if every request is maximum size.
- Paid-inference default: 6,000 characters/day. At 600 characters that is **10 voice requests/day**, or as few as two commentary calls if each measures 4,000 characters.
- Each admitted request needs one atomic reserve before any upstream call, and a refund only when the upstream definitely did not bill. That is hundreds of store operations per month at cap, not hundreds of thousands.

An adversarial pattern of 1-character requests could reach 9,000 reserves/day against the TTS ceiling (about 279,000/month). That is still the right planning upper bound for command or row counts. It is not expected usage.

None of the options below creates a new vendor account or project in this PR.

### 3.1 (a) Upstash Redis (what Vercel KV is now)

Vercel KV is no longer a separate product. Existing KV stores were moved to Upstash Redis in December 2024; new stores come from the Vercel Marketplace ([vercel.com/docs/redis](https://vercel.com/docs/redis), fetched 24 November 2026). The TTS proxy already speaks this store over REST (`redisRestConfig`, `limiter.ts:623–627`) and documents the integration as the Marketplace free tier in `services/aerodj-tts/README.md`.

**Monthly cost, at the volume above.** Official prices from [upstash.com/pricing/redis](https://upstash.com/pricing/redis) and [upstash.com/docs/redis/overall/billing](https://upstash.com/docs/redis/overall/billing), fetched 24 November 2026:

| Plan | List price | Notes that matter here |
| --- | --- | --- |
| Free | **$0 / month** | 500,000 commands, 250 MB, 10 GB bandwidth, 1 database. No credit card. |
| Pay as You Go | **$0.20 per 100,000 commands**; first 1 GB storage free | Adding a payment method moves every free database on the account to PAYG; an account with a card cannot keep a free Redis. |
| Fixed 250 MB | **$10 / month** | Flat; no per-command charge. Larger fixed tiers start at $20. |

At expected volume (hundreds of operations per month) this stays inside the 500,000-command Free allowance, so the store bill is **$0 / month** if the account is still on Free. If the existing `aerodj-tts` database is already PAYG (likely once a card is on file), the incremental cost of a paid-inference prefix on that same database is **$0.20 per 100,000 commands**. Hundreds of commands per month are a fraction of a cent; even the 279,000-command adversarial month is **$0.56** at the PAYG list rate, or still $0 if the account is Free. Lua scripts are billed as one command plus each `redis.call` / `redis.pcall` inside; the exact multiplier depends on the script, so a precise PAYG invoice is **unverified, owner to confirm**. This note does not create a second database. Reuse the existing one with a separate key prefix (for example `ray-do:chars:…`), if the owner confirms that integration is present.

**Failure mode.** Fail **closed**, the same as today's TTS proxy: if the store is missing, returns an error, or exceeds `UPSTASH_FETCH_TIMEOUT_MS = 2,000` (`upstash.ts:8`), do not call MiniMax or ElevenLabs. Answer 500 or 503 and leave the budget unchanged. Do not fall back to the in-memory counter. A slow store is a timeout, then the same closed path.

**Consistency.** One Lua `EVAL` per reserve, atomic in Redis, as `RedisUsageLimiter` already does. Two concurrent 600-character requests with 600 left get one admission and one refusal. Refunds are a second atomic script, at most once per reservation id.

**Latency.** One HTTPS REST round trip per reserve (and per refund), bounded at 2,000 ms. Typical faster times were not measured here.

**Secrets and env (names only).** `KV_REST_API_URL` and `KV_REST_API_TOKEN`, or `UPSTASH_REDIS_REST_URL` and `UPSTASH_REDIS_REST_TOKEN`. Already the TTS names. `ENABLE_PAID_INFERENCE`, `PAID_INFERENCE_DAILY_CHAR_BUDGET`, `MINIMAX_API_KEY`, and `RAY_DO_ADMIN_TOKEN` already exist on `ray-do`. No new secret names are required if `ray-do` is given the same store pair, Production scope.

**Privacy.** Store only day keys, integer counts, and — if a per-install bucket is ever added — `sha256(install id)` as `subjectBucket` already does (`limiter.ts:43–48`). No request text, tokens, or personal content.

**Operational burden.** Low, if the Marketplace integration is already on `aerodj-tts`. Watch the monthly command count. Do not add a second Redis in this design. Confirm whether that database is Free or PAYG before relying on the $0 row.

### 3.2 (b) Supabase Postgres

The owner already has a Supabase project wired for the legacy web app through `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY`, and `SUPABASE_SERVICE_ROLE_KEY` (`.env.example:37–41`, `lib/database/supabase.ts`). This option would add a quota table (and a single-statement increment RPC) **in that existing project**. It would not create a new Supabase project or organization. I did not open the dashboard, so the live project ref and whether that organization is Free or Pro are **unverified, owner to confirm**.

**Monthly cost, at the volume above.** Official prices from [supabase.com/pricing](https://supabase.com/pricing) and auto-pause rules from [supabase.com/docs/guides/platform/free-project-pausing](https://supabase.com/docs/guides/platform/free-project-pausing), fetched 24 November 2026:

| Plan | List price | Notes that matter here |
| --- | --- | --- |
| Free | **$0 / month** | Unlimited API requests, 500 MB database, 2 active projects. **Paused after 1 week of inactivity** (low activity over a 7-day window; a few user requests per day typically prevent it). |
| Pro | **from $25 / month** | Includes $10 of compute credits (one Micro). Paid projects are not paused. Extra projects from $10 / month after credits. |

Quota rows and a few hundred RPC calls per month fit either plan's request and size allowances, so the **incremental** bill on the existing project is **$0 / month** while that project remains in its current tier. If the project is Free and the owner wants a quota store that cannot auto-pause, the published way to stop pausing is to move that organization to Pro at **$25 / month**. This note does not change the billing plan.

**Failure mode.** Fail **closed**. A paused Free project, a DNS or connection error, a statement timeout, or an RPC error must not call MiniMax. Answer 500 or 503. Do not fall back to module memory. A paused project looks like "store down" until someone resumes it in the dashboard (resume is allowed for up to a year).

**Consistency.** One SQL statement or `SECURITY DEFINER` RPC: `UPDATE … SET used = used + $chars WHERE day = $day AND used + $chars <= $cap RETURNING …`, in one transaction. That is an atomic compare-and-add, equivalent in effect to Redis `INCR` under a cap. Row locks are only needed if the increment is split across statements; it should not be.

**Latency.** One database round trip per reserve (and per refund) through the existing server-side client. There is no quota-specific timeout in the repo today; a later implementation should bound the call and treat a timeout as store-down. Typical latency was not measured here.

**Secrets and env (names only).** `NEXT_PUBLIC_SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` on the server only. Do not write quota rows with the anon key. No new secret names if the existing project is reused.

**Privacy.** Same rule as (a): integer counts, day keys, hashed ids only. The service role can read the rest of that project, so the quota table's grants must be tight and the service role must stay server-only (already called out in `docs/LEGACY_AUDIT.md`).

**Operational burden.** Medium. Needs a migration and an RPC, connection discipline on serverless, and (if the project is Free) monitoring so a quiet week does not pause the meter. Heavier than reusing the Redis the TTS proxy already has.

### 3.3 (c) No store

Keep the in-memory meter. Do not add a shared database. The real backstops are: leave `ENABLE_PAID_INFERENCE` unset so the routes 404; keep iOS paid voice at $0; and rely on a provider-side hard cap (the ElevenLabs key or plan character limit for `aerodj-tts`; a MiniMax account cap for `ray-do`, if one exists) if anyone later enables spend.

**Monthly cost.** **$0 / month** for a store, because there isn't one. This is not a claim that MiniMax or ElevenLabs would be free if the flag were turned on. The live ElevenLabs plan, key cap, and any MiniMax account cap are **unverified, owner to confirm**. The 2026-10-29 Starter / 40k-credit / 9k-key-cap comment in `PremiumVoiceCatalog.swift:60–62` is an operational note, not a current list price (see `docs/VOICE_BAKEOFF.md`).

**Failure mode.** There is no store to go down. The failure mode is **fail open against the configured cap**: each new isolate can spend another 6,000 characters, as §2. Provider-side caps, if any, are the only hard stop, and they sit behind the upstream call. The TTS proxy does *not* use this pattern for paid voice: a missing store plus an `ELEVENLABS_API_KEY` is already 500 `misconfig`.

**Consistency.** Atomic only inside one isolate. No cross-instance increment. Cold start resets the day counter.

**Latency.** No added network hop for a store.

**Secrets and env (names only).** None new. Keep `ENABLE_PAID_INFERENCE` unset. `MINIMAX_API_KEY` and `ELEVENLABS_API_KEY` already exist.

**Privacy.** No quota rows to store. Do not start logging text or ids as a substitute meter.

**Operational burden.** Lowest, as long as the flag stays off and TTS stays fail-closed without a store. It does **not** close #80 for `ray-do` if someone sets `ENABLE_PAID_INFERENCE=true`.

### 3.4 (d) Vercel Edge Config / Global Config — not suitable

Edge Config has been renamed Global Config ([vercel.com/docs/global-config/global-config-limits](https://vercel.com/docs/global-config/global-config-limits), fetched 24 November 2026). It is a read-heavy, globally replicated config store: writes can take **up to 10 seconds** to propagate, and the same page says not to use it for frequently updated data or for data that must be read immediately after a write. Hobby includes **100 writes / month**, then **$1 per 100 writes**; there is no atomic increment. A per-request reserve would burn the write budget on day one (15 writes/day at the TTS cap is already about 465/month) and would race during propagation. **Do not use this as the quota store.** Included only so it is not mistaken for a fourth viable option. Cost at cap volume is not a useful planning number, because the product is the wrong shape.

## 4. Comparison

| | (a) Upstash Redis (reuse) | (b) Supabase Postgres (existing project) | (c) No store | (d) Global Config |
| --- | --- | --- | --- | --- |
| Monthly store cost at cap volume | $0 on Free; ~$0.00–$0.56 on PAYG depending on command count | $0 incremental on the current tier; $25/mo only if the owner upgrades that org to Pro to avoid auto-pause | $0 | Not applicable |
| Failure mode | Fail closed (500/503, no upstream) | Fail closed, including auto-pause | Fail open on the 6,000 cap; provider cap only backstop | Racy, write-limited |
| Cross-instance cap | Yes, atomic Lua | Yes, one-statement RPC | No | No |
| Added latency | ≤ 2,000 ms bound, one REST call | One DB round trip, timeout to be defined | None | Writes up to 10 s to appear |
| Closes #80 if the flag is enabled | Yes | Yes | No | No |
| New service in this design | No (reuse) | No (reuse) | No | No |

## 5. Atlas's recommendation (not the owner's decision)

**Recommend (a): reuse the existing Upstash Redis (the current Vercel Marketplace / ex-KV store), with a separate key prefix for `ray-do`, and fail closed.**

Reasoning, briefly: the TTS proxy already has the client, the atomic reserve/refund scripts, the 2,000 ms bound, hashed-id keys, and the fail-closed rule when a paid key is present without a store. Expected volume fits the published Free allowance and is cheap on PAYG. It adds no new vendor and no Free-tier auto-pause. Supabase (b) would also work on the existing project and is a fair second choice if the owner prefers one database, but only after the live tier is confirmed; a Free-tier pause would look like an outage of the meter. (c) is the right *interim* posture — keep `ENABLE_PAID_INFERENCE` unset, keep the $0 iOS cap, do not treat this note as permission to spend — but it does not remediate #80. (d) is out.

**The owner still decides.** Please pick (a), (b), or (c). Until that pick, and until a follow-up implementation PR exists, `ENABLE_PAID_INFERENCE` stays unset in every deployed environment.

