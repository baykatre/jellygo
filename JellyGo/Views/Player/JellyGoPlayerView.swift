import SwiftUI
import MobileVLCKit
import MediaPlayer
import AVFoundation

// MARK: - JellyGoPlayerView

struct JellyGoPlayerView: View {
    let item: JellyfinItem
    var localURL: URL? = nil

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
    @State private var brightnessValue: CGFloat = UIScreen.main.brightness
    @State private var volumeValue: Float = 0.5
    @State private var mpVolView: MPVolumeView?
    enum AdjustMode { case brightness, volume }


    private var isSlowScrubbing: Bool {
        isScrubbing && scrubTranslation.y >= 60
    }

    private var shouldDim: Bool {
        showOverlay && !isScrubbing
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                VLCVideoSurface(player: vm.player)
                    .scaleEffect(videoScale)
                    .ignoresSafeArea()

                // Dim overlay: 0.5 when overlay visible & not scrubbing
                Color.black
                    .opacity(shouldDim ? 0.5 : 0)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .animation(.linear(duration: 0.2), value: shouldDim)

                // Custom subtitle overlay (independent of video scale)
                SubtitleOverlayView(manager: subtitleManager)
                    .ignoresSafeArea()

                if vm.isLoading {
                    ProgressView().tint(.white).scaleEffect(1.5)
                        .allowsHitTesting(false)
                }

                if let err = vm.error {
                    errorView(message: err)
                }

                controlsOverlay(geo: geo)


                // Brightness / Volume indicator
                Group {
                    if adjustMode != nil {
                        adjustIndicator
                            .transition(
                                .asymmetric(
                                    insertion: .scale(scale: 0.8).combined(with: .opacity),
                                    removal: .scale(scale: 0.9).combined(with: .opacity)
                                )
                            )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 40)
                .allowsHitTesting(false)
                .animation(.spring(duration: 0.4, bounce: 0.15), value: adjustMode != nil)
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
                        // Ignore mostly-horizontal drags (scrubbing area)
                        let h = abs(val.translation.width)
                        let v = abs(val.translation.height)
                        if !isSwipeActive {
                            guard v > h * 1.2 else { return }
                            isSwipeActive = true
                            swipeStartBrightness = UIScreen.main.brightness
                            swipeStartVolume = AVAudioSession.sharedInstance().outputVolume
                            volumeValue = swipeStartVolume
                            brightnessValue = swipeStartBrightness
                        }
                        // Softer sensitivity: 1.8x screen height for full range
                        let delta = -val.translation.height / (geo.size.height * 1.8)
                        if val.startLocation.x < geo.size.width / 2 {
                            adjustMode = .brightness
                            let bri = max(0, min(1, swipeStartBrightness + delta))
                            UIScreen.main.brightness = bri; brightnessValue = bri
                        } else {
                            adjustMode = .volume
                            let vol = max(0, min(1, Float(swipeStartVolume) + Float(delta)))
                            setSystemVolume(vol); volumeValue = vol
                        }
                        adjustHideTask?.cancel()
                    }
                    .onEnded { _ in
                        isSwipeActive = false
                        adjustHideTask = Task {
                            try? await Task.sleep(for: .milliseconds(1400))
                            guard !Task.isCancelled else { return }
                            withAnimation(.easeOut(duration: 0.3)) { adjustMode = nil }
                        }
                    }
            )
            // 3) Double-tap: aspect fill toggle
            .onTapGesture(count: 2) {
                isAspectFilled.toggle()
                applyAspectFill(isAspectFilled)
                UIImpactFeedbackGenerator(style: isAspectFilled ? .medium : .light).impactOccurred()
                pokeTimer()
            }
            // 4) Single-tap: toggle overlay
            .onTapGesture(count: 1) { toggleOverlay() }
            .onChange(of: vm.videoSize) { _, _ in
                if isAspectFilled { videoScale = aspectFillScale }
            }
            // Sync custom subtitles with playback
            .onChange(of: vm.position) { _, _ in
                subtitleManager.update(currentSeconds: vm.currentSeconds)
            }
        }
        .environment(\.colorScheme, .dark)
        .statusBarHidden(true)
        .animation(.linear(duration: 0.1), value: isScrubbing)
        .animation(.bouncy(duration: 0.25), value: showOverlay)
        .task {
            vm.disableVLCSubtitles = true
            // Fetch item details (for mediaStreams) in parallel with video load
            async let _ = autoSelectSubtitle()
            if let url = localURL {
                await vm.loadLocal(url: url, item: item, appState: appState)
            } else {
                await vm.load(item: item, appState: appState)
            }
        }
        .onDisappear { vm.stop() }
        .onAppear {
            // Orientation already set before fullScreenCover presentation
            scheduleHide()
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
                    .sfVisible(!isScrubbing && showOverlay)
                    .offset(y: showOverlay ? 0 : -20)
                    .padding(.top, geo.safeAreaInsets.top)
                    .padding(.leading, geo.safeAreaInsets.leading)
                    .padding(.trailing, geo.safeAreaInsets.trailing)

                Spacer().allowsHitTesting(false)

                sfPlaybackProgress
                    .sfVisible(showOverlay)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, geo.safeAreaInsets.leading)
                    .padding(.trailing, geo.safeAreaInsets.trailing)
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
                .sfVisible(!isScrubbing && showOverlay)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Navigation Bar

    private var sfNavigationBar: some View {
        HStack(alignment: .center) {
            sfNavButton("xmark") { vm.stop(); dismiss() }

            sfTitleView.frame(maxWidth: .infinity, alignment: .leading)

            sfMoreMenu
        }
        .background { Color.clear.allowsHitTesting(true) }
    }

    /// Standalone nav bar button with overlay style
    private func sfNavButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .semibold))
                .padding(8)
                .contentShape(Rectangle())
        }
        .buttonStyle(JGOverlayButtonStyle(onPressed: { p in
            if p { stopTimer() } else { pokeTimer() }
        }))
    }

    // MARK: - Title View

    @State private var subtitleContentSize: CGSize = .zero

    private var sfTitleView: some View {
        let ts: (title: String, subtitle: String?) = {
            if item.type == "Episode", let sn = item.seriesName {
                let ep = item.indexNumber.map { "E\($0)" } ?? ""
                let se = item.parentIndexNumber.map { "S\($0)" } ?? ""
                let label = [se, ep].filter { !$0.isEmpty }.joined(separator: ":")
                return (sn, label.isEmpty ? nil : label)
            }
            return (vm.itemTitle, nil)
        }()

        return Text(ts.title)
            .fontWeight(.semibold).lineLimit(1)
            .frame(minWidth: max(50, subtitleContentSize.width))
            .overlay(alignment: .bottomLeading) {
                if let sub = ts.subtitle {
                    Text(sub).font(.subheadline).fontWeight(.medium)
                        .foregroundStyle(.white).lineLimit(1)
                        .background(GeometryReader { g in
                            Color.clear.onAppear { subtitleContentSize = g.size }
                        })
                        .offset(y: subtitleContentSize.height)
                }
            }
    }

    // MARK: - Playback Buttons

    private var sfPlaybackButtons: some View {
        HStack(spacing: 0) {
            Button { vm.skip(seconds: -10) } label: {
                Label("10s", systemImage: "gobackward.10")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 32, weight: .regular))
                    .padding(10)
            }.foregroundStyle(.primary)

            Button { vm.togglePlayPause() } label: {
                Group {
                    if vm.isPlaying {
                        Label("Pause", systemImage: "pause.fill")
                    } else {
                        Label("Play", systemImage: "play.fill")
                    }
                }
                .transition(.opacity.combined(with: .scale)
                    .animation(.bouncy(duration: 0.7, extraBounce: 0.2)))
                .font(.system(size: 36, weight: .bold))
                .contentShape(Rectangle())
                .labelStyle(.iconOnly)
                .padding(20)
            }
            .frame(minWidth: 50, maxWidth: 150)

            Button { vm.skip(seconds: 30) } label: {
                Label("30s", systemImage: "goforward.30")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 32, weight: .regular))
                    .padding(10)
            }.foregroundStyle(.primary)
        }
        .buttonStyle(JGOverlayButtonStyle(onPressed: { p in
            if p { stopTimer() } else { pokeTimer() }
        }))
        .padding(.horizontal, 50)
    }

    // MARK: - Playback Progress

    @State private var sliderSize: CGSize = .zero

    private var sfPlaybackProgress: some View {
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
        .animation(.bouncy(duration: 0.4, extraBounce: 0.1), value: isScrubbing)
        .overlay(alignment: .bottom) {
            if isSlowScrubbing {
                HStack {
                    Image(systemName: "backward.fill")
                    Text("Slow Scrubbing")
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

    // MARK: - More Menu (native Menu with accordion sub-menus)

    private var sfMoreMenu: some View {
        let audioStreams = (resolvedItem ?? item).mediaStreams?.filter(\.isAudio) ?? []
        let vlcAudioTracks = vm.audioTracks
        // Map VLC tracks to clean names using Jellyfin mediaStreams (matched by order)
        let cleanAudio: [SFAudioTrack] = vlcAudioTracks.enumerated().map { i, t in
            // VLC track 0 is usually "Disable", skip it for matching
            let jellyfinIdx = t.index == -1 ? nil : (i < audioStreams.count ? audioStreams[i] : nil)
            let name = jellyfinIdx?.languageName ?? t.name
            return SFAudioTrack(index: t.index, name: name)
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
            onSubtitleChanged: { selectSubtitle(index: $0) },
            onAudioChanged: { vm.setAudio(index: $0) },
            onQualityChanged: { q in Task { await vm.changeQuality(to: q) } },
            onPressed: { p in if p { stopTimer() } else { pokeTimer() } }
        ).equatable()
    }

    // MARK: - Brightness / Volume Indicator

    private var adjustIndicator: some View {
        let pct = adjustMode == .brightness ? brightnessValue : CGFloat(volumeValue)
        return VStack(spacing: 10) {
            Image(systemName: adjustMode == .brightness ? briIcon : volIcon)
                .font(.system(size: 22, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.15)).frame(width: 140, height: 5)
                Capsule().fill(.white)
                    .frame(width: max(5, 140 * pct), height: 5)
                    .animation(.smooth(duration: 0.15), value: pct)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20).padding(.vertical, 14)
        .glassEffect(in: .rect(cornerRadius: 18))
    }

    private var briIcon: String {
        brightnessValue > 0.66 ? "sun.max.fill" : brightnessValue > 0.33 ? "sun.min.fill" : "moon.fill"
    }
    private var volIcon: String {
        volumeValue > 0.66 ? "speaker.wave.3.fill" : volumeValue > 0.33 ? "speaker.wave.2.fill"
            : volumeValue > 0 ? "speaker.wave.1.fill" : "speaker.slash.fill"
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

    // MARK: - Timer

    private func dismissAllPanels() { }

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
            withAnimation(.spring(duration: 0.3, bounce: 0.2)) { dismissAllPanels() }
            withAnimation { showOverlay = false }
        }
    }

    // MARK: - Helpers

    private var aspectFillScale: CGFloat {
        let v = vm.videoSize
        guard v.width > 0, v.height > 0 else { return 1.33 }
        let screen = UIScreen.main.bounds.size
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
        volumeValue = value
        if let slider = mpVolView?.subviews.compactMap({ $0 as? UISlider }).first {
            DispatchQueue.main.async { slider.value = value }
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
            print("[Player] item.mediaStreams is empty — fetching full item details")
            // Try cached details first (works offline)
            if let cached = DownloadManager.loadItemDetails(itemId: item.id),
               !(cached.mediaStreams ?? []).isEmpty {
                richItem = cached
                resolvedItem = cached
                print("[Player] Loaded cached details: mediaStreams=\(cached.mediaStreams?.count ?? 0)")
            } else if let detailed = try? await JellyfinAPI.shared.getItemDetails(
                serverURL: appState.serverURL, itemId: item.id,
                userId: appState.userId, token: appState.token
            ) {
                richItem = detailed
                resolvedItem = detailed
                print("[Player] Fetched details: mediaStreams=\(detailed.mediaStreams?.count ?? 0)")
            }
        }
        let subtitleStreams = richItem.mediaStreams?.filter(\.isSubtitle) ?? []
        print("[Player] autoSelectSubtitle: \(subtitleStreams.count) subtitle streams, mediaStreams total: \(richItem.mediaStreams?.count ?? 0)")
        for (i, s) in subtitleStreams.enumerated() {
            print("[Player]   sub[\(i)]: index=\(s.index) lang=\(s.language ?? "nil") codec=\(s.codec ?? "nil") default=\(s.isDefault ?? false) external=\(s.isExternal ?? false) canSRT=\(s.canDownloadAsSRT) title=\(s.displayTitle ?? "nil")")
        }
        guard !subtitleStreams.isEmpty else {
            print("[Player] No subtitle streams found — trying local SRT files directly")
            // Fallback: if no mediaStreams but local SRT files exist, load the first one
            if localURL != nil {
                let downloadsDir = DownloadManager.downloadsDirectory
                let prefix = "\(item.id)_"
                if let files = try? FileManager.default.contentsOfDirectory(atPath: downloadsDir.path),
                   let srtFile = files.first(where: { $0.hasPrefix(prefix) && $0.hasSuffix(".srt") }) {
                    print("[Player] Fallback: loading local SRT: \(srtFile)")
                    subtitleManager.loadLocal(from: downloadsDir.appendingPathComponent(srtFile))
                }
            }
            return
        }

        // Pick default or preferred language subtitle
        let preferred = appState.preferredSubtitleLanguage.lowercased()
        let defaultSub = subtitleStreams.first(where: { $0.isDefault == true })
        let preferredSub = !preferred.isEmpty
            ? subtitleStreams.first(where: { $0.language?.lowercased() == preferred })
            : nil

        print("[Player] preferred='\(preferred)' defaultSub=\(defaultSub?.language ?? "nil") preferredSub=\(preferredSub?.language ?? "nil") subtitlesEnabled=\(appState.subtitlesEnabledByDefault)")
        guard let target = preferredSub ?? defaultSub ?? (appState.subtitlesEnabledByDefault ? subtitleStreams.first : nil) else {
            print("[Player] No subtitle target found (none default, none preferred, subtitlesEnabledByDefault=\(appState.subtitlesEnabledByDefault))")
            return
        }
        print("[Player] Selected target: index=\(target.index) lang=\(target.language ?? "nil") canSRT=\(target.canDownloadAsSRT)")

        guard target.canDownloadAsSRT else {
            print("[Player] Target is image-based (PGS/VobSub) — delegating to VLC")
            vm.currentSubtitleIndex = Int32(target.index)
            vm.setVLCSubtitleTrack(Int32(target.index))
            return
        }

        vm.currentSubtitleIndex = Int32(target.index)

        // Local playback
        if localURL != nil {
            print("[Player] Local playback — looking for SRT: itemId=\(item.id) lang=\(target.language ?? "nil") index=\(target.index)")
            if let srtURL = Self.findLocalSubtitle(itemId: item.id, stream: target) {
                print("[Player] Found local SRT: \(srtURL.lastPathComponent)")
                subtitleManager.loadLocal(from: srtURL)
                return
            }
            print("[Player] No local SRT found")
        }

        // Remote: try SRT first, then VTT as fallback
        let mediaSourceId = richItem.mediaSources?.first?.id ?? richItem.id
        await fetchSubtitleWithFallback(itemId: richItem.id, mediaSourceId: mediaSourceId, streamIndex: target.index)
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
            print("[Player] Trying \(format.uppercased()) from: \(url.absoluteString)")
            let success = await subtitleManager.load(from: url, token: appState.token)
            if success {
                print("[Player] \(format.uppercased()) loaded: \(subtitleManager.entries.count) entries")
                return true
            }
            print("[Player] \(format.uppercased()) failed, trying next format...")
        }
        print("[Player] All subtitle formats failed")
        return false
    }

    private func selectSubtitle(index: Int32) {
        print("[Player] selectSubtitle called: index=\(index)")
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

        // Remote — fetch with SRT→VTT fallback
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
            .scaleEffect(configuration.isPressed ? 0.8 : 1)
            .animation(.bouncy(duration: 0.25, extraBounce: 0.25), value: configuration.isPressed)
            .padding(8)
            .contentShape(Rectangle())
            .background {
                Circle()
                    .foregroundStyle(Color.white.opacity(configuration.isPressed ? 0.25 : 0))
                    .scaleEffect(configuration.isPressed ? 1 : 0.8)
                    .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
            }
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

private struct SFAudioTrack: Identifiable, Equatable {
    let index: Int32
    let name: String
    var id: Int32 { index }
}

// MARK: - Isolated More Menu (won't re-render from vm.position changes)

private struct JGMoreMenuView: View {
    let subtitleStreams: [JellyfinMediaStream]
    let audioTracks: [SFAudioTrack]
    let currentSubIdx: Int32
    let currentAudioIdx: Int32
    let currentQuality: VideoQuality
    let onSubtitleChanged: (Int32) -> Void
    let onAudioChanged: (Int32) -> Void
    let onQualityChanged: (VideoQuality) -> Void
    let onPressed: (Bool) -> Void

    @State private var selectedSub: Int32 = -1
    @State private var selectedAudio: Int32 = 0

    var body: some View {
        Menu {
            subtitleSection
            audioSection
            qualitySection
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 24, weight: .semibold))
                .padding(8)
                .contentShape(Rectangle())
        }
        .buttonStyle(JGOverlayButtonStyle(onPressed: onPressed))
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
                ? (subtitleStreams.first(where: { Int32($0.index) == selectedSub })?.languageName ?? "On")
                : "Off"
            Menu {
                Picker("Subtitles", selection: $selectedSub) {
                    Text("Off").tag(Int32(-1))
                    ForEach(subtitleStreams, id: \.index) { s in
                        Text(s.languageName ?? "Track \(s.index)")
                            .tag(Int32(s.index))
                    }
                }
            } label: {
                Label("Subtitles \u{2022} \(label)", systemImage: "captions.bubble")
            }
        }
    }

    @ViewBuilder
    private var audioSection: some View {
        if audioTracks.count > 1 {
            let label = audioTracks.first(where: { $0.index == selectedAudio })?.name ?? ""
            Menu {
                Picker("Audio", selection: $selectedAudio) {
                    ForEach(audioTracks) { t in
                        Text(t.name).tag(t.index)
                    }
                }
            } label: {
                Label("Audio \u{2022} \(label)", systemImage: "waveform")
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
        lhs.subtitleStreams.count == rhs.subtitleStreams.count &&
        lhs.audioTracks == rhs.audioTracks
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


