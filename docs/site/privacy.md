# OnAirly Privacy Policy

_Last updated: November 13, 2026_

## The short version

OnAirly: Personal AI Radio DJ is a radio DJ that runs on your iPhone or iPad, with iOS 17 or iPadOS 17 or later and an Apple Music subscription. Your calendar, Markdown notes, the things you share to OnAirly, your music library and your station settings are read and kept on your device. There are no ads, no analytics, no tracking and no data brokers in OnAirly, and we don't sell or share your data.

Playback goes through Apple Music. Local weather goes through Apple Weather. In TestFlight tester builds, local news can send a city or region name to a news provider. If you turn on the optional cloud voice, the text of every DJ line is sent to our voice server and on to ElevenLabs. Details are below.

## What stays on your device

- **Calendar.** If you allow it, OnAirly reads events from the calendars you pick so the DJ can mention them. Events stay on your device unless you turn on cloud voice, in which case the words of a DJ line that mentions them are sent as described below. Spoken clips that use them expire after 7 days and are deleted when you remove access.
- **Markdown notes and shared items.** Markdown notes (.md files you pick), and text or links you share to OnAirly, stay on your device. For each note, OnAirly keeps only a link to the file and its name, and reads the text when it's needed; the note's text isn't saved. Shared items are deleted after 7 days, or right away when you delete them. Spoken clips made from a note or a shared item expire after 7 days, and are deleted when you stop using the note or delete the item. If you turn on cloud voice, the words of a DJ line that uses a note or a shared item, including a shared email digest, are sent as described below.
- **Your music library and stations.** Library playlists, songs and artists you use as station seeds, and the names you give your stations, stay on your device. If you turn on cloud voice, lines about library tracks, catalog titles and artists, and the station names you type are sent as described below.
- **On-device voices.** The built-in voices speak entirely on your device.
- **Spoken clips.** So the DJ doesn't have to make the same clip twice, OnAirly saves the audio of what it says on your device, protected by iOS Data Protection. Only the audio is saved, not the written text. A clip is never played once it's 7 days old, and it's deleted the next time OnAirly runs (the app checks when it starts and every hour while it's open). Clips made from your calendar, Markdown notes or shared items are also deleted each time OnAirly starts, and right away when you stop using that source or delete the item. Like other app data, saved clips can be included in your iCloud or computer backups.

## Cloud voice

Some TestFlight testers can try a cloud voice for the DJ. This voice is made online, not on your device. It is off unless you turn it on. OnAirly asks you before any DJ line leaves your device. You have to accept the current notice; an older acceptance does not count.

What's sent: the text of every DJ line. That includes your personal items (calendar events, your shared email digest and other shared items, and notes), lines about songs from your music library, the station names you type, and the news and weather lines. Catalog song titles and artists can also be in those lines. OnAirly sends every line the DJ says to our voice server and on to ElevenLabs, which turns it into audio.

What's never sent to the voice server: your Apple ID, your contacts, or anything you haven't approved for your briefing. Only the words the DJ speaks are sent. Your coordinates and your location itself are never sent, but a local news line can name your city or area.

How it's stored: our server keeps a short technical log without the text. Model training is turned off for our ElevenLabs account, but ElevenLabs may keep the text and audio it receives under [its own privacy policy](https://elevenlabs.io/privacy-policy).

You can switch back to the on-device voice at any time in Settings. Turning the cloud voice off stops this from the next line and deletes the saved cloud clips. Cloud clips of library songs and station names are kept between launches, for up to 7 days, so the same words aren't sent again. "Delete DJ clips, ratings and location" deletes them, along with the cloud clips made from your calendar, notes and shared items.

## Local news and weather

If you allow approximate location, or type a city, OnAirly can mention local weather and, in TestFlight tester builds, local news.

For local news in those tester builds, OnAirly sends only the city or region name to the GDELT Project, so it can fetch headlines. Coordinates, ZIP codes and street addresses are not sent. If you type a ZIP code, it is turned into a city name on your device first; if that fails, nothing is sent. App Store builds do not include this news provider.

For local weather, a coarse coordinate is sent only to Apple WeatherKit. Apple handles that data under [Apple's Privacy Policy](https://www.apple.com/legal/privacy/).

## Apple Music

Playback, search, charts and your library go through Apple's MusicKit under your Apple ID. Apple handles that data under [Apple's Privacy Policy](https://www.apple.com/legal/privacy/). We don't receive your Apple ID.

## Data we collect

We use the data below only to run the features you turn on. We don't use it for tracking, advertising or analytics, and we don't sell it.

OnAirly has no account for you. Some of this can still identify you, because a request can include your calendar, a shared email digest or your notes, and song titles can travel in the same request.

- **City or region name.** In TestFlight tester builds, the city or region name sent to GDELT for local news, as described above. This is not linked to your name or account.
- **Shared email digest.** After you accept the cloud-voice notice, the text of a shared email digest that appears in a DJ line.
- **Other content you provide.** After you accept the cloud-voice notice, the text of DJ lines that use your calendar, notes, other shared items, library-track lines, typed station names, and news or weather lines. Every DJ line's text goes to ElevenLabs, which may keep the text and the audio it generates. Model training is turned off for our ElevenLabs account.
- **Device identifier.** In TestFlight builds that use cloud voice, an App Attest install ID and key ID, so our server can confirm the request comes from a genuine copy of OnAirly. These are not linked to your name or Apple ID. Our server does not keep the raw install ID with the script text.
- **Song titles and artists.** After you accept the cloud-voice notice, catalog song titles and artists that appear in a DJ line. These can travel in the same request as personal text.

We do not collect a separate name field, a recording of your voice, purchase records, precise location, a user ID, crash or advertising data, browsing history, health or financial data, or your contacts. A typed station name that happens to be a person's name is treated as other content you provide. MusicKit and WeatherKit are Apple services.

## Children

OnAirly is rated 13+.

## Your choices

You can deny or revoke calendar, Apple Music and location access in iOS Settings, stop using your calendar or Markdown notes in the app's Connections, delete shared items in the app, or turn off cloud voice in Settings. "Delete DJ clips, ratings and location" removes saved spoken clips, ratings and location data on your device. Deleting the app removes everything it stored on your device.

## Changes

We'll update this page, and the notice in the app, before we change anything about what leaves your device.

## Contact

Email [support@onairly.app](mailto:support@onairly.app). Replies come from onairly@agentmail.to. For help using the app, see [Support](/support).
