import SwiftUI
import Combine
import MediaPlayer
import AVFoundation
import Darwin.Mach

extension Notification.Name {
    static let playbackStopped = Notification.Name("playbackStopped")
    static let personFilmographySelected = Notification.Name("personFilmographySelected")
}

// MARK: - ViewModel

final class PlayerViewModel: ObservableObject, PlayerEngineDelegate {
    private var engine: PlayerEngineBackend

    @Published var isLoading = true
    @Published var isPlaying = false
    @Published var error: String?
    @Published var position: Float = 0
    @Published var selectedQuality: VideoQuality = .direct
    @Published var playbackSpeed: Float = 1.0

    func setPlaybackSpeed(_ speed: Float) {
        playbackSpeed = speed
        engine.setRate(speed)
    }

    /// Audio volume boost (100 = normal, 200 = 2× boost).
    @Published var volumeBoost: Int32 = 100

    func setVolumeBoost(_ value: Int32) {
        let clamped = max(100, min(200, value))
        guard clamped != volumeBoost else { return }
        volumeBoost = clamped
        engine.setVolume(clamped)
    }

    /// Video brightness boost via gamma correction (1.0 = normal, 1.5 = max boost).
    @Published var brightnessBoost: Float = 1.0

    func setBrightnessBoost(_ value: Float) {
        let clamped = max(1.0, min(1.5, value))
        guard abs(clamped - brightnessBoost) > 0.001 else { return }
        brightnessBoost = clamped
        engine.setBrightnessBoost(clamped)
    }

    @Published var isLocal = false
    /// When true, engine subtitle rendering is disabled at media load (JellyGo player manages its own).
    var disableEngineSubtitlesFlag = false
    @Published var statsBitrateMbps: Double = 0
    @Published var statsDecodedFrames: Int32 = 0
    @Published var statsDroppedFrames: Int32 = 0
    @Published var statsVideoCodec: String = "\u{2014}"
    @Published var statsVideoProfile: String = ""
    @Published var statsVideoResolution: String = ""
    @Published var statsVideoBitDepth: String = ""
    @Published var statsVideoRange: String = "SDR"
    @Published var statsAudioCodec: String = "\u{2014}"
    @Published var statsAudioLabel: String = ""
    @Published var statsContainer: String = "\u{2014}"
    @Published var statsIsTranscoding: Bool = false
    @Published var statsTranscodeReasons: [String] = []
    @Published var statsIsManualQuality: Bool = false
    @Published var statsReadBytes: Int = 0
    @Published var statsDisplayedPictures: Int32 = 0
    @Published var statsLostAudioBuffers: Int32 = 0
    @Published var statsDemuxBitrateMbps: Double = 0

    /// Engine info for HUD display (e.g. "VLC · MobileVLCKit" or "KSPlayer · KSMEPlayer · FFmpeg HW")
    @Published var statsEngineLabel: String = ""
    @Published var statsCpuUsage: Double = 0       // process CPU % (0–100+)
    @Published var statsFps: Double = 0            // render FPS
    @Published var statsThermal: String = "Nominal" // thermal state label
    @Published var bufferedPosition: Double = 0    // 0–1 how far buffer extends

    @Published var videoSize: CGSize = .zero
    @Published var subtitleTracks: [(index: Int32, name: String)] = []
    @Published var audioTracks: [(index: Int32, name: String)] = []
    @Published var currentSubtitleIndex: Int32 = -1
    @Published var currentAudioIndex: Int32 = -1

    private var item: JellyfinItem?
    private var appState: AppState?
    private var positionTimer: Task<Void, Never>?
    private var metricsTimer: Task<Void, Never>?
    private var resumeMs: Int32 = 0
    private var didSeekToResume = false
    private var lastPositionUpdate: CFTimeInterval = 0
    /// For KSPlayer transcode: HLS stream starts from this offset (ms).
    /// KSPlayer reports time relative to stream start, we add this to get real video time.
    private var transcodeOffsetMs: Int32 = 0

    init() {
        // Select engine based on user preference
        let pref = PlayerEngine(rawValue: UserDefaults.standard.string(forKey: "jellygo.playerEngine") ?? "") ?? .ksplayer
        switch pref {
        case .vlc:
            engine = VLCEngine()
            statsEngineLabel = "VLC \u{00B7} MobileVLCKit"
        case .ksplayer:
            engine = KSEngine()
            statsEngineLabel = "KSPlayer \u{00B7} init"
        }
        engine.delegate = self
    }

    // MARK: - PlayerEngineDelegate

    func engineStateChanged(isPlaying: Bool, isBuffering: Bool, error: String?) {
        self.isPlaying = isPlaying
        if let error { self.error = error }

        if isPlaying {
            // Seek to resume position on first play
            if !didSeekToResume && resumeMs > 0 {
                didSeekToResume = true
                engine.seekTime(ms: resumeMs)
                Task {
                    let target = resumeMs
                    var waited = 0
                    while waited < engine.resumeSeekTimeoutMs {
                        try? await Task.sleep(for: .milliseconds(200))
                        waited += 200
                        let current = engine.currentTimeMs
                        if current > 0 && abs(current - target) < 2000 {
                            break
                        }
                    }
                    let settle = engine.resumeSeekSettleDelay
                    if settle > 0 { try? await Task.sleep(for: .seconds(settle)) }
                    await MainActor.run { self.isLoading = false }
                }
            }
        }
    }

    func enginePositionChanged(position: Float, currentMs: Int32, durationMs: Int32) {
        let now = CACurrentMediaTime()
        guard now - lastPositionUpdate >= 0.25 else { return }
        lastPositionUpdate = now

        self.position = position
    }

    func engineTracksUpdated(subtitles: [(Int32, String)], audio: [(Int32, String)]) {
        subtitleTracks = subtitles
        audioTracks = audio
        if disableEngineSubtitlesFlag {
            engine.setSubtitleTrack(-1)
        } else {
            currentSubtitleIndex = engine.currentSubtitleTrackIndex
        }
        currentAudioIndex = engine.currentAudioTrackIndex
    }

    func engineVideoSizeChanged(_ size: CGSize) {
        if size.width > 0, size != videoSize { videoSize = size }
    }

    func engineStatsUpdated(_ stats: EngineStats) {
        if abs(statsBitrateMbps - stats.inputBitrateMbps) > 0.01 { statsBitrateMbps = stats.inputBitrateMbps }
        if abs(statsDemuxBitrateMbps - stats.demuxBitrateMbps) > 0.01 { statsDemuxBitrateMbps = stats.demuxBitrateMbps }
        if statsReadBytes != stats.readBytes { statsReadBytes = stats.readBytes }
        if statsDroppedFrames != stats.droppedFrames { statsDroppedFrames = stats.droppedFrames }
        if statsDecodedFrames != stats.decodedFrames { statsDecodedFrames = stats.decodedFrames }
        if statsDisplayedPictures != stats.displayedPictures { statsDisplayedPictures = stats.displayedPictures }
        if statsLostAudioBuffers != stats.lostAudioBuffers { statsLostAudioBuffers = stats.lostAudioBuffers }
        if abs(statsFps - stats.fps) > 0.5 { statsFps = stats.fps }
        // Buffer position: playableTime is absolute (seconds into video the buffer reaches)
        if stats.bufferedSeconds > 0, let ticks = item?.runTimeTicks, ticks > 0 {
            let totalSecs = Double(ticks) / 10_000_000
            let bufPos = min(1, stats.bufferedSeconds / totalSecs)
            if abs(bufferedPosition - bufPos) > 0.005 { bufferedPosition = bufPos }
        }
    }

    func engineInfoUpdated(_ label: String) {
        if statsEngineLabel != label { statsEngineLabel = label }
    }

    // MARK: - Video Surface

    /// True if engine doesn't handle brightness internally — view should apply visual modifier.
    var needsViewBrightnessBoost: Bool { !engine.handlesBrightnessBoost }

    @MainActor func makeVideoSurface() -> AnyView {
        engine.makeVideoSurface()
    }

    // MARK: - Disable Engine Subtitles

    func disableEngineSubtitles() {
        disableEngineSubtitlesFlag = true
        engine.disableEngineSubtitles()
    }

    // MARK: - Load Local

    func loadLocal(url: URL, item: JellyfinItem, appState: AppState) async {
        self.item = item
        self.appState = appState
        DispatchQueue.main.async { self.isLoading = true; self.error = nil; self.isLocal = true }

        engine.play(url: url, startTimeMs: 0, options: [
            "appState": appState,
            "disableSubs": disableEngineSubtitlesFlag,
            "useStartTime": false
        ])

        if NetworkMonitor.shared.isConnected {
            await JellyfinAPI.shared.reportPlaybackStart(
                serverURL: appState.serverURL, itemId: item.id, token: appState.token)
        }

        // Add external subtitle files (.srt) saved next to the video
        if !disableEngineSubtitlesFlag {
            let downloadsDir = DownloadManager.downloadsDirectory
            let prefix = "\(item.id)_"
            if let files = try? FileManager.default.contentsOfDirectory(atPath: downloadsDir.path) {
                for file in files where file.hasPrefix(prefix) && file.hasSuffix(".srt") {
                    let srtURL = downloadsDir.appendingPathComponent(file)
                    engine.addExternalSubtitle(url: srtURL)
                }
            }
        }

        await waitForPlaying()
        if playbackSpeed != 1.0 { engine.setRate(playbackSpeed) }

        // If runTimeTicks is missing (old downloads), read duration from the media file
        if item.runTimeTicks == nil || item.runTimeTicks == 0 {
            let ms = engine.duration
            if ms > 0 {
                let ticks = Int64(ms) * 10_000
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
            }
        } else {
            self.item = item
        }

        // Seek to saved local position
        let savedSecs = LocalPlaybackStore.position(for: item.id)
        if savedSecs > 2 {
            resumeMs = Int32(savedSecs * 1000)
            engine.seekTime(ms: resumeMs)
            didSeekToResume = true
        }

        DispatchQueue.main.async { self.isLoading = false; self.isPlaying = self.engine.isPlaying }
        startPositionTimer()
        startMetricsTimer()
    }

    // MARK: - Load Streaming

    func load(item: JellyfinItem, appState: AppState, qualityOverride: VideoQuality? = nil) async {
        self.item = item
        self.appState = appState
        selectedQuality = qualityOverride ?? appState.defaultVideoQuality
        DispatchQueue.main.async { self.isLoading = true; self.error = nil; self.statsReadBytes = 0 }

        guard !item.isSeries && !item.isSeason else {
            DispatchQueue.main.async { self.error = String(localized: "Select an episode to play", bundle: AppState.currentBundle); self.isLoading = false }
            return
        }

        let resumeTicks = item.userData?.playbackPositionTicks ?? 0
        let seekMs = Int32(resumeTicks / 10_000)
        await startPlayback(jellyfinStartTicks: resumeTicks, seekMs: seekMs)
    }

    private var pendingAudioStreamIndex: Int? = nil

    private func startPlayback(jellyfinStartTicks: Int64, seekMs: Int32) async {
        guard let item, let appState else { return }

        didSeekToResume = false
        transcodeOffsetMs = 0

        // Check for pure Dolby Vision before direct play — VLC renders pink on DOVI.
        // KSPlayer (FFmpeg) handles DOVI natively, so only force transcode for VLC.
        let doviRange = item.mediaStreams?.first(where: { $0.isVideo })?.videoRangeType
            ?? item.mediaSources?.first?.mediaStreams?.first(where: { $0.isVideo })?.videoRangeType
        let doviNeedsTranscode = doviRange == "DOVI" && engine.needsDoviTranscode
        if doviNeedsTranscode && selectedQuality.resolved.forceDirectPlay {
            // Override to use PlaybackInfo with forceTranscode instead of direct play
            // Fall through to PlaybackInfo path below
        }

        // Direct mode: skip PlaybackInfo, stream the file as-is
        if selectedQuality.resolved.forceDirectPlay && !doviNeedsTranscode {
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
                self.statsVideoCodec = dpVideo?.codec?.uppercased() ?? "\u{2014}"
                self.statsVideoProfile = dpVideo?.profile ?? ""
                self.statsVideoResolution = "\(dpVideo?.width ?? 0)\u{00D7}\(dpVideo?.height ?? 0)"
                self.statsVideoBitDepth = dpVideo?.bitDepth.map { "\($0)-bit" } ?? ""
                self.statsVideoRange = dpVideo?.videoRangeType ?? dpVideo?.videoRange ?? "SDR"
                self.statsAudioCodec = dpAudio?.codec?.uppercased() ?? "\u{2014}"
                self.statsAudioLabel = dpAudio?.audioLabel ?? dpAudio?.language ?? ""
                self.statsContainer = "\u{2014}"
                self.statsIsTranscoding = false
                self.statsTranscodeReasons = []
            }

            if seekMs > 0 {
                resumeMs = seekMs
            } else {
                resumeMs = 0
            }

            engine.play(url: directURL, startTimeMs: seekMs, options: [
                "appState": appState,
                "disableSubs": disableEngineSubtitlesFlag,
                "useStartTime": seekMs > 0
            ])

            if NetworkMonitor.shared.isConnected {
                await JellyfinAPI.shared.reportPlaybackStart(
                    serverURL: appState.serverURL, itemId: item.id, token: appState.token)
            }
            await waitForPlaying()
            if playbackSpeed != 1.0 { engine.setRate(playbackSpeed) }
            if disableEngineSubtitlesFlag { engine.setSubtitleTrack(-1) }
            DispatchQueue.main.async {
                if self.resumeMs <= 0 { self.isLoading = false }
                self.isPlaying = self.engine.isPlaying
            }
            startPositionTimer()
        startMetricsTimer()
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
                externalSubtitles: disableEngineSubtitlesFlag,
                audioStreamIndex: audioIdx,
                forceTranscode: doviNeedsTranscode
            )
            guard let source = info.mediaSources.first else {
                DispatchQueue.main.async { self.error = String(localized: "No playable source found", bundle: AppState.currentBundle); self.isLoading = false }
                return
            }

            var url: URL
            if let transcodePath = source.transcodingUrl,
               let transURL = URL(string: appState.serverURL + transcodePath) {
                // Strip embedded subtitles from transcode URL when we manage subs externally
                if disableEngineSubtitlesFlag,
                   var comps = URLComponents(url: transURL, resolvingAgainstBaseURL: false) {
                    var items = comps.queryItems ?? []
                    items.removeAll { $0.name == "SubtitleStreamIndex" }
                    items.append(URLQueryItem(name: "SubtitleStreamIndex", value: "-1"))
                    comps.queryItems = items
                    url = comps.url ?? transURL
                } else {
                    url = transURL
                }
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
            var displayRes = "\(videoStream?.width ?? 0)\u{00D7}\(videoStream?.height ?? 0)"
            if isTranscoding {
                if let transcodePath = source.transcodingUrl,
                   let comps = URLComponents(string: transcodePath) {
                    let params = comps.queryItems ?? []
                    let maxW = params.first(where: { $0.name == "MaxWidth" })?.value.flatMap(Int.init)
                    let maxH = params.first(where: { $0.name == "MaxHeight" })?.value.flatMap(Int.init)
                    let srcW = videoStream?.width ?? 0
                    let srcH = videoStream?.height ?? 0
                    if let maxW, let maxH {
                        displayRes = "\(maxW)\u{00D7}\(maxH)"
                    } else if let maxW, srcW > 0, srcH > 0 {
                        let outW = min(maxW, srcW)
                        let outH = Int(Double(outW) * Double(srcH) / Double(srcW)) & ~1
                        displayRes = "\(outW)\u{00D7}\(outH)"
                    } else if let maxH, srcW > 0, srcH > 0 {
                        let outH = min(maxH, srcH)
                        let outW = Int(Double(outH) * Double(srcW) / Double(srcH)) & ~1
                        displayRes = "\(outW)\u{00D7}\(outH)"
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
                self.statsVideoCodec = videoStream?.codec?.uppercased() ?? "\u{2014}"
                self.statsVideoProfile = vProfile
                self.statsVideoResolution = displayRes
                self.statsVideoBitDepth = vBitDepth
                self.statsVideoRange = vRange
                self.statsAudioCodec = audioStream?.codec?.uppercased() ?? "\u{2014}"
                self.statsAudioLabel = aLabel
                self.statsContainer = source.container?.uppercased() ?? "\u{2014}"
                self.statsIsTranscoding = isTranscoding
                self.statsTranscodeReasons = reasons
                self.statsIsManualQuality = isManual
            }

            let useStartTime = !isTranscoding && seekMs > 0
            if seekMs > 0 {
                resumeMs = seekMs
            } else {
                resumeMs = 0
            }
            // KSPlayer transcode: HLS starts from seekMs, engine reports 0-based time
            // transcodeOffsetMs reserved for engines that report HLS time as 0-based
            // Currently disabled — KSPlayer appears to report absolute time on transcode

            engine.play(url: url, startTimeMs: seekMs, options: [
                "appState": appState,
                "disableSubs": disableEngineSubtitlesFlag,
                "useStartTime": useStartTime,
                "isTranscoding": isTranscoding
            ])
        } catch {
            DispatchQueue.main.async { self.error = error.localizedDescription; self.isLoading = false }
            return
        }

        if NetworkMonitor.shared.isConnected {
            await JellyfinAPI.shared.reportPlaybackStart(
                serverURL: appState.serverURL, itemId: item.id, token: appState.token)
        }

        if disableEngineSubtitlesFlag { engine.setSubtitleTrack(-1) }
        await waitForPlaying()
        if playbackSpeed != 1.0 { engine.setRate(playbackSpeed) }
        if disableEngineSubtitlesFlag { engine.setSubtitleTrack(-1) }
        DispatchQueue.main.async {
            if self.resumeMs <= 0 { self.isLoading = false }
            self.isPlaying = self.engine.isPlaying
        }
        startPositionTimer()
        startMetricsTimer()
    }

    private func waitForPlaying() async {
        var waited = 0
        while !engine.isPlaying && error == nil && waited < 15_000 {
            try? await Task.sleep(for: .milliseconds(200))
            waited += 200
        }
    }

    func changeQuality(to quality: VideoQuality) async {
        guard item != nil else { return }
        selectedQuality = quality

        let currentMs = engine.currentTimeMs

        positionTimer?.cancel()
        engine.stop()
        DispatchQueue.main.async { self.isLoading = true; self.isPlaying = false }

        try? await Task.sleep(for: .milliseconds(500))

        let startTicks = Int64(currentMs) * 10_000
        await startPlayback(jellyfinStartTicks: startTicks, seekMs: currentMs)
    }

    func togglePlayPause() {
        if engine.isPlaying {
            engine.pause()
            isPlaying = false
        } else {
            engine.resume()
            isPlaying = true
        }
    }

    func seek(to pos: Float) {
        engine.seek(to: pos)
        DispatchQueue.main.async { self.position = pos }
    }

    func skip(seconds: Int) {
        let currentMs = Int(engine.currentTimeMs)
        let newMs = max(0, currentMs + seconds * 1000)
        engine.seekTime(ms: Int32(newMs))
    }

    @Published var subtitleDelaySecs: Double = 0

    func setSubtitle(index: Int32) {
        currentSubtitleIndex = index
        engine.setSubtitleTrack(index)
    }

    func setEngineSubtitleTrack(_ index: Int32) {
        engine.setSubtitleTrack(index)
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
            engine.setAudioTrack(index)
            return
        }
        Task {
            let currentMs = engine.currentTimeMs
            positionTimer?.cancel()
            engine.stop()
            DispatchQueue.main.async { self.isLoading = true; self.isPlaying = false }
            try? await Task.sleep(for: .milliseconds(500))
            pendingAudioStreamIndex = Int(index)
            let startTicks = Int64(currentMs) * 10_000
            await startPlayback(jellyfinStartTicks: startTicks, seekMs: currentMs)
        }
    }

    func stop() {
        positionTimer?.cancel()
        metricsTimer?.cancel()
        engine.stop()
        guard let item, let appState else { return }

        let ticks: Int64
        if isLoading && resumeMs > 0 {
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

    private func startMetricsTimer() {
        metricsTimer?.cancel()
        metricsTimer = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { break }
                let cpu = PlayerViewModel.processCpuUsage()
                let thermal = PlayerViewModel.thermalLabel()
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if abs(self.statsCpuUsage - cpu) > 0.5 { self.statsCpuUsage = cpu }
                    self.statsThermal = thermal
                }
            }
        }
    }

    /// Returns total CPU usage of this process (all threads) as a percentage.
    private static func processCpuUsage() -> Double {
        var threadList: thread_act_array_t?
        var threadCount = mach_msg_type_number_t(0)
        guard task_threads(mach_task_self_, &threadList, &threadCount) == KERN_SUCCESS,
              let threads = threadList else { return 0 }
        var totalUsage: Double = 0
        for i in 0..<Int(threadCount) {
            var info = thread_basic_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
            let kr = withUnsafeMutablePointer(to: &info) { ptr in
                ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
                    thread_info(threads[i], thread_flavor_t(THREAD_BASIC_INFO), raw, &count)
                }
            }
            if kr == KERN_SUCCESS && info.flags & TH_FLAGS_IDLE == 0 {
                totalUsage += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100
            }
        }
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: threads), vm_size_t(threadCount) * vm_size_t(MemoryLayout<thread_t>.size))
        return totalUsage
    }

    private static func thermalLabel() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  return "Nominal"
        case .fair:     return "Fair"
        case .serious:  return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
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
        return parts.joined(separator: " \u{2022} ")
    }
}
