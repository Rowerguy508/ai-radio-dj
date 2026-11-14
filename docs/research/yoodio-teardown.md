# Yoodio teardown: DJ breaks and personal updates

> Author: Nova (design and SwiftUI). Researched 2026-10-27 from public sources only. I haven't installed or run
> the app, so nothing here was observed on a device.
> Each claim is tagged **[V]** (verified: stated in a cited source) or **[U]** (unverified: inferred, or a
> single user report, or a developer claim with no shipped release note). Feature text in quotes is copied from
> the source.

## Sources

| # | Source | URL |
|---|---|---|
| S1 | App Store listing, "Yoodio: AI Radio with Live DJs" (description, version history, privacy label, IAP, reviews) | https://apps.apple.com/us/app/yoodio-ai-radio-with-live-djs/id6743950965 |
| S2 | Older App Store listing text, "Yoodio: Generative Radio" (v1.01, Apr 2025) | https://apps.apple.com/us/app/yoodio-generative-radio/id6743950965 |
| S3 | Developer launch post, MacRumors forums (Feb 23, 2025) | https://forums.macrumors.com/threads/i-made-an-ai-dj-for-apple-music.2450033/ |
| S4 | Same launch post plus user feedback, r/AppleMusic (Feb 2025) | https://www.reddit.com/r/AppleMusic/comments/1iwi68c/i_made_an_ai_dj_for_apple_music/ |
| S5 | User review thread, r/AppleMusic "Awesome radio app" (Apr 2025) | https://www.reddit.com/r/AppleMusic/comments/1jp3for/awesome_radio_app/ |
| S6 | Dev blog: "How to get the most out of Yoodio (and life)" (Dec 15, 2025) | https://yoodioapp.substack.com/p/how-to-get-the-most-out-of-yoodio |
| S7 | Dev blog: "Happy Birthday, Yoodio Radio" (Apr 1, 2026), tier restructure | https://yoodioapp.substack.com/p/happy-birthday-yoodio-radio |
| S8 | Dev blog: "Meet Valerie. New Pro Plan. And More." (Apr 7, 2026), v1.05.4 | https://yoodioapp.substack.com/p/meet-valerie-new-pro-plan-and-more |
| S9 | Dev blog: "Yoodio Radio no longer requires Apple Music" (Apr 16, 2026) | https://yoodioapp.substack.com/p/yoodio-radio-no-longer-requires-apple |
| S10 | Dev blog: "Listening, in progress" (Apr 30, 2026) | https://yoodioapp.substack.com/p/listening-in-progress |
| S11 | Dev blog: "Grab it while it's hot" (May 3, 2026), Pro sale and roadmap | https://yoodioapp.substack.com/p/grab-it-while-its-hot |
| S12 | Dev blog: "Yoodio for Web is available for you" (May 15, 2026) | https://yoodioapp.substack.com/p/yoodio-for-web-is-available-for-you |
| S13 | Dev blog: "How a feature request changed everything about my app" (Dec 23, 2025) | https://yoodioapp.substack.com/p/how-a-feature-request-changed-everything |
| S14 | Dev blog: "She's Not Real…" (Feb 12, 2026), Daily Stations (written as an in-character interview) | https://yoodioapp.substack.com/p/shes-not-real-but-her-taste-in-music |

Not readable: https://yoodioapp.com/privacy and the rest of yoodioapp.com are a client-rendered web app, and
neither fetch nor curl returned any policy text. **The privacy policy wasn't reviewed.** The privacy section
below relies only on the App Store privacy label (S1).

## 1. Product at a glance

- **[V]** iPhone app by Generative Experiences LLC. Free with in-app purchases. The current listing needs
  iOS 26. The latest version is 2.20.0 (Jul 23, 2026), "Apple Music restored". Rated 4.2 from 18 ratings (S1).
- **[V]** Stations come from a natural-language prompt ("70s Ethiopian jazz", "what college radio played in
  1996") or from curated stations with named hosts: Solvang Radio with DJ Aya, Doubledoor Radio with DJ Flash,
  and Personal Radio with Joey Cotillard (S1).
- **[V]** It's LLM-driven. The developer says "a consequence of using LLMs is that all the languages of the world
  are built into the knowledge of the DJs" (S6).
- **[V]** Catalog: it launched on Apple Music. Since Apr 2026 it defaults to SoundCloud and no longer needs
  Apple Music, and you can switch catalogs in settings (S9). One review (Jun 28) said Apple Music integration
  had disappeared, and the developer answered that 2.20.0 restored it (S1).
- **[V]** A web version (May 2026) focuses on "news by the minute" stations (S12).

## 2. DJ break structure

### When breaks happen
- **[V]** Breaks happen between tracks. 1.03.7 (Nov 27, 2025): "Transition commentary is now placed between
  tracks to avoid interrupting track endings" (S1). Before that, users reported DJs talking over songs:
  "some of these DJs go on for an entire minute before the song is even over!" (S5).
- **[V]** 1.04.1 (Dec 18, 2025): "Fixed commentary silence between when track ends and host starts speaking"
  (S1). So the handoff is a track end, then the host, with no deliberate gap.
- **[U]** How often breaks happen. Early users said the DJ spoke after every track. "I don't think the voice needs
  to come on after every track" (S4). "You don't need to talk in and out of every song" (S5). 1.03.2 added "a
  station frequency toggle in settings" (S1). It's unclear whether that controls talk frequency or something
  else, and no cadence numbers are published.

### Length
- **[V]** 1.03.7 added "a user-configurable commentary length setting" (S1). The values and range aren't
  published **[U]**.
- **[V]** Users heard up to about a minute of talk before the change to between-track placement (S5).

### Segments and content
- **[V]** Listing: "Between tracks: real commentary, local weather, life advice, and stories from their past" (S1).
- **[V]** 1.04.1 widened commentary to "music deep dives, life stories, weather reports/forecasts, lyric
  breakdowns, and local business shoutouts" (S1).
- **[V]** Older listing: "Grounded news, traffic, and local updates from around your area" (S2).
- **[V]** A reviewer: the DJ "introduces and backsells music", "works in local references and even the user's
  name", and adds "little stories". They also mention "time checks" (S5).
- **[V]** Hosts have invented biographies and backstories. Valerie "started as an intern… then she got fired"
  (S8), and DJ Ilya told a story about "frozen nitrogen to keep powering his radio transmitters" (S6). The
  personas are fictional characters, presented with a wink.
- **[U]** Fixed intro and outro packaging such as jingles or station IDs. Nothing found. There's a "wait
  soundbed" while a station is being generated (S9), but that isn't a break element.
- **[V]** Roadmap, not confirmed shipped: "caller events", "mini-interview segments", and "podcast style reports
  on your interests" for Pro (S7). Also "real-time world news", sports, and markets, "first-available to Pro"
  (S11).

### Voice
- **[V]** "1000+ radio personalities and 30+ unique voices" (1.02.4, S1). A reviewer called it "one of the best
  sounding AI voice tracks I've heard" (S5).
- **[U]** The TTS vendor and whether synthesis runs on a server. Not published. A cloud voice is likely given
  the quality and the LLM use, but that's unconfirmed.
- **[V]** Known audio-route bug (early 2025): music played on a HomePod over AirPlay while "the AI voice plays
  through the phone" (S4).

## 3. Personal updates

### Weather
- **[V]** Local weather is in the listing (S1). Weather reports and forecasts were added to commentary in
  1.04.1 (S1).
- **[U]** The weather provider. Not stated.

### News, traffic, and "alerts"
- **[V]** At launch the developer said: "news commentary between tracks focusing on news, traffic, and weather
  around you… If there's an accident or construction on your route ahead, the host will point it out" (S3, S4).
- **[U]** Route-aware traffic. That's a developer claim from the TestFlight era. No release note confirms it, and
  nothing explains how a route is known (no navigation or Maps integration is documented).
- **[V]** 1.02.4: "set a location to bring in news and traffic updates from there" during station creation (S1).
  1.03.6: "Station addons… include tracks, artists, location" (S1). Location is a station attribute.
- **[U]** Whether that location is device GPS, typed, or both. "Set a location" reads as manual entry, and the
  privacy label lists **Location** under "Data Not Linked to You" (S1), so a location value leaves the device in
  some form.
- **[V]** A user review (Jun 2026) mentions "local news traffic and weather forecast" (S1).
- **[V]** Not found: anything resembling official weather or emergency alerts. "Alerts" in Yoodio means
  traffic and news commentary.

### Calendar
- **[V]** **No calendar feature found** in any source (listing, version history, dev posts, reviews). Yoodio's
  "personal" layer is the user's name, location, taste, and the developer's stated ambition for a "companion"
  that knows "what you did this week, or what you have planned next" (S13). That last part is a vision, not a
  shipped feature.

### Other personalization
- **[V]** "Personal Radio" is built from Apple Music taste. It was removed for SoundCloud users because it "leaned
  on artist preferences Yoodio doesn't have access to with SoundCloud". Host preferences were also removed:
  "Better to remove them than to have controls that lie about what they do" (S10).
- **[V]** "Daily Stations" (Feb 2026): a new curated station every day for engaged listeners (S14, written as
  in-character fiction).
- **[V]** Like and dislike, with confirmation alerts (S10).

## 4. Permissions, setup and onboarding

- **[V]** Sign in with Apple (1.03.2, S1). The privacy label shows Name, Email, and User ID linked to the user (S1).
- **[V]** Onboarding went from 4 screens to 2 (1.03.2), was "slightly revamped… with clearer guidance"
  (1.03.7), and the "authenticate with Apple Music" step was removed from sign-in (Apr 2026). Now "Onboarding is
  super simple" (S1, S9, S10).
- **[V]** Notifications tell you when a station finishes generating (1.02.4, 1.03.2). A Live Activity tracks
  station creation (1.05.4) (S1, S8).
- **[V]** It asks for an App Store review after 10 minutes of listening (S10).
- **[U]** When each system permission prompt appears (notifications, location, Apple Music). No screenshots or
  docs found. Given the 2-screen onboarding, notifications may be requested early, but that's unconfirmed.
- **[V]** Privacy label (S1). Linked to you: Contact Info, Identifiers, Diagnostics (analytics: email, name, user
  ID, crash data). Not linked: Location, User Content, Usage Data.

## 5. Settings and controls

- **[V]** Commentary length (1.03.7). A "station frequency toggle" (1.03.2). Catalog switch, Apple Music or
  SoundCloud (S9). Like and dislike. "Recycle your setlist". You can back out of a station "without interrupting
  your stream" (1.02.4) (S1).
- **[V]** Removed over time: Last.fm scrobbling, station search, and the "context bar" (S9). Personal Radio and
  host preferences for SoundCloud (S10).
- **[U]** Per-segment toggles, for example weather on and news off. None documented. A user asked for news,
  traffic, and weather to be optional (S3), and no reply confirms that shipped.

## 6. Monetization

- **[V]** Pro launched in 1.03.1 (Aug 2025): "10x more daily Advance Host transitions" and up to 10 Advance Hosts
  a day (S1).
- **[V]** Current IAP: Yoodio Pro $2.99 a month and $29.99 a year (S1). Anniversary sale in Apr–May 2026: $0.99
  and $9.99 (S7, S8, S11).
- **[V]** Since Apr 2026, free users get **1 hour of premier-DJ listening** (Aya, Flash, Joey), and then the
  basic host Valerie takes over. Pro gets 10 hours and unlimited custom DJs (S7, S8). So the limit is metered on
  **DJ quality and time**, not music. That fits a per-minute cloud LLM and TTS cost **[U: inference]**.
- **[V]** The referral view was added in 1.05.4 (S8).

## 7. What this means for AeroDJ

1. **Between-track placement and length control are table stakes.** Yoodio's worst reviews were about talking
   over songs and talking after every song. AeroDJ already plans breaks only at natural boundaries
   (`DJBreakSession.naturalBoundary`), caps them at 12 s and 45 s (`DJCadence`), and spaces them at least 2 songs
   apart, which delivers about 30% of boundaries. Keep it that way.
2. **Weather and local updates are the personal hook. Calendar is open ground.** Yoodio has no calendar. A
   private, on-device "your next meeting is at 10" is a real differentiator, and our `CalendarContextSource`
   already exists.
3. **Yoodio's cost structure is the opposite of ours.** It meters DJ time because voice and LLM cost money per
   minute. With $0 on-device voice and template copy, AeroDJ can be unmetered. We should say so honestly, not
   copy the paywall.
4. **Their location goes to a server** (privacy label). Ours stays on device, rounded per L4, through WeatherKit.
   That's a privacy story worth telling in Connections copy.
5. **Their "controls that lie" lesson matches our UI contract.** Our `honestDescription` copy and
   `mayShowConnected` rules are the same instinct. Follow it for weather and alerts too.
6. **Audio route.** Their voice went to the phone while music went to AirPlay. Our P9 private-route rule and the
   session work in #125 need a device check on AirPlay before personal updates ship.
7. **Don't imitate:** fictional host biographies presented as real, route-traffic claims we can't source, and
   any wording that sounds like an emergency alert (W3).
