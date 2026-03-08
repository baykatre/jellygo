import AVKit
import SwiftUI
import Combine
import MediaPlayer

extension Notification.Name {
    static let playbackStopped = Notification.Name("jellygo.playbackStopped")
}

@MainActor
final class PlayerViewModel: ObservableObject {
    @Published var player: AVPlayer?
    @Published var isLoading = true
    @Published var error: String?
    @Published var subtitleStreams: [JellyfinMediaStream] = []
    @Published var audioStreams: [JellyfinMediaStream] = []
    @Published var selectedSubtitleIndex: Int? = nil   // nil = off

    private var item: JellyfinItem?
    private var appState: AppState?
    private var mediaSource: JellyfinMediaSource?
    private var mediaSourceId: String?
    private var progressTimer: Task<Void, Never>?
    private var lastReportedTicks: Int64 = 0

    func load(item: JellyfinItem, appState: AppState) async {
        self.item = item
        self.appState = appState

        // Series items have no media source — must play an episode
        guard !item.isSeries && !item.isSeason else {
            error = "Select an episode to play"
            isLoading = false
            return
        }

        isLoading = true
        error = nil

        do {
            let resumeTicks = item.userData?.playbackPositionTicks ?? 0

            // Pass startTimeTicks so Jellyfin generates the transcoding URL
            // starting from the resume position — avoids the StartTimeTicks-in-segment bug
            let info = try await JellyfinAPI.shared.getPlaybackInfo(
                serverURL: appState.serverURL,
                itemId: item.id,
                userId: appState.userId,
                token: appState.token,
                startTimeTicks: resumeTicks
            )

            guard let source = info.mediaSources.first else {
                error = "No playable source found"
                isLoading = false
                return
            }

            mediaSourceId = source.id
            mediaSource = source

            // Collect available streams for UI
            subtitleStreams = source.mediaStreams?.filter { $0.isSubtitle } ?? []
            audioStreams = source.mediaStreams?.filter { $0.isAudio } ?? []

            // Auto-select default or first subtitle
            let defaultSub = subtitleStreams.first(where: { $0.isDefault == true })
                ?? subtitleStreams.first
            selectedSubtitleIndex = defaultSub?.index

            let (streamURL, isHLS) = resolveStreamURL(
                source: source,
                item: item,
                appState: appState,
                subtitleIndex: selectedSubtitleIndex
            )

            let playerItem = buildPlayerItem(url: streamURL, source: source, item: item, appState: appState)
            let avPlayer = AVPlayer(playerItem: playerItem)

            player = avPlayer
            isLoading = false

            await JellyfinAPI.shared.reportPlaybackStart(
                serverURL: appState.serverURL,
                itemId: item.id,
                token: appState.token
            )

            startProgressReporting()
            avPlayer.play()

            // Seek to resume position for both HLS and direct play.
            // Called after play() so AVPlayer has started loading the playlist/file.
            // Generous tolerance allows HLS to snap to the nearest segment boundary quickly.
            if resumeTicks > 0 {
                let secs = Double(resumeTicks) / 10_000_000
                let target = CMTime(seconds: secs, preferredTimescale: 600)
                let tolerance = CMTime(seconds: 5, preferredTimescale: 1)
                Task {
                    await avPlayer.seek(to: target, toleranceBefore: tolerance, toleranceAfter: tolerance)
                }
            }

        } catch let err as JellyfinAPIError {
            error = err.errorDescription
            isLoading = false
        } catch {
            self.error = error.localizedDescription
            isLoading = false
        }
    }

    private func resolveStreamURL(source: JellyfinMediaSource, item: JellyfinItem, appState: AppState, subtitleIndex: Int?) -> (url: URL, isHLS: Bool) {
        if var transcodingPath = source.transcodingUrl {
            // startTimeTicks already embedded by PlaybackInfo — do NOT add it here
            // (Jellyfin rejects StartTimeTicks in segment requests)
            if let idx = subtitleIndex, !transcodingPath.contains("SubtitleStreamIndex") {
                transcodingPath += "&SubtitleStreamIndex=\(idx)&SubtitleMethod=Hls"
            } else if subtitleIndex == nil, !transcodingPath.contains("SubtitleStreamIndex") {
                transcodingPath += "&SubtitleStreamIndex=-1"
            }
            if let url = URL(string: appState.serverURL + transcodingPath) {
                return (url, true)
            }
        }
        // Direct play — AVPlayer seeks to resume position after load
        let url = JellyfinAPI.shared.streamURL(
            serverURL: appState.serverURL,
            itemId: item.id,
            mediaSourceId: source.id,
            token: appState.token
        ) ?? URL(string: appState.serverURL)!
        return (url, false)
    }

    func selectSubtitle(index: Int?) async {
        guard let item, let appState, let source = mediaSource else { return }
        selectedSubtitleIndex = index
        let currentTime = player?.currentTime()
        player?.pause()

        let (newURL, _) = resolveStreamURL(source: source, item: item, appState: appState, subtitleIndex: index)
        let playerItem = AVPlayerItem(url: newURL)
        player?.replaceCurrentItem(with: playerItem)

        if let time = currentTime, time.seconds > 0 {
            await player?.seek(to: time)
        }
        player?.play()
    }

    private func buildPlayerItem(url: URL, source: JellyfinMediaSource, item: JellyfinItem, appState: AppState) -> AVPlayerItem {
        let asset = AVURLAsset(url: url)
        let playerItem = AVPlayerItem(asset: asset)

        var metadata: [AVMetadataItem] = []

        // Build display strings
        let (overlayTitle, nowPlayingTitle, nowPlayingArtist) = playerTitles(for: item)

        metadata.append(metadataItem(.commonIdentifierTitle, value: overlayTitle))
        playerItem.externalMetadata = metadata
        setNowPlayingInfo(item: item, title: nowPlayingTitle, artist: nowPlayingArtist)

        return playerItem
    }

    /// Returns (overlayTitle, nowPlayingTitle, nowPlayingArtist)
    private func playerTitles(for item: JellyfinItem) -> (String, String, String) {
        if item.isEpisode {
            let s = item.parentIndexNumber.map { "S\($0)" } ?? ""
            let e = item.indexNumber.map { "E\($0)" } ?? ""
            let epCode = s + e  // e.g. "S1E3"
            let seriesName = item.seriesName ?? item.name
            // Overlay (single line): "Series Name  S1E3 — Episode Title"
            let overlay = epCode.isEmpty
                ? seriesName
                : "\(seriesName)  \(epCode) — \(item.name)"
            // Lock screen: title = episode name, artist = "Series S1E3"
            let artist = epCode.isEmpty ? seriesName : "\(seriesName)  \(epCode)"
            return (overlay, item.name, artist)
        } else {
            let year = item.productionYear.map { " (\($0))" } ?? ""
            return (item.name + year, item.name, "")
        }
    }

    private func metadataItem(_ identifier: AVMetadataIdentifier, value: String) -> AVMetadataItem {
        let mi = AVMutableMetadataItem()
        mi.identifier = identifier
        mi.value = value as NSString
        mi.extendedLanguageTag = "und"
        return mi
    }

    private func setNowPlayingInfo(item: JellyfinItem, title: String, artist: String) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyMediaType: MPMediaType.movie.rawValue
        ]
        if !artist.isEmpty {
            info[MPMediaItemPropertyArtist] = artist
        }
        if let ticks = item.runTimeTicks {
            info[MPMediaItemPropertyPlaybackDuration] = Double(ticks) / 10_000_000
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func startProgressReporting() {
        progressTimer?.cancel()
        progressTimer = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { break }
                await reportProgress(isPaused: false)
            }
        }
    }

    private func reportProgress(isPaused: Bool) async {
        guard let player, let item, let appState else { return }
        let seconds = player.currentTime().seconds
        guard seconds > 0 else { return }
        let ticks = Int64(seconds * 10_000_000)
        lastReportedTicks = ticks
        await JellyfinAPI.shared.reportPlaybackProgress(
            serverURL: appState.serverURL,
            itemId: item.id,
            positionTicks: ticks,
            isPaused: isPaused,
            token: appState.token
        )
    }

    func stop() {
        progressTimer?.cancel()
        progressTimer = nil
        player?.pause()

        // Only report if we actually started playing (player was created successfully)
        guard let item, let appState, player != nil,
              !item.isSeries, !item.isSeason else { return }

        let rawSeconds = player?.currentTime().seconds ?? 0
        let seconds = rawSeconds.isFinite && rawSeconds > 0 ? rawSeconds : 0
        let ticks = seconds > 0 ? Int64(seconds * 10_000_000) : lastReportedTicks

        Task {
            await JellyfinAPI.shared.reportPlaybackStopped(
                serverURL: appState.serverURL,
                itemId: item.id,
                positionTicks: ticks,
                token: appState.token
            )
            // Notify listeners (e.g. HomeView) to refresh continue-watching data
            await MainActor.run {
                NotificationCenter.default.post(name: .playbackStopped, object: nil)
            }
        }
    }
}
