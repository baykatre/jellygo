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
            DispatchQueue.main.async { self?.position = pos }
        }
    }

    func load(item: JellyfinItem, appState: AppState) async {
        self.item = item
        self.appState = appState
        DispatchQueue.main.async { self.isLoading = true; self.error = nil }

        guard !item.isSeries && !item.isSeason else {
            DispatchQueue.main.async { self.error = "Select an episode to play"; self.isLoading = false }
            return
        }
        guard let url = JellyfinAPI.shared.streamURL(
            serverURL: appState.serverURL, itemId: item.id,
            mediaSourceId: item.id, token: appState.token
        ) else {
            DispatchQueue.main.async { self.error = "No playable source found"; self.isLoading = false }
            return
        }

        let media = VLCMedia(url: url)
        if let resumeTicks = item.userData?.playbackPositionTicks, resumeTicks > 0 {
            let seconds = Double(resumeTicks) / 10_000_000
            resumeMs = Int32(resumeTicks / 10_000)
            didSeekToResume = false
            media.addOption(":start-time=\(seconds)")
        }
        player.media = media

        await JellyfinAPI.shared.reportPlaybackStart(
            serverURL: appState.serverURL, itemId: item.id, token: appState.token)

        player.play()
        try? await Task.sleep(for: .milliseconds(800))
        DispatchQueue.main.async { self.isLoading = false; self.isPlaying = self.player.isPlaying }
        startPositionTimer()
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

    @EnvironmentObject private var appState: AppState
    @StateObject private var vm = VLCPlayerViewModel()
    @Environment(\.dismiss) private var dismiss

    @State private var showControls = true
    @State private var hideTask: Task<Void, Never>?
    @State private var showTracks = false
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
        .task { await vm.load(item: item, appState: appState) }
        .onDisappear { vm.stop() }
        .onAppear {
            AppDelegate.orientationLock = .landscape
            PlayerView.rotate(to: .landscapeRight)
            scheduleHide()
        }
        .sheet(isPresented: $showTracks) { tracksSheet }
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
