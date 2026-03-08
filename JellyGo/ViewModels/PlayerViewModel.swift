import AVKit
import SwiftUI
import Combine

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
            error = "Oynatmak için bir bölüm seçin"
            isLoading = false
            return
        }

        isLoading = true
        error = nil

        do {
            let info = try await JellyfinAPI.shared.getPlaybackInfo(
                serverURL: appState.serverURL,
                itemId: item.id,
                userId: appState.userId,
                token: appState.token
            )

            guard let source = info.mediaSources.first else {
                error = "Oynatılabilir kaynak bulunamadı"
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

            // For direct play only: seek via HTTP Range (HLS starts from StartTimeTicks already)
            if !isHLS, let resumeTicks = item.userData?.playbackPositionTicks, resumeTicks > 0 {
                let seconds = Double(resumeTicks) / 10_000_000
                await avPlayer.seek(to: CMTime(seconds: seconds, preferredTimescale: 1))
            }

            player = avPlayer
            isLoading = false

            await JellyfinAPI.shared.reportPlaybackStart(
                serverURL: appState.serverURL,
                itemId: item.id,
                token: appState.token
            )

            startProgressReporting()
            avPlayer.play()

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
            // Start transcoding from resume position — avoids waiting for Jellyfin
            // to encode from 0:00 before reaching the seek point
            if let ticks = item.userData?.playbackPositionTicks, ticks > 0,
               !transcodingPath.contains("StartTimeTicks") {
                transcodingPath += "&StartTimeTicks=\(ticks)"
            }
            // Subtitle embedding
            if let idx = subtitleIndex, !transcodingPath.contains("SubtitleStreamIndex") {
                transcodingPath += "&SubtitleStreamIndex=\(idx)&SubtitleMethod=Hls"
            } else if subtitleIndex == nil, !transcodingPath.contains("SubtitleStreamIndex") {
                transcodingPath += "&SubtitleStreamIndex=-1"
            }
            if let url = URL(string: appState.serverURL + transcodingPath) {
                return (url, true)
            }
        }
        // Direct play — AVPlayer will seek via HTTP Range requests
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

        guard let streams = source.mediaStreams else { return playerItem }

        // Add external WebVTT subtitles as external metadata
        let subtitleStreams = streams.filter { $0.isSubtitle && $0.isExternal == true }
        var externalMetadata: [AVMetadataItem] = []

        for sub in subtitleStreams {
            guard let vttURL = JellyfinAPI.shared.subtitleURL(
                serverURL: appState.serverURL,
                itemId: item.id,
                mediaSourceId: source.id,
                subtitleIndex: sub.index,
                format: "vtt"
            ) else { continue }

            let titleItem = AVMutableMetadataItem()
            titleItem.identifier = .commonIdentifierTitle
            titleItem.value = (sub.displayTitle ?? sub.language ?? "Subtitle") as NSString
            titleItem.extendedLanguageTag = sub.language ?? "und"

            let localeItem = AVMutableMetadataItem()
            localeItem.identifier = .commonIdentifierLanguage
            localeItem.value = (sub.language ?? "und") as NSString

            _ = vttURL // used in stream construction above
            externalMetadata.append(titleItem)
        }

        if !externalMetadata.isEmpty {
            playerItem.externalMetadata = externalMetadata
        }

        return playerItem
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

        let seconds = player?.currentTime().seconds ?? 0
        let ticks = seconds > 0 ? Int64(seconds * 10_000_000) : lastReportedTicks

        Task {
            await JellyfinAPI.shared.reportPlaybackStopped(
                serverURL: appState.serverURL,
                itemId: item.id,
                positionTicks: ticks,
                token: appState.token
            )
        }
    }
}
