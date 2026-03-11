import SwiftUI
import MobileVLCKit
import MediaPlayer
import AVFoundation
import os

// MARK: - JellyGoPlayerView

struct JellyGoPlayerView: View {
    let initialItem: JellyfinItem
    var localURL: URL? = nil
    var qualityOverride: VideoQuality? = nil
    @State private var item: JellyfinItem

    init(item: JellyfinItem, localURL: URL? = nil, qualityOverride: VideoQuality? = nil) {
        self.initialItem = item
        self.localURL = localURL
        self.qualityOverride = qualityOverride
        self._item = State(initialValue: item)
    }

    @EnvironmentObject private var appState: AppState
    @StateObject private var vm = VLCPlayerViewModel()
    @StateObject private var subtitleManager = SubtitleManager()
    @Environment(\.dismiss) private var dismiss

    @State private var showOverlay = true
    @State private var hideTask: Task<Void, Never>?

    @State private var isScrubbing = false
    @State private var scrubbedSeconds: Double = 0
    @State private var scrubTranslation: CGPoint = .zero

    // Aspect fill
    @State private var isAspectFilled = true
    @State private var videoScale: CGFloat = 1

    // Brightness / Volume swipe
    @State private var isSwipeActive = false
    @State private var swipeStartBrightness: CGFloat = 0
    @State private var swipeStartVolume: Float = 0
    @State private var adjustMode: AdjustMode?
    @State private var adjustHideTask: Task<Void, Never>?
    private static var currentScreen: UIScreen {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first!.screen
    }

    @State private var brightnessValue: CGFloat = JellyGoPlayerView.currentScreen.brightness
    @State private var volumeValue: Float = 0.5
    @State private var mpVolView: MPVolumeView?
    enum AdjustMode { case brightness, volume }

    // Subtitle delay bar
    @State private var showDelayBar = false
    @State private var showHUD = false

    // Skip accumulator (double-tap)
    @State private var skipAccum: Int = 0
    @State private var skipCommitTask: Task<Void, Never>?
    @State private var skipBounceCount: Int = 0
    @State private var doubleTapSide: DoubleTapSide?
    @State private var doubleTapLocation: CGPoint = .zero
    enum DoubleTapSide { case left, right }

    // Episode list
    @State private var showEpisodeList = false
    @State private var episodeListItems: [JellyfinItem] = []


    private var isSlowScrubbing: Bool {
        isScrubbing && scrubTranslation.y >= 60
    }

    private var shouldDim: Bool {
        showOverlay && !isScrubbing
    }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                // Video area
                ZStack {
                    Color.black.ignoresSafeArea()

                    VLCVideoSurface(player: vm.player)
                        .scaleEffect(videoScale)
                        .opacity(vm.isLoading ? 0 : 1)
                        .ignoresSafeArea()

                    // Dim overlay: 0.5 when overlay visible & not scrubbing
                    Color.black
                        .opacity(shouldDim ? 0.5 : 0)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .simultaneousGesture(
                            SpatialTapGesture(count: 2)
                                .onEnded { val in
                                    let x = val.location.x
                                    let w = geo.size.width
                                    // Only trigger in left 35% or right 35%, ignore middle 30%
                                    guard x < w * 0.35 || x > w * 0.65 else { return }
                                    let isLeft = x < w * 0.35
                                    doubleTapLocation = val.location
                                    accumulateSkip(isLeft ? -10 : 10)
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        doubleTapSide = isLeft ? .left : .right
                                    }
                                }
                        )
                        .onTapGesture(count: 1) {
                            if showEpisodeList { withAnimation(.spring(duration: 0.4, bounce: 0.15)) { showEpisodeList = false } }
                            else if showDelayBar { showDelayBar = false }
                            else { toggleOverlay() }
                        }
                        .animation(.linear(duration: 0.2), value: shouldDim)

                    // Double-tap skip indicator — appears at tap location
                    if doubleTapSide != nil {
                        VStack(spacing: 4) {
                            Image(systemName: doubleTapSide == .left ? "gobackward.10" : "goforward.10")
                                .font(.system(size: 32, weight: .medium))
                            if skipAccum != 0 {
                                Text(skipAccum > 0 ? "+\(skipAccum)s" : "\(skipAccum)s")
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                                    .contentTransition(.numericText(value: Double(skipAccum)))
                            }
                        }
                        .foregroundStyle(.white)
                        .symbolEffect(.bounce, value: skipBounceCount)
                        .position(x: doubleTapLocation.x, y: doubleTapLocation.y - 90)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                        .animation(.smooth(duration: 0.2), value: skipAccum)
                    }

                    // Custom subtitle overlay (independent of video scale)
                    SubtitleOverlayView(manager: subtitleManager)
                        .ignoresSafeArea()

                    if vm.isLoading {
                        // Show backdrop image while loading (local cache first, then server)
                        let activeItem = resolvedItem ?? item
                        let backdropId = activeItem.seriesId ?? activeItem.id
                        GeometryReader { loadGeo in
                            ZStack {
                                if let localURL = DownloadManager.localBackdropURL(itemId: backdropId) {
                                    Image(uiImage: UIImage(contentsOfFile: localURL.path) ?? UIImage())
                                        .resizable().scaledToFill()
                                        .frame(width: loadGeo.size.width, height: loadGeo.size.height)
                                        .clipped()
                                } else if let url = JellyfinAPI.shared.backdropURL(serverURL: appState.serverURL, itemId: backdropId) {
                                    AsyncImage(url: url) { img in
                                        img.resizable().scaledToFill()
                                            .frame(width: loadGeo.size.width, height: loadGeo.size.height)
                                            .clipped()
                                    } placeholder: {
                                        Color.black
                                    }
                                }
                                Color.black.opacity(0.5)
                                VStack(spacing: 12) {
                                    ProgressView().tint(.white).scaleEffect(1.5)
                                    if vm.statsIsTranscoding {
                                        Text(String(localized: "Transcoding", bundle: AppState.currentBundle))
                                            .font(.caption)
                                            .foregroundStyle(.white.opacity(0.7))
                                    }
                                }
                            }
                            .frame(width: loadGeo.size.width, height: loadGeo.size.height)
                        }
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                    }

                    if let err = vm.error {
                        errorView(message: err)
                    }

                    controlsOverlay(geo: geo)

                    // Brightness bar (left)
                    Group {
                        if adjustMode == .brightness {
                            brightnessBar
                                .transition(.move(edge: .leading).combined(with: .opacity))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .padding(.leading, geo.safeAreaInsets.leading + geo.size.width * 0.10)
                    .animation(.spring(duration: 0.4, bounce: 0.15), value: adjustMode)

                    // Volume bar (right)
                    Group {
                        if adjustMode == .volume {
                            volumeBar
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .padding(.trailing, geo.safeAreaInsets.trailing + geo.size.width * 0.10)
                    .animation(.spring(duration: 0.4, bounce: 0.15), value: adjustMode)

                    // Subtitle delay bar (bottom, above progress bar)
                    Group {
                        if showDelayBar {
                            subtitleDelayBar
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.bottom, geo.safeAreaInsets.bottom + geo.size.height * 0.04 + 60)
                    .padding(.trailing, geo.safeAreaInsets.trailing + geo.size.width * 0.05)
                    .animation(.spring(duration: 0.4, bounce: 0.15), value: showDelayBar)

                    // Stats HUD (bottom-left, always visible when enabled)
                    if showHUD {
                        statsHUD
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                            .padding(.bottom, geo.safeAreaInsets.bottom + 60)
                            .padding(.leading, geo.safeAreaInsets.leading + 52)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                            .animation(.easeInOut(duration: 0.2), value: showHUD)
                    }
                }
                .frame(width: showEpisodeList ? geo.size.width * 0.6 : geo.size.width)
                .clipShape(RoundedRectangle(cornerRadius: showEpisodeList ? 16 : 0))

                // Episode list panel
                if showEpisodeList {
                    episodeListPanel(geo: geo)
                        .frame(width: geo.size.width * 0.4)
                        .transition(.move(edge: .trailing))
                }
            }
            .contentShape(Rectangle())
            // 1) Pinch: aspect fill toggle (Acts during gesture, not on end)
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { val in
                        if val > 1.15, !isAspectFilled {
                            isAspectFilled = true
                            applyAspectFill(true)
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        } else if val < 0.85, isAspectFilled {
                            isAspectFilled = false
                            applyAspectFill(false)
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                    }
            )
            // 2) Vertical swipe: brightness (left) / volume (right)
            .simultaneousGesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { val in
                        guard !showEpisodeList else { return }
                        let h = abs(val.translation.width)
                        let v = abs(val.translation.height)
                        if !isSwipeActive {
                            guard v > h * 1.2 else { return }
                            isSwipeActive = true
                            // If boost is active, start from effective brightness (1 + boost fraction)
                            swipeStartBrightness = vm.brightnessBoost > 1.0
                                ? 1.0 + CGFloat(vm.brightnessBoost - 1.0) / 0.5
                                : Self.currentScreen.brightness
                            let sysVol = AVAudioSession.sharedInstance().outputVolume
                            // If boost is active, start from effective volume (1 + boost fraction)
                            swipeStartVolume = vm.volumeBoost > 100
                                ? 1.0 + Float(vm.volumeBoost - 100) / 100.0
                                : sysVol
                            volumeValue = swipeStartVolume
                            brightnessValue = swipeStartBrightness
                        }
                        if val.startLocation.x < geo.size.width / 2 {
                            adjustMode = .brightness
                            let delta = -val.translation.height / geo.size.height
                            let raw = swipeStartBrightness + delta
                            if raw <= 1 {
                                // Normal system brightness range 0–1
                                let bri = max(0, min(1, raw))
                                Self.currentScreen.brightness = bri; brightnessValue = bri
                                if vm.brightnessBoost > 1.0 { vm.setBrightnessBoost(1.0) }
                            } else {
                                // Boost range: system stays at 1, VLC filter goes 1.0–1.5
                                Self.currentScreen.brightness = 1; brightnessValue = 1
                                let boost = Float(1.0 + min(0.5, max(0, (raw - 1) * 0.5)))
                                vm.setBrightnessBoost(boost)
                            }
                        } else {
                            adjustMode = .volume
                            // Use 1.0× sensitivity so a full-screen swipe covers ~1.0 range (enough for 0→2)
                            let delta = -val.translation.height / geo.size.height
                            let raw = Float(swipeStartVolume) + Float(delta)
                            if raw <= 1 {
                                // Normal system volume range 0–1
                                let vol = max(0, min(1, raw))
                                setSystemVolume(vol)
                                if vm.volumeBoost > 100 { vm.setVolumeBoost(100) }
                            } else {
                                // Boost range: system stays at 1, VLC goes 100–200
                                setSystemVolume(1)
                                let boost = Int32(100 + min(100, max(0, (raw - 1) * 100)))
                                vm.setVolumeBoost(boost)
                            }
                        }
                        adjustHideTask?.cancel()
                    }
                    .onEnded { _ in
                        isSwipeActive = false
                        adjustHideTask = Task {
                            try? await Task.sleep(for: .milliseconds(1400))
                            guard !Task.isCancelled else { return }
                            withAnimation { adjustMode = nil }
                        }
                    }
            )
            .onChange(of: vm.videoSize) { _, _ in
                if isAspectFilled { videoScale = aspectFillScale }
            }
            // Sync custom subtitles with playback
            .onChange(of: vm.position) { _, _ in
                subtitleManager.update(currentSeconds: vm.currentSeconds)
            }
        .ignoresSafeArea()
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .statusBarHidden(true)
        .animation(.linear(duration: 0.1), value: isScrubbing)
        .animation(.bouncy(duration: 0.25), value: showOverlay)
        .onChange(of: vm.isLoading) { _, loading in
            if loading {
                hideTask?.cancel()
                showOverlay = true
            } else {
                scheduleHide()
            }
        }
        .background(Color.black.ignoresSafeArea())
        .animation(.spring(duration: 0.4, bounce: 0.15), value: showEpisodeList)
        .task {
            vm.disableVLCSubtitles = true
            // Start subtitle fetch and episode list in parallel with video load
            async let subtitleTask: () = autoSelectSubtitle()
            async let episodeTask: () = loadEpisodeList()
            if let url = localURL {
                await vm.loadLocal(url: url, item: item, appState: appState)
            } else {
                await vm.load(item: item, appState: appState, qualityOverride: qualityOverride)
            }
            // Ensure subtitle fetch completes before we consider player ready
            _ = await (subtitleTask, episodeTask)
        }
        .onDisappear { vm.stop() }
        .onAppear {
            // Orientation already set before fullScreenCover presentation
            scheduleHide()
            brightnessValue = Self.currentScreen.brightness
            volumeValue = AVAudioSession.sharedInstance().outputVolume
            // Init MPVolumeView off-screen in background to avoid first-tap stutter
            if mpVolView == nil {
                let v = MPVolumeView(frame: .init(x: -1000, y: -1000, width: 1, height: 1))
                v.alpha = 0.01
                UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .first?.windows.first?.addSubview(v)
                mpVolView = v
            }
        }
    }

    // MARK: - Controls Overlay

    private func controlsOverlay(geo: GeometryProxy) -> some View {
        ZStack {
            VStack {
                sfNavigationBar
                    .sfVisible(!isScrubbing && (showOverlay || vm.isLoading))
                    .offset(y: (showOverlay || vm.isLoading) ? 0 : -20)
                    .padding(.top, geo.safeAreaInsets.top + geo.size.height * 0.03)
                    .padding(.leading, geo.safeAreaInsets.leading + geo.size.width * 0.05)
                    .padding(.trailing, geo.safeAreaInsets.trailing + geo.size.width * 0.05)

                Spacer().allowsHitTesting(false)

                sfPlaybackProgress
                    .sfVisible(showOverlay && !vm.isLoading)
                    .padding(.bottom, geo.safeAreaInsets.bottom + geo.size.height * 0.04)
                    .padding(.leading, geo.safeAreaInsets.leading + geo.size.width * 0.05)
                    .padding(.trailing, geo.safeAreaInsets.trailing + geo.size.width * 0.05)
                    .background(alignment: .top) {
                        Color.black
                            .mask(LinearGradient(
                                stops: [.init(color: .clear, location: 0),
                                        .init(color: .black.opacity(0.5), location: 1)],
                                startPoint: .top, endPoint: .bottom))
                            .sfVisible(isScrubbing)
                            .frame(height: 120)
                    }
            }

            sfPlaybackButtons
                .sfVisible(!isScrubbing && showOverlay && !vm.isLoading)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Navigation Bar

    private var sfNavigationBar: some View {
        HStack(alignment: .center) {
            sfNavButton("xmark") { vm.stop(); dismiss() }

            mediaInfoCard
                .contentShape(RoundedRectangle(cornerRadius: 14))
                .onTapGesture {
                    guard item.type == "Episode" else { return }
                    withAnimation(.spring(duration: 0.4, bounce: 0.15)) {
                        showEpisodeList.toggle()
                    }
                    if showEpisodeList { stopTimer() } else { pokeTimer() }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                sfQualityButton

                if item.type == "Episode" {
                    sfGlassButton("rectangle.stack.fill") {
                        withAnimation(.spring(duration: 0.4, bounce: 0.15)) {
                            showEpisodeList.toggle()
                        }
                        if showEpisodeList { stopTimer() } else { pokeTimer() }
                    }
                }
            }
        }
        .background { Color.clear.allowsHitTesting(true) }
    }

    private var localQualityText: String {
        if let dl = DownloadManager.shared.downloads.first(where: { $0.id == item.id }) {
            return dl.quality
        }
        return "Direct"
    }

    private var sfQualityLabel: some View {
        HStack(spacing: 4) {
            Text(localURL != nil ? localQualityText : vm.selectedQuality.rawValue)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
            Circle()
                .fill(vm.statsIsTranscoding ? Color.orange.opacity(0.7) : ((vm.selectedQuality == .direct || (localURL != nil && localQualityText == "Direct")) ? Color.green.opacity(0.7) : Color.white.opacity(0.3)))
                .frame(width: 5, height: 5)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var sfQualityButton: some View {
        if localURL != nil {
            sfQualityLabel
                .glassEffect(.regular.tint(Color.black.opacity(0.05)), in: .capsule)
        } else {
            Menu {
                ForEach(VideoQuality.allCases) { q in
                    Button {
                        Task {
                            subtitleManager.reset()
                            await vm.changeQuality(to: q)
                            await autoSelectSubtitle()
                        }
                    } label: {
                        if vm.selectedQuality == q {
                            Label(q.rawValue, systemImage: "checkmark")
                        } else {
                            Text(q.rawValue)
                        }
                    }
                }
            } label: {
                sfQualityLabel
                    .glassEffect(.regular.tint(Color.black.opacity(0.05)), in: .capsule)
            }
            .buttonStyle(.plain)
            .menuStyle(.borderlessButton)
        }
    }

    private func sfGlassButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            pokeTimer()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .padding(12)
                .contentShape(Circle())
        }
        .glassEffect(.regular.tint(Color.black.opacity(0.15)), in: .circle)
        .buttonStyle(.plain)
    }

    /// Standalone nav bar button
    private func sfNavButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            pokeTimer()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .padding(8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }


    // MARK: - Playback Buttons

    private func accumulateSkip(_ seconds: Int) {
        skipAccum += seconds
        skipBounceCount += 1
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        skipCommitTask?.cancel()
        skipCommitTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            let total = skipAccum
            vm.skip(seconds: total)
            // Keep showing the total for a moment before fading
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.5)) { skipAccum = 0; doubleTapSide = nil }
            skipBounceCount = 0
        }
    }

    private func switchToEpisode(_ episode: JellyfinItem) {
        withAnimation(.spring(duration: 0.4, bounce: 0.15)) {
            showEpisodeList = false
            item = episode
        }
        Task {
            vm.stop()
            subtitleManager.reset()
            async let _ = autoSelectSubtitle()
            if localURL != nil,
               let dl = DownloadManager.shared.downloads.first(where: { $0.id == episode.id }),
               let dlURL = dl.localURL,
               FileManager.default.fileExists(atPath: dlURL.path) {
                await vm.loadLocal(url: dlURL, item: episode, appState: appState)
            } else {
                await vm.load(item: episode, appState: appState)
            }
        }
    }

    private var canGoPrev: Bool {
        guard let idx = episodeListItems.firstIndex(where: { $0.id == item.id }) else { return false }
        return idx > 0
    }
    private var canGoNext: Bool {
        guard let idx = episodeListItems.firstIndex(where: { $0.id == item.id }) else { return false }
        return idx < episodeListItems.count - 1
    }

    private var isEpisode: Bool { item.type == "Episode" }

    private var sfPlaybackButtons: some View {
        HStack(spacing: 48) {
            // Previous episode (only for episodes)
            if isEpisode {
                Button {
                    guard let idx = episodeListItems.firstIndex(where: { $0.id == item.id }),
                          idx > 0 else { return }
                    switchToEpisode(episodeListItems[idx - 1])
                } label: {
                    Label("Previous", systemImage: "backward.fill")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 30, weight: .regular))
                        .padding(12)
                }
                .opacity(canGoPrev ? 1 : 0.3)
                .disabled(!canGoPrev)
            }

            // Play / Pause
            Button { vm.togglePlayPause() } label: {
                Group {
                    if vm.isPlaying {
                        Label("Pause", systemImage: "pause.fill")
                    } else {
                        Label("Play", systemImage: "play.fill")
                    }
                }
                .font(.system(size: 44, weight: .bold))
                .labelStyle(.iconOnly)
                .padding(20)
                .contentShape(Circle())
            }

            // Next episode (only for episodes)
            if isEpisode {
                Button {
                    guard let idx = episodeListItems.firstIndex(where: { $0.id == item.id }),
                          idx < episodeListItems.count - 1 else { return }
                    switchToEpisode(episodeListItems[idx + 1])
                } label: {
                    Label("Next", systemImage: "forward.fill")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 30, weight: .regular))
                        .padding(12)
                }
                .opacity(canGoNext ? 1 : 0.3)
                .disabled(!canGoNext)
            }
        }
        .buttonStyle(JGOverlayButtonStyle(onPressed: { p in
            if p { stopTimer() } else { pokeTimer() }
        }))
    }

    // MARK: - Playback Progress

    @State private var sliderSize: CGSize = .zero

    private var sfPlaybackProgress: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(spacing: 5) {
                sfCapsuleSlider
                    .background(GeometryReader { g in
                        Color.clear.onAppear { sliderSize = g.size }
                            .onChange(of: g.size) { _, s in sliderSize = s }
                    })

                sfSplitTimestamp
                    .offset(y: isScrubbing ? 5 : 0)
                    .frame(maxWidth: isScrubbing ? nil : max(0, sliderSize.width - 32))
            }
            .frame(maxWidth: .infinity)

            sfMoreMenu
                .sfVisible(!isScrubbing)
        }
        .frame(maxWidth: .infinity)
        .animation(.bouncy(duration: 0.4, extraBounce: 0.1), value: isScrubbing)
        .overlay(alignment: .bottom) {
            if isSlowScrubbing {
                HStack {
                    Image(systemName: "backward.fill")
                    Text(String(localized: "Slow Scrubbing", bundle: AppState.currentBundle))
                    Image(systemName: "forward.fill")
                }.font(.caption).offset(y: 32)
                    .transition(.opacity.animation(.linear(duration: 0.1)))
            }
        }
    }

    // MARK: - Capsule Slider

    @State private var sliderContentSize: CGSize = .zero
    @State private var dragStartLocation: CGPoint = .zero
    @State private var currentDampingStart: CGPoint = .zero
    @State private var currentDampingValue: Double = 0
    @State private var currentDamping: Double = 1.0
    @State private var needsSetStart = true

    private var valueDamping: Double { isSlowScrubbing ? 0.1 : 1.0 }

    private var displayProgress: Double {
        let total = max(1, vm.totalSeconds)
        return isScrubbing
            ? max(0, min(1, scrubbedSeconds / total))
            : max(0, min(1, vm.currentSeconds / total))
    }

    private var sfCapsuleSlider: some View {
        JGProgressBar(progress: displayProgress)
            .frame(height: isScrubbing ? 20 : 10)
            .foregroundStyle(vm.isLoading ? AnyShapeStyle(Color.gray) : AnyShapeStyle(.primary))
            .background(GeometryReader { g in
                Color.clear.onAppear { sliderContentSize = g.size }
                    .onChange(of: g.size) { _, s in sliderContentSize = s }
            })
            .overlay {
                Color.clear
                    .frame(height: sliderContentSize.height + 30)
                    .contentShape(Rectangle())
                    .highPriorityGesture(
                        DragGesture(coordinateSpace: .global)
                            .onChanged { val in
                                if needsSetStart {
                                    dragStartLocation = val.location
                                    needsSetStart = false
                                    currentDamping = valueDamping
                                    currentDampingStart = val.location
                                    currentDampingValue = isScrubbing ? scrubbedSeconds : vm.currentSeconds
                                }
                                if valueDamping != currentDamping {
                                    currentDamping = valueDamping
                                    currentDampingStart = val.location
                                    currentDampingValue = scrubbedSeconds
                                }
                                scrubTranslation = CGPoint(
                                    x: dragStartLocation.x - val.location.x,
                                    y: dragStartLocation.y - val.location.y)
                                let dx = (currentDampingStart.x - val.location.x) * currentDamping
                                let total = max(1, vm.totalSeconds)
                                let newSec = currentDampingValue - (dx / sliderContentSize.width) * total
                                scrubbedSeconds = max(0, min(total, newSec))
                                if scrubbedSeconds == 0 || scrubbedSeconds >= total {
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                }
                            }
                    )
                    .onLongPressGesture(minimumDuration: 0.01, perform: {}) { pressing in
                        if pressing {
                            scrubbedSeconds = vm.currentSeconds
                            isScrubbing = true
                            needsSetStart = true
                            stopTimer()
                        } else {
                            vm.seek(to: Float(scrubbedSeconds / max(1, vm.totalSeconds)))
                            scrubTranslation = .zero
                            isScrubbing = false
                            pokeTimer()
                        }
                    }
            }
            .frame(height: 10)
            .disabled(vm.isLoading)
            .animation(.linear(duration: 0.05), value: scrubbedSeconds)
            .onChange(of: isSlowScrubbing) { _, _ in
                guard isScrubbing else { return }
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            }
    }

    // MARK: - Split Timestamp

    @State private var showTotalTime = false

    private var sfSplitTimestamp: some View {
        let cur = isScrubbing ? scrubbedSeconds : vm.currentSeconds
        let total = vm.totalSeconds
        let rem = max(0, total - cur)

        return HStack {
            Button { showTotalTime.toggle() } label: {
                HStack(spacing: 2) {
                    Text(fmtTime(cur))
                    Group { Text("/"); Text(fmtTime(vm.currentSeconds)) }
                        .foregroundStyle(.secondary).sfVisible(isScrubbing)
                }
            }.foregroundStyle(.primary, .secondary)

            Spacer()

            Button { showTotalTime.toggle() } label: {
                HStack(spacing: 2) {
                    Group { Text(fmtTime(max(0, total - vm.currentSeconds))); Text("/") }
                        .foregroundStyle(.secondary).sfVisible(isScrubbing)
                    Text(showTotalTime ? fmtTime(total) : "-\(fmtTime(rem))")
                }
            }.foregroundStyle(.primary, .secondary)
        }
        .monospacedDigit().font(.caption2).lineLimit(1)
        .foregroundStyle(isScrubbing ? .primary : .secondary, .secondary)
    }

    // MARK: - Stats HUD

    private var statsHUD: some View {
        let isLocal = localURL != nil
        return VStack(alignment: .leading, spacing: 3) {
            // ── Source ──
            Text(isLocal ? "LOCAL FILE" : appState.serverURL)
                .foregroundStyle(.gray)

            // ── Media info ──
            Text("\(vm.statsVideoCodec) \(vm.statsVideoProfile) \(vm.statsVideoResolution) \(vm.statsVideoBitDepth) \(vm.statsVideoRange)")
            Text("\(vm.statsAudioCodec) \(vm.statsAudioLabel)")
                .foregroundStyle(.white.opacity(0.7))

            // ── Playback ──
            HStack(spacing: 4) {
                if isLocal {
                    Text("LOCAL PLAY").foregroundStyle(.cyan).bold()
                } else if vm.statsIsTranscoding {
                    Text("TRANSCODE").foregroundStyle(.orange).bold()
                } else {
                    Text("DIRECT PLAY").foregroundStyle(.green).bold()
                }
                if !vm.statsContainer.isEmpty && vm.statsContainer != "—" {
                    Text("· \(vm.statsContainer)").foregroundStyle(.white.opacity(0.5))
                }
            }
            if !isLocal && vm.statsIsTranscoding {
                if vm.statsIsManualQuality {
                    Text(String(localized: "Reason: Manual quality (\(vm.selectedQuality.rawValue))", bundle: Self.bundle))
                        .foregroundStyle(.orange.opacity(0.9))
                } else if !vm.statsTranscodeReasons.isEmpty {
                    Text("\(String(localized: "Reason", bundle: Self.bundle)): \(vm.statsTranscodeReasons.map { Self.readableReason($0) }.joined(separator: ", "))")
                        .foregroundStyle(.orange.opacity(0.9))
                }
            }

            // ── Network / Disk ──
            HStack(spacing: 6) {
                if isLocal {
                    Circle().fill(.cyan).frame(width: 6, height: 6)
                    Text("Disk").foregroundStyle(.cyan)
                } else {
                    let quality = Self.networkQuality(
                        inputBitrate: vm.statsBitrateMbps,
                        demuxBitrate: vm.statsDemuxBitrateMbps,
                        dropped: vm.statsDroppedFrames,
                        decoded: vm.statsDecodedFrames
                    )
                    Circle().fill(quality.color).frame(width: 6, height: 6)
                    Text(quality.label).foregroundStyle(quality.color)
                    if vm.statsBitrateMbps > 0 {
                        Text(String(format: "%.1f Mbps", vm.statsBitrateMbps))
                    }
                }
                Text("· \(Self.formatBytes(vm.statsReadBytes))")
                    .foregroundStyle(.white.opacity(0.6))
            }
            if vm.statsDroppedFrames > 0 {
                Text("Dropped: \(vm.statsDroppedFrames) frames")
                    .foregroundStyle(.red.opacity(0.8))
            }
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(.white)
        .padding(8)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
    }

    /// Network quality based on current input bitrate.
    /// inputBitrate = how fast data arrives from network. 0 means buffer is full (good) or no data (bad).
    /// demuxBitrate = how fast player consumes data. If input < demux consistently, buffering will happen.
    private static func networkQuality(inputBitrate: Double, demuxBitrate: Double, dropped: Int32, decoded: Int32) -> (label: String, color: Color) {
        // No data yet
        let b = AppState.currentBundle
        if decoded == 0 { return (String(localized: "Connecting", bundle: b), .yellow) }
        let dropRate = decoded > 100 ? Double(dropped) / Double(decoded) : 0
        if dropRate > 0.03 { return (String(localized: "Poor", bundle: b), .red) }
        if demuxBitrate > 0 && inputBitrate > 0 && inputBitrate < demuxBitrate * 0.5 {
            return (String(localized: "Slow", bundle: b), .orange)
        }
        if dropRate > 0.005 { return (String(localized: "Fair", bundle: b), .yellow) }
        return (String(localized: "Good", bundle: b), .green)
    }

    private static func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024
        if kb < 1024 { return String(format: "%.0f KB", kb) }
        let mb = kb / 1024
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        let gb = mb / 1024
        return String(format: "%.2f GB", gb)
    }

    private static let bundle = AppState.currentBundle
    private static func readableReason(_ reason: String) -> String {
        switch reason {
        case "VideoCodecNotSupported": return String(localized: "Video codec not supported", bundle: bundle)
        case "AudioCodecNotSupported": return String(localized: "Audio codec not supported", bundle: bundle)
        case "ContainerNotSupported": return String(localized: "Container not supported", bundle: bundle)
        case "VideoBitDepthNotSupported": return String(localized: "Bit depth not supported", bundle: bundle)
        case "VideoRangeTypeNotSupported": return String(localized: "HDR → SDR conversion", bundle: bundle)
        case "VideoProfileNotSupported": return String(localized: "Video profile not supported", bundle: bundle)
        case "VideoLevelNotSupported": return String(localized: "Video level not supported", bundle: bundle)
        case "AudioProfileNotSupported": return String(localized: "Audio profile not supported", bundle: bundle)
        case "ContainerBitrateExceedsLimit": return String(localized: "Bitrate limit exceeded", bundle: bundle)
        case "VideoBitrateNotSupported": return String(localized: "Video bitrate too high", bundle: bundle)
        case "AudioBitrateNotSupported": return String(localized: "Audio bitrate too high", bundle: bundle)
        case "AudioChannelsNotSupported": return String(localized: "Audio channels not supported", bundle: bundle)
        case "SubtitleCodecNotSupported": return String(localized: "Subtitle codec not supported", bundle: bundle)
        case "DirectPlayError": return String(localized: "Direct play error", bundle: bundle)
        case "VideoResolutionNotSupported": return String(localized: "Resolution not supported", bundle: bundle)
        case "AudioSampleRateNotSupported": return String(localized: "Sample rate not supported", bundle: bundle)
        default: return reason
        }
    }

    // MARK: - More Menu (native Menu with accordion sub-menus)

    private var sfMoreMenu: some View {
        let audioStreams = (resolvedItem ?? item).mediaStreams?.filter(\.isAudio) ?? []
        let vlcAudioTracks = vm.audioTracks
        // Map VLC tracks to clean names using Jellyfin mediaStreams (matched by order)
        let cleanAudio: [JGAudioTrack] = vlcAudioTracks.enumerated().map { i, t in
            // VLC track 0 is usually "Disable", skip it for matching
            let jellyfinIdx = t.index == -1 ? nil : (i < audioStreams.count ? audioStreams[i] : nil)
            let name = jellyfinIdx?.languageName ?? t.name
            return JGAudioTrack(index: t.index, name: name)
        }
        // Offline: only show subtitles that have local files on disk
        let allSubs = (resolvedItem ?? item).mediaStreams?.filter(\.isSubtitle) ?? []
        let availableSubs: [JellyfinMediaStream] = localURL != nil
            ? allSubs.filter { Self.findLocalSubtitle(itemId: item.id, stream: $0) != nil }
            : allSubs
        return JGMoreMenuView(
            subtitleStreams: availableSubs,
            audioTracks: cleanAudio,
            currentSubIdx: vm.currentSubtitleIndex,
            currentAudioIdx: vm.currentAudioIndex,
            currentQuality: vm.selectedQuality,
            subtitleDelay: vm.subtitleDelaySecs,
            onSubtitleChanged: { selectSubtitle(index: $0) },
            onAudioChanged: { vm.setAudio(index: $0) },
            onQualityChanged: { q in Task {
                subtitleManager.reset()
                await vm.changeQuality(to: q)
                await autoSelectSubtitle()
            } },
            onDelayChanged: { vm.setSubtitleDelay($0); subtitleManager.delaySecs = vm.subtitleDelaySecs },
            onShowDelayBar: { showDelayBar = true },
            showHUD: showHUD,
            onToggleHUD: { showHUD.toggle() },
            onPressed: { p in if p { stopTimer() } else { pokeTimer() } }
        ).equatable()
    }

    // MARK: - Episode List Panel

    private func episodeListPanel(geo: GeometryProxy) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                if let se = item.parentIndexNumber {
                    Text("Season \(se)")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                }
                Spacer()
                Button {
                    withAnimation(.spring(duration: 0.4, bounce: 0.15)) {
                        showEpisodeList = false
                    }
                    pokeTimer()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, geo.safeAreaInsets.top + 12)
            .padding(.bottom, 10)

            // Episode list
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(episodeListItems) { episode in
                            episodeRow(episode: episode)
                                .id(episode.id)
                                .onTapGesture {
                                    guard episode.id != item.id else {
                                        withAnimation(.spring(duration: 0.4, bounce: 0.15)) { showEpisodeList = false }
                                        return
                                    }
                                    withAnimation(.spring(duration: 0.4, bounce: 0.15)) {
                                        showEpisodeList = false
                                        item = episode
                                    }
                                    Task {
                                        vm.stop()
                                        subtitleManager.reset()
                                        async let _ = autoSelectSubtitle()
                                        if localURL != nil,
                                           let dl = DownloadManager.shared.downloads.first(where: { $0.id == episode.id }),
                                           let dlURL = dl.localURL,
                                           FileManager.default.fileExists(atPath: dlURL.path) {
                                            await vm.loadLocal(url: dlURL, item: episode, appState: appState)
                                        } else {
                                            await vm.load(item: episode, appState: appState)
                                        }
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, geo.safeAreaInsets.bottom + 16)
                }
                .onAppear {
                    proxy.scrollTo(item.id, anchor: .center)
                }
            }
        }
        .background(Color.black.opacity(0.95))
    }

    private func episodeRow(episode: JellyfinItem) -> some View {
        let isCurrent = episode.id == item.id
        let thumbURL: URL? = {
            if let cached = DownloadManager.localPosterURL(itemId: episode.id) {
                return cached
            }
            return JellyfinAPI.shared.imageURL(
                serverURL: appState.serverURL,
                itemId: episode.id,
                imageType: "Primary",
                maxWidth: 300
            )
        }()

        return HStack(alignment: .top, spacing: 10) {
            // Thumbnail
            ZStack(alignment: .bottomLeading) {
                AsyncImage(url: thumbURL) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().aspectRatio(contentMode: .fill)
                    default:
                        Color.white.opacity(0.1)
                    }
                }
                .frame(width: 96, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isCurrent ? Color.accentColor : .clear, lineWidth: 2)
                )

                // Progress bar
                if let pos = episode.userData?.resumePositionSeconds,
                   let ticks = episode.runTimeTicks, ticks > 0 {
                    let progress = min(pos / (Double(ticks) / 10_000_000), 1.0)
                    GeometryReader { g in
                        VStack {
                            Spacer()
                            Capsule().fill(.white)
                                .frame(width: (g.size.width - 8) * progress, height: 2)
                                .padding(.horizontal, 4)
                                .padding(.bottom, 3)
                        }
                    }
                    .frame(width: 96, height: 54)
                }

                // Watched badge
                if episode.userData?.played == true {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.white)
                        .background(Color.green, in: Circle())
                        .offset(x: 80, y: -40)
                }
            }

            // Info
            VStack(alignment: .leading, spacing: 3) {
                Text(episode.name)
                    .font(.system(size: 12, weight: isCurrent ? .bold : .medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                HStack(spacing: 4) {
                    if let ep = episode.indexNumber {
                        Text("E\(ep)")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(isCurrent ? Color.accentColor : .white.opacity(0.5))
                    }
                    if let ticks = episode.runTimeTicks {
                        let mins = Int(ticks / 600_000_000)
                        Text("\u{00B7} \(mins) min")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                }
                if let overview = episode.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func loadEpisodeList() async {
        guard item.type == "Episode",
              let seriesId = item.seriesId else { return }

        // Try API first (even for downloaded episodes, if online)
        if NetworkMonitor.shared.isConnected {
            // fall through to online fetch below
        } else if localURL != nil {
            // Offline fallback: load only downloaded episodes
            let downloaded = DownloadManager.shared.downloads
                .filter { $0.seriesId == seriesId && $0.seasonNumber == item.parentIndexNumber }
                .sorted { ($0.episodeNumber ?? 0) < ($1.episodeNumber ?? 0) }
            episodeListItems = downloaded.map { $0.toJellyfinItem() }
            return
        }

        // Online: fetch from API
        do {
            let seasonsResp = try await JellyfinAPI.shared.getItems(
                serverURL: appState.serverURL,
                userId: appState.userId,
                token: appState.token,
                parentId: seriesId,
                itemTypes: ["Season"],
                sortBy: "IndexNumber",
                sortOrder: "Ascending",
                limit: 100
            )
            if let currentSeason = seasonsResp.items.first(where: { $0.indexNumber == item.parentIndexNumber }) {
                let epsResp = try await JellyfinAPI.shared.getItems(
                    serverURL: appState.serverURL,
                    userId: appState.userId,
                    token: appState.token,
                    parentId: currentSeason.id,
                    itemTypes: ["Episode"],
                    sortBy: "IndexNumber",
                    sortOrder: "Ascending",
                    limit: 200
                )
                episodeListItems = epsResp.items
            }
        } catch {
            Logger(subsystem: "JellyGo", category: "JellyGoPlayerView").error("loadEpisodeList failed: \(error)")
        }
    }

    // MARK: - Media Info Card

    private var mediaInfoCard: some View {
        let isEpisode = item.type == "Episode"
        let logoId = isEpisode ? (item.seriesId ?? item.id) : item.id
        let logoURL: URL? = DownloadManager.localLogoURL(itemId: logoId)
            ?? JellyfinAPI.shared.logoURL(serverURL: appState.serverURL, itemId: logoId, maxWidth: 300)

        return HStack(spacing: 12) {
            AsyncImage(url: logoURL) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().aspectRatio(contentMode: .fit)
                default:
                    // Fallback: show name if no logo
                    Text(isEpisode ? (item.seriesName ?? item.name) : item.name)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: 100, maxHeight: 40)

            if isEpisode {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let se = item.parentIndexNumber, let ep = item.indexNumber {
                        Text("S\(se) \u{00B7} E\(ep)")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
            } else {
                if let year = item.productionYear {
                    Text(String(year))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .glassEffect(.regular.tint(Color.black.opacity(0.15)), in: .rect(cornerRadius: 14))
    }

    // MARK: - Subtitle Delay Bar

    @State private var delayDragStart: Double = 0

    private var subtitleDelayBar: some View {
        HStack(spacing: 14) {
            Image(systemName: "timer")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))

            // Horizontal slider track
            GeometryReader { geo in
                let range: Double = 20 // -10 to +10
                let pct = (vm.subtitleDelaySecs + 10) / range
                let barW = geo.size.width

                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.15))
                    Capsule().fill(.white)
                        .frame(width: max(4, barW * CGFloat(pct)))
                }
                .frame(height: 6)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .highPriorityGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { val in
                            let frac = val.location.x / barW
                            let clamped = max(0, min(1, frac))
                            let newVal = (clamped * range) - 10
                            let snapped = (newVal * 10).rounded() / 10
                            vm.setSubtitleDelay(snapped)
                            subtitleManager.delaySecs = vm.subtitleDelaySecs
                        }
                )
            }
            .frame(width: 220, height: 36)

            Text(vm.subtitleDelaySecs == 0
                 ? "0s"
                 : String(format: "%+.1fs", vm.subtitleDelaySecs))
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .frame(width: 50, alignment: .center)
                .contentTransition(.numericText())
                .animation(.smooth(duration: 0.15), value: vm.subtitleDelaySecs)

            Button {
                vm.setSubtitleDelay(0)
                subtitleManager.delaySecs = 0
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(vm.subtitleDelaySecs != 0 ? 0.8 : 0.2))
            }
            .disabled(vm.subtitleDelaySecs == 0)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture { }
        .glassEffect(in: .rect(cornerRadius: 18))
    }

    // MARK: - Brightness Bar (Left)

    private var brightnessBar: some View {
        let isBoost = vm.brightnessBoost > 1.0
        let sysZone: CGFloat = 0.75
        let boostZone: CGFloat = 0.25
        let boostFrac = CGFloat(max(0, vm.brightnessBoost - 1.0)) / 0.5
        let barHeight: CGFloat = 140 + 30 * boostFrac
        let sysBri = CGFloat(min(1, max(0, brightnessValue)))
        return VStack(spacing: 10) {
            Image(systemName: briIcon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(isBoost ? (vm.brightnessBoost > 1.3 ? .orange : .yellow) : .white.opacity(0.6))
                .contentTransition(.symbolEffect(.replace))

            GeometryReader { geo in
                let barH = geo.size.height
                let sysH = barH * sysZone
                let normalFillH = sysH * sysBri
                let boostFillH = barH * boostZone * boostFrac
                let fillH = isBoost ? sysH + boostFillH : normalFillH
                ZStack(alignment: .bottom) {
                    Capsule().fill(.white.opacity(0.15))
                        .frame(width: 6)
                    // 100% marker dot
                    Circle().fill(.white.opacity(0.3))
                        .frame(width: 4, height: 4)
                        .offset(y: -(sysH - 2))
                    // Unified fill capsule with gradient for boost zone
                    Capsule()
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: .white, location: 0),
                                    .init(color: .white, location: isBoost ? sysH / max(1, fillH) : 1),
                                    .init(color: .yellow, location: isBoost ? sysH / max(1, fillH) + 0.01 : 1),
                                    .init(color: .orange, location: 1)
                                ],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                        .frame(width: 6, height: max(4, fillH))
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { val in
                            var tx = Transaction()
                            tx.disablesAnimations = true
                            withTransaction(tx) {
                                let frac = 1.0 - (val.location.y / barH)
                                if frac <= sysZone {
                                    let bri = max(0, min(1, frac / sysZone))
                                    Self.currentScreen.brightness = bri
                                    brightnessValue = bri
                                    if vm.brightnessBoost > 1.0 { vm.setBrightnessBoost(1.0) }
                                } else {
                                    Self.currentScreen.brightness = 1
                                    brightnessValue = 1
                                    let bf = (frac - sysZone) / boostZone
                                    vm.setBrightnessBoost(Float(1.0 + min(0.5, max(0, bf * 0.5))))
                                }
                            }
                        }
                )
            }
            .frame(width: 36, height: barHeight)

            Text("\(Int(vm.brightnessBoost * 100))%")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(vm.brightnessBoost > 1.3 ? .orange : .yellow)
                .opacity(isBoost ? 1 : 0)
                .frame(height: isBoost ? nil : 0)
        }
        .animation(.easeInOut(duration: 0.3), value: vm.brightnessBoost)
        .animation(.smooth(duration: 0.15), value: brightnessValue)
        .padding(.horizontal, 2).padding(.vertical, 14)
        .glassEffect(in: .rect(cornerRadius: 16))
    }

    // MARK: - Volume Bar (Right)

    private var volumeBar: some View {
        let isBoost = vm.volumeBoost > 100
        let sysZone: CGFloat = 0.75
        let boostZone: CGFloat = 0.25
        let boostFrac = CGFloat(max(0, vm.volumeBoost - 100)) / 100.0
        let barHeight: CGFloat = 140 + 30 * boostFrac
        let sysVol = CGFloat(min(1, max(0, volumeValue)))
        return VStack(spacing: 10) {
            Image(systemName: volIcon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(isBoost ? .orange : .white.opacity(0.6))
                .contentTransition(.symbolEffect(.replace))

            GeometryReader { geo in
                let barH = geo.size.height
                let sysH = barH * sysZone
                let normalFillH = sysH * sysVol
                let boostFillH = barH * boostZone * boostFrac
                // Single unified fill height
                let fillH = isBoost ? sysH + boostFillH : normalFillH
                ZStack(alignment: .bottom) {
                    Capsule().fill(.white.opacity(0.15))
                        .frame(width: 6)
                    // 100% marker dot
                    Circle().fill(.white.opacity(0.3))
                        .frame(width: 4, height: 4)
                        .offset(y: -(sysH - 2))
                    // Unified fill capsule with gradient for boost zone
                    Capsule()
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: .white, location: 0),
                                    .init(color: .white, location: isBoost ? sysH / max(1, fillH) : 1),
                                    .init(color: .orange, location: isBoost ? sysH / max(1, fillH) + 0.01 : 1),
                                    .init(color: .orange, location: 1)
                                ],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                        .frame(width: 6, height: max(4, fillH))
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { val in
                            var tx = Transaction()
                            tx.disablesAnimations = true
                            withTransaction(tx) {
                                let frac = Float(1.0 - (val.location.y / barH))
                                if frac <= Float(sysZone) {
                                    let vol = max(0, frac / Float(sysZone))
                                    setSystemVolume(vol)
                                    if vm.volumeBoost > 100 { vm.setVolumeBoost(100) }
                                } else {
                                    setSystemVolume(1)
                                    let bf = (frac - Float(sysZone)) / Float(boostZone)
                                    vm.setVolumeBoost(Int32(100 + min(100, max(0, bf * 100))))
                                }
                            }
                        }
                )
            }
            .frame(width: 36, height: barHeight)

            Text("\(vm.volumeBoost)%")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.orange)
                .opacity(isBoost ? 1 : 0)
                .frame(height: isBoost ? nil : 0)
        }
        .animation(.easeInOut(duration: 0.3), value: vm.volumeBoost)
        .animation(.smooth(duration: 0.15), value: volumeValue)
        .padding(.horizontal, 2).padding(.vertical, 14)
        .glassEffect(in: .rect(cornerRadius: 16))
    }

    private var briIcon: String {
        if vm.brightnessBoost > 1.0 { return "sun.max.fill" }
        return brightnessValue > 0.66 ? "sun.max.fill" : brightnessValue > 0.33 ? "sun.min.fill" : "moon.fill"
    }
    private var volIcon: String {
        if vm.volumeBoost > 100 { return "speaker.wave.3.fill" }
        return volumeValue > 0.66 ? "speaker.wave.3.fill" : volumeValue > 0.33 ? "speaker.wave.2.fill"
            : volumeValue > 0 ? "speaker.wave.1.fill" : "speaker.slash.fill"
    }

    // MARK: - Error

    private func errorView(message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44)).foregroundStyle(.yellow)
            Text(message).font(.subheadline).foregroundStyle(.white)
                .multilineTextAlignment(.center).padding(.horizontal, 32)
            Button(String(localized: "Dismiss", bundle: AppState.currentBundle)) { dismiss() }.buttonStyle(.bordered).tint(.white)
        }
    }

    // MARK: - Timer

    private func dismissAllPanels() {
    }

    private func toggleOverlay() {
        hideTask?.cancel()
        if showOverlay {
            withAnimation(.spring(duration: 0.3, bounce: 0.2)) { dismissAllPanels() }
            withAnimation { showOverlay = false }
        } else {
            withAnimation { showOverlay = true }; scheduleHide()
        }
    }

    private func stopTimer() { hideTask?.cancel() }
    private func pokeTimer() { scheduleHide() }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            guard !vm.isLoading else { return } // Don't hide while loading
            withAnimation(.spring(duration: 0.3, bounce: 0.2)) { dismissAllPanels() }
            withAnimation { showOverlay = false }
        }
    }

    // MARK: - Helpers

    private var aspectFillScale: CGFloat {
        let v = vm.videoSize
        guard v.width > 0, v.height > 0 else { return 1.33 }
        let screen = Self.currentScreen.bounds.size
        let sw = max(screen.width, screen.height)
        let sh = min(screen.width, screen.height)
        guard sh > 0 else { return 1.33 }
        let vw = max(v.width, v.height)
        let vh = min(v.width, v.height)
        let videoAR = vw / vh
        let screenAR = sw / sh
        return videoAR > screenAR ? videoAR / screenAR : screenAR / videoAR
    }

    private func applyAspectFill(_ fill: Bool) {
        withAnimation(.easeInOut(duration: 0.2)) {
            videoScale = fill ? aspectFillScale : 1
        }
    }

    private func setSystemVolume(_ value: Float) {
        let clamped = max(0, min(1, value))
        volumeValue = clamped
        if let slider = mpVolView?.subviews.compactMap({ $0 as? UISlider }).first {
            DispatchQueue.main.async { slider.value = clamped }
        }
    }

    private func fmtTime(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        let h = s / 3600; let m = (s % 3600) / 60; let sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    // MARK: - Custom Subtitle Management

    @State private var resolvedItem: JellyfinItem?

    private func autoSelectSubtitle() async {
        // item from list views may not have mediaStreams — fetch full details if needed
        var richItem = item
        if (richItem.mediaStreams ?? []).isEmpty {
            // Try cached details first (works offline)
            if let cached = DownloadManager.loadItemDetails(itemId: item.id),
               !(cached.mediaStreams ?? []).isEmpty {
                richItem = cached
                resolvedItem = cached
            } else {
                // Try up to 3 times with delay — server may not be ready yet
                for attempt in 1...3 {
                    if let detailed = try? await JellyfinAPI.shared.getItemDetails(
                        serverURL: appState.serverURL, itemId: item.id,
                        userId: appState.userId, token: appState.token
                    ), !(detailed.mediaStreams ?? []).isEmpty {
                        richItem = detailed
                        resolvedItem = detailed
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(500 * attempt))
                }
            }
        }
        let subtitleStreams = richItem.mediaStreams?.filter(\.isSubtitle) ?? []
        guard !subtitleStreams.isEmpty else {
            // Fallback: if no mediaStreams but local SRT files exist, load the first one
            if localURL != nil {
                let downloadsDir = DownloadManager.downloadsDirectory
                let prefix = "\(item.id)_"
                if let files = try? FileManager.default.contentsOfDirectory(atPath: downloadsDir.path),
                   let srtFile = files.first(where: { $0.hasPrefix(prefix) && $0.hasSuffix(".srt") }) {
                    subtitleManager.loadLocal(from: downloadsDir.appendingPathComponent(srtFile))
                }
            }
            return
        }

        // Build candidate list: preferred → secondary → default (no random fallback)
        let preferred = appState.preferredSubtitleLanguage.lowercased()
        let secondary = appState.secondarySubtitleLanguage.lowercased()
        var candidates: [JellyfinMediaStream] = []

        // Helper to add streams for a language (text-based first, then image-based)
        func addLang(_ lang: String) {
            guard !lang.isEmpty else { return }
            let langStreams = subtitleStreams.filter { $0.language?.lowercased() == lang }
            // Non-forced text first, then non-forced image, then forced
            let nonForced = langStreams.filter { $0.isForced != true }
            let forced = langStreams.filter { $0.isForced == true }
            let sorted = nonForced.sorted { $0.canDownloadAsSRT && !$1.canDownloadAsSRT } + forced
            for s in sorted where !candidates.contains(where: { $0.index == s.index }) { candidates.append(s) }
        }

        // 1. Preferred language
        addLang(preferred)
        // 2. Secondary language
        addLang(secondary)
        // 3. Default subtitle (if not already in list)
        if let def = subtitleStreams.first(where: { $0.isDefault == true }), !candidates.contains(where: { $0.index == def.index }) {
            candidates.append(def)
        }

        guard !candidates.isEmpty else {
            return
        }

        let mediaSourceId = richItem.mediaSources?.first?.id ?? richItem.id

        // Try each candidate until one loads successfully
        for candidate in candidates {
            vm.currentSubtitleIndex = Int32(candidate.index)

            // Local playback
            if localURL != nil {
                if let srtURL = Self.findLocalSubtitle(itemId: item.id, stream: candidate) {
                    subtitleManager.loadLocal(from: srtURL)
                    return
                }
                continue
            }

            // Remote: try fetching as text
            let success = await fetchSubtitleWithFallback(itemId: richItem.id, mediaSourceId: mediaSourceId, streamIndex: candidate.index)
            if success {
                return
            }
        }
    }

    /// Try fetching subtitle as SRT, fall back to VTT if server returns error.
    /// Returns true if subtitle was loaded successfully.
    @discardableResult
    private func fetchSubtitleWithFallback(itemId: String, mediaSourceId: String, streamIndex: Int) async -> Bool {
        let formats = ["srt", "vtt", "ass"]
        for format in formats {
            guard let url = DownloadManager.subtitleURL(
                serverURL: appState.serverURL, itemId: itemId,
                mediaSourceId: mediaSourceId,
                streamIndex: streamIndex, token: appState.token,
                format: format
            ) else { continue }
            let success = await subtitleManager.load(from: url, token: appState.token)
            if success {
                return true
            }
        }
        return false
    }

    private func selectSubtitle(index: Int32) {
        vm.currentSubtitleIndex = index

        if index == -1 {
            subtitleManager.clear()
            return
        }

        let activeItem = resolvedItem ?? item
        let subtitleStreams = activeItem.mediaStreams?.filter(\.isSubtitle) ?? []
        guard let stream = subtitleStreams.first(where: { Int32($0.index) == index }) else {
            subtitleManager.clear()
            return
        }

        // Local playback — check for local SRT file
        if localURL != nil {
            if let srtURL = Self.findLocalSubtitle(itemId: item.id, stream: stream) {
                subtitleManager.loadLocal(from: srtURL)
                return
            }
            subtitleManager.clear()
            return
        }

        // Remote — fetch as text from server (handles both text and image-based)
        let mediaSourceId = activeItem.mediaSources?.first?.id ?? activeItem.id
        Task {
            await fetchSubtitleWithFallback(itemId: activeItem.id, mediaSourceId: mediaSourceId, streamIndex: stream.index)
        }
    }

    /// Finds a local subtitle file matching the given stream.
    /// Tries: exact match (lang + index), then lang-only, then index-only.
    private static func findLocalSubtitle(itemId: String, stream: JellyfinMediaStream) -> URL? {
        let downloadsDir = DownloadManager.downloadsDirectory
        let prefix = "\(itemId)_"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: downloadsDir.path) else { return nil }
        let srtFiles = files.filter { $0.hasPrefix(prefix) && $0.hasSuffix(".srt") }
        guard !srtFiles.isEmpty else { return nil }

        let lang = stream.language ?? "und"

        // 1. Exact match: {itemId}_{lang}_{index}.srt
        if let exact = srtFiles.first(where: { $0.contains("_\(lang)_\(stream.index).srt") }) {
            return downloadsDir.appendingPathComponent(exact)
        }
        // 2. Match by stream index only (lang may differ between cache and download)
        if let byIndex = srtFiles.first(where: { $0.hasSuffix("_\(stream.index).srt") }) {
            return downloadsDir.appendingPathComponent(byIndex)
        }
        // 3. Match by language only
        if let byLang = srtFiles.first(where: { $0.contains("_\(lang)_") }) {
            return downloadsDir.appendingPathComponent(byLang)
        }
        // 4. Any subtitle for this item
        if let any = srtFiles.first {
            return downloadsDir.appendingPathComponent(any)
        }
        return nil
    }

}

// MARK: - OverlayButtonStyle (JellyGo player)

private struct JGOverlayButtonStyle: ButtonStyle {
    let onPressed: (Bool) -> Void
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? AnyShapeStyle(HierarchicalShapeStyle.primary) : AnyShapeStyle(Color.gray))
            .labelStyle(.iconOnly)
            .scaleEffect(configuration.isPressed ? 0.85 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
            .padding(8)
            .contentShape(Rectangle())
            .onChange(of: configuration.isPressed) { _, p in onPressed(p) }
    }
}

// MARK: - Progress Bar (capsule, no thumb — JellyGo player)

private struct JGProgressBar: View {
    let progress: Double
    @State private var sz: CGSize = .zero

    var body: some View {
        Capsule().foregroundStyle(.secondary).opacity(0.2)
            .overlay(alignment: .leading) {
                let w = sz.width * max(0, min(1, progress)) + sz.height
                Rectangle()
                    .clipShape(JGRoundedCorner(radius: sz.height / 2, corners: [.topLeft, .bottomLeft]))
                    .frame(width: w).offset(x: -sz.height)
                    .foregroundStyle(.primary)
            }
            .background(GeometryReader { g in
                Color.clear.onAppear { sz = g.size }
                    .onChange(of: g.size) { _, s in sz = s }
            })
            .mask { Capsule() }
    }
}

// MARK: - Helpers

private extension View {
    @ViewBuilder
    func sfVisible(_ condition: Bool) -> some View {
        self.opacity(condition ? 1 : 0).allowsHitTesting(condition)
    }
}

private struct JGAudioTrack: Identifiable, Equatable {
    let index: Int32
    let name: String
    var id: Int32 { index }
}

// MARK: - Isolated More Menu (won't re-render from vm.position changes)

private struct JGMoreMenuView: View {
    let subtitleStreams: [JellyfinMediaStream]
    let audioTracks: [JGAudioTrack]
    let currentSubIdx: Int32
    let currentAudioIdx: Int32
    let currentQuality: VideoQuality
    let subtitleDelay: Double
    let onSubtitleChanged: (Int32) -> Void
    let onAudioChanged: (Int32) -> Void
    let onQualityChanged: (VideoQuality) -> Void
    let onDelayChanged: (Double) -> Void
    let onShowDelayBar: () -> Void
    let showHUD: Bool
    let onToggleHUD: () -> Void
    let onPressed: (Bool) -> Void

    @State private var selectedSub: Int32 = -1
    @State private var selectedAudio: Int32 = 0

    var body: some View {
        Menu {
            subtitleSection
            subtitleDelaySection
            audioSection

            Divider()

            Button {
                onToggleHUD()
            } label: {
                Label(
                    String(localized: "Stats", bundle: AppState.currentBundle),
                    systemImage: showHUD ? "info.circle.fill" : "info.circle"
                )
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .padding(10)
                .glassEffect(.regular.tint(Color.black.opacity(0.15)), in: .circle)
        }
        .buttonStyle(.plain)
        .menuStyle(.borderlessButton)
        .onAppear {
            selectedSub = currentSubIdx
            selectedAudio = currentAudioIdx
        }
        .onChange(of: currentSubIdx) { _, val in selectedSub = val }
        .onChange(of: selectedSub) { _, val in
            guard val != currentSubIdx else { return }
            onSubtitleChanged(val)
        }
        .onChange(of: currentAudioIdx) { _, val in selectedAudio = val }
        .onChange(of: selectedAudio) { _, val in
            guard val != currentAudioIdx else { return }
            onAudioChanged(val)
        }
    }

    @ViewBuilder
    private var subtitleSection: some View {
        if !subtitleStreams.isEmpty {
            let label = selectedSub >= 0
                ? (subtitleStreams.first(where: { Int32($0.index) == selectedSub })?.languageName ?? String(localized: "On", bundle: AppState.currentBundle))
                : String(localized: "Off", bundle: AppState.currentBundle)
            Menu {
                Picker(String(localized: "Subtitles", bundle: AppState.currentBundle), selection: $selectedSub) {
                    Text(String(localized: "Off", bundle: AppState.currentBundle)).tag(Int32(-1))
                    ForEach(subtitleStreams, id: \.index) { s in
                        Text(s.languageName ?? "Track \(s.index)")
                            .tag(Int32(s.index))
                    }
                }
            } label: {
                Label("\(String(localized: "Subtitles", bundle: AppState.currentBundle)) \u{2022} \(label)", systemImage: "captions.bubble")
            }
        }
    }

    @ViewBuilder
    private var subtitleDelaySection: some View {
        if selectedSub >= 0 {
            Button {
                onShowDelayBar()
            } label: {
                let delayStr = subtitleDelay == 0
                    ? "0s"
                    : String(format: "%+.1fs", subtitleDelay)
                Label("\(String(localized: "Subtitle Delay", bundle: AppState.currentBundle)) \u{2022} \(delayStr)", systemImage: "timer")
            }
        }
    }

    @ViewBuilder
    private var audioSection: some View {
        if audioTracks.count > 1 {
            let label = audioTracks.first(where: { $0.index == selectedAudio })?.name ?? ""
            Menu {
                Picker(String(localized: "Audio", bundle: AppState.currentBundle), selection: $selectedAudio) {
                    ForEach(audioTracks) { t in
                        Text(t.name).tag(t.index)
                    }
                }
            } label: {
                Label("\(String(localized: "Audio", bundle: AppState.currentBundle)) \u{2022} \(label)", systemImage: "waveform")
            }
        }
    }

    private var qualitySection: some View {
        Menu {
            ForEach(VideoQuality.allCases) { q in
                Button {
                    onQualityChanged(q)
                } label: {
                    if currentQuality == q {
                        Label(q.rawValue, systemImage: "checkmark")
                    } else {
                        Text(q.rawValue)
                    }
                }
            }
        } label: {
            Label("Quality \u{2022} \(currentQuality.rawValue)", systemImage: "sparkles")
        }
    }
}

// MARK: - Equatable conformance for isolation
extension JGMoreMenuView: Equatable {
    static func == (lhs: JGMoreMenuView, rhs: JGMoreMenuView) -> Bool {
        lhs.currentSubIdx == rhs.currentSubIdx &&
        lhs.currentAudioIdx == rhs.currentAudioIdx &&
        lhs.currentQuality == rhs.currentQuality &&
        lhs.subtitleDelay == rhs.subtitleDelay &&
        lhs.subtitleStreams.count == rhs.subtitleStreams.count &&
        lhs.audioTracks == rhs.audioTracks &&
        lhs.showHUD == rhs.showHUD
    }
}

extension JGMoreMenuView {
    func equatable() -> EquatableView<JGMoreMenuView> {
        EquatableView(content: self)
    }
}

private struct JGRoundedCorner: Shape {
    var radius: CGFloat; var corners: UIRectCorner
    func path(in rect: CGRect) -> Path {
        Path(UIBezierPath(roundedRect: rect, byRoundingCorners: corners,
                          cornerRadii: CGSize(width: radius, height: radius)).cgPath)
    }
}



