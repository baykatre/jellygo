# JellyGo Privacy Policy

**Effective:** July 30, 2026
**App version:** 1.0.0
**Applies to:** iOS

## The short version

JellyGo is a client for **your own** Jellyfin media server. It talks to that server and to nothing else that identifies you. We — the developer — don't run any servers that see your library, your watch history, or your credentials. There's no analytics, no ad tracking, and nothing to sell, because we never receive the data in the first place.

## 1. What JellyGo connects to

JellyGo is a native player for [Jellyfin](https://jellyfin.org/), an open-source media server that you — or someone you trust — host and control. Everything the app shows you comes from two places:

- **Your Jellyfin server.** The address you enter, your login, and every request for a poster, a video stream, or a "mark as watched" action goes directly from your device to that server over the network you configure. We have no server in the middle and no copy of any of it.
- **The Movie Database (TMDb).** The server-selection screen shows a handful of trending posters fetched anonymously from TMDb's public API, purely for visual decoration before you're signed in. These requests don't include your name, your server address, or any other identifying information.

## 2. What we don't collect

JellyGo has no account system of its own and no backend. As the developer, we do not receive, store, or have access to:

- Your Jellyfin username, password, or access tokens
- What you watch, search for, or download
- Your server's address or network location
- Analytics, crash reports, or usage statistics
- Advertising identifiers — JellyGo shows no ads and does no tracking

## 3. What's stored on your device

Everything JellyGo needs to work day-to-day stays local to your device, inside the app's own sandboxed storage:

| Data | Where | Why |
|---|---|---|
| Login token | iOS Keychain | So you stay signed in without re-entering your password |
| Posters & artwork | App cache | Faster browsing; cleared automatically or via Settings |
| Downloaded videos & subtitles | App storage | Offline playback you explicitly requested |
| App preferences | On-device settings | Remembers things like playback quality and app language |

None of this leaves your device except when it's sent to your own Jellyfin server as part of normal use (for example, reporting playback progress so "Continue Watching" works). Deleting the app removes all of it.

## 4. In-app purchases

JellyGo Pro is a one-time purchase handled entirely by Apple through StoreKit. Your payment details go to Apple, not to us — we only receive confirmation that an entitlement was purchased, so Pro features stay unlocked.

## 5. Third-party libraries

Playback is powered by open-source engines (KSPlayer/FFmpeg and MobileVLCKit) that run entirely on your device to decode and render video. They don't communicate with anyone on their own — all network activity still flows only to your configured Jellyfin server.

## 6. Children's privacy

JellyGo isn't directed at children and doesn't knowingly collect information from anyone, of any age — there's simply no collection mechanism to speak of. Content shown in the app depends entirely on what's available on the Jellyfin server you connect to, which is under your own control.

## 7. Changes to this policy

If this policy changes, the updated version will be posted at this same address with a new effective date. Material changes will also be noted in the App Store release notes.

## Contact

Questions about this policy or the app? Reach out at [support@anilozturk.com.tr](mailto:support@anilozturk.com.tr) or open an issue on [GitHub](https://github.com/baykatre/jellygo).
