# Disclosure copy: DRAFT

> **Status: draft wording for the owner and Nova (UI).** Nothing here ships until the owner approves it, and the factual claims are re-checked against the code at release time. Items marked **[owner]** need an owner decision. Items marked **unverified** are not yet confirmed.

## 1. In-app disclosure before any third-party voice is used

**When it appears:** the first time the listener picks a voice that runs off the device, **before** any DJ text is sent. Picking the voice is not consent; tapping "Use cloud voice" is. It appears again if this text changes materially. Until the listener accepts, every voice stays on the device. Declining keeps the on-device voice and changes nothing else.

**Where it lives afterward:** Settings → Voice → "Cloud voice" toggle. Turning it off stops sending immediately and cancels any queued cloud renders.

### Sheet copy

> **Use a cloud voice?**
>
> This voice is generated online, not on your iPhone. To speak each DJ break, AeroDJ sends the words of that break to our voice server, and on to **ElevenLabs**, which turns them into audio.
>
> **What's sent:** only the text the DJ is about to say, such as song and artist names, your station's name, and time-of-day lines. [If personal briefings are enabled for cloud voices: "and the lines you approved in your briefing, such as a calendar event title".] **[owner]**
>
> **What's never sent:** your Apple ID, your contacts, your location, your music library when a station is built from your library (those stations always use the on-device voice), or anything you haven't approved for your briefing.
>
> **How it's stored:** our server keeps a short technical log without the text. ElevenLabs may keep the text and audio under its own privacy policy **[owner: training opt-out status and retention, see the label doc's questions 2-3]**.
>
> You can switch back to the on-device voice at any time in Settings.
>
> [Use cloud voice]   [Keep on-device voice]
>
> Privacy Policy · ElevenLabs Privacy Policy

Notes for implementation (Sentinel):
- The sheet is a gate, not a banner. Until the listener accepts, `PremiumVoiceRoutes.compose` must omit the route (a new `OmitReason`, e.g. `noConsent`). Store consent with a version number so a copy change can ask again.
- The "never sent" claims hold only after `data-flows.md` 3.1 and 3.2 are fixed. Do not ship this copy before that.
- Link to <https://elevenlabs.io/privacy-policy> (fetched 2026-10-29, "Updated 9 October 2026").

### Short footer (voice picker row, below the voice name)

> Cloud voice: the DJ's words are sent to ElevenLabs to make audio. On-device voices never leave your iPhone.

## 2. Privacy-policy section draft

> **AeroDJ and your data**
>
> AeroDJ is designed to work on your iPhone. Your calendar, notes, items you share to AeroDJ, your music library and your station settings are read and stored only on your device. We do not run analytics, advertising or tracking in the app, and we do not sell or share your data.
>
> **Apple Music.** Playback, search and your library are handled by Apple through MusicKit under your Apple ID. Apple's privacy policy applies to that data.
>
> **Voice model download.** To use the on-device "Phonon" voice, AeroDJ downloads a voice model file once, over Wi-Fi, from GitHub. No personal information is sent. As with any download, GitHub can see your device's IP address.
>
> **Cloud voices (optional, off by default).** If you turn on a cloud voice, the text of each DJ break is sent over an encrypted connection to our voice server (hosted by Vercel) and then to ElevenLabs, which generates the audio. We send only the text to be spoken. We do not send your name, Apple ID or location. Stations built from your music library always use the on-device voice.
> - Our voice server logs a random request ID, the result, and the number of characters. It does not log the text. Our hosting provider, Vercel, keeps standard request logs (which include IP address and browser or app identifier) for **[owner: 1 hour / 1 day / 30 days, depending on plan]**.
> - ElevenLabs processes the text and audio under its privacy policy (elevenlabs.io/privacy-policy). **[owner: "We have opted out of ElevenLabs using this data to train its models." Only if true.]** ElevenLabs may retain request history **[owner: confirm retention]**.
> - Turn cloud voices off at any time in Settings → Voice. Nothing is sent after that.
>
> **Children.** **[owner: age rating; ElevenLabs minimum age is unverified.]**
>
> **Contact.** **[owner: contact email and postal address.]**
>
> **Changes.** We will update this page and the in-app notice before any change to what leaves your device.

Do not publish any sentence that mentions the legacy web app or Telegram until the owner decides on `ray-do` (`data-flows.md` §4 and §6 item 5).
