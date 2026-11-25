# OnAirly Privacy Policy

_Last updated: November 23, 2026_

## The short version

OnAirly: Personal AI Radio DJ is a radio DJ that runs on your iPhone or iPad, with iOS 17 or iPadOS 17 or later and an Apple Music subscription. Your calendar, Markdown notes, the things you share to OnAirly, your music library and your station settings are read and kept on your device. There are no ads, no analytics, no tracking and no data brokers in OnAirly, and we don't sell or share your data.

Playback goes through Apple Music. Local weather and local news are off until you turn them on; then Apple's geocoding service looks up your area and Apple Weather gets a coarse point, and in TestFlight tester builds local news can send a city or region name to a news provider. On iOS 27 and later, OnAirly also asks our server for a few on/off settings each time it starts, without any account, ID or content. If you turn on the optional cloud voice, the text of every DJ line is sent to our voice server and on to ElevenLabs. Details are below.

## What stays on your device

- **Calendar.** If you allow it, OnAirly reads events from the calendars you pick so the DJ can mention them. Events stay on your device unless you turn on cloud voice, in which case the words of a DJ line that mentions them are sent as described below. Spoken clips that use them expire after 7 days and are deleted when you remove access.
- **Markdown notes and shared items.** Markdown notes (.md files you pick), and text or links you share to OnAirly, stay on your device. For each note, OnAirly keeps only a link to the file and its name, and reads the text when it's needed; the note's text isn't saved. Shared items are deleted after 7 days, or right away when you delete them. Spoken clips made from a note or a shared item expire after 7 days, and are deleted when you stop using the note or delete the item. If you turn on cloud voice, the words of a DJ line that uses a note or a shared item, including a shared email digest, are sent as described below.
- **Your music library and stations.** Library playlists, songs and artists you use as station seeds, and the names you give your stations, stay on your device. If you turn on cloud voice, lines about library tracks, catalog titles and artists, and the station names you type are sent as described below.
- **On-device voices.** The built-in voices speak entirely on your device.
- **Spoken clips.** So the DJ doesn't have to make the same clip twice, OnAirly saves the audio of what it says on your device, protected by iOS Data Protection. Only the audio is saved, not the written text. A clip is never played once it's 7 days old, and it's deleted the next time OnAirly runs (the app checks when it starts and every hour while it's open). Clips made from your calendar, Markdown notes or shared items are also deleted each time OnAirly starts, and right away when you stop using that source or delete the item. Like other app data, saved clips can be included in your iCloud or computer backups.

## Cloud voice

Some TestFlight testers can try a cloud voice for the DJ. This voice is made online, not on your device. It is off unless you turn it on. OnAirly asks you before any DJ line leaves your device. You have to accept the current notice; an older acceptance does not count.

What's sent: the text of every DJ line. That includes your personal items (calendar events, your shared email digest and other shared items, and notes), lines about songs from your music library, the station names you type, and the news and weather lines. Catalog song titles and artists can also be in those lines. OnAirly sends every line the DJ says to our voice server and on to ElevenLabs, which turns it into audio.

What's never sent: your Apple ID, your contacts, your coordinates or your location itself, or anything you haven't approved for your briefing. Only the words the DJ speaks are sent, and a local news line can name your city or area.

Your coordinates and your location itself are never sent, but a local news line can name your city or area.

How it's stored: our server keeps a short technical log without the text, plus the App Attest security and quota records described under Data we collect below. Model training is turned off for our ElevenLabs account, but zero retention is not enabled, and ElevenLabs may keep the text and audio it receives under [its own privacy policy](https://elevenlabs.io/privacy-policy).

You can switch back to the on-device voice at any time in Settings. Turning the cloud voice off stops future sends from the next line and deletes the saved cloud clips on your device. It does not delete text or audio already sent to ElevenLabs (governed by ElevenLabs' privacy policy), and server-side App Attest records expire automatically on the timers below. Cloud clips of library songs and station names are kept between launches, for up to 7 days, so the same words aren't sent again. "Delete DJ clips, ratings and location" deletes them, along with the cloud clips made from your calendar, notes and shared items.

## Local news and weather

Local weather and local news each have their own switch in Tune → DJ, and both start off. OnAirly asks about your location only after you turn one of them on: you can allow approximate location (only while the app is open) or type a city or ZIP instead. Then OnAirly can mention local weather and, in TestFlight tester builds, local news.

For local news in those tester builds, OnAirly sends only the city or region name to the GDELT Project, so it can fetch headlines. For a few countries the query also names the country, to narrow the results. Coordinates, ZIP codes and street addresses are not sent to GDELT. If you type a ZIP code, it is first turned into a city name by Apple's geocoding service (see below), and only the city name goes to GDELT; if that fails, nothing is sent. App Store builds do not include this news provider.

For local weather, a coarse coordinate is sent only to Apple WeatherKit. The coordinate is rounded to a tenth of a degree first.

To find the name of your city or region, OnAirly uses Apple's geocoding service, which works over the network: it sends Apple the rounded coordinate when you allow approximate location, or the city or ZIP you type. Apple handles WeatherKit and geocoding data under [Apple's Privacy Policy](https://www.apple.com/legal/privacy/).

## Apple Music

Playback, search, charts and your library go through Apple's MusicKit under your Apple ID. Apple handles that data under [Apple's Privacy Policy](https://www.apple.com/legal/privacy/). We don't receive your Apple ID.

**Settings check.** OnAirly asks our server for a few on/off settings: on iOS 27 and later, once each time the app starts (for example, whether to use OnAirly's own lock-screen player), and on any iOS version, once per launch when you first play to an AirPlay speaker (how the DJ voice plays there). The request sends no account, ID, token or content from your device. Like any web request, it carries your IP address and the app and iOS version, and our server code doesn't store or log your IP. On iOS 26 and earlier, when you're not using AirPlay, this request is never made.

## Data we collect

We use the data below only to run the features you turn on. We don't use it for tracking, advertising or analytics, and we don't sell it.

OnAirly has no account for you. Some of this can still identify you, because a request can include your calendar, a shared email digest or your notes, and song titles can travel in the same request.

- **City or region name.** In TestFlight tester builds, the city or region name sent to GDELT for local news, as described above. This is not linked to your name or account.
- **Shared email digest.** After you accept the cloud-voice notice, the text of a shared email digest that appears in a DJ line.
- **Other content you provide.** After you accept the cloud-voice notice, the text of DJ lines that use your calendar, notes, other shared items, library-track lines, typed station names, and news or weather lines. Every DJ line's text goes to ElevenLabs, which may keep the text and the audio it generates. Model training is turned off for our ElevenLabs account.
- **Device identifier and attestation records.** In TestFlight builds that use cloud voice, an App Attest key ID, plus a random install ID (made on your device, kept in its Keychain, and sent only when the app enrolls), so our server can confirm the request comes from a genuine copy of OnAirly. For each enrolled install, our voice server stores a per-install key record (public key, App Attest environment, creation day, tester tier and why that tier was granted) and the key's assertion counter, with a 90-day sliding TTL that refreshes when the app mints a token and expires automatically after 90 days of inactivity. For abuse and quota limits it also keeps day-scoped counters with a 2-day TTL: enrollment counts stored under keyed hashes of your network address and of the install ID (the address and the install ID themselves are not stored), a count of tokens each key minted that day, and a hashed per-install count of cloud-voice characters used that day. Per-minute request counters last about 2 minutes, and single-use challenge marks last up to 5 minutes to prevent replay. If we revoke an install's key to stop abuse, a revocation entry for that key is kept for 90 days. These security and quota records are not linked to your name or Apple ID, and our server never stores them with script text.
- **Song titles and artists.** After you accept the cloud-voice notice, catalog song titles and artists that appear in a DJ line. These can travel in the same request as personal text.

We do not collect a separate name field, a recording of your voice, purchase records, precise location, a user ID, crash or advertising data, browsing history, health or financial data, or your contacts. A typed station name that happens to be a person's name is treated as other content you provide. MusicKit and WeatherKit are Apple services.

## Children

OnAirly is rated 13+.

## Your choices

You can deny or revoke calendar, Apple Music and location access in iOS Settings, stop using your calendar or Markdown notes in the app's Connections, delete shared items in the app, or turn off cloud voice in Settings. "Delete DJ clips, ratings and location" removes saved spoken clips, ratings and location data on your device. Deleting the app removes everything it stored on your device. Server-side App Attest records expire automatically (90-day sliding TTL for key records; 2-day TTL for daily counters; 90 days for a revocation entry) and are not deleted on demand; text already sent to ElevenLabs while cloud voice was on cannot be remotely deleted by OnAirly and remains subject to ElevenLabs' privacy policy.

## Changes

We'll update this page, and the notice in the app, before we change anything about what leaves your device.

## Contact

Email [support@onairly.app](mailto:support@onairly.app). Replies come from onairly@agentmail.to. For help using the app, see [Support](/support).
