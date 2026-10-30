# OnAirly Privacy Policy (DRAFT)

> **Draft for the owner. Do not publish until every [owner] and [PENDING] marker is resolved.**
> Before publishing, strip this whole header and every bracketed marker from the page.
> Sources: #174 `docs/privacy/disclosure-copy.md` and `data-flows.md`, and #245 `app-store-privacy-label-v1.md`.
> The facts are re-checked against the release build before publishing. Sections marked
> [PENDING: paid voice] depend on the owner's ElevenLabs decisions (#245 §6) and must not go live
> in their current form until those decisions are made.
>
> Anything that isn't in the app yet (the cloud-voice switch and its "Use cloud voice" button, the age
> question, cancelling queued cloud clips, the device check with 90-day key deletion and the one-way
> network code, purchases) stays inside a [PENDING] block and must not appear on the live page until
> it ships. The Phonon download is marked [PENDING: Phonon]: AeroDJPhonon isn't embedded in current
> builds (ITMS-90755) and needs iOS 18.
> Never mention the legacy web app or Telegram here.

_Last updated: [owner: date]_

## The short version

OnAirly: Personal AI Radio DJ is a radio DJ that runs on your iPhone or iPad, with iOS 17 or iPadOS 17 or later and an Apple Music subscription. Your calendar, Markdown notes, the things you share to OnAirly, your music library and your station settings are read and kept on your device only. There are no ads, no analytics, no tracking and no data brokers in OnAirly, and we don't sell or share your data.

Apart from Apple Music itself, nothing leaves your device.

[PENDING: Phonon and paid voice. Replace the sentence above only when these ship:] There are only two cases where anything leaves your device, apart from Apple Music itself:

1. A one-time download of the on-device voice model, which sends no personal information. [PENDING: Phonon]
2. The optional cloud voice, which is off until you turn it on. [PENDING: paid voice]

## What stays on your device

- **Calendar.** If you allow it, OnAirly reads events from the calendars you pick so the DJ can mention them. Events are never sent anywhere. Spoken clips that use them expire after 7 days and are deleted when you remove access.
- **Markdown notes and shared items.** Markdown notes (.md files you pick), and text or links you share to OnAirly, stay on your device. For each note, OnAirly keeps only a link to the file and its name, and reads the text when it's needed; the note's text isn't saved. Shared items are deleted after 7 days, or right away when you delete them. Spoken clips made from a note or a shared item expire after 7 days, and are deleted when you stop using the note or delete the item.
- **Your music library and stations.** Library playlists, songs and artists you use as station seeds, and the names you give your stations, stay on your device.
- **On-device voices.** The built-in voices speak entirely on your device.
- **Spoken clips.** So the DJ doesn't have to make the same clip twice, OnAirly saves the audio of what it says on your device, protected by iOS Data Protection. Only the audio is saved, not the written text. A clip is never played once it's 7 days old, and it's deleted the next time OnAirly runs (the app checks when it starts and every hour while it's open). Clips made from your calendar, Markdown notes or shared items are also deleted each time OnAirly starts, and right away when you stop using that source or delete the item. Like other app data, saved clips can be included in your iCloud or computer backups.

Personal items, such as calendar events, Markdown notes, shared items, library tracks and the station names you type, are never sent off your device. [PENDING: paid voice, add when it ships:] This holds even when the cloud voice is on.

## Apple Music

Playback, search, charts and your library go through Apple's MusicKit under your Apple ID. Apple handles that data under [Apple's Privacy Policy](https://www.apple.com/legal/privacy/). We don't receive your Apple ID.

## Voice model download [PENDING: Phonon]

Not in current builds; publish only if the Phonon voice ships (it needs iOS 18 or iPadOS 18). To use the on-device "Phonon" voice, OnAirly downloads a voice model file once, over Wi-Fi, from GitHub. The download sends no personal information. As with any download, GitHub can see your device's IP address.

## Cloud voice (optional, off by default) [PENDING: paid voice]

Before any text leaves your device, OnAirly asks you. Until you tap "Use cloud voice", every voice stays on your device.

If you turn it on, the words of each DJ break are sent over an encrypted connection to our voice server, which runs on Vercel. The server passes them on to ElevenLabs, which turns them into audio. Those words are made up of fixed DJ phrasing, the app's name, and the Apple Music catalog song titles and artist names of what you're listening to. Stations built from your own music library always use the on-device voice. Audio that comes back from the cloud voice is saved on your device like any other spoken clip, with the same 7-day limit.

- **What we don't send:** your name, Apple ID, contacts, location, calendar, notes, shared items, library tracks or the station names you type.
- **Our server's log:** it records a random request ID, the result and the number of characters. It doesn't log the text.
- **Hosting logs:** Vercel keeps standard request logs, which include IP address and app identifier. These logs are kept for up to 30 days. [owner: confirm the number against the Vercel plan; it depends on the plan. Say whether IP address is used for rate limiting.]
- **Usage counters:** daily usage counts, with no text, kept for up to 2 days. No DJ text is stored on our server.
- **ElevenLabs:** ElevenLabs processes the text and audio under its [privacy policy](https://elevenlabs.io/privacy-policy). By default, ElevenLabs keeps a history of requests. [owner: retention, Zero Retention Mode, and whether model training is opted out. Include "We have opted out of ElevenLabs using this data to train its models" only if that is true.]
- **Device check:** [PENDING: #256 and enabling App Attest. Not built yet; keep off the live page.] When it's enabled, our server keeps a key for your install, which it uses to confirm requests come from a genuine copy of OnAirly and to stop abuse. The key is deleted after 90 days without use and is never stored with the spoken text. To limit sign-ups from one network, the server also keeps a one-way code made from your IP address and the date. That code can't be turned back into your IP address, is never stored with your key or the spoken text, and expires within 2 days.
- **Turning it off:** [PENDING: paid voice. The switch and clip cancelling aren't built yet.] You can turn the cloud voice off at any time in Settings. Nothing more is sent after that, and any queued cloud clips are cancelled.

## Purchases [PENDING: paid voice]

Payments are handled by Apple through the App Store; we never see your payment details. [owner, pending the IAP and PR 6 design: describe what our server keeps to check a purchase, such as a transaction ID and its status, how long it's kept, and that it isn't linked to the spoken text.]

## Data we collect

OnAirly doesn't collect any data.

[PENDING: paid voice. When the cloud voice ships, replace the sentence above with these two lines:]
- **With the cloud voice off:** none. OnAirly doesn't collect any data.
- **With the cloud voice on:** song and artist names of what you're playing (usage data, not linked to you), used only to generate the voice. [PENDING: paid voice, label per #245 §3. Add a device identifier if the device check stores one.]

## Children

OnAirly is rated 13+.

[PENDING: paid voice and the age gate. The age question isn't built yet.] The cloud voice is for listeners 18 and older, because ElevenLabs' services aren't directed at people under 18. OnAirly asks you to confirm your age before turning it on, and if you're under 18 every voice stays on your device.

## Your choices

You can deny or revoke calendar and Apple Music access in iOS Settings, stop using your calendar or Markdown notes in the app's Connections, delete shared items in the app, or delete the app, which removes everything it stored on your device.

[PENDING: paid voice] You can also turn the cloud voice off. [owner: how to ask us or ElevenLabs to delete server-side data.]

## Changes

We'll update this page, and the notice in the app, before we change anything about what leaves your device.

## Contact

Email [support@onairly.app](mailto:support@onairly.app). Replies come from onairly@agentmail.to. [owner: postal address, if required.] For help using the app, see [Support](/support).
