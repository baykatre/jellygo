<p align="center">
  <img src="docs/assets/icon.png" width="128" alt="JellyGo Icon" />
</p>

<h1 align="center">JellyGo</h1>

<p align="center">
  <img src="https://img.shields.io/badge/iOS-26.0+-blue.svg" alt="iOS" />
  <img src="https://img.shields.io/badge/Swift-5-F05138.svg" alt="Swift" />
  <img src="https://img.shields.io/badge/Jellyfin-10.8.0+-8A2BE2.svg" alt="Jellyfin" />
  <img src="https://img.shields.io/badge/License-GPLv3-blue.svg" alt="License" />
</p>

**JellyGo** is a fast, modern, and fully native iOS client for [Jellyfin](https://jellyfin.org/) media servers. Built from the ground up with SwiftUI, it provides a seamless way to browse and play your self-hosted media library on the go.

## Features

- **Hero Browse:** Full-screen hero banner with featured content, Continue Watching, Next Up, Latest Movies & Shows sections on the home screen.
- **Explore Tab:** Discover top-rated movies & series, favorites, and genre-based sections — preloaded in the background for instant access.
- **Detail Pages:** Backdrop with parallax, logo, metadata chips, genres, ratings (TMDb & critic), cast & crew, season/episode browser with resume highlighting.
- **Resume Playback:** Picks up exactly where you left off — both on the detail page and inside the player.
- **Playback Reporting:** Reports start, progress (every 10 s), and stop events to the Jellyfin server.
- **Search:** Full-text search across your entire library.
- **Library Browser:** Browse all Jellyfin libraries with grid layout; Favorites card at top with a random cover from your favorite items.
- **Favorites & Watched:** Toggle favorite and watched state directly from the detail page.
- **Person Detail:** Tap any cast or crew member to see their filmography.
- **Apple Liquid Glass UI:** Action buttons and player indicators use iOS 26 native `glassEffect`.
- **Secure Auth:** Token-based login with Keychain storage; session restores automatically on launch.
- **QuickConnect:** Log in via QuickConnect code or authorize other devices from Settings.
- **Multi-Account & Quick Switch:** Seamlessly switch between multiple Jellyfin servers and accounts without re-authenticating. Tokens are shared across URL variants of the same server (e.g. local IP vs domain), so you never get logged out when your network changes.
- **Smart Connectivity:** Automatic server validation with parallel fallback — if the current server is unreachable, JellyGo tries all saved servers before going offline.
- **Localization:** 18 languages — English, Turkish, Arabic, Azerbaijani, Danish, German, Spanish, Persian, French, Italian, Japanese, Korean, Dutch, Portuguese, Russian, Swedish, Ukrainian, Chinese.

### Player

JellyGo features a custom native player with two selectable engines:

#### KSPlayer (Recommended)

The default player engine with a hybrid architecture for optimal performance:

- **Hybrid Playback:** Apple AVPlayer for native formats (MP4/TS/HLS) with automatic FFmpeg fallback for unsupported containers (MKV, WebM).
- **VideoToolbox Hardware Decode:** Near-zero CPU usage on supported codecs (H.264, HEVC, VP9, AV1).
- **Metal Renderer:** Direct GPU rendering — eliminates frame timing jank on 4K content.
- **HDR & Dolby Vision:** Native HDR passthrough when using AVPlayer path.
- **PiP & AirPlay Ready:** Native Picture-in-Picture and AirPlay support via AVPlayer.
- **Smart Buffer:** 10-minute forward buffer on AVPlayer path; buffer position shown on the progress bar.
- **Instant Audio Switch:** Audio track changes apply immediately with buffer flush — no delay.
- **Performance HUD:** Real-time CPU usage, FPS, thermal state, decoder info (VideoToolbox HW / FFmpeg SW), codec details, and network quality.

#### VLC

Alternative engine powered by MobileVLCKit:

- **Broad Codec Support:** Plays virtually any format without transcoding.
- **VideoToolbox Decode:** Hardware acceleration detected and reported at runtime via log sniffing.
- **Native Gamma Boost:** Built-in brightness/gamma adjustment via VLC's adjust filter.
- **Proven Stability:** Battle-tested VLC core with extensive format compatibility.

#### Shared Player Features

- Pinch-to-zoom with aspect-fill toggle
- Brightness/volume swipe gestures with glass indicator
- Subtitle/audio track picker with alphabetical sorting
- SDH subtitle avoidance — prefers regular subtitles over SDH/HI tracks
- Transcode quality switching (Direct / 1080p / 720p / 480p)
- Subtitle delay adjustment
- Playback speed control
- Double-tap skip (10s back / 30s forward)
- Long-press 2x speed
- Dolby Vision content automatically transcoded (both engines)
- Burned-in subtitle prevention on transcode streams

### Offline & Downloads

- **Offline Mode:** Dedicated offline view with hero banner, continue watching, next up, and dynamic content sections — all from local cache.
- **Background Downloads:** Download movies and episodes for offline viewing via URLSession background sessions.
- **Quality Selection:** Choose Direct (original file) or transcoded quality (1080p / 720p / 480p / 360p) per download.
- **Audio Language Selection:** When downloading with transcode, choose which audio language to include.
- **Subtitle Downloads:** Text-based subtitle tracks (SRT) are automatically downloaded alongside the video. Auto-repair downloads missing subtitles when viewing online.
- **Stable Queue:** Active, paused, and queued downloads maintain stable ordering in the Downloads tab.
- **Pause & Resume:** Downloads can be paused mid-way and resumed from the exact byte offset.
- **Kill Recovery:** Downloads in progress when the app is killed are automatically recovered on next launch.
- **In-App Banner:** A banner notification appears when a download starts; tap it to open the item's detail page directly.
- **Progress Popover:** Tap the download button on an actively downloading item to see a live progress popover with pause and cancel controls.

## Screenshots

| Home | Media Details | Player |
| :---: | :---: | :---: |
| <img src="docs/assets/home.png" width="250" alt="Home Screen"/> | <img src="docs/assets/detail.png" width="250" alt="Detail Screen"/> | <img src="docs/assets/player.png" width="250" alt="Player Screen"/> |

## Tech Stack

| Layer | Technology |
|---|---|
| Language | Swift 5 |
| UI Framework | SwiftUI |
| Player Engine (Default) | [KSPlayer](https://github.com/kingslay/KSPlayer) 2.x — AVPlayer + FFmpeg hybrid, Metal renderer |
| Player Engine (Alt) | [MobileVLCKit](https://code.videolan.org/videolan/VLCKit) 3.x — VLC core, VideoToolbox HW decode |
| Networking | URLSession + async/await |
| Background Downloads | URLSession background session + URLSessionDownloadDelegate |
| Auth Storage | Keychain |
| State Management | ObservableObject / @EnvironmentObject |

## Getting Started

### Prerequisites

- **macOS** with Xcode 16 or later
- **iOS Device or Simulator** running iOS 26.0+
- A running **Jellyfin Server** (v10.8.0 or newer)

### Installation

1. Clone the repository:
   ```bash
   git clone https://github.com/baykatre/jellygo.git
   cd jellygo/JellyGo
   ```

2. Open `JellyGo.xcodeproj` in Xcode.

3. **KSPlayer** is added as a Swift Package dependency and resolves automatically.

4. The **MobileVLCKit** XCFramework is included locally under `MobileVLCKit-binary/`. Download it from the [MobileVLCKit releases](https://code.videolan.org/videolan/VLCKit/-/releases) and place it there.

5. Select your target device/simulator and hit **Run**.

### Quick Switch Setup

If you access your Jellyfin server from different URLs (e.g. `192.168.1.100:8096` at home and `jellyfin.example.com` outside), add both URLs to the same account:

1. Go to **Settings > Accounts**.
2. Log in with your first server URL.
3. Tap **Add Server** and log in with the second URL using the same credentials.
4. JellyGo automatically shares your session token across both URLs, so switching networks never logs you out.

## License

This project is licensed under the **GNU General Public License v3.0** — see the [LICENSE](LICENSE) file for details.

### Third-Party Licenses

| Component | License |
|---|---|
| [KSPlayer](https://github.com/kingslay/KSPlayer) | GPLv3 |
| [FFmpegKit](https://github.com/kingslay/FFmpegKit) (KSPlayer dependency) | LGPLv3 |
| [MobileVLCKit](https://code.videolan.org/videolan/VLCKit) | LGPLv2.1+ |
