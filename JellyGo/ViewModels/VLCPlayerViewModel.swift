import SwiftUI
import MobileVLCKit
import Combine
import MediaPlayer
import AVFoundation

extension Notification.Name {
    static let playbackStopped = Notification.Name("playbackStopped")
    static let personFilmographySelected = Notification.Name("personFilmographySelected")
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
    @Published var selectedQuality: VideoQuality = .direct

    /// VLC audio volume boost (100 = normal, 200 = 2× boost).
    @Published var volumeBoost: Int32 = 100

    func setVolumeBoost(_ value: Int32) {
        let clamped = max(100, min(200, value))
        guard clamped != volumeBoost else { return }
        volumeBoost = clamped
        player.audio?.volume = clamped
    }

    /// VLC video brightness boost via gamma correction (1.0 = normal, 1.5 = max boost).
    /// Internally maps 1.0→1.5 to gamma 1.0→0.35 (lower gamma = brighter midtones, no white wash).
    @Published var brightnessBoost: Float = 1.0

    func setBrightnessBoost(_ value: Float) {
        let clamped = max(1.0, min(1.5, value))
        guard abs(clamped - brightnessBoost) > 0.001 else { return }
        brightnessBoost = clamped
        let isActive = clamped > 1.001
        player.adjustFilter.isEnabled = isActive
        if isActive {
            // Map boost 1.0→1.5 to gamma 1.0→3.0 (higher gamma = brighter in VLC)
            let t = (clamped - 1.0) / 0.5 // 0→1
            let gamma = 1.0 + t * 2.0      // 1.0→3.0
            player.adjustFilter.gamma.value = NSNumber(value: gamma)
        } else {
            player.adjustFilter.gamma.value = NSNumber(value: 1.0)
        }
    }

    @Published var isLocal = false
    /// When true, VLC subtitle rendering is disabled at media load (JellyGo player manages its own).
    var disableVLCSubtitles = false
    @Published var statsBitrateMbps: Double = 0
    @Published var statsDecodedFrames: Int32 = 0
    @Published var statsDroppedFrames: Int32 = 0
    @Published var statsVideoCodec: String = "—"
    @Published var statsVideoProfile: String = ""
    @Published var statsVideoResolution: String = ""
    @Published var statsVideoBitDepth: String = ""
    @Published var statsVideoRange: String = "SDR"
    @Published var statsAudioCodec: String = "—"
    @Published var statsAudioLabel: String = ""
    @Published var statsContainer: String = "—"
    @Published var statsIsTranscoding: Bool = false
    @Published var statsTranscodeReasons: [String] = []
    @Published var statsIsManualQuality: Bool = false
    @Published var statsReadBytes: Int = 0
    @Published var statsDisplayedPictures: Int32 = 0
    @Published var statsLostAudioBuffers: Int32 = 0
    @Published var statsDemuxBitrateMbps: Double = 0

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
                    // Seek to resume position on first play
                    if !self.didSeekToResume && self.resumeMs > 0 {
                        self.didSeekToResume = true
                        self.player.time = VLCTime(int: self.resumeMs)
                        // Wait until player time is near seek target before dismissing loading
                        Task {
                            let target = self.resumeMs
                            var waited = 0
                            while waited < 15000 {
                                try? await Task.sleep(for: .milliseconds(200))
                                waited += 200
                                let current = self.player.time.intValue
                                // Dismiss when player time is within 2s of target and actually advancing
                                if current > 0 && abs(current - target) < 2000 {
                                    break
                                }
                            }
                            try? await Task.sleep(for: .seconds(1))
                            await MainActor.run { self.isLoading = false }
                        }
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
                    // Network / input bitrate
                    let rawInput = Double(s.inputBitrate) * 8 / 1_000_000
                    if abs(self.statsBitrateMbps - rawInput) > 0.01 { self.statsBitrateMbps = rawInput }
                    // Demux bitrate (actual stream bitrate)
                    let rawDemux = Double(s.demuxBitrate) * 8 / 1_000_000
                    if abs(self.statsDemuxBitrateMbps - rawDemux) > 0.01 { self.statsDemuxBitrateMbps = rawDemux }
                    // Bytes read from network
                    let newRead = max(0, max(Int(s.readBytes), Int(s.demuxReadBytes)))
                    if self.statsReadBytes != newRead { self.statsReadBytes = newRead }
                    // Video frames
                    if self.statsDroppedFrames != s.lostPictures { self.statsDroppedFrames = s.lostPictures }
                    if self.statsDecodedFrames != s.decodedVideo { self.statsDecodedFrames = s.decodedVideo }
                    if self.statsDisplayedPictures != s.displayedPictures { self.statsDisplayedPictures = s.displayedPictures }
                    // Audio buffers lost
                    if self.statsLostAudioBuffers != s.lostAudioBuffers { self.statsLostAudioBuffers = s.lostAudioBuffers }
                }
            }
        }
    }

    func loadLocal(url: URL, item: JellyfinItem, appState: AppState) async {
        self.item = item
        self.appState = appState
        tracksLoaded = false
        didDisableVLCSubs = false
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

    func load(item: JellyfinItem, appState: AppState, qualityOverride: VideoQuality? = nil) async {
        self.item = item
        self.appState = appState
        selectedQuality = qualityOverride ?? appState.defaultVideoQuality
        tracksLoaded = false
        didDisableVLCSubs = false
        DispatchQueue.main.async { self.isLoading = true; self.error = nil; self.statsReadBytes = 0 }

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

        // Check for pure Dolby Vision before direct play — VLC renders pink
        let doviRange = item.mediaStreams?.first(where: { $0.isVideo })?.videoRangeType
            ?? item.mediaSources?.first?.mediaStreams?.first(where: { $0.isVideo })?.videoRangeType
        if doviRange == "DOVI" && selectedQuality.resolved.forceDirectPlay {
            // Override to use PlaybackInfo with forceTranscode instead of direct play
            // Fall through to PlaybackInfo path below
        }

        // Direct mode: skip PlaybackInfo, stream the file as-is
        if selectedQuality.resolved.forceDirectPlay && doviRange != "DOVI" {
            guard let directURL = JellyfinAPI.shared.streamURL(
                serverURL: appState.serverURL,
                itemId: item.id,
                mediaSourceId: item.id,
                token: appState.token
            ) else {
                DispatchQueue.main.async { self.error = String(localized: "No playable source found", bundle: AppState.currentBundle); self.isLoading = false }
                return
            }
            let dpVideo = item.mediaStreams?.first(where: \.isVideo)
            let dpAudio = item.mediaStreams?.first(where: \.isAudio)
            DispatchQueue.main.async {
                self.statsVideoCodec = dpVideo?.codec?.uppercased() ?? "—"
                self.statsVideoProfile = dpVideo?.profile ?? ""
                self.statsVideoResolution = "\(dpVideo?.width ?? 0)×\(dpVideo?.height ?? 0)"
                self.statsVideoBitDepth = dpVideo?.bitDepth.map { "\($0)-bit" } ?? ""
                self.statsVideoRange = dpVideo?.videoRangeType ?? dpVideo?.videoRange ?? "SDR"
                self.statsAudioCodec = dpAudio?.codec?.uppercased() ?? "—"
                self.statsAudioLabel = dpAudio?.audioLabel ?? dpAudio?.language ?? ""
                self.statsContainer = "—"
                self.statsIsTranscoding = false
                self.statsTranscodeReasons = []
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
            if disableVLCSubtitles { player.currentVideoSubTitleIndex = -1 }
            DispatchQueue.main.async {
                // Keep loading if resume seek is pending
                if self.resumeMs <= 0 { self.isLoading = false }
                self.isPlaying = self.player.isPlaying
            }
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
                audioStreamIndex: audioIdx,
                forceTranscode: doviRange == "DOVI"
            )
            guard let source = info.mediaSources.first else {
                DispatchQueue.main.async { self.error = String(localized: "No playable source found", bundle: AppState.currentBundle); self.isLoading = false }
                return
            }

            var url: URL
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

            // Get transcode reasons from source field or parse from URL
            var reasons = source.transcodeReasons ?? []
            if reasons.isEmpty, let transcodePath = source.transcodingUrl,
               let comps = URLComponents(string: transcodePath),
               let reasonParam = comps.queryItems?.first(where: { $0.name == "TranscodeReasons" })?.value {
                reasons = reasonParam.components(separatedBy: ",")
            }
            // Calculate displayed resolution
            var displayRes = "\(videoStream?.width ?? 0)×\(videoStream?.height ?? 0)"
            if isTranscoding {
                if let transcodePath = source.transcodingUrl,
                   let comps = URLComponents(string: transcodePath) {
                    let params = comps.queryItems ?? []
                    let maxW = params.first(where: { $0.name == "MaxWidth" })?.value.flatMap(Int.init)
                    let maxH = params.first(where: { $0.name == "MaxHeight" })?.value.flatMap(Int.init)
                    let srcW = videoStream?.width ?? 0
                    let srcH = videoStream?.height ?? 0
                    if let maxW, let maxH {
                        displayRes = "\(maxW)×\(maxH)"
                    } else if let maxW, srcW > 0, srcH > 0 {
                        let outW = min(maxW, srcW)
                        let outH = Int(Double(outW) * Double(srcH) / Double(srcW)) & ~1
                        displayRes = "\(outW)×\(outH)"
                    } else if let maxH, srcW > 0, srcH > 0 {
                        let outH = min(maxH, srcH)
                        let outW = Int(Double(outH) * Double(srcW) / Double(srcH)) & ~1
                        displayRes = "\(outW)×\(outH)"
                    } else {
                        displayRes = self.selectedQuality.resolved.rawValue
                    }
                }
            }
            let isManual = !self.selectedQuality.resolved.forceDirectPlay
            let vProfile = videoStream?.profile ?? ""
            let vBitDepth = videoStream?.bitDepth.map { "\($0)-bit" } ?? ""
            let vRange = videoStream?.videoRangeType ?? videoStream?.videoRange ?? "SDR"
            let aLabel = audioStream?.audioLabel ?? audioStream?.language ?? ""
            DispatchQueue.main.async {
                self.statsVideoCodec = videoStream?.codec?.uppercased() ?? "—"
                self.statsVideoProfile = vProfile
                self.statsVideoResolution = displayRes
                self.statsVideoBitDepth = vBitDepth
                self.statsVideoRange = vRange
                self.statsAudioCodec = audioStream?.codec?.uppercased() ?? "—"
                self.statsAudioLabel = aLabel
                self.statsContainer = source.container?.uppercased() ?? "—"
                self.statsIsTranscoding = isTranscoding
                self.statsTranscodeReasons = reasons
                self.statsIsManualQuality = isManual
            }

            let media = VLCMedia(url: url)
            applySubtitleAppearance(to: media)
            if disableVLCSubtitles {
                media.addOption(":sub-track-id=-1")
            }
            if vlcSeekMs > 0 {
                resumeMs = vlcSeekMs
                if !isTranscoding {
                    media.addOption(":start-time=\(Double(vlcSeekMs) / 1000.0)")
                }
                // Transcode: start-time doesn't work on HLS, resumeMs fallback will seek after playing
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

        if disableVLCSubtitles { player.currentVideoSubTitleIndex = -1 }
        player.play()
        await waitForPlaying()
        if disableVLCSubtitles { player.currentVideoSubTitleIndex = -1 }
        DispatchQueue.main.async {
            if self.resumeMs <= 0 { self.isLoading = false }
            self.isPlaying = self.player.isPlaying
        }
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
        didDisableVLCSubs = false
        DispatchQueue.main.async { self.isLoading = true; self.isPlaying = false }

        try? await Task.sleep(for: .milliseconds(500))

        let startTicks = Int64(currentMs) * 10_000
        await startPlayback(jellyfinStartTicks: startTicks, vlcSeekMs: currentMs)
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
            let startTicks = Int64(currentMs) * 10_000
            await startPlayback(jellyfinStartTicks: startTicks, vlcSeekMs: currentMs)
        }
    }

    private var tracksLoaded = false
    var didDisableVLCSubs = false

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
        if disableVLCSubtitles {
            player.currentVideoSubTitleIndex = -1
        } else {
            currentSubtitleIndex = player.currentVideoSubTitleIndex
        }
        currentAudioIndex = player.currentAudioTrackIndex
    }

    func stop() {
        positionTimer?.cancel()
        player.stop()
        guard let item, let appState else { return }

        let ticks: Int64
        if isLoading && resumeMs > 0 {
            // Closed during loading before seek completed — report the original resume position
            ticks = Int64(resumeMs) * 10_000
        } else {
            ticks = Int64(Double(position) * Double(item.runTimeTicks ?? 0))
        }

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
