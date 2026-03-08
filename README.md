# JellyGo 🎬

![iOS](https://img.shields.io/badge/iOS-26.0+-blue.svg)
![Swift](https://img.shields.io/badge/Swift-6-F05138.svg)
![Jellyfin](https://img.shields.io/badge/Jellyfin-10.8.0+-8A2BE2.svg)
![License](https://img.shields.io/badge/License-MIT-green.svg)

**JellyGo** is a fast, modern, and fully native iOS client for [Jellyfin](https://jellyfin.org/) media servers. Built from the ground up with SwiftUI, it provides a seamless way to browse and play your self-hosted media library on the go.

## ✨ Features

- **Hero Browse:** Full-screen hero banner with featured content, Continue Watching, Next Up, Latest Movies & Shows sections on the home screen.
- **Detail Pages:** Backdrop, logo, metadata chips, genres, ratings, cast & crew, season/episode browser with resume highlighting.
- **Dual Player Engine:** Switch between the native AVFoundation player and an in-app VLC player (MobileVLCKit) from Profile settings.
- **Native Player:** AVKit-based playback with subtitle/audio track selection, skip controls, and progress reporting.
- **VLC Player:** MobileVLCKit-powered player with pinch-to-zoom (capped at screen-fill scale), double-tap punch zoom, subtitle/audio track picker, and forced landscape orientation.
- **Resume Playback:** Picks up exactly where you left off — both on the detail page and inside the player.
- **Playback Reporting:** Reports start, progress (every 10 s), and stop events to the Jellyfin server.
- **Search:** Full-text search across your entire library.
- **Library Browser:** Browse all Jellyfin libraries with grid layout; Favorites card at top with a random cover from your favorite items.
- **Favorites & Watched:** Toggle favorite and watched state directly from the detail page.
- **Apple Liquid Glass UI:** Detail page action buttons use iOS 26 native `glassEffect` with Capsule shape.
- **Secure Auth:** Token-based login with Keychain storage; session restores automatically on launch.
- **Multi-Account:** Switch between multiple Jellyfin servers/accounts; tokens shared across URL variants of the same server.
- **Localization:** English and Turkish string tables included.

### Offline Downloads

- **Background Downloads:** Download movies and episodes for offline viewing via URLSession background sessions.
- **Quality Selection:** Choose Direct (original file) or transcoded quality (1080p / 720p / 480p / 360p) per download.
- **Stable Queue:** Active, paused, and queued downloads maintain stable ordering in the Downloads tab.
- **Pause & Resume:** Downloads can be paused mid-way and resumed from the exact byte offset.
- **Kill Recovery:** Downloads in progress when the app is killed are automatically recovered on next launch.
- **Subtitle Downloads:** Text-based subtitle tracks (SRT) are automatically downloaded alongside the video. Image-based codecs (PGS, VobSub) are filtered out. Subtitles load automatically during offline VLC playback.
- **Download Detail Sheet:** From a downloaded item's detail page, view all downloaded episodes per series, see file sizes, and delete individual episodes.
- **Auto-dismiss:** The download detail sheet closes automatically when the last episode is deleted.
- **In-App Banner:** A banner notification appears when a download starts; tap it to open the item's detail page directly.
- **Progress Popover:** Tap the download button on an actively downloading item to see a live progress popover with pause and cancel controls.

## 📱 Screenshots

| Home | Media Details | Player |
| :---: | :---: | :---: |
| <img src="docs/assets/home.png" width="250" alt="Home Screen"/> | <img src="docs/assets/detail.png" width="250" alt="Detail Screen"/> | <img src="docs/assets/player.png" width="250" alt="Player Screen"/> |

## 🛠️ Tech Stack

| Layer | Technology |
|---|---|
| Language | Swift 6 |
| UI Framework | SwiftUI |
| Native Player | AVFoundation / AVKit |
| VLC Player | MobileVLCKit 3.7.3 (XCFramework) |
| Networking | URLSession + async/await |
| Background Downloads | URLSession background session + URLSessionDownloadDelegate |
| Auth Storage | Keychain |
| State Management | ObservableObject / @EnvironmentObject |
| Dependency Manager | Manual XCFramework (MobileVLCKit) |

## 🚀 Getting Started

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

3. The MobileVLCKit XCFramework is included in the repo under `MobileVLCKit-binary/`. It is already linked in the project — no additional setup needed.

4. Select your target device/simulator and hit **Run**.

### Player Engine

Go to **Profile → Player** and choose between:
- **Original** — native AVFoundation/AVKit player
- **VLC** — in-app MobileVLCKit player (useful for formats AVFoundation doesn't support)
