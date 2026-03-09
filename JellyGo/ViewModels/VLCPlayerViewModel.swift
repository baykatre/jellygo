import SwiftUI
import MobileVLCKit
import Combine
import MediaPlayer
import AVFoundation

extension Notification.Name {
    static let playbackStopped = Notification.Name("playbackStopped")
}

// MARK: - Delegate Bridge

private final class VLCDelegateBridge: NSObject, VLCMediaPlayerDelegate {
    var onStateChanged: ((VLCMediaPlayerState) -> Void)?
    var onPositionChanged: ((Float) -> Void)?

    func mediaPlayerStateChanged(_ notification: Notification) {
        guard let p = notification.object as? VLCMediaPlayer else { return }
        onStateChanged?(p.state)
    }
    func mediaPlayerTimeChanged(_ notification: Notification) {
        guard let p = notification.object as? VLCMediaPlayer else { return }
        onPositionChanged?(p.position)
    }
}

// MARK: - ViewModel

final class VLCPlayerViewModel: ObservableObject {
    let player = VLCMediaPlayer()

    @Published var isLoading = true
    @Published var isPlaying = false
    @Published var error: String?
    @Published var position: Float = 0
    @Published var selectedQuality: VideoQuality = .auto

    @Published var isLocal = false
    /// When true, VLC subtitle rendering is disabled at media load (JellyGo player manages its own).
    var disableVLCSubtitles = false
    @Published var statsBitrateMbps: Double = 0
    @Published var statsDecodedFrames: Int32 = 0
    @Published var statsDroppedFrames: Int32 = 0
    @Published var statsVideoCodec: String = "—"
    @Published var statsAudioCodec: String = "—"
    @Published var statsContainer: String = "—"
    @Published var statsIsTranscoding: Bool = false

    @Published var videoSize: CGSize = .zero
    @Published var subtitleTracks: [(index: Int32, name: String)] = []
    @Published var audioTracks: [(index: Int32, name: String)] = []
    @Published var currentSubtitleIndex: Int32 = -1
    @Published var currentAudioIndex: Int32 = -1

    private var item: JellyfinItem?
    private var appState: AppState?
    private var positionTimer: Task<Void, Never>?
    private let bridge = VLCDelegateBridge()
    private var resumeMs: Int32 = 0
    private var didSeekToResume = false
    private var lastPositionUpdate: CFTimeInterval = 0

    init() {
        player.delegate = bridge
        bridge.onStateChanged = { [weak self] state in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isPlaying = self.player.isPlaying
                if state == .playing {
                    self.loadTracks()
                    // Force-disable VLC subtitles once after tracks first load
                    if self.disableVLCSubtitles && self.tracksLoaded && !self.didDisableVLCSubs {
                        self.didDisableVLCSubs = true
                        self.player.currentVideoSubTitleIndex = -1
                    }
                    // Seek to resume position on first play if media option didn't work
                    if !self.didSeekToResume && self.resumeMs > 0 {
                        self.didSeekToResume = true
                        self.player.time = VLCTime(int: self.resumeMs)
                    }
                }
                if state == .error { self.error = String(localized: "Playback error", bundle: AppState.currentBundle) }
            }
        }
        bridge.onPositionChanged = { [weak self] pos in
            DispatchQueue.main.async {
                guard let self else { return }
                // Throttle @Published position updates to ~4 Hz to avoid excessive SwiftUI re-renders
                let now = CACurrentMediaTime()
                guard now - self.lastPositionUpdate >= 0.25 else { return }
                self.lastPositionUpdate = now
                self.position = pos
                // Stats — only update when values actually change
                if let media = self.player.media {
                    let s = media.statistics
                    let raw = s.inputBitrate > 0 ? s.inputBitrate : s.demuxBitrate
                    let newBitrate = Double(raw) * 8 / 1_000_000
                    if abs(self.statsBitrateMbps - newBitrate) > 0.01 { self.statsBitrateMbps = newBitrate }
                    if self.statsDroppedFrames != s.lostPictures { self.statsDroppedFrames = s.lostPictures }
                    if self.statsDecodedFrames != s.decodedVideo { self.statsDecodedFrames = s.decodedVideo }
                }
            }
        }
    }

    func loadLocal(url: URL, item: JellyfinItem, appState: AppState) async {
        self.appState = appState
        DispatchQueue.main.async { self.isLoading = true; self.error = nil; self.isLocal = true }

        let media = VLCMedia(url: url)
        applySubtitleAppearance(to: media)
        player.media = media
        if NetworkMonitor.shared.isConnected {
            await JellyfinAPI.shared.reportPlaybackStart(
                serverURL: appState.serverURL, itemId: item.id, token: appState.token)
        }
        player.play()

        // Add external subtitle files (.srt) saved next to the video
        // Skip when JellyGo player manages subtitles externally
        if !disableVLCSubtitles {
            let downloadsDir = DownloadManager.downloadsDirectory
            let prefix = "\(item.id)_"
            if let files = try? FileManager.default.contentsOfDirectory(atPath: downloadsDir.path) {
                for file in files where file.hasPrefix(prefix) && file.hasSuffix(".srt") {
                    let srtURL = downloadsDir.appendingPathComponent(file)
                    player.addPlaybackSlave(srtURL, type: .subtitle, enforce: false)
                }
            }
        }
        await waitForPlaying()

        // If runTimeTicks is missing (old downloads), read duration from the media file
        if item.runTimeTicks == nil || item.runTimeTicks == 0,
           let ms = player.media?.length, ms.intValue > 0 {
            let ticks = Int64(ms.intValue) * 10_000
            let patched = JellyfinItem(
                id: item.id, name: item.name, type: item.type,
                overview: item.overview, productionYear: item.productionYear,
                communityRating: item.communityRating, criticRating: item.criticRating,
                runTimeTicks: ticks,
                seriesName: item.seriesName, seriesId: item.seriesId,
                seasonName: item.seasonName, indexNumber: item.indexNumber,
                parentIndexNumber: item.parentIndexNumber,
                userData: item.userData, imageBlurHashes: item.imageBlurHashes,
                primaryImageAspectRatio: item.primaryImageAspectRatio,
                genres: item.genres, officialRating: item.officialRating,
                taglines: item.taglines, people: item.people,
                premiereDate: item.premiereDate, mediaStreams: item.mediaStreams,
                mediaSources: item.mediaSources, childCount: item.childCount,
                providerIds: item.providerIds,
                endDate: item.endDate, productionLocations: item.productionLocations
            )
            self.item = patched
        } else {
            self.item = item
        }

        // Seek to saved local position
        let savedSecs = LocalPlaybackStore.position(for: item.id)
        if savedSecs > 2 {
            resumeMs = Int32(savedSecs * 1000)
            player.time = VLCTime(int: resumeMs)
            didSeekToResume = true
        }

        DispatchQueue.main.async { self.isLoading = false; self.isPlaying = self.player.isPlaying }
        startPositionTimer()
    }

    func load(item: JellyfinItem, appState: AppState) async {
        self.item = item
        self.appState = appState
        DispatchQueue.main.async { self.isLoading = true; self.error = nil }

        guard !item.isSeries && !item.isSeason else {
            DispatchQueue.main.async { self.error = String(localized: "Select an episode to play", bundle: AppState.currentBundle); self.isLoading = false }
            return
        }

        let resumeTicks = item.userData?.playbackPositionTicks ?? 0
        let vlcSeekMs = Int32(resumeTicks / 10_000)
        await startPlayback(jellyfinStartTicks: resumeTicks, vlcSeekMs: vlcSeekMs)
    }

    private var pendingAudioStreamIndex: Int? = nil

    private func startPlayback(jellyfinStartTicks: Int64, vlcSeekMs: Int32) async {
        guard let item, let appState else { return }

        didSeekToResume = false

        // Direct mode: skip PlaybackInfo, stream the file as-is
        if selectedQuality.resolved.forceDirectPlay {
            guard let directURL = JellyfinAPI.shared.streamURL(
                serverURL: appState.serverURL,
                itemId: item.id,
                mediaSourceId: item.id,
                token: appState.token
            ) else {
                DispatchQueue.main.async { self.error = String(localized: "No playable source found", bundle: AppState.currentBundle); self.isLoading = false }
                return
            }
            DispatchQueue.main.async {
                self.statsVideoCodec = "—"
                self.statsAudioCodec = "—"
                self.statsContainer = "—"
                self.statsIsTranscoding = false
            }
            let media = VLCMedia(url: directURL)
            applySubtitleAppearance(to: media)
            if vlcSeekMs > 0 {
                resumeMs = vlcSeekMs
                media.addOption(":start-time=\(Double(vlcSeekMs) / 1000.0)")
            } else {
                resumeMs = 0
            }
            player.media = media
            if NetworkMonitor.shared.isConnected {
                await JellyfinAPI.shared.reportPlaybackStart(
                    serverURL: appState.serverURL, itemId: item.id, token: appState.token)
            }
            player.play()
            await waitForPlaying()
            DispatchQueue.main.async { self.isLoading = false; self.isPlaying = self.player.isPlaying }
            startPositionTimer()
            return
        }

        do {
            let audioIdx = pendingAudioStreamIndex
            pendingAudioStreamIndex = nil
            let info = try await JellyfinAPI.shared.getPlaybackInfo(
                serverURL: appState.serverURL,
                itemId: item.id,
                userId: appState.userId,
                token: appState.token,
                startTimeTicks: jellyfinStartTicks,
                maxBitrate: selectedQuality.resolved.maxBitrate,
                externalSubtitles: disableVLCSubtitles,
                audioStreamIndex: audioIdx
            )
            guard let source = info.mediaSources.first else {
                DispatchQueue.main.async { self.error = String(localized: "No playable source found", bundle: AppState.currentBundle); self.isLoading = false }
                return
            }

            let url: URL
            if let transcodePath = source.transcodingUrl,
               let transURL = URL(string: appState.serverURL + transcodePath) {
                url = transURL
            } else if let directURL = JellyfinAPI.shared.streamURL(
                serverURL: appState.serverURL,
                itemId: item.id,
                mediaSourceId: source.id,
                token: appState.token
            ) {
                url = directURL
            } else {
                DispatchQueue.main.async { self.error = String(localized: "No playable source found", bundle: AppState.currentBundle); self.isLoading = false }
                return
            }

            let streams = source.mediaStreams ?? []
            let videoStream = streams.first(where: { $0.isVideo })
            let audioStream = streams.first(where: { $0.isAudio })
            let isTranscoding = source.transcodingUrl != nil
            DispatchQueue.main.async {
                self.statsVideoCodec = videoStream?.codec?.uppercased() ?? "—"
                self.statsAudioCodec = audioStream?.codec?.uppercased() ?? "—"
                self.statsContainer = source.container?.uppercased() ?? "—"
                self.statsIsTranscoding = isTranscoding
            }

            let media = VLCMedia(url: url)
            applySubtitleAppearance(to: media)
            if vlcSeekMs > 0 && jellyfinStartTicks == 0 {
                resumeMs = vlcSeekMs
                media.addOption(":start-time=\(Double(vlcSeekMs) / 1000.0)")
            } else {
                resumeMs = 0
            }
            player.media = media
        } catch {
            DispatchQueue.main.async { self.error = error.localizedDescription; self.isLoading = false }
            return
        }

        if NetworkMonitor.shared.isConnected {
            await JellyfinAPI.shared.reportPlaybackStart(
                serverURL: appState.serverURL, itemId: item.id, token: appState.token)
        }

        player.play()
        await waitForPlaying()
        DispatchQueue.main.async { self.isLoading = false; self.isPlaying = self.player.isPlaying }
        startPositionTimer()
    }

    private func waitForPlaying() async {
        var waited = 0
        while !player.isPlaying && player.state != .error && waited < 15_000 {
            try? await Task.sleep(for: .milliseconds(200))
            waited += 200
        }
    }

    func changeQuality(to quality: VideoQuality) async {
        guard item != nil else { return }
        selectedQuality = quality

        let currentMs = Int32(max(0, player.time.intValue))

        positionTimer?.cancel()
        player.stop()
        player.media = nil
        tracksLoaded = false
        DispatchQueue.main.async { self.isLoading = true; self.isPlaying = false }

        try? await Task.sleep(for: .milliseconds(500))

        await startPlayback(jellyfinStartTicks: 0, vlcSeekMs: currentMs)
    }

    func togglePlayPause() {
        if player.isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    func seek(to pos: Float) {
        player.position = pos
        DispatchQueue.main.async { self.position = pos }
    }

    func skip(seconds: Int) {
        let currentMs = Int(player.time.intValue)
        let newMs = max(0, currentMs + seconds * 1000)
        player.time = VLCTime(int: Int32(newMs))
    }

    @Published var subtitleDelaySecs: Double = 0

    func setSubtitle(index: Int32) {
        currentSubtitleIndex = index
        Task.detached { [player] in
            player.currentVideoSubTitleIndex = index
        }
    }

    func setVLCSubtitleTrack(_ index: Int32) {
        Task.detached { [player] in
            player.currentVideoSubTitleIndex = index
        }
    }

    func adjustSubtitleDelay(by delta: Double) {
        setSubtitleDelay(subtitleDelaySecs + delta)
    }

    func setSubtitleDelay(_ secs: Double) {
        subtitleDelaySecs = max(-10, min(10, secs))
        let delayUs = Int(subtitleDelaySecs * 1_000_000)
        Task.detached { [player] in
            player.currentVideoSubTitleDelay = delayUs
        }
    }

    func setAudio(index: Int32) {
        currentAudioIndex = index
        if !statsIsTranscoding {
            Task.detached { [player] in
                player.currentAudioTrackIndex = index
            }
            return
        }
        Task {
            let currentMs = Int32(max(0, player.time.intValue))
            positionTimer?.cancel()
            player.stop()
            player.media = nil
            tracksLoaded = false
            DispatchQueue.main.async { self.isLoading = true; self.isPlaying = false }
            try? await Task.sleep(for: .milliseconds(500))
            pendingAudioStreamIndex = Int(index)
            await startPlayback(jellyfinStartTicks: 0, vlcSeekMs: currentMs)
        }
    }

    private var tracksLoaded = false
    private var didDisableVLCSubs = false

    private func loadTracks() {
        let size = player.videoSize
        if size.width > 0, size != videoSize { videoSize = size }

        guard !tracksLoaded else { return }

        let subIndexes = player.videoSubTitlesIndexes as? [NSNumber] ?? []
        let subNames   = player.videoSubTitlesNames   as? [String]   ?? []
        let subs = zip(subIndexes, subNames).map { (Int32($0.intValue), $1) }

        let audIndexes = player.audioTrackIndexes as? [NSNumber] ?? []
        let audNames   = player.audioTrackNames   as? [String]   ?? []
        let auds = zip(audIndexes, audNames).map { (Int32($0.intValue), $1) }

        if !subs.isEmpty || !auds.isEmpty {
            tracksLoaded = true
        }

        subtitleTracks = subs
        audioTracks = auds
        if !disableVLCSubtitles {
            currentSubtitleIndex = player.currentVideoSubTitleIndex
        }
        currentAudioIndex = player.currentAudioTrackIndex
    }

    func stop() {
        positionTimer?.cancel()
        player.stop()
        guard let item, let appState else { return }
        let ticks = Int64(Double(position) * Double(item.runTimeTicks ?? 0))

        if currentSeconds > 2 {
            LocalPlaybackStore.savePosition(currentSeconds, for: item.id)
        }

        Task {
            if NetworkMonitor.shared.isConnected {
                await JellyfinAPI.shared.reportPlaybackStopped(
                    serverURL: appState.serverURL, itemId: item.id,
                    positionTicks: ticks, token: appState.token)
            }
            await MainActor.run {
                NotificationCenter.default.post(name: .playbackStopped, object: nil)
            }
        }
    }

    private func startPositionTimer() {
        positionTimer?.cancel()
        positionTimer = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, let item, let appState else { continue }
                let ticks = Int64(Double(position) * Double(item.runTimeTicks ?? 0))
                guard ticks > 0 else { continue }
                let secs = Double(ticks) / 10_000_000
                if secs > 2 { LocalPlaybackStore.savePosition(secs, for: item.id) }
                if NetworkMonitor.shared.isConnected {
                    await JellyfinAPI.shared.reportPlaybackProgress(
                        serverURL: appState.serverURL, itemId: item.id,
                        positionTicks: ticks, isPaused: !isPlaying, token: appState.token)
                }
            }
        }
    }

    func applySubtitleAppearance(to media: VLCMedia) {
        guard let appState else { return }
        media.addOption("--file-caching=300")
        media.addOption("--network-caching=1500")
        if disableVLCSubtitles {
            media.addOption(":sub-track-id=-1")
            media.addOption("--no-sub-autodetect-file")
            return
        }
        media.addOption(":sub-text-renderer=freetype")
        media.addOption(":freetype-rel-fontsize=\(appState.subtitleFontSize)")
        media.addOption("--freetype-rel-fontsize=\(appState.subtitleFontSize)")
        if appState.subtitleBold {
            media.addOption(":freetype-bold=1")
            media.addOption("--freetype-bold=1")
        }
        let colorInt = appState.subtitleColor == "yellow" ? 0xFFFF00 : 0xFFFFFF
        media.addOption(":freetype-color=\(colorInt)")
        media.addOption("--freetype-color=\(colorInt)")
        if appState.subtitleBackgroundEnabled {
            media.addOption(":freetype-background-opacity=200")
            media.addOption("--freetype-background-opacity=200")
            media.addOption(":freetype-background-color=0")
        }
        media.addOption(":ass-override=2")
    }

    var currentSeconds: Double {
        guard let ticks = item?.runTimeTicks else { return 0 }
        return Double(position) * Double(ticks) / 10_000_000
    }
    var totalSeconds: Double {
        guard let ticks = item?.runTimeTicks else { return 0 }
        return Double(ticks) / 10_000_000
    }
    var itemTitle: String { item?.name ?? "" }
    var itemMeta: String {
        var parts: [String] = []
        if let year = item?.productionYear { parts.append("\(year)") }
        if let mins = item?.runtimeMinutes, mins > 0 { parts.append("\(mins) min") }
        return parts.joined(separator: " • ")
    }
}

// MARK: - Video Surface

struct VLCVideoSurface: UIViewRepresentable {
    let player: VLCMediaPlayer

    func makeUIView(context: Context) -> PassthroughView {
        let view = PassthroughView()
        view.backgroundColor = .black
        player.drawable = view
        return view
    }

    func updateUIView(_ uiView: PassthroughView, context: Context) {}
}

/// Passes all touches through to SwiftUI so gesture modifiers on the ZStack work correctly.
final class PassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}
