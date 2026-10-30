# Held copy: paid voice, ElevenLabs, Pro and IAP (not published)

This file is NOT under `site/`, so it is never served, and `site/render-copy.py` and `site/check.sh` don't read it.
It holds, verbatim from `docs/site/privacy.md` and `docs/site/support.md` as of integration/device-duo 8537934,
every block stripped when onairly.app went live on October 30, 2026 (paid voice, ElevenLabs, Pro and IAP don't ship in v1).
Restore the relevant parts, with their markers resolved, when Pro ships. The Phonon (on-device voice download) blocks were
stripped at the same time and are held at the end.

## Replacement hosting-logs bullet (restore in place of the original "Hosting logs" bullet when Pro ships)

- **Hosting logs:** Vercel keeps standard request logs, which include IP address and app identifier, for up to 30 days. Our voice server uses your network address only to limit how many times a device can register each day; it stores just a scrambled, day-specific code that can't be turned back into your address, and deletes it after 2 days.

## From privacy.md

### Editorial header (lines 1-15)

```
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
```

### The short version (lines 25-28)

```
[PENDING: Phonon and paid voice. Replace the sentence above only when these ship:] There are only two cases where anything leaves your device, apart from Apple Music itself:

1. A one-time download of the on-device voice model, which sends no personal information. [PENDING: Phonon]
2. The optional cloud voice, which is off until you turn it on. [PENDING: paid voice]
```

### What stays on your device (line 38)

```
Personal items, such as calendar events, Markdown notes, shared items, library tracks and the station names you type, are never sent off your device. [PENDING: paid voice, add when it ships:] This holds even when the cloud voice is on.
```

### Cloud voice and Purchases sections (lines 48-64)

```
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
```

### Data we collect (lines 70-72)

```
[PENDING: paid voice. When the cloud voice ships, replace the sentence above with these two lines:]
- **With the cloud voice off:** none. OnAirly doesn't collect any data.
- **With the cloud voice on:** song and artist names of what you're playing (usage data, not linked to you), used only to generate the voice. [PENDING: paid voice, label per #245 §3. Add a device identifier if the device check stores one.]
```

### Children (line 78)

```
[PENDING: paid voice and the age gate. The age question isn't built yet.] The cloud voice is for listeners 18 and older, because ElevenLabs' services aren't directed at people under 18. OnAirly asks you to confirm your age before turning it on, and if you're under 18 every voice stays on your device.
```

### Your choices (line 84)

```
[PENDING: paid voice] You can also turn the cloud voice off. [owner: how to ask us or ElevenLabs to delete server-side data.]
```

### Contact (line 92, original)

```
Email [support@onairly.app](mailto:support@onairly.app). Replies come from onairly@agentmail.to. [owner: postal address, if required.] For help using the app, see [Support](/support).
```

## From support.md

### Editorial header (lines 1-7)

```
# OnAirly Support (DRAFT)

> **Draft for the owner. Do not publish until the [owner] markers are resolved.** Before publishing,
> strip this whole header and every bracketed marker from the page. Paid-voice
> answers are marked [PENDING: paid voice] until the owner's ElevenLabs decisions are made (#245 §6),
> and the Phonon answer is marked [PENDING: Phonon] (not embedded in current builds). Nothing in a
> [PENDING] block goes on the live page until it ships. Don't link /terms until Pro ships.
```

### Contact us (line 13, original)

```
Email [support@onairly.app](mailto:support@onairly.app). Replies come from onairly@agentmail.to, so please look for that address (and check your spam folder). We aim to reply within [owner: e.g. 2 business days]. Please include your iPhone or iPad model, iOS or iPadOS version and OnAirly version. To find the OnAirly version, open iOS Settings, go to General, then iPhone Storage (or iPad Storage), and tap OnAirly. [PENDING: app name. Current builds still list the app under its old name there.] Never send us your Apple ID password or payment details.
```

### Common questions (lines 20-36, original)

```
**The DJ isn't talking.**
Check that DJ talk isn't set to Off for the station and that your device isn't muted. [PENDING: paid voice] If the cloud voice isn't available, OnAirly falls back to the on-device voice. [PENDING: Phonon] The Phonon voice needs a one-time download over Wi-Fi.

**Why does OnAirly want my calendar?**
So the DJ can mention what's coming up in your day. It's optional, the events stay on your device, and you can turn access off in iOS Settings at any time.

**What leaves my device?**
Nothing personal. Your calendar, Markdown notes and shared items stay on your device. See our [Privacy Policy](/privacy) for the full details. [PENDING: paid voice] With the cloud voice on, only song and artist names and fixed DJ phrasing are sent to make the voice.

**How do I turn the cloud voice off?** [PENDING: paid voice. The switch isn't built yet.]
Go to Settings, then Voice, and switch the cloud voice off. Nothing more is sent after that.

**Subscriptions and refunds** [PENDING: paid voice]
Purchases are handled by Apple. To cancel, use iOS Settings, then your name, then Subscriptions. To ask for a refund, go to [reportaproblem.apple.com](https://reportaproblem.apple.com). [owner: confirm product names and what happens to Pro voice after a refund.]

**How do I delete my data?**
Delete shared items in the app, stop using your calendar or Markdown notes in Connections, or delete OnAirly to remove everything it stored on your device. [owner, pending paid voice: how to ask for server-side deletion.]
```

## Phonon (held, not paid voice)

### privacy.md Voice model download (lines 44-46)

```
## Voice model download [PENDING: Phonon]

Not in current builds; publish only if the Phonon voice ships (it needs iOS 18 or iPadOS 18). To use the on-device "Phonon" voice, OnAirly downloads a voice model file once, over Wi-Fi, from GitHub. The download sends no personal information. As with any download, GitHub can see your device's IP address.
```
