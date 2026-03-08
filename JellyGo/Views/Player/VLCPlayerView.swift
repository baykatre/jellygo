import SwiftUI
import MobileVLCKit
import Combine
import MediaPlayer

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

    init() {
        player.delegate = bridge
        bridge.onStateChanged = { [weak self] state in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isPlaying = self.player.isPlaying
                if state == .playing {
                    self.loadTracks()
                    // Seek to resume position on first play if media option didn't work
                    if !self.didSeekToResume && self.resumeMs > 0 {
                        self.didSeekToResume = true
                        self.player.time = VLCTime(int: self.resumeMs)
                    }
                }
                if state == .error { self.error = "Playback error" }
            }
        }
        bridge.onPositionChanged = { [weak self] pos in
            DispatchQueue.main.async {
                self?.position = pos
                if let media = self?.player.media {
                    let s = media.statistics
                    // inputBitrate is 0 for HLS; fall back to demuxBitrate (bytes/sec → Mbps)
                    let raw = s.inputBitrate > 0 ? s.inputBitrate : s.demuxBitrate
                    self?.statsBitrateMbps = Double(raw) * 8 / 1_000_000
                    self?.statsDroppedFrames = s.lostPictures
                    self?.statsDecodedFrames = s.decodedVideo
                }
            }
        }
    }

    func loadLocal(url: URL, item: JellyfinItem, appState: AppState) async {
        self.appState = appState
        DispatchQueue.main.async { self.isLoading = true; self.error = nil; self.isLocal = true }

        let media = VLCMedia(url: url)
        player.media = media
        await JellyfinAPI.shared.reportPlaybackStart(
            serverURL: appState.serverURL, itemId: item.id, token: appState.token)
        player.play()

        // Add external subtitle files (.srt) saved next to the video
        let downloadsDir = DownloadManager.downloadsDirectory
        let prefix = "\(item.id)_"
        if let files = try? FileManager.default.contentsOfDirectory(atPath: downloadsDir.path) {
            for file in files where file.hasPrefix(prefix) && file.hasSuffix(".srt") {
                let srtURL = downloadsDir.appendingPathComponent(file)
                player.addPlaybackSlave(srtURL, type: .subtitle, enforce: false)
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
                mediaSources: item.mediaSources, childCount: item.childCount
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
            DispatchQueue.main.async { self.error = "Select an episode to play"; self.isLoading = false }
            return
        }

        let resumeTicks = item.userData?.playbackPositionTicks ?? 0
        // For direct play: VLC seeks via :start-time (jellyfinStartTicks unused).
        // For transcode: Jellyfin starts from resumeTicks; vlcSeekMs stays 0
        //   (no double-seek — Jellyfin already embeds the position in the HLS).
        let vlcSeekMs = Int32(resumeTicks / 10_000)
        await startPlayback(jellyfinStartTicks: resumeTicks, vlcSeekMs: vlcSeekMs)
    }

    /// - Parameters:
    ///   - jellyfinStartTicks: Passed as `startTimeTicks` to Jellyfin's PlaybackInfo.
    ///                         For initial resume: the saved position ticks.
    ///                         For quality changes: 0 (transcode from beginning).
    ///   - vlcSeekMs: If > 0, VLC seeks to this position (ms) via `:start-time` after media is set.
    ///                For initial resume of direct streams: same as jellyfinStartTicks/10000.
    ///                For quality changes: the current playback position so slider stays correct.
    private func startPlayback(jellyfinStartTicks: Int64, vlcSeekMs: Int32) async {
        guard let item, let appState else { return }

        didSeekToResume = false
        // resumeMs will be set specifically per path below

        // Direct mode: skip PlaybackInfo, stream the file as-is
        if selectedQuality.resolved.forceDirectPlay {
            guard let directURL = JellyfinAPI.shared.streamURL(
                serverURL: appState.serverURL,
                itemId: item.id,
                mediaSourceId: item.id,
                token: appState.token
            ) else {
                DispatchQueue.main.async { self.error = "No playable source found"; self.isLoading = false }
                return
            }
            DispatchQueue.main.async {
                self.statsVideoCodec = "—"
                self.statsAudioCodec = "—"
                self.statsContainer = "—"
                self.statsIsTranscoding = false
            }
            let media = VLCMedia(url: directURL)
            if vlcSeekMs > 0 {
                resumeMs = vlcSeekMs  // delegate will seek after first .playing state
                media.addOption(":start-time=\(Double(vlcSeekMs) / 1000.0)")
            } else {
                resumeMs = 0
            }
            player.media = media
            await JellyfinAPI.shared.reportPlaybackStart(
                serverURL: appState.serverURL, itemId: item.id, token: appState.token)
            player.play()
            await waitForPlaying()
            DispatchQueue.main.async { self.isLoading = false; self.isPlaying = self.player.isPlaying }
            startPositionTimer()
            return
        }

        do {
            let info = try await JellyfinAPI.shared.getPlaybackInfo(
                serverURL: appState.serverURL,
                itemId: item.id,
                userId: appState.userId,
                token: appState.token,
                startTimeTicks: jellyfinStartTicks,
                maxBitrate: selectedQuality.resolved.maxBitrate
            )
            guard let source = info.mediaSources.first else {
                DispatchQueue.main.async { self.error = "No playable source found"; self.isLoading = false }
                return
            }

            // Prefer transcoding URL, fall back to direct stream
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
                DispatchQueue.main.async { self.error = "No playable source found"; self.isLoading = false }
                return
            }

            // Extract codec / container metadata for stats
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
            if vlcSeekMs > 0 && jellyfinStartTicks == 0 {
                // Quality change: Jellyfin transcodes from 0, VLC seeks to current pos.
                // Safe to seek because the HLS stream itself starts from 0.
                resumeMs = vlcSeekMs
                media.addOption(":start-time=\(Double(vlcSeekMs) / 1000.0)")
            } else {
                // Initial resume: Jellyfin already starts HLS from the resume position.
                // Do NOT add :start-time — VLC would double-seek (seek within an HLS
                // that already starts at the target position → overshoots).
                resumeMs = 0
            }
            player.media = media
        } catch {
            DispatchQueue.main.async { self.error = error.localizedDescription; self.isLoading = false }
            return
        }

        await JellyfinAPI.shared.reportPlaybackStart(
            serverURL: appState.serverURL, itemId: item.id, token: appState.token)

        player.play()
        await waitForPlaying()
        DispatchQueue.main.async { self.isLoading = false; self.isPlaying = self.player.isPlaying }
        startPositionTimer()
    }

    /// Polls until VLC reaches playing or error state (max 15s).
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

        // Capture current position BEFORE stopping
        let currentMs = Int32(max(0, player.time.intValue))

        positionTimer?.cancel()
        player.stop()
        player.media = nil   // Fully release — fixes hang on some content
        DispatchQueue.main.async { self.isLoading = true; self.isPlaying = false }

        // Wait for VLC to fully stop before setting new media
        try? await Task.sleep(for: .milliseconds(500))

        // jellyfinStartTicks = 0: Jellyfin transcodes from the beginning.
        // vlcSeekMs = currentMs: VLC seeks to the current position via :start-time.
        // This avoids the double-seek that caused freezes when both were non-zero.
        await startPlayback(jellyfinStartTicks: 0, vlcSeekMs: currentMs)
    }

    func togglePlayPause() {
        if player.isPlaying { player.pause() } else { player.play() }
        DispatchQueue.main.async { self.isPlaying = self.player.isPlaying }
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

    func setSubtitle(index: Int32) {
        player.currentVideoSubTitleIndex = index
        currentSubtitleIndex = index
    }

    func setAudio(index: Int32) {
        player.currentAudioTrackIndex = index
        currentAudioIndex = index
    }

    private func loadTracks() {
        let size = player.videoSize
        if size.width > 0 { videoSize = size }

        let subIndexes = player.videoSubTitlesIndexes as? [NSNumber] ?? []
        let subNames   = player.videoSubTitlesNames   as? [String]   ?? []
        subtitleTracks = zip(subIndexes, subNames).map { (Int32($0.intValue), $1) }
        currentSubtitleIndex = player.currentVideoSubTitleIndex

        let audIndexes = player.audioTrackIndexes as? [NSNumber] ?? []
        let audNames   = player.audioTrackNames   as? [String]   ?? []
        audioTracks = zip(audIndexes, audNames).map { (Int32($0.intValue), $1) }
        currentAudioIndex = player.currentAudioTrackIndex
    }

    func stop() {
        positionTimer?.cancel()
        player.stop()
        guard let item, let appState else { return }
        let ticks = Int64(Double(position) * Double(item.runTimeTicks ?? 0))

        // Save local position for downloaded files
        if isLocal && currentSeconds > 2 {
            LocalPlaybackStore.savePosition(currentSeconds, for: item.id)
        }

        Task {
            await JellyfinAPI.shared.reportPlaybackStopped(
                serverURL: appState.serverURL, itemId: item.id,
                positionTicks: ticks, token: appState.token)
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
                await JellyfinAPI.shared.reportPlaybackProgress(
                    serverURL: appState.serverURL, itemId: item.id,
                    positionTicks: ticks, isPaused: !isPlaying, token: appState.token)
            }
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
        return parts.joined(separator: " • ")
    }
}

// MARK: - View

struct VLCPlayerView: View {
    let item: JellyfinItem
    var localURL: URL? = nil

    @EnvironmentObject private var appState: AppState
    @StateObject private var vm = VLCPlayerViewModel()
    @Environment(\.dismiss) private var dismiss

    @State private var showControls = true
    @State private var hideTask: Task<Void, Never>?
    @State private var showTracks = false
    @State private var showQualityPicker = false
    @State private var showStats = false
    @State private var videoScale: CGFloat = 1.0
    @State private var baseScale: CGFloat = 1.0

    private var isZoomed: Bool { videoScale > 1.05 }

    /// Scale needed to make the video fill the screen with no letterboxing/pillarboxing.
    /// Always treats the view as landscape (width > height).
    private func fillScale(for viewSize: CGSize) -> CGFloat {
        let vSize = vm.videoSize
        guard vSize.width > 0, vSize.height > 0 else { return 1.33 }

        // Normalize to landscape regardless of current device orientation
        let screenW = max(viewSize.width, viewSize.height)
        let screenH = min(viewSize.width, viewSize.height)
        guard screenH > 0 else { return 1.33 }

        // VLC renders with aspect-fit (maintains video AR, adds black bars)
        // Video AR from its natural dimensions (wider dimension first)
        let videoW = max(vSize.width, vSize.height)
        let videoH = min(vSize.width, vSize.height)
        let videoAR = videoW / videoH
        let screenAR = screenW / screenH

        // Scale = ratio needed to make the constrained axis fill the screen
        return videoAR > screenAR
            ? videoAR / screenAR   // letterboxed top/bottom → scale up height
            : screenAR / videoAR   // pillarboxed left/right → scale up width
    }

    var body: some View {
        GeometryReader { geo in
            let fill = fillScale(for: geo.size)

            ZStack {
                Color.black.ignoresSafeArea()

                VLCVideoSurface(player: vm.player)
                    .ignoresSafeArea()
                    .scaleEffect(videoScale)

                if vm.isLoading {
                    ProgressView().tint(.white).scaleEffect(1.4)
                        .allowsHitTesting(false)
                }

                if let error = vm.error { errorView(message: error) }

                if showControls {
                    overlayControls.transition(.opacity)
                }

                if showStats {
                    statsHUD
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(.top, 70)
                        .padding(.leading, 20)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                MagnificationGesture()
                    .onChanged { val in
                        videoScale = min(fill, max(1.0, baseScale * val))
                    }
                    .onEnded { val in
                        let result = min(fill, max(1.0, baseScale * val))
                        if result < 1.1 {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                videoScale = 1.0
                            }
                            baseScale = 1.0
                        } else {
                            baseScale = result
                            videoScale = result
                        }
                    }
            )
            .onTapGesture(count: 2) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                    if isZoomed { videoScale = 1.0; baseScale = 1.0 }
                    else { videoScale = fill; baseScale = fill }
                }
                resetHideTimer()
            }
            .onTapGesture(count: 1) { toggleControls() }
        }
        .statusBarHidden(true)
        .animation(.easeInOut(duration: 0.2), value: showControls)
        .task {
            if let url = localURL {
                await vm.loadLocal(url: url, item: item, appState: appState)
            } else {
                await vm.load(item: item, appState: appState)
            }
        }
        .onDisappear { vm.stop() }
        .onAppear {
            AppDelegate.orientationLock = .landscape
            PlayerView.rotate(to: .landscapeRight)
            scheduleHide()
        }
        .sheet(isPresented: $showTracks) { tracksSheet }
        .confirmationDialog("Quality", isPresented: $showQualityPicker, titleVisibility: .visible) {
            ForEach(VideoQuality.allCases) { quality in
                Button(quality.rawValue) {
                    Task { await vm.changeQuality(to: quality) }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Overlay

    private var overlayControls: some View {
        ZStack {
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.7), .clear],
                               startPoint: .top, endPoint: .bottom).frame(height: 120)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.7)],
                               startPoint: .top, endPoint: .bottom).frame(height: 140)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack {
                topBar
                Spacer()
                centerControls
                Spacer()
                bottomBar
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(alignment: .center, spacing: 14) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.white.opacity(0.15), in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(vm.itemTitle)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if !vm.itemMeta.isEmpty {
                    Text(vm.itemMeta)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            Spacer()
            // Zoom reset
            if isZoomed {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                        videoScale = 1.0; baseScale = 1.0
                    }
                    resetHideTimer()
                } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(.white.opacity(0.15), in: Capsule())
                }
            }
        }
    }

    // MARK: - Center Controls

    private var centerControls: some View {
        HStack(spacing: 32) {
            skipButton(systemImage: "gobackward.10") { vm.skip(seconds: -10); resetHideTimer() }
            Button { vm.togglePlayPause(); resetHideTimer() } label: {
                Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 68, height: 68)
                    .background(Color.white, in: Circle())
            }
            skipButton(systemImage: "goforward.30") { vm.skip(seconds: 30); resetHideTimer() }
        }
    }

    private func skipButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(.white.opacity(0.15), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.2), lineWidth: 1))
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        VStack(spacing: 10) {
            Slider(value: Binding(
                get: { Double(vm.position) },
                set: { vm.seek(to: Float($0)); resetHideTimer() }
            ), in: 0...1)
            .tint(.white)

            HStack {
                Text("\(formatTime(vm.currentSeconds)) / \(formatRemaining())")
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                HStack(spacing: 8) {
                    Button {
                        showTracks = true
                        resetHideTimer()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "text.bubble")
                                .font(.system(size: 13, weight: .medium))
                            Text("Tracks")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.white.opacity(0.15), in: Capsule())
                        .overlay(Capsule().stroke(.white.opacity(0.2), lineWidth: 1))
                    }
                    Button {
                        if !vm.isLocal { showQualityPicker = true }
                        resetHideTimer()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: vm.isLocal ? "internaldrive" : "square.3.layers.3d")
                                .font(.system(size: 13, weight: .medium))
                            Text(vm.isLocal ? "Local" : vm.selectedQuality.rawValue)
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(vm.isLocal ? Color.green : .white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.white.opacity(0.15), in: Capsule())
                        .overlay(Capsule().stroke(.white.opacity(0.2), lineWidth: 1))
                    }
                    Button {
                        showStats.toggle()
                        resetHideTimer()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chart.bar")
                                .font(.system(size: 13, weight: .medium))
                            Text("Stats")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .foregroundStyle(showStats ? Color.accentColor : .white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.white.opacity(0.15), in: Capsule())
                        .overlay(Capsule().stroke(.white.opacity(0.2), lineWidth: 1))
                    }
                }
            }
        }
    }

    // MARK: - Tracks Sheet

    private var tracksSheet: some View {
        NavigationStack {
            List {
                if !vm.subtitleTracks.isEmpty {
                    Section("Subtitles") {
                        ForEach(vm.subtitleTracks, id: \.index) { track in
                            Button {
                                vm.setSubtitle(index: track.index)
                                showTracks = false
                            } label: {
                                HStack {
                                    Text(track.name)
                                    Spacer()
                                    if vm.currentSubtitleIndex == track.index {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                }
                if !vm.audioTracks.isEmpty {
                    Section("Audio") {
                        ForEach(vm.audioTracks, id: \.index) { track in
                            Button {
                                vm.setAudio(index: track.index)
                                showTracks = false
                            } label: {
                                HStack {
                                    Text(track.name)
                                    Spacer()
                                    if vm.currentAudioIndex == track.index {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                }
            }
            .navigationTitle("Tracks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showTracks = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Error

    private func errorView(message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44)).foregroundStyle(.yellow)
            Text(message).font(.subheadline).foregroundStyle(.white)
                .multilineTextAlignment(.center).padding(.horizontal, 32)
            Button("Dismiss") { dismiss() }.buttonStyle(.bordered).tint(.white)
        }
    }

    // MARK: - Control Visibility

    private func toggleControls() {
        hideTask?.cancel()
        if showControls { showControls = false } else { showControls = true; scheduleHide() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation { showControls = false }
        }
    }

    private func resetHideTimer() {
        if !showControls { showControls = true }
        scheduleHide()
    }

    // MARK: - Stats HUD

    private var statsHUD: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Playback mode
            let mode = vm.isLocal ? "Local File" : (vm.statsIsTranscoding ? "Transcode" : "Direct Play")
            let modeColor: Color = vm.isLocal ? .green : (vm.statsIsTranscoding ? .orange : .green)
            statsRow("Mode", mode, highlight: modeColor)

            Divider().background(.white.opacity(0.2))

            // Video
            statsRow("Resolution", vm.videoSize == .zero ? "—" : "\(Int(vm.videoSize.width))×\(Int(vm.videoSize.height))")
            statsRow("Video", vm.statsVideoCodec)
            statsRow("Audio", vm.statsAudioCodec)
            statsRow("Container", vm.statsContainer)

            Divider().background(.white.opacity(0.2))

            // Quality & bitrate
            statsRow("Quality", vm.selectedQuality.rawValue)
            statsRow("Bitrate", vm.statsBitrateMbps > 0.01 ? String(format: "%.2f Mbps", vm.statsBitrateMbps) : "—")

        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundStyle(.white)
        .frame(width: 210)
    }

    private func statsRow(_ key: String, _ value: String, highlight: Color? = nil) -> some View {
        HStack(spacing: 6) {
            Text(key)
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 72, alignment: .leading)
            Text(value)
                .foregroundStyle(highlight ?? .white)
        }
    }

    // MARK: - Helpers

    private func formatTime(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        let h = s / 3600; let m = (s % 3600) / 60; let sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }

    private func formatRemaining() -> String {
        "-" + formatTime(max(0, vm.totalSeconds - vm.currentSeconds))
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
