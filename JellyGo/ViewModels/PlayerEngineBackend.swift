import SwiftUI

// MARK: - Player Engine Backend Protocol

protocol PlayerEngineBackend: AnyObject {
    var delegate: PlayerEngineDelegate? { get set }

    func play(url: URL, startTimeMs: Int32, options: [String: Any])
    func stop()
    func pause()
    func resume()
    func seek(to position: Float)
    func seekTime(ms: Int32)
    func setRate(_ rate: Float)
    func setVolume(_ value: Int32)
    func setBrightnessBoost(_ value: Float)

    var currentTimeMs: Int32 { get }
    var duration: Int32 { get }
    var position: Float { get }
    var isPlaying: Bool { get }
    var videoSize: CGSize { get }

    var subtitleTracks: [(index: Int32, name: String)] { get }
    var audioTracks: [(index: Int32, name: String)] { get }
    var currentSubtitleTrackIndex: Int32 { get }
    var currentAudioTrackIndex: Int32 { get }
    func setSubtitleTrack(_ index: Int32)
    func setAudioTrack(_ index: Int32)
    func disableEngineSubtitles()
    func setSubtitleDelay(ms: Int)
    func addExternalSubtitle(url: URL)

    func applySubtitleAppearance(appState: AppState, disableSubs: Bool)

    @MainActor func makeVideoSurface() -> AnyView

    // MARK: - Engine Capabilities

    /// True if this engine renders Dolby Vision incorrectly and needs server-side transcode.
    var needsDoviTranscode: Bool { get }

    /// True if this engine needs a manual seekTime() call after playback starts to reach resume position.
    /// False if the engine handles startPlayTime internally (e.g. via KSOptions.startPlayTime).
    var needsManualResumeSeek: Bool { get }

    /// Maximum ms to wait for resume seek to settle before dismissing loading overlay.
    var resumeSeekTimeoutMs: Int { get }

    /// Extra delay (seconds) after resume seek settles before dismissing loading (smooths transition).
    var resumeSeekSettleDelay: TimeInterval { get }

    /// True if this engine reports HLS transcode time relative to stream start (0-based)
    /// rather than absolute video time. ViewModel will track offset and adjust position/seek.
    var reportsTranscodeTimeRelative: Bool { get }

    /// True if the engine handles brightness/gamma boost internally (e.g. VLC adjustFilter).
    /// False means the view layer should apply a visual brightness modifier.
    var handlesBrightnessBoost: Bool { get }

    /// True if the engine's primary player can't handle MKV/WebM containers natively
    /// and needs server-side remux to MP4.
    var needsContainerRemux: Bool { get }

    // MARK: - Picture-in-Picture

    /// True if this engine supports PiP on the current platform.
    var isPipSupported: Bool { get }

    /// True if PiP is currently active.
    var isPipActive: Bool { get }

    /// Start Picture-in-Picture playback.
    func startPip()

    /// Stop Picture-in-Picture playback.
    func stopPip()

    /// Called when PiP ends externally (user dismissed PiP window).
    /// Engine should notify delegate so ViewModel can clean up.
    var onPipStopped: (() -> Void)? { get set }
}

// MARK: - Player Engine Delegate

protocol PlayerEngineDelegate: AnyObject {
    func engineStateChanged(isPlaying: Bool, isBuffering: Bool, error: String?)
    func enginePositionChanged(position: Float, currentMs: Int32, durationMs: Int32)
    func engineTracksUpdated(subtitles: [(Int32, String)], audio: [(Int32, String)])
    func engineVideoSizeChanged(_ size: CGSize)
    func engineStatsUpdated(_ stats: EngineStats)
    func engineInfoUpdated(_ label: String)
}

struct EngineStats {
    var inputBitrateMbps: Double = 0
    var demuxBitrateMbps: Double = 0
    var readBytes: Int = 0
    var decodedFrames: Int32 = 0
    var droppedFrames: Int32 = 0
    var displayedPictures: Int32 = 0
    var lostAudioBuffers: Int32 = 0
    var fps: Double = 0
    var bufferedSeconds: Double = 0  // how far ahead the buffer extends
}
