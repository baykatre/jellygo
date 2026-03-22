#if canImport(KSPlayer)
import SwiftUI
import KSPlayer
import AVFoundation
import AVKit

// MARK: - KS Engine

final class KSEngine: NSObject, PlayerEngineBackend, @unchecked Sendable {
    weak var delegate: PlayerEngineDelegate?
    var onPipStopped: (() -> Void)?
    var onPipStarted: (() -> Void)?

    private var playerLayer: KSPlayerLayer?
    private var shouldDisableSubs = false
    private var _isPlaying = false
    private var _position: Float = 0
    private var _currentTimeMs: Int32 = 0
    private var _durationMs: Int32 = 0
    private var _videoSize: CGSize = .zero
    /// Persistent container view — player.view is added/removed dynamically
    private let containerView = KSPassthroughView()
    /// Shared KS options instance — kept alive for PiP display-layer toggling.
    private var currentOptions: JellyGoKSOptions?
    /// KVO observation on AVPictureInPictureController.isPictureInPictureActive.
    private var pipObservation: NSKeyValueObservation?
    /// CATextLayer for rendering subtitles visible in PiP window.
    private var pipSubtitleLayer: CATextLayer?

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
        currentOptions = ksOptions

        let layer = KSPlayerLayer(url: url, options: ksOptions, delegate: self)
        self.playerLayer = layer

        // Observe AVPictureInPictureController.isPictureInPictureActive via KVO
        // to detect PiP start (e.g. auto-PiP from background) and PiP end.
        if let pip = layer.player.pipController {
            pipObservation = pip.observe(\.isPictureInPictureActive, options: [.new]) { [weak self] _, change in
                guard let self, let active = change.newValue else { return }
                DispatchQueue.main.async {
                    if active {
                        // PiP started externally (auto-PiP when app goes to background).
                        // Notify via onPipStarted so ViewModel sets isPipActive = true.
                        self.onPipStarted?()
                    } else {
                        // PiP ended externally (user dismissed PiP window)
                        self.onPipStopped?()
                    }
                }
            }
        }

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
        removePipSubtitleLayer()
        currentOptions?.pipActive = false
        pipObservation = nil
        playerLayer?.stop()
        playerLayer = nil
        currentOptions = nil
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

    // MARK: - Picture-in-Picture

    var isPipSupported: Bool {
        guard let playerLayer else { return false }
        return playerLayer.player.pipController != nil
    }

    var isPipActive: Bool {
        playerLayer?.player.pipController?.isPictureInPictureActive ?? false
    }

    func startPip() {
        guard let playerLayer, let pip = playerLayer.player.pipController else { return }
        // For KSMEPlayer with Metal rendering: switch to display-layer mode so frames
        // flow through AVSampleBufferDisplayLayer which PiP reads from.
        currentOptions?.pipActive = true
        // Directly call AVPictureInPictureController.startPictureInPicture()
        // instead of going through KSPlayerLayer.isPipActive which sends app to background.
        pip.delegate = playerLayer
        pip.startPictureInPicture()
    }

    func stopPip() {
        currentOptions?.pipActive = false
        if let pip = playerLayer?.player.pipController {
            pip.stopPictureInPicture()
        }
    }

    // MARK: - PiP Subtitles (CATextLayer overlay)

    private func findVideoLayer() -> CALayer? {
        guard let playerView = playerLayer?.player.view else { return nil }
        return findDisplayLayer(in: playerView.layer)
    }

    private func findDisplayLayer(in layer: CALayer) -> CALayer? {
        if layer is AVSampleBufferDisplayLayer || layer is AVPlayerLayer {
            return layer
        }
        for sub in layer.sublayers ?? [] {
            if let found = findDisplayLayer(in: sub) { return found }
        }
        return nil
    }

    func addPipSubtitleLayer() {
        guard pipSubtitleLayer == nil else { return }
        guard let targetLayer = playerLayer?.player.view?.layer else { return }

        let textLayer = CATextLayer()
        textLayer.isWrapped = true
        textLayer.alignmentMode = .center
        textLayer.contentsScale = UIScreen.main.scale
        textLayer.fontSize = 16
        textLayer.foregroundColor = UIColor.white.cgColor
        textLayer.shadowColor = UIColor.black.cgColor
        textLayer.shadowRadius = 3
        textLayer.shadowOpacity = 1.0
        textLayer.shadowOffset = CGSize(width: 0, height: 1)
        textLayer.truncationMode = .end
        textLayer.backgroundColor = UIColor.black.withAlphaComponent(0.55).cgColor
        textLayer.cornerRadius = 4
        textLayer.string = ""
        textLayer.isHidden = true

        let bounds = targetLayer.bounds
        let height: CGFloat = 60
        let hPad: CGFloat = 20
        textLayer.frame = CGRect(x: hPad, y: bounds.height - height - 12,
                                 width: bounds.width - hPad * 2, height: height)
        textLayer.zPosition = 9999

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        targetLayer.addSublayer(textLayer)
        CATransaction.commit()

        pipSubtitleLayer = textLayer
    }

    func removePipSubtitleLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pipSubtitleLayer?.removeFromSuperlayer()
        CATransaction.commit()
        pipSubtitleLayer = nil
    }

    func updatePipSubtitleText(_ text: String) {
        guard let layer = pipSubtitleLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        if text.isEmpty {
            layer.isHidden = true
            layer.string = ""
        } else {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.lineBreakMode = .byWordWrapping
            let font = UIFont.systemFont(ofSize: 16, weight: .semibold)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor.white,
                .paragraphStyle: style,
            ]
            layer.string = NSAttributedString(string: text, attributes: attrs)
            layer.isHidden = false

            if let parent = layer.superlayer {
                let parentBounds = parent.bounds
                let hPad: CGFloat = 20
                let maxWidth = parentBounds.width - hPad * 2
                let textSize = (text as NSString).boundingRect(
                    with: CGSize(width: maxWidth - 16, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: attrs, context: nil).size
                let layerHeight = min(textSize.height + 12, 80)
                let layerWidth = min(textSize.width + 16, maxWidth)
                let x = (parentBounds.width - layerWidth) / 2
                layer.frame = CGRect(x: x, y: parentBounds.height - layerHeight - 12,
                                     width: layerWidth, height: layerHeight)
            }
        }

        CATransaction.commit()
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
                if shouldDisableSubs && !isPipActive {
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
    /// When true, routes frames through AVSampleBufferDisplayLayer for PiP support.
    nonisolated(unsafe) var pipActive = false

    nonisolated override init() {
        super.init()
        autoRotate = false
        autoSelectEmbedSubtitle = false
    }

    /// Always route frames through AVSampleBufferDisplayLayer so PiP is ready instantly.
    /// This ensures PiP works on first tap and when app goes to background (auto-PiP).
    /// Metal renderer is not used; display layer handles all rendering.
    nonisolated override func isUseDisplayLayer() -> Bool {
        true
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
    var onPipStopped: (() -> Void)?
    var onPipStarted: (() -> Void)?

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

    var isPipSupported: Bool { false }
    var isPipActive: Bool { false }
    func startPip() {}
    func stopPip() {}
    func addPipSubtitleLayer() {}
    func removePipSubtitleLayer() {}
    func updatePipSubtitleText(_ text: String) {}

    var needsDoviTranscode: Bool { true }  // DOVI RPU tone mapping not implemented
    var needsManualResumeSeek: Bool { true }
    var resumeSeekTimeoutMs: Int { 5000 }
    var resumeSeekSettleDelay: TimeInterval { 0 }
    var reportsTranscodeTimeRelative: Bool { true }
    var handlesBrightnessBoost: Bool { false }
    var needsContainerRemux: Bool { true }
}

#endif
