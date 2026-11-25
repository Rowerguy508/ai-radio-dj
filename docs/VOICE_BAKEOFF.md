# Voice bake-off rubric, clip IDs, and cost estimate

Part of [#24](https://github.com/Rowerguy508/ai-radio-dj/issues/24). Written against `integration/device-duo` at `5a57269f`. This file is documentation only.

**Nothing paid was run for this document.** The paid cap stays $0: `VoiceBetaDefaults.paidDailyCapMicrodollars = 0` (`VoiceRendering.swift:208`) and `BetaVoicePolicy.paidSpendAllowedMicrodollars = 0` (`EditorialNarration.swift:749`). Running the bake-off needs explicit owner approval and a budget. The on-device provider is free, and it was not run here either.

No provider is recommended in this document. Issue #24 allows a recommendation only after representative listening scores average at least 4 out of 5.

## 1. Rubric

The bake-off compares providers that already exist in the repo (see §3) on one fixed clip list (see §2). Scoring is blind: listeners hear anonymized clip IDs only, with provider labels withheld until scores are in. Do not use celebrity voice cloning, instant clones, or "sound like" prompts. Use only the stock or catalog voices already listed for that provider.

### 1.1 Listening scale (1–5)

Use this scale for naturalness, pronunciation, emotional restraint, artifacts, and consistency. Half points are allowed (for example 3.5).

| Score | Meaning |
| --- | --- |
| 1 | Unusable: wrong language, frequent stalls, or a read that could not air. |
| 2 | Poor: many errors or a clearly synthetic, rushed, or theatrical delivery. |
| 3 | Acceptable but not host-quality: understandable, with noticeable issues. |
| 4 | Broadcast-ready for a calm DJ: small faults a listener might miss. |
| 5 | Excellent: a restrained human host, with no issues worth noting. |

Criterion notes:

- **Naturalness.** Does it sound like a calm radio host, not a ringtone or an ad?
- **Pronunciation.** Artist and track names, including Spanish; NYC place names; acronyms (MTA, LIRR, JFK, MoMA, CUNY); dates and times. A missed stress, a spelled-out acronym that should be lettered (or the reverse), or an Anglicized Spanish name is a deduction.
- **Emotional restraint.** Warm and steady. No shouting, no parody, no laugh track, no sudden theatrical swing.
- **Artifacts.** Glitches, clipped words, repeated syllables, odd breaths, drop-outs, or a hard cut at the end.
- **Consistency across breaks.** Same provider, same voice, all 20 clips. A host who changes tone, rate, or mic distance from clip to clip scores lower here, even if each clip is fine alone.

### 1.2 Weights and pass bar

The recommendation number is the weighted listening average across all 20 clips and all listeners:

| Criterion | Weight |
| --- | --- |
| Naturalness | 25% |
| Pronunciation | 25% |
| Emotional restraint | 15% |
| Artifacts | 15% |
| Consistency across breaks | 20% |

**Pass bar:** a provider may be recommended only when that weighted average is **at least 4.0 out of 5**. If two providers both pass, record both scores and let the owner choose; do not break a tie by cost alone in the write-up, but do put the cost table next to the scores. If every provider is under 4.0, recommend none and keep on-device as the shipping default.

Unresolved cases are recorded, not rounded away: a clip the listener could not score, a large disagreement (2 or more points on the same criterion after a second listen), or a render that failed and had no audio. Failed renders do not get a courtesy 1 on listening; they go in the failure log and leave that clip out of the average, with the omission named.

### 1.3 Measured checks (not folded into the 4.0 bar)

These are reported beside the listening score. They do not get a 1–5 average.

| Check | How to record it | What “good” looks like |
| --- | --- | --- |
| Latency to first audio | Wall time from the start of `synthesize` to the first playable audio byte or frame. Report per clip, plus p50 and p95 per provider. | Completes inside the route timeout (20 s on-device and Phonon, 16 s on the ElevenLabs proxy route, 8 s `VoiceRoute` default). Flag any clip that would miss the ordinary 15 s main-segment prepare window (`docs/editorial-narration.md`). This document does not invent a tighter SLA. |
| SSML or prosody control | For each provider, note whether it accepts SSML (`VoiceRoute.acceptsSSML`), ignores tags, or reads markup aloud. The clip list itself is **plain text** (contractions, em dashes, ellipses) so every provider gets the same input. An optional SSML re-run is out of scope until the owner asks for one. | On-device `avspeech` routes set `acceptsSSML: true`. Phonon and the ElevenLabs proxy routes set `acceptsSSML: false`. Cartesia has no shipping route, so this is unknown until one exists. |
| Failure behaviour | For a timeout, invalid audio, 429 or 5xx, over-cap reservation, unimplemented stub, or cancel: does `VoiceRenderer` continue to the next route, and does on-device remain last, without a silent break? | Paid or proxy failures must not silence the DJ. `DessaVoiceProvider` always throws `notImplemented` and must never be placed ahead of a working route (`VoiceRendering.swift:1122–1129`). An over-cap paid route records `.overCostCap` and falls through (`VoiceRendering.swift:973–974`). |
| Privacy (does text leave the device?) | Factual, not a style score. Record `VoiceRoute.leavesDevice` for the route under test. | On-device and Phonon: no. Proxy Cartesia and ElevenLabs: yes. Bake-off scripts are public sample text only, never private user content. A future run that included personal lines must keep those lines on-device unless the owner has already approved a cloud-voice path and the cue passes `VoiceRenderer.mayLeaveDevice`. |
| Cost per break | Characters in that clip × the provider rate in §4. Also report $/spoken minute after a run, once duration is measured; until then, use characters only. | See §4. A cache hit is not a second take: turn the cache off or bypass it, or the second take is free and not independent. |

## 2. Clip-ID list

Twenty fixed scripts, IDs `BO-01` through `BO-20`. Types: intro, back-announce, time and weather, hard names, and long break. The set covers the #24 brief: acronyms, names, NYC terms, bilingual names, dates, pauses, and questions. Tone is a calm DJ host.

Text is generic or public catalog sample copy only. There is no private calendar, mail, message, note, or listener content. Weather and time figures are invented for pronunciation and pacing, not live conditions. Artist and track names are well-known public recordings, used here as pronunciation material, not as a license or playlist claim.

**Character counts** use Swift `String.count` (extended grapheme clusters), the same unit `VoiceRenderer` reserves with (`VoiceRendering.swift:973` and `VoiceRoute.cost` at `:75–76`). Every letter, number, space, punctuation mark, and the em dash `—` counts as one. The scripts are NFC, plain text, no SSML. Ellipses are three periods (`...`). Every clip is at most 600 characters, which is the proxy default `AERODJ_TTS_MAX_TEXT_CHARS` (`handler.ts:35`, `:683`).

| ID | Type | Characters | What it stresses |
| --- | --- | --- | --- |
| BO-01 | intro | 144 | Calm morning open |
| BO-02 | intro | 130 | Mid-day open, a question |
| BO-03 | intro | 120 | Evening open |
| BO-04 | back-announce | 109 | English title and artist |
| BO-05 | back-announce | 112 | Spanish artist and title (Rosalía, Malamente) |
| BO-06 | back-announce | 113 | José González, Midtown, a question |
| BO-07 | back-announce | 95 | Shakira, Carlos Vives, La Bicicleta |
| BO-08 | time and weather | 172 | Time, date, NYC weather |
| BO-09 | time and weather | 169 | p.m., date, a pause, a question |
| BO-10 | time and weather | 152 | Mid-day, Queens, a question |
| BO-11 | hard names | 156 | Bad Bunny, Tití Me Preguntó, Celia Cruz, Café Tacvba |
| BO-12 | hard names | 167 | A train, Washington Heights, BQE, Kosciuszko, LIRR, a pause |
| BO-13 | hard names | 176 | MoMA, CUNY, JFK, MTA, LGA, EWR, Q train |
| BO-14 | hard names | 153 | Luis Fonsi, Juanes, Despechá |
| BO-15 | hard names | 154 | Dates and ordinals (2nd of March, November 24) |
| BO-16 | long break | 594 | Morning wrap: NYC terms, Spanish names, a question |
| BO-17 | long break | 590 | Back-announce chain, pause, weather, a question |
| BO-18 | intro | 157 | Opening pause, restrained tone |
| BO-19 | back-announce | 172 | WNYC, José González, Q train, a question |
| BO-20 | long break | 599 | Close: names, NYC map, date |
| **Total** | **20 clips** | **4,234** | |

### 2.1 Exact text

**BO-01** (intro, 144)

Good morning. This is OnAirly, and I'm glad you're here. We'll keep things easy: a little music, a short word between songs, and no rush at all.

**BO-02** (intro, 130)

Hey, you're with OnAirly in the middle of the day. Need a short break from the noise? Stay close. The next few songs are for that.

**BO-03** (intro, 120)

Evening from OnAirly. The city's still moving, but we can take it slower in here. Settle in for a calm stretch of music.

**BO-04** (back-announce, 109)

That was The Beatles with Here Comes the Sun. A little light for the room, and we'll keep that feeling going.

**BO-05** (back-announce, 112)

You just heard Rosalía with Malamente. We'll stay in that pocket for one more, then ease into something quieter.

**BO-06** (back-announce, 113)

José González, Heartbeats, coming to you from a rainy Midtown afternoon. Want to ride this mood to the next stop?

**BO-07** (back-announce, 95)

That was Shakira and Carlos Vives with La Bicicleta. A sunny little trip, no passport required.

**BO-08** (time and weather, 172)

It's 8:07 in the morning in New York, Tuesday, November 24. Overcast, about forty-four degrees, and a light wind off the Hudson. Give yourself a minute before you head out.

**BO-09** (time and weather, 169)

Right now it's 5:42 p.m. on Friday, July 3. The air is thick, mid-eighties, and... there's a rumble of storms later tonight. If you're walking, maybe grab that umbrella.

**BO-10** (time and weather, 152)

It's 12:15 p.m. on a bright Saturday in Queens. Clear skies, a light breeze, and the weekend is still young. Want to stay with us through the afternoon?

**BO-11** (hard names, 156)

Up next: Bad Bunny with Tití Me Preguntó, then Celia Cruz, La Vida Es un Carnaval, and a little Café Tacvba with Eres. That's a lot of joy in a small space.

**BO-12** (hard names, 167)

If you're on the A train through Washington Heights, or stuck on the BQE near the Kosciuszko Bridge, or waiting on the LIRR at Jamaica... breathe. We'll be right here.

**BO-13** (hard names, 176)

A listener note from near MoMA, another from CUNY, and one more from JFK after a long delay on the MTA. However you got here — LGA, EWR, or the Q train — you're on OnAirly now.

**BO-14** (hard names, 153)

Coming up: Luis Fonsi with Despacito, Juanes with A Dios le Pido, and Rosalía with Despechá. I'll take care with those names. You just enjoy the records.

**BO-15** (hard names, 154)

This hour was put together on Monday, the 2nd of March, 2026, and we're playing it again today, Tuesday, November 24. Same calm hour. No need to catch up.

**BO-16** (long break, 594)

Good morning, and welcome to a quieter start. It's Tuesday, November 24, a little after eight, and New York is already on the move: the MTA, the LIRR, a line at JFK, someone walking the High Line before the offices fill in. The forecast is cool and overcast, with a light wind off the Hudson... nothing dramatic, just a gray morning that asks for an easy tempo. We'll stay with that. Next up is a mix you can leave on: a little Rosalía, a little José González, and a back-announce or two when the songs ask for it. Need one more minute with your coffee before the day picks up? Stay right here.

**BO-17** (long break, 590)

That last stretch went by quickly, didn't it? Let's take a breath — not a long speech, just a moment to name what we heard and where we're going. You just heard Celia Cruz with La Vida Es un Carnaval, and before that, Café Tacvba with Eres. Coming up: Shakira and Carlos Vives, La Bicicleta, then Bad Bunny, Tití Me Preguntó. If a name is new to you, that's fine... let the record do the work. It's 5:42 p.m. in Midtown, mid-eighties and sticky, with storms possible later. Want to keep this window open through the commute? We'll be here through the next few songs, and we'll keep it calm.

**BO-18** (intro, 157)

Give it a second... there. This is OnAirly, and we can start whenever you're ready. No big open, no raised voice. Just a few songs, and a word when it helps.

**BO-19** (back-announce, 172)

That was WNYC's kind of afternoon energy, but this is OnAirly: José González with Heartbeats, then a quiet turn toward evening. The Q train can wait one more song. Can you?

**BO-20** (long break, 599)

We're at the end of this set, so here's a short close. Today is Tuesday, November 24, 2026. We opened in the morning, checked the time and the New York weather, and spent care on names: Rosalía, José González, Café Tacvba, Juanes, Luis Fonsi, Bad Bunny, Celia Cruz, Shakira. We mentioned the A train, the BQE, the Kosciuszko Bridge, MoMA, CUNY, JFK, LGA, EWR, the MTA and the LIRR — the ordinary map of a day in this city. If a name was hard to say, that was the point, not a test for you. Thank you for listening. We'll start the next hour the same way: calmly, and on time. See you after the song.

## 3. Providers on integration (`5a57269f`)

Taken only from the tree as it stands. `BetaVoicePolicy.disabledProviderIDs` is `["cartesia", "dessa", "elevenlabs"]` (`EditorialNarration.swift:751`). `BetaVoicePolicy.paidProvidersEnabled` is `false` (`:748`). Production audio still comes from `VoiceRenderer.onDeviceDefault()` (`OnDeviceSpeechProvider.swift:207–219`).

| Provider | Repo id | Leaves the device? | Repo rate (`microdollarsPerThousandCharacters`) | Status on this tip |
| --- | --- | --- | --- | --- |
| On-device Apple speech | `avspeech` (`OnDeviceSpeechProvider.swift:13–14`) | No | 0 (default). `billableUnits` is 0 (`OnDeviceSpeechProvider.swift:59`). | Shipping last route. `VoiceRoute.onDeviceRoutes()` (`:199–211`) uses a 20 s timeout and `acceptsSSML: true`. `BetaVoicePolicy.onDeviceRoute` names the same kind of route `device` (`EditorialNarration.swift:753`). |
| Phonon (on-device) | `phonon` (`PhononSpeechSelection.swift:11`) | No | 0 (`PhononSpeechProvider.swift:68`) | Optional extra route in `PhononSpeechRoutes.make()`, only when the flag is on and the runtime is iOS 18 arm64. It throws when the model is missing and the renderer continues to `avspeech`. Not in `disabledProviderIDs`. `acceptsSSML: false`. |
| ElevenLabs via the TTS proxy | `elevenlabs` (`PremiumVoiceCatalog.swift:107`); `ProxyVoiceProvider.Upstream.elevenlabs` (`ProxyVoiceProvider.swift:30`) | Yes (`PremiumVoiceCatalog.swift:167–171`; `TesterVoiceRoute.swift:55–64`) | **0 in the app.** Spend is meant to be capped upstream, so `VoiceBudget` does not block it (`PremiumVoiceCatalog.swift:159–161`). | Named in `disabledProviderIDs`. The deployed proxy accepts only `upstream: "elevenlabs"` (`handler.ts:677`). Default model is `eleven_flash_v2_5` (`handler.ts:36`, `:686`). Owner A/B and attested tester compositions exist, and both still need an owner decision plus the existing gates before a bake-off can use them. |
| Cartesia via the TTS proxy | `cartesia` (`ProxyVoiceProvider.Upstream.cartesia`, `ProxyVoiceProvider.swift:30`) | Would be yes (any `ProxyVoiceProvider` route) | No shipping route, so no repo rate. | Named in `disabledProviderIDs`. The client enum exists; `services/aerodj-tts` has no Cartesia adapter, and the proxy returns 400 for any upstream other than `elevenlabs`. A Cartesia bake-off cannot run on this tip without new proxy work and a separate owner approval. |
| Dessa stub | `dessa` (`DessaVoiceProvider`, `VoiceRendering.swift:1124–1125`) | n/a (no request is made) | n/a | Disabled. `synthesize` always throws `VoiceRenderError.notImplemented("Dessa adapter is not implemented yet")` (`:1127–1129`). There is still no documented Dessa API. Do not invent a request, and do not place this stub ahead of a working route. |

`ProxyVoiceProvider` (`ProxyVoiceProvider.swift:20–29`) is the only cloud client: the app never holds a provider API key, and text that uses it leaves the device. It is not enabled in `onDeviceDefault()`.

`BundledClipResolver` (`elevenlabs-bundled`) serves pre-rendered audio already in the app bundle. It is not a live TTS provider and is out of scope for this bake-off.

Roadmap items that are not `VoiceProvider`s on this tip (for example OpenAI realtime in `docs/AERODJ_IOS_ROADMAP.md`) are also out of scope.

## 4. Cost write-up

One pass of the clip list is **4,234 characters**. The planning example is **3 listeners × 2 takes = 6 passes**, which is **25,404 characters per provider**, if every take is actually re-rendered (cache off or bypassed).

### 4.1 Rates in the repo

There is **no configured paid rate** on integration. Every shipping `VoiceRoute` sets `microdollarsPerThousandCharacters` to 0: on-device and Phonon as above, and the ElevenLabs proxy routes at `PremiumVoiceCatalog.swift:167` and `TesterVoiceRoute.swift:59`. `VoiceRoute.isPaid` is therefore false for all of them (`VoiceRendering.swift:56`). Values such as `10_000`, `30_000`, and `50_000` appear only in tests; they are fixtures, not prices, and are not used here.

`VoiceRoute.cost` is `(characters * microdollarsPerThousandCharacters + 999) / 1000` (`VoiceRendering.swift:75–76`). With a 0 rate that cost is always 0, and `VoiceBetaDefaults.paidDailyCapMicrodollars = 0` still refuses any route that *was* priced above 0.

A comment at `PremiumVoiceCatalog.swift:60–62` (2026-10-29) notes an ElevenLabs Starter arrangement (a hard 40k-credit ceiling, a 9k-credit key cap, and the proxy's 9,000-character daily cap). That is an operational note, not a current list price, and it is **unverified against today's plan; owner to confirm** before treating those caps as the bake-off budget.

The proxy's own character caps, independent of vendor list prices (`limiter.ts` and `services/aerodj-tts/README.md`):

| Cap | Default | One pass (4,234) | Six passes (25,404) |
| --- | --- | --- | --- |
| Per request | 600 (`handler.ts:35`) | Each clip fits | Each clip fits |
| Global daily | 9,000 (`DEFAULT_GLOBAL_DAILY_CHAR_CAP`) | Fits | Over — would need more than one UTC day, or an owner-approved cap change |
| Owner share daily | 3,000 (`DEFAULT_OWNER_SHARE_DAILY_CHAR_CAP`) | Over | Over |
| Per-install daily | 1,500 | Over | Over |
| Tester pool daily | 6,000 | Fits | Over |

A paid run on the current defaults cannot be a single-day 6-pass owner or tester bake-off without the owner raising caps or spreading the work across days. That is a cap issue, not a reason to change code in this PR.

### 4.2 Public list prices (fetched 24 November 2026)

Where the repo has no rate, the figures below come from the provider's public pricing page, fetched on 24 November 2026 (America/New_York). Dollar amounts are USD list prices, excluding tax. If a page changes, the owner should re-check before approving spend.

**ElevenLabs** — [https://elevenlabs.io/pricing/api](https://elevenlabs.io/pricing/api), fetched 24 November 2026. The FAQ on that page states that the Text to Speech API costs **$0.08 per 1,000 characters** on Eleven v4, v3, and Multilingual v2, and **$0.04 per 1,000 characters** on Eleven v4 Turbo, v3 Conversational, and Flash and Turbo models. Dollar prices are the same on every plan. The shipping proxy default, `eleven_flash_v2_5`, is a Flash model, so the **$0.04** row is the one that applies unless the owner changes `ELEVENLABS_MODEL_ID`.

**Cartesia** — [https://www.cartesia.ai/pricing](https://www.cartesia.ai/pricing) and [https://docs.cartesia.ai/pricing](https://docs.cartesia.ai/pricing), fetched 24 November 2026. Cartesia does not publish a flat per-character dollar list price. Official docs say Sonic TTS costs **approximately 1 credit per character** (transcript pre-processing can vary slightly; that variance is **unverified, owner to confirm** after a real invoice). Published plans on 24 November 2026:

| Plan | Monthly price | Credits included | Published overage (if enabled) |
| --- | --- | --- | --- |
| Free | $0 | 20,000 | None (requests stop) |
| Pro | $5 | 100,000 | $65 per 1M credits |
| Startup | $49 | 1,250,000 | $45 per 1M credits |
| Scale | $299 | 8,000,000 | $38 per 1M credits |

USD per character is therefore **derived** (plan price ÷ included credits, or the published overage), not a vendor list price. Derived included rates: Pro $0.0500, Startup $0.0392, Scale $0.037375 per 1,000 characters. The Pro row is the planning figure below (smallest paid plan that the page lists with a commercial-use license). The roadmap's older “$5 / 100k credits, about 133 minutes” note still matches this Pro plan; the per-character dollar math is ours.

**On-device `avspeech` and Phonon:** $0 and 0 credits. **Dessa:** not runnable; $0 because no call is made.

**Unverified, owner to confirm:**

- Whether ElevenLabs bills `previousText` / `nextText` stitching context in addition to the spoken line. The proxy does not count context toward its own character caps (`services/aerodj-tts/README.md`). The totals below use spoken clip text only.
- Whether Cartesia credit use is exactly 1 credit per character after pre-processing.
- The live ElevenLabs subscription, key cap, and any remaining credits on the owner's account (the 2026-10-29 comment is not treated as current billing).
- Any tax, overage flag, or Enterprise discount.

### 4.3 Estimated spend

Formula, using spoken characters only: `USD = characters / 1000 × dollars_per_thousand`. This is the vendor list (or derived plan) arithmetic, not `VoiceRoute.cost`, which would be 0 on today's routes.

| Provider | Rate used | Source | One pass (4,234 chars) | 3 listeners × 2 takes (25,404 chars) |
| --- | --- | --- | --- | --- |
| On-device `avspeech` | $0 | Repo (`OnDeviceSpeechProvider.swift:59`) | $0 | $0 |
| Phonon | $0 | Repo (`PhononSpeechProvider.swift:68`) | $0 | $0 |
| Dessa stub | n/a | Repo (`VoiceRendering.swift:1127–1129`) | $0 (no call) | $0 (no call) |
| ElevenLabs Flash / Turbo (default `eleven_flash_v2_5`) | $0.04 / 1,000 characters | [elevenlabs.io/pricing/api](https://elevenlabs.io/pricing/api), 24 November 2026 | **$0.1694** | **$1.0162** |
| ElevenLabs v3 / v4 / Multilingual v2 (only if the model is changed) | $0.08 / 1,000 characters | Same page | $0.3387 | $2.0323 |
| Cartesia Sonic, credits | ~1 credit / character | [docs.cartesia.ai/pricing](https://docs.cartesia.ai/pricing), 24 November 2026 | 4,234 credits | 25,404 credits |
| Cartesia, derived Pro included ($5 / 100k credits) | $0.0500 / 1,000 characters | Arithmetic from [cartesia.ai/pricing](https://www.cartesia.ai/pricing), 24 November 2026 | $0.2117 | $1.2702 |
| Cartesia, published Pro overage | $65 / 1M credits | Same page, FAQ | $0.2752 | $1.6513 |

If both ElevenLabs Flash and Cartesia Pro (included-rate) were run for six passes, the sum of those two planning rows is about **$2.29**, plus whatever a monthly plan itself costs if one is not already in place. Cartesia cannot actually be called on this tip (see §3). ElevenLabs also cannot be called while the paid cap stays $0 and `disabledProviderIDs` still includes `elevenlabs`, unless the owner explicitly approves a bake-off path and budget.

Cost per break is the clip's character count times the same rate. The most expensive single clip is BO-20 (599 characters): about $0.0240 on ElevenLabs Flash, $0.0479 on ElevenLabs v3/v4, 599 Cartesia credits, and about $0.0300 on the derived Cartesia Pro included rate.

## 5. What this document does not do

- It does not change any code, config, env, CI, feature flag, or expected test value.
- It does not call ElevenLabs, Cartesia, Dessa, or any other paid API, and it does not run on-device or Phonon synthesis.
- It does not raise `paidDailyCapMicrodollars`, enable `paidProvidersEnabled`, or remove an id from `disabledProviderIDs`.
- It does not close or “fix” #24. The owner still decides whether to run the bake-off, on which providers, at what budget, and whether any later PR should change shipping policy.
