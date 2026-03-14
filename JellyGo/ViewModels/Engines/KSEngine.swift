#if canImport(KSPlayer)
import SwiftUI
import KSPlayer
import AVFoundation

// MARK: - KS Engine

final class KSEngine: NSObject, PlayerEngineBackend, @unchecked Sendable {
    weak var delegate: PlayerEngineDelegate?

    private var playerLayer: KSPlayerLayer?
    private var shouldDisableSubs = false
    private var _isPlaying = false
    private var _position: Float = 0
    private var _currentTimeMs: Int32 = 0
    private var _durationMs: Int32 = 0
    private var _videoSize: CGSize = .zero
    /// Persistent container view — player.view is added/removed dynamically
    private let containerView = KSPassthroughView()

    override init() {
        super.init()
        KSOptions.isAutoPlay = true
        KSOptions.isSecondOpen = true
        KSOptions.isAccurateSeek = true
        // Hybrid: AVPlayer first (native HW, low CPU), KSMEPlayer fallback (broad codec)
        KSOptions.firstPlayerType = KSAVPlayer.self
        KSOptions.secondPlayerType = KSMEPlayer.self
    }

    // MARK: - Playback

    func play(url: URL, startTimeMs: Int32, options: [String: Any]) {
        stop()

        let ksOptions = JellyGoKSOptions()
        if startTimeMs > 0, options["useStartTime"] as? Bool == true {
            ksOptions.startPlayTime = TimeInterval(startTimeMs) / 1000.0
        }

        shouldDisableSubs = options["disableSubs"] as? Bool ?? false

        let layer = KSPlayerLayer(url: url, options: ksOptions, delegate: self)
        self.playerLayer = layer

        // Attach player's rendering view to the persistent container synchronously
        containerView.subviews.forEach { $0.removeFromSuperview() }
        if let pv = layer.player.view {
            pv.translatesAutoresizingMaskIntoConstraints = false
            containerView.addSubview(pv)
            NSLayoutConstraint.activate([
                pv.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
                pv.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
                pv.topAnchor.constraint(equalTo: containerView.topAnchor),
                pv.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            ])
        }

        layer.play()
    }

    func stop() {
        playerLayer?.stop()
        playerLayer = nil
        containerView.subviews.forEach { $0.removeFromSuperview() }
        _isPlaying = false
        _position = 0
        _currentTimeMs = 0
        _durationMs = 0
    }

    func pause() {
        playerLayer?.pause()
        _isPlaying = false
    }

    func resume() {
        playerLayer?.play()
        _isPlaying = true
    }

    func seek(to position: Float) {
        let dur = playerLayer?.player.duration ?? 0
        guard dur > 0 else { return }
        let time = TimeInterval(position) * dur
        doSeek(to: time)
    }

    func seekTime(ms: Int32) {
        doSeek(to: TimeInterval(ms) / 1000.0)
    }

    private func doSeek(to time: TimeInterval) {
        guard let layer = playerLayer else { return }
        if layer.player.seekable {
            layer.seek(time: time, autoPlay: true) { _ in }
        } else {
            layer.player.seek(time: time) { [weak self] finished in
                if finished { self?.playerLayer?.play() }
            }
        }
    }

    func setRate(_ rate: Float) {
        playerLayer?.player.playbackRate = rate
    }

    func setVolume(_ value: Int32) {
        // Map from 100-200 (VLC range) to 0.0-2.0 (KSPlayer range)
        playerLayer?.player.playbackVolume = Float(value) / 100.0
    }

    func setBrightnessBoost(_ value: Float) {
        // Apply brightness via screen brightness adjustment.
        // KSPlayer uses AVSampleBufferDisplayLayer which doesn't support gamma filters.
        // The actual screen brightness approach is handled at the view level, same as VLC.
        // This is a no-op; JellyGoPlayerView already manages system brightness for both engines.
    }

    // MARK: - Properties

    var currentTimeMs: Int32 { _currentTimeMs }
    var duration: Int32 { _durationMs }
    var position: Float { _position }
    var isPlaying: Bool { _isPlaying }
    var videoSize: CGSize { _videoSize }

    // MARK: - Tracks

    var subtitleTracks: [(index: Int32, name: String)] {
        guard let tracks = playerLayer?.player.tracks(mediaType: .subtitle) else { return [] }
        return tracks.enumerated().map { (Int32($0.offset), $0.element.name) }
    }

    var audioTracks: [(index: Int32, name: String)] {
        guard let tracks = playerLayer?.player.tracks(mediaType: .audio) else { return [] }
        return tracks.enumerated().map { (Int32($0.offset), $0.element.name) }
    }

    var currentSubtitleTrackIndex: Int32 {
        guard let tracks = playerLayer?.player.tracks(mediaType: .subtitle) else { return -1 }
        if let idx = tracks.firstIndex(where: { $0.isEnabled }) { return Int32(idx) }
        return -1
    }

    var currentAudioTrackIndex: Int32 {
        guard let tracks = playerLayer?.player.tracks(mediaType: .audio) else { return -1 }
        if let idx = tracks.firstIndex(where: { $0.isEnabled }) { return Int32(idx) }
        return -1
    }

    func setSubtitleTrack(_ index: Int32) {
        guard let tracks = playerLayer?.player.tracks(mediaType: .subtitle) else { return }
        for (i, track) in tracks.enumerated() {
            track.isEnabled = (Int32(i) == index)
        }
    }

    func setAudioTrack(_ index: Int32) {
        guard let tracks = playerLayer?.player.tracks(mediaType: .audio) else { return }
        for (i, track) in tracks.enumerated() {
            track.isEnabled = (Int32(i) == index)
        }
        // Seek to current position to flush audio buffer and apply new track immediately
        if let layer = playerLayer {
            let cur = layer.player.currentPlaybackTime
            layer.player.seek(time: cur) { [weak self] finished in
                if finished { self?.playerLayer?.play() }
            }
        }
    }

    func disableEngineSubtitles() {
        shouldDisableSubs = true
        if let tracks = playerLayer?.player.tracks(mediaType: .subtitle) {
            for track in tracks { track.isEnabled = false }
        }
    }

    func setSubtitleDelay(ms: Int) {
        // KSPlayer subtitle delay via SubtitleDataSouce infos
        if let infos = playerLayer?.player.subtitleDataSouce?.infos {
            for info in infos {
                info.delay = TimeInterval(ms) / 1000.0
            }
        }
    }

    func addExternalSubtitle(url: URL) {
        // KSPlayer external subtitle support via subtitle data source
        // External subtitles can be loaded at the KSOptions level before playback
    }

    func applySubtitleAppearance(appState: AppState, disableSubs: Bool) {
        shouldDisableSubs = disableSubs
    }

    // MARK: - Video Surface

    @MainActor func makeVideoSurface() -> AnyView {
        AnyView(KSVideoSurface(containerView: containerView))
    }

    // MARK: - Capabilities

    var needsDoviTranscode: Bool { true }  // DOVI RPU tone mapping not implemented
    var needsManualResumeSeek: Bool { true }
    var resumeSeekTimeoutMs: Int { 5000 }
    var resumeSeekSettleDelay: TimeInterval { 0 }
    var reportsTranscodeTimeRelative: Bool { true }
    var handlesBrightnessBoost: Bool { false }
    var needsContainerRemux: Bool { true }
}

// MARK: - KSPlayerLayerDelegate

extension KSEngine: KSPlayerLayerDelegate {
    // KSPlayerLayerDelegate is @MainActor — callbacks arrive on main thread directly
    func player(layer: KSPlayerLayer, state: KSPlayerState) {
        switch state {
        case .readyToPlay, .bufferFinished:
            _isPlaying = true
            delegate?.engineStateChanged(isPlaying: true, isBuffering: false, error: nil)
            if state == .readyToPlay {
                let subs = subtitleTracks
                let auds = audioTracks
                delegate?.engineTracksUpdated(subtitles: subs, audio: auds)
                if shouldDisableSubs {
                    disableEngineSubtitles()
                }
                let size = layer.player.naturalSize
                if size.width > 0 {
                    _videoSize = size
                    delegate?.engineVideoSizeChanged(size)
                }
                let playerType = String(describing: type(of: layer.player))
                    .replacingOccurrences(of: "KSPlayer.", with: "")
                let hw = layer.options.hardwareDecode ? "VideoToolbox" : "SW"
                let videoTracks = layer.player.tracks(mediaType: .video)
                let videoDesc = videoTracks.first?.description ?? ""
                let label = "KSPlayer \u{00B7} \(playerType) \u{00B7} \(hw)\(videoDesc.isEmpty ? "" : " \u{00B7} \(videoDesc)")"
                delegate?.engineInfoUpdated(label)
                // KSAVPlayer: large buffer (keeps on seek). KSMEPlayer: default (flushes on seek).
                if layer.player is KSAVPlayer {
                    layer.options.preferredForwardBufferDuration = 60
                    layer.options.maxBufferDuration = 600
                }
            }
        case .buffering:
            delegate?.engineStateChanged(isPlaying: _isPlaying, isBuffering: true, error: nil)
        case .paused:
            _isPlaying = false
            delegate?.engineStateChanged(isPlaying: false, isBuffering: false, error: nil)
        case .playedToTheEnd:
            _isPlaying = false
            delegate?.engineStateChanged(isPlaying: false, isBuffering: false, error: nil)
        case .error:
            _isPlaying = false
            delegate?.engineStateChanged(isPlaying: false, isBuffering: false,
                error: String(localized: "Playback error", bundle: AppState.currentBundle))
        default:
            break
        }
    }

    func player(layer: KSPlayerLayer, currentTime: TimeInterval, totalTime: TimeInterval) {
        guard totalTime > 0 else { return }
        let currentMs = Int32(currentTime * 1000)
        let durationMs = Int32(totalTime * 1000)
        let pos = Float(currentTime / totalTime)
        _currentTimeMs = currentMs
        _durationMs = durationMs
        _position = pos
        delegate?.enginePositionChanged(position: pos, currentMs: currentMs, durationMs: durationMs)
        var stats = EngineStats()
        stats.bufferedSeconds = layer.player.playableTime
        if let info = layer.player.dynamicInfo {
            // KSMEPlayer path — full stats from FFmpeg
            stats.inputBitrateMbps = Double(info.videoBitrate + info.audioBitrate) / 1_000_000
            stats.readBytes = Int(info.bytesRead)
            stats.droppedFrames = Int32(info.droppedVideoFrameCount)
            stats.fps = info.displayFPS
        } else if let avPlayer = (layer.player as? KSAVPlayer)?.player,
                  let event = avPlayer.currentItem?.accessLog()?.events.last {
            // KSAVPlayer path — stats from AVPlayer accessLog
            stats.inputBitrateMbps = event.observedBitrate / 1_000_000
            stats.readBytes = Int(event.numberOfBytesTransferred)
            stats.fps = event.indicatedBitrate > 0 ? 0 : 0  // no FPS from accessLog
        }
        delegate?.engineStatsUpdated(stats)
    }

    func player(layer: KSPlayerLayer, finish error: Error?) {
        if let error {
            delegate?.engineStateChanged(isPlaying: false, isBuffering: false, error: error.localizedDescription)
        }
    }

    func player(layer: KSPlayerLayer, bufferedCount: Int, consumeTime: TimeInterval) {}
}

// MARK: - KS Video Surface

struct KSVideoSurface: UIViewRepresentable {
    let containerView: KSPassthroughView

    func makeUIView(context: Context) -> KSPassthroughView {
        containerView.backgroundColor = .black
        return containerView
    }

    func updateUIView(_ uiView: KSPassthroughView, context: Context) {}
}

/// Passes all touches through to SwiftUI so gesture modifiers on the ZStack work correctly.
final class KSPassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}

// MARK: - Custom KSOptions (force HW decode, skip rotation SW fallback)

final class JellyGoKSOptions: KSOptions {
    nonisolated override init() {
        super.init()
        autoRotate = false
        autoSelectEmbedSubtitle = false
    }

    /// Use Metal renderer — fixes VideoToolbox frame timing jank on 4K.
    nonisolated override func isUseDisplayLayer() -> Bool {
        false
    }

    /// Force HW decode — Metal renderer handles rotation, no need for SW FFmpeg filters.
    nonisolated override func process(assetTrack: some MediaPlayerTrack) {
        super.process(assetTrack: assetTrack)
        // Re-enable HW if super disabled it (rotation/interlace) — Metal can handle it
        hardwareDecode = true
        videoFilters.removeAll()
    }
}

#else

import SwiftUI

/// Stub KSEngine when KSPlayer SPM package is not available.
final class KSEngine: NSObject, PlayerEngineBackend {
    weak var delegate: PlayerEngineDelegate?

    func play(url: URL, startTimeMs: Int32, options: [String: Any]) {
        DispatchQueue.main.async {
            self.delegate?.engineStateChanged(isPlaying: false, isBuffering: false,
                error: "KSPlayer is not installed. Add it via Xcode Package Dependencies.")
        }
    }

    func stop() {}
    func pause() {}
    func resume() {}
    func seek(to position: Float) {}
    func seekTime(ms: Int32) {}
    func setRate(_ rate: Float) {}
    func setVolume(_ value: Int32) {}
    func setBrightnessBoost(_ value: Float) {}

    var currentTimeMs: Int32 { 0 }
    var duration: Int32 { 0 }
    var position: Float { 0 }
    var isPlaying: Bool { false }
    var videoSize: CGSize { .zero }

    var subtitleTracks: [(index: Int32, name: String)] { [] }
    var audioTracks: [(index: Int32, name: String)] { [] }
    var currentSubtitleTrackIndex: Int32 { -1 }
    var currentAudioTrackIndex: Int32 { -1 }
    func setSubtitleTrack(_ index: Int32) {}
    func setAudioTrack(_ index: Int32) {}
    func disableEngineSubtitles() {}
    func setSubtitleDelay(ms: Int) {}
    func addExternalSubtitle(url: URL) {}
    func applySubtitleAppearance(appState: AppState, disableSubs: Bool) {}

    @MainActor func makeVideoSurface() -> AnyView {
        AnyView(Color.black)
    }

    var needsDoviTranscode: Bool { true }  // DOVI RPU tone mapping not implemented
    var needsManualResumeSeek: Bool { true }
    var resumeSeekTimeoutMs: Int { 5000 }
    var resumeSeekSettleDelay: TimeInterval { 0 }
    var reportsTranscodeTimeRelative: Bool { true }
    var handlesBrightnessBoost: Bool { false }
    var needsContainerRemux: Bool { true }
}

#endif
