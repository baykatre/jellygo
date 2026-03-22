import SwiftUI
import MobileVLCKit

// MARK: - VLC Delegate Bridge

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

// MARK: - VLC Engine

final class VLCEngine: PlayerEngineBackend {
    let player = VLCMediaPlayer()
    weak var delegate: PlayerEngineDelegate?
    var onPipStopped: (() -> Void)?

    private let bridge = VLCDelegateBridge()
    private let logSniffer = VLCDecoderLogSniffer()
    private var tracksLoaded = false
    private var didDisableSubs = false
    private var shouldDisableSubs = false
    private var didReportInfo = false

    init() {
        player.delegate = bridge
        VLCLibrary.shared().loggers = [logSniffer]

        bridge.onStateChanged = { [weak self] state in
            DispatchQueue.main.async {
                guard let self else { return }
                let playing = self.player.isPlaying
                let error = state == .error ? String(localized: "Playback error", bundle: AppState.currentBundle) : nil
                self.delegate?.engineStateChanged(isPlaying: playing, isBuffering: false, error: error)

                if state == .playing {
                    self.updateTracks()
                    // Force-disable VLC subtitles once after tracks first load
                    if self.shouldDisableSubs && self.tracksLoaded && !self.didDisableSubs {
                        self.didDisableSubs = true
                        self.player.currentVideoSubTitleIndex = -1
                    }
                    // Report engine info once
                    if !self.didReportInfo {
                        self.didReportInfo = true
                        self.delegate?.engineInfoUpdated(self.buildEngineLabel())
                        VLCLibrary.shared().loggers = nil
                    }
                }
            }
        }

        bridge.onPositionChanged = { [weak self] pos in
            DispatchQueue.main.async {
                guard let self else { return }
                let currentMs = self.player.time.intValue
                let durationMs = self.player.media?.length.intValue ?? 0
                self.delegate?.enginePositionChanged(position: pos, currentMs: currentMs, durationMs: durationMs)

                // Stats
                if let media = self.player.media {
                    let s = media.statistics
                    var stats = EngineStats()
                    let inputBitrate = Double(s.inputBitrate)
                    let demuxBitrate = Double(s.demuxBitrate)
                    stats.inputBitrateMbps = inputBitrate * 8 / 1_000_000
                    stats.demuxBitrateMbps = demuxBitrate * 8 / 1_000_000
                    stats.readBytes = max(0, max(Int(s.readBytes), Int(s.demuxReadBytes)))
                    stats.droppedFrames = s.lostPictures
                    stats.decodedFrames = s.decodedVideo
                    stats.displayedPictures = s.displayedPictures
                    stats.lostAudioBuffers = s.lostAudioBuffers
                    // VLC does not expose buffer/playable time — buffer bar unavailable
                    self.delegate?.engineStatsUpdated(stats)
                }
            }
        }
    }

    // MARK: - Playback

    func play(url: URL, startTimeMs: Int32, options: [String: Any]) {
        tracksLoaded = false
        didDisableSubs = false
        let media = VLCMedia(url: url)

        // Apply media options passed from ViewModel
        if let appState = options["appState"] as? AppState,
           let disableSubs = options["disableSubs"] as? Bool {
            applySubtitleAppearance(to: media, appState: appState, disableSubs: disableSubs)
            shouldDisableSubs = disableSubs
        }

        if startTimeMs > 0, options["useStartTime"] as? Bool == true {
            media.addOption(":start-time=\(Double(startTimeMs) / 1000.0)")
        }
        if shouldDisableSubs {
            media.addOption(":sub-track-id=-1")
        }

        player.media = media
        player.play()
    }

    func stop() {
        player.stop()
        player.media = nil
    }

    func pause() {
        player.pause()
    }

    func resume() {
        player.play()
    }

    func seek(to position: Float) {
        player.position = position
    }

    func seekTime(ms: Int32) {
        player.time = VLCTime(int: ms)
    }

    func setRate(_ rate: Float) {
        player.rate = rate
    }

    func setVolume(_ value: Int32) {
        player.audio?.volume = value
    }

    func setBrightnessBoost(_ value: Float) {
        let isActive = value > 1.001
        player.adjustFilter.isEnabled = isActive
        if isActive {
            let t = (value - 1.0) / 0.5
            let gamma = 1.0 + t * 2.0
            player.adjustFilter.gamma.value = NSNumber(value: gamma)
        } else {
            player.adjustFilter.gamma.value = NSNumber(value: 1.0)
        }
    }

    // MARK: - Properties

    var currentTimeMs: Int32 { player.time.intValue }
    var duration: Int32 { player.media?.length.intValue ?? 0 }
    var position: Float { player.position }
    var isPlaying: Bool { player.isPlaying }
    var videoSize: CGSize { player.videoSize }

    // MARK: - Tracks

    var subtitleTracks: [(index: Int32, name: String)] {
        let indexes = player.videoSubTitlesIndexes as? [NSNumber] ?? []
        let names = player.videoSubTitlesNames as? [String] ?? []
        return zip(indexes, names).map { (Int32($0.intValue), $1) }
    }

    var audioTracks: [(index: Int32, name: String)] {
        let indexes = player.audioTrackIndexes as? [NSNumber] ?? []
        let names = player.audioTrackNames as? [String] ?? []
        return zip(indexes, names).map { (Int32($0.intValue), $1) }
    }

    var currentSubtitleTrackIndex: Int32 { player.currentVideoSubTitleIndex }
    var currentAudioTrackIndex: Int32 { player.currentAudioTrackIndex }

    func setSubtitleTrack(_ index: Int32) {
        Task.detached { [player] in
            player.currentVideoSubTitleIndex = index
        }
    }

    func setAudioTrack(_ index: Int32) {
        Task.detached { [player] in
            player.currentAudioTrackIndex = index
        }
    }

    func disableEngineSubtitles() {
        shouldDisableSubs = true
        player.currentVideoSubTitleIndex = -1
    }

    func setSubtitleDelay(ms: Int) {
        // VLC subtitle delay is managed externally by SubtitleManager
    }

    func addExternalSubtitle(url: URL) {
        player.addPlaybackSlave(url, type: .subtitle, enforce: false)
    }

    // MARK: - Subtitle Appearance

    func applySubtitleAppearance(appState: AppState, disableSubs: Bool) {
        // This variant is called from PlayerViewModel; the actual VLC media options
        // are applied in the private method when play() is called
    }

    private func applySubtitleAppearance(to media: VLCMedia, appState: AppState, disableSubs: Bool) {
        media.addOption("--file-caching=3000")
        media.addOption("--network-caching=10000")
        if disableSubs {
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

    // MARK: - Track Updates

    private func updateTracks() {
        let size = player.videoSize
        if size.width > 0 {
            delegate?.engineVideoSizeChanged(size)
        }

        guard !tracksLoaded else { return }

        let subs = subtitleTracks
        let auds = audioTracks

        if !subs.isEmpty || !auds.isEmpty {
            tracksLoaded = true
        }

        delegate?.engineTracksUpdated(subtitles: subs, audio: auds)
    }

    // MARK: - Engine Label

    private func buildEngineLabel() -> String {
        guard let tracks = player.media?.tracksInformation as? [[String: Any]] else {
            return "VLC \u{00B7} MobileVLCKit"
        }
        let videoTrack = tracks.first { ($0[VLCMediaTracksInformationType] as? String) == VLCMediaTracksInformationTypeVideo }
        guard let vt = videoTrack else { return "VLC \u{00B7} MobileVLCKit" }

        var parts = ["VLC"]
        // Codec
        if let fourcc = vt[VLCMediaTracksInformationCodec] as? UInt32 {
            let codecName = VLCMedia.codecName(forFourCC: fourcc, trackType: VLCMediaTracksInformationTypeVideo)
            if !codecName.isEmpty { parts.append(codecName) }
        }
        // Profile & Level (skip if unavailable / -1)
        if let profile = vt[VLCMediaTracksInformationCodecProfile] as? Int, profile > 0,
           let level = vt[VLCMediaTracksInformationCodecLevel] as? Int, level > 0 {
            parts.append("P\(profile)/L\(level)")
        }
        // Resolution
        if let w = vt[VLCMediaTracksInformationVideoWidth] as? Int,
           let h = vt[VLCMediaTracksInformationVideoHeight] as? Int, w > 0 {
            parts.append("\(w)\u{00D7}\(h)")
        }
        // FPS
        if let fpsNum = vt[VLCMediaTracksInformationFrameRate] as? Int,
           let fpsDen = vt[VLCMediaTracksInformationFrameRateDenominator] as? Int, fpsDen > 0 {
            let fps = Double(fpsNum) / Double(fpsDen)
            parts.append(String(format: "%.2f fps", fps))
        }
        if logSniffer.detectedDecoder != "detecting..." {
            parts.append(logSniffer.detectedDecoder)
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    // MARK: - Video Surface

    @MainActor func makeVideoSurface() -> AnyView {
        AnyView(VLCVideoSurface(player: player))
    }

    // MARK: - Picture-in-Picture

    var isPipSupported: Bool { false }
    var isPipActive: Bool { false }
    func startPip() {}
    func stopPip() {}

    // MARK: - Capabilities

    var needsDoviTranscode: Bool { true }
    var needsManualResumeSeek: Bool { true }
    var resumeSeekTimeoutMs: Int { 15000 }
    var resumeSeekSettleDelay: TimeInterval { 1.0 }
    var reportsTranscodeTimeRelative: Bool { false }
    var handlesBrightnessBoost: Bool { true }
    var needsContainerRemux: Bool { false }
}

// MARK: - Decoder Log Sniffer

/// Captures VLC log output to detect which video decoder is actually being used.
final class VLCDecoderLogSniffer: NSObject, VLCLogging {
    var level: VLCLogLevel = .debug
    private(set) var detectedDecoder = "detecting..."
    private var detected = false
    private(set) var decoderModules = Set<String>()

    func handleMessage(_ message: String, logLevel: VLCLogLevel, context: VLCLogContext?) {
        guard !detected else { return }
        let mod = (context?.module ?? "").lowercased()
        let msg = message.lowercased()
        // Collect decoder-related module names for fallback display
        if !mod.isEmpty && (mod.contains("dec") || mod.contains("codec") || mod.contains("video") || mod.contains("vt")) {
            decoderModules.insert(mod)
        }
        if mod.contains("videotoolbox") || mod.contains("vt_") || msg.contains("videotoolbox") {
            detectedDecoder = "VideoToolbox HW"
            detected = true
        } else if msg.contains("hardware") && msg.contains("accel") {
            detectedDecoder = "VideoToolbox HW"
            detected = true
        } else if (mod == "avcodec" || mod.contains("decoder")) && msg.contains("codec") {
            detectedDecoder = "avcodec SW"
            detected = true
        } else if msg.contains("using codec module") {
            // Extract module name from log
            if msg.contains("videotoolbox") {
                detectedDecoder = "VideoToolbox HW"
            } else {
                let cleaned = message.replacingOccurrences(of: "using codec module \"", with: "")
                    .replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespaces)
                detectedDecoder = cleaned.isEmpty ? "avcodec" : cleaned
            }
            detected = true
        }
    }

    func reset() {
        detected = false
        detectedDecoder = "detecting..."
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
