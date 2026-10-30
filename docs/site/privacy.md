# OnAirly Privacy Policy (DRAFT)

> **Draft for the owner. Do not publish until every [owner] and [PENDING] marker is resolved.**
> Sources: #174 `docs/privacy/disclosure-copy.md` and `data-flows.md`, and #245 `app-store-privacy-label-v1.md`.
> The facts are re-checked against the release build before publishing. Sections marked
> [PENDING: paid voice] depend on the owner's ElevenLabs decisions (#245 §6) and must not go live
> in their current form until those decisions are made.
> Never mention the legacy web app or Telegram here; `ray-do` is a separate product that is still being locked down.

_Last updated: [owner: date]_

## The short version

OnAirly is a radio DJ that runs on your iPhone. Your calendar, notes, the things you share to OnAirly, your music library and your station settings are read and kept on your device only. There are no ads, no analytics, no tracking and no data brokers in OnAirly, and we don't sell or share your data.

There are only two cases where anything leaves your phone, apart from Apple Music itself:

1. A one-time download of the on-device voice model, which sends no personal information.
2. The optional cloud voice, which is off until you turn it on. [PENDING: paid voice]

## What stays on your iPhone

- **Calendar.** If you allow it, OnAirly reads events from the calendars you pick so the DJ can mention them. Events are never sent anywhere. Spoken clips that use them are kept for at most 7 days and are deleted when you remove access.
- **Notes and shared items.** Notes files you choose, and text or links you share to OnAirly, stay on your device. Shared items are deleted after 7 days, or right away when you delete them.
- **Your music library and stations.** Library playlists, songs and artists you use as station seeds, and the names you give your stations, stay on your device.
- **On-device voices.** The built-in voices speak entirely on your iPhone.

Personal items, such as calendar events, notes, shared items, library tracks and the station names you type, are never sent off your device, even when the cloud voice is on.

## Apple Music

Playback, search, charts and your library go through Apple's MusicKit under your Apple ID. Apple handles that data under [Apple's Privacy Policy](https://www.apple.com/legal/privacy/). We don't receive your Apple ID.

## Voice model download

To use the on-device "Phonon" voice, OnAirly downloads a voice model file once, over Wi-Fi, from GitHub. The download sends no personal information. As with any download, GitHub can see your device's IP address.

## Cloud voice (optional, off by default) [PENDING: paid voice]

Before any text leaves your phone, OnAirly asks you. Until you tap "Use cloud voice", every voice stays on your device.

If you turn it on, the words of each DJ break are sent over an encrypted connection to our voice server, which runs on Vercel. The server passes them on to ElevenLabs, which turns them into audio. Those words are made up of fixed DJ phrasing, the app's name, and the Apple Music catalog song titles and artist names of what you're listening to. Stations built from your own music library always use the on-device voice.

- **What we don't send:** your name, Apple ID, contacts, location, calendar, notes, shared items, library tracks or the station names you type.
- **Our server's log:** it records a random request ID, the result and the number of characters. It doesn't log the text.
- **Hosting logs:** Vercel keeps standard request logs, which include IP address and app identifier. These logs are kept for up to 30 days. [owner: say whether IP address is used for rate limiting.]
- **Usage counters:** daily usage counts, with no text, reset every day. No DJ text is stored on our server.
- **ElevenLabs:** ElevenLabs processes the text and audio under its [privacy policy](https://elevenlabs.io/privacy-policy). By default, ElevenLabs keeps a history of requests. [owner: retention, Zero Retention Mode, and whether model training is opted out. Include "We have opted out of ElevenLabs using this data to train its models" only if that is true.]
- **Device check:** when it's enabled, our server keeps a key for your install, which it uses to confirm requests come from a genuine copy of OnAirly and to stop abuse. The key is deleted after 90 days without use and is never stored with the spoken text. To limit sign-ups from one network, the server also keeps a one-way code made from your IP address and the date. That code can't be turned back into your IP address, is never stored with your key or the spoken text, and expires within 2 days. [PENDING: #256 and enabling App Attest]
- **Turning it off:** you can turn the cloud voice off at any time in Settings. Nothing more is sent after that, and any queued cloud clips are cancelled.

## Purchases [PENDING: paid voice]

Payments are handled by Apple through the App Store; we never see your payment details. [owner, pending the IAP and PR 6 design: describe what our server keeps to check a purchase, such as a transaction ID and its status, how long it's kept, and that it isn't linked to the spoken text.]

## Data we collect

- **With the cloud voice off:** none. OnAirly doesn't collect any data.
- **With the cloud voice on:** song and artist names of what you're playing (usage data, not linked to you), used only to generate the voice. [PENDING: paid voice, label per #245 §3. Add a device identifier if the device check stores one.]

## Children

OnAirly is rated 13+. The cloud voice is for listeners 18 and older, because ElevenLabs' services aren't directed at people under 18. OnAirly asks you to confirm your age before turning it on, and if you're under 18 every voice stays on your device. [PENDING: paid voice and the age gate]

## Your choices

You can deny or revoke calendar and Apple Music access in iOS Settings, delete shared items in the app, turn the cloud voice off, or delete the app, which removes everything it stored on your device. [owner, pending paid voice: how to ask us or ElevenLabs to delete server-side data.]

## Changes

We'll update this page, and the notice in the app, before we change anything about what leaves your device.

## Contact

Email [support@onairly.app](mailto:support@onairly.app). [owner: postal address, if required.] For help using the app, see [Support](/support).
