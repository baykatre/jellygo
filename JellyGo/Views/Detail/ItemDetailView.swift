import SwiftUI

private enum DownloadPopoverStep: Identifiable {
    case scope, quality, audio, progress
    var id: Int { hashValue }
}

struct ItemDetailView: View {
    let item: JellyfinItem
    @State var isFromDownloads: Bool = false
    var autoPlay: Bool = false

    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var dm: DownloadManager
    @StateObject private var vm = ItemDetailViewModel()
    @State private var activeItem: JellyfinItem
    @State private var itemToPlay: JellyfinItem?
    @State private var selectedSeason: JellyfinItem?
    @State private var downloadPopoverStep: DownloadPopoverStep? = nil
    @State private var pendingDownloadSeason = false
    @State private var showDeleteConfirm = false
    @State private var showDownloadDetail = false
    @State private var downloadedEpisodeTarget: String? = nil
    @State private var playAfterSheetDismiss = false
    @State private var overviewExpanded = false
    @State private var episodeDeleteTarget: JellyfinItem? = nil
    @State private var pendingQuality: (label: String, bitrate: Int?)? = nil
    @State private var selectedAudioStreamIndex: Int? = nil
    private let backdropHeight: CGFloat = 580
    @State private var showPlayQualityDialog = false
    @State private var playQualityOverride: VideoQuality?
    private let qualities: [(label: String, bitrate: Int?)] = [
        ("Direct",  nil),
        ("1080p",   8_000_000),
        ("720p",    4_000_000),
        ("480p",    2_000_000),
    ]

    init(item: JellyfinItem, isFromDownloads: Bool = false, autoPlay: Bool = false) {
        self.item = item
        self.isFromDownloads = isFromDownloads
        self.autoPlay = autoPlay
        _activeItem = State(initialValue: item)
    }

    private var displayItem: JellyfinItem { vm.fullItem ?? activeItem }

    @State private var detailScrollProxy: ScrollViewProxy?

    var body: some View {
        ScrollViewReader { scrollProxy in
        detailScrollView
        .overlay {
            if overviewExpanded, let overview = activeItem.overview ?? displayItem.overview {
                overviewPopup(overview)
                    .transition(.opacity)
            }
        }
        .fullScreenCover(item: $itemToPlay, onDismiss: {
            appState.isPlayerActive = false
            AppDelegate.orientationLock = .portrait
            PlayerContainerView.rotate(to: .portrait)
            Task { await vm.load(item: item, appState: appState) }
        }) { ep in
            let localURL = dm.downloads.first(where: { $0.id == ep.id })
                .flatMap { item -> URL? in
                    guard let url = item.localURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
                    return url
                }
            PlayerContainerView(item: ep, localURL: localURL, qualityOverride: playQualityOverride)
                .environmentObject(appState)
                .onAppear { appState.isPlayerActive = true; playQualityOverride = nil }
        }
        .task {
            let isOffline = isFromDownloads || appState.manualOffline || appState.serverUnreachable

            if isOffline {
                // Offline / Downloads: skip API, build from local downloads immediately
                if item.isSeries {
                    vm.buildOfflineData(from: dm.downloads, seriesId: item.id)
                } else if item.isEpisode, let seriesId = item.seriesId {
                    vm.buildOfflineData(from: dm.downloads, seriesId: seriesId)
                }
                // Still load cached details for movies/episodes
                if let cached = DownloadManager.loadItemDetails(itemId: item.id) {
                    vm.fullItem = cached
                }
            } else {
                await vm.load(item: item, appState: appState)
                if item.isSeries && vm.seasons.isEmpty {
                    vm.buildOfflineData(from: dm.downloads, seriesId: item.id)
                }
            }

            if item.isSeries {
                // Check for downloaded episodes — prefer the most recent one
                let latestDownload = dm.downloads
                    .filter { ($0.seriesId ?? $0.id) == item.id && $0.isEpisode }
                    .sorted {
                        let s0 = $0.seasonNumber ?? 0, s1 = $1.seasonNumber ?? 0
                        if s0 != s1 { return s0 > s1 }
                        return ($0.episodeNumber ?? 0) > ($1.episodeNumber ?? 0)
                    }
                    .first

                if let dl = latestDownload,
                   let targetSeason = vm.seasons.first(where: { $0.indexNumber == dl.seasonNumber }) {
                    downloadedEpisodeTarget = dl.id
                    selectedSeason = targetSeason
                } else if !isOffline {
                    let season = await vm.bestSeasonToOpen(appState: appState)
                    selectedSeason = season ?? vm.seasons.first
                    if let sid = selectedSeason?.id, let ep = vm.resumeEpisode(seasonId: sid) {
                        activeItem = ep
                    }
                } else {
                    selectedSeason = vm.seasons.first
                }
            } else {
                selectedSeason = vm.seasons.first(where: { $0.indexNumber == item.parentIndexNumber })
                    ?? vm.seasons.first
                if let sid = selectedSeason?.id, !isOffline {
                    await vm.loadEpisodes(seasonId: sid, appState: appState)
                }
            }

            if autoPlay {
                await startPlayback()
            }
        }
        .onChange(of: selectedSeason) { _, newSeason in
            guard let sid = newSeason?.id else { return }
            Task {
                await vm.loadEpisodes(seasonId: sid, appState: appState)
                if let dlId = downloadedEpisodeTarget,
                   let ep = vm.episodes[sid]?.first(where: { $0.id == dlId }) {
                    activeItem = ep
                    let shouldPlay = playAfterSheetDismiss
                    downloadedEpisodeTarget = nil
                    playAfterSheetDismiss = false
                    if shouldPlay {
                        try? await Task.sleep(for: .milliseconds(400))
                        await startPlayback()
                    }
                } else if item.isEpisode && newSeason?.indexNumber == item.parentIndexNumber {
                    activeItem = item
                } else if let ep = vm.resumeEpisode(seasonId: sid) {
                    activeItem = ep
                }
            }
        }
        .sheet(isPresented: $showDownloadDetail) {
            NavigationStack {
                DownloadedSeriesDetailView(
                    seriesId: activeItem.seriesId ?? activeItem.id,
                    onPlay: { downloadedItem in
                        showDownloadDetail = false
                        playAfterSheetDismiss = true
                        downloadedEpisodeTarget = downloadedItem.id
                        let jellyfinItem = downloadedItem.toJellyfinItem()
                        let targetSeason = vm.seasons.first(where: { $0.indexNumber == downloadedItem.seasonNumber })
                        if let targetSeason, targetSeason.id == selectedSeason?.id {
                            activeItem = jellyfinItem
                            downloadedEpisodeTarget = nil
                            Task {
                                try? await Task.sleep(for: .milliseconds(400))
                                await startPlayback()
                                playAfterSheetDismiss = false
                            }
                        } else if let targetSeason {
                            selectedSeason = targetSeason
                        } else {
                            activeItem = jellyfinItem
                            downloadedEpisodeTarget = nil
                            Task {
                                try? await Task.sleep(for: .milliseconds(400))
                                await startPlayback()
                                playAfterSheetDismiss = false
                            }
                        }
                    },
                    onNavigate: { jellyfinItem in
                        showDownloadDetail = false
                        let targetSeason = vm.seasons.first(where: { $0.indexNumber == jellyfinItem.parentIndexNumber })
                        if let targetSeason {
                            selectedSeason = targetSeason
                        }
                        Task {
                            try? await Task.sleep(for: .milliseconds(400))
                            activeItem = jellyfinItem
                        }
                    }
                )
            }
            .environmentObject(appState)
            .environmentObject(dm)
        }
        .onReceive(NotificationCenter.default.publisher(for: .playbackStopped)) { _ in
            Task {
                if NetworkMonitor.shared.isConnected,
                   let updated = try? await JellyfinAPI.shared.getItemDetails(
                    serverURL: appState.serverURL,
                    itemId: activeItem.id,
                    userId: appState.userId,
                    token: appState.token
                ) {
                    activeItem = updated
                }
            }
        }
        .onAppear { detailScrollProxy = scrollProxy }
        }
    }

    // MARK: - Toolbar Content

    @ToolbarContentBuilder
    private var detailToolbarContent: some ToolbarContent {
        if isFromDownloads {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    if !appState.manualOffline && !appState.serverUnreachable {
                        isFromDownloads = false
                        vm.seasons = []
                        vm.episodes = [:]
                        vm.fullItem = nil
                        selectedSeason = nil
                        Task {
                            await vm.load(item: item, appState: appState)
                            if item.isSeries {
                                let season = await vm.bestSeasonToOpen(appState: appState)
                                selectedSeason = season ?? vm.seasons.first
                            } else {
                                selectedSeason = vm.seasons.first(where: { $0.indexNumber == item.parentIndexNumber })
                                    ?? vm.seasons.first
                                if let sid = selectedSeason?.id {
                                    await vm.loadEpisodes(seasonId: sid, appState: appState)
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 11, weight: .bold))
                        Text(String(localized: "Downloaded View", bundle: AppState.currentBundle))
                            .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(appState.manualOffline || appState.serverUnreachable ? .gray : .green)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                }
            }
        } else {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    Task { await vm.toggleWatched(item: activeItem, appState: appState) }
                } label: {
                    Image(systemName: vm.isWatched ? "eye.fill" : "eye")
                        .foregroundStyle(.white)
                }
                Button {
                    Task { await vm.toggleFavorite(item: activeItem, appState: appState) }
                } label: {
                    Image(systemName: vm.isFavorite ? "heart.fill" : "heart")
                        .foregroundStyle(vm.isFavorite ? .red : .white)
                }
            }
        }
    }

    // MARK: - Detail Scroll View

    private var detailScrollView: some View {
        ScrollView(showsIndicators: false) {
            scrollContent
        }
        .coordinateSpace(name: "detailScroll")
        .ignoresSafeArea(edges: .top)
        .scrollEdgeEffectStyle(.none, for: .top)
        .background(Color(.systemBackground).ignoresSafeArea())
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationTitle("")
        .toolbar { detailToolbarContent }
        .toolbar(.hidden, for: .tabBar)
    }

    // MARK: - Scroll Content

    private var scrollContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 0).id("detailTop")
            ZStack(alignment: .bottom) {
                // Backdrop image with parallax
                GeometryReader { geo in
                    let minY = geo.frame(in: .named("detailScroll")).minY
                    let stretch = max(0, minY)
                    backdropImage
                        .frame(width: geo.size.width, height: backdropHeight + stretch)
                        .clipped()
                        .offset(y: minY > 0 ? -minY : -minY * 0.4)
                }
                .frame(height: backdropHeight)

                // Gradient overlay + title + buttons
                backdropOverlayContent
            }
            Color(.systemBackground).frame(height: 24)
            mainContent
                .background(Color(.systemBackground))
            Color(.systemBackground).frame(height: 100)
        }
    }

    // MARK: - Backdrop Image

    private var backdropImage: some View {
        let backdropId = activeItem.isEpisode ? (activeItem.seriesId ?? activeItem.id) : activeItem.id
        let url = DownloadManager.localBackdropURL(itemId: backdropId)
            ?? JellyfinAPI.shared.backdropURL(serverURL: appState.serverURL, itemId: backdropId, maxWidth: 1280)
        return Group {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().aspectRatio(contentMode: .fill)
                    default:
                        Color(white: 0.12)
                    }
                }
            } else {
                Color(white: 0.12)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Backdrop Overlay (gradient + title + buttons, scrolls with content)

    private var backdropOverlayContent: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .clear, location: 0.35),
                    .init(color: .black.opacity(0.42), location: 0.58),
                    .init(color: .black.opacity(0.82), location: 0.78),
                    .init(color: .black.opacity(0.93), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            VStack(alignment: .center, spacing: 12) {
                let logoItemId = activeItem.isEpisode ? (activeItem.seriesId ?? activeItem.id) : activeItem.id
                LogoTitleView(
                    title: activeItem.isEpisode ? (activeItem.seriesName ?? activeItem.name) : activeItem.name,
                    logoURL: DownloadManager.localLogoURL(itemId: logoItemId)
                        ?? JellyfinAPI.shared.logoURL(serverURL: appState.serverURL, itemId: logoItemId)
                )

                if activeItem.isEpisode {
                    let sLabel = activeItem.parentIndexNumber.map { "S\($0)" } ?? ""
                    let eLabel = activeItem.indexNumber.map { "B\($0)" } ?? ""
                    Text("\(sLabel) • \(eLabel) - \(activeItem.name)")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                }

                metaChips

                if let genres = displayItem.genres, !genres.isEmpty {
                    Text(genres.prefix(3).joined(separator: ", "))
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.65))
                        .multilineTextAlignment(.center)
                }

                actionButtons
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(height: backdropHeight)
    }

    private var metaChips: some View {
        HStack(spacing: 8) {
            if activeItem.isSeries {
                let count = (displayItem.childCount ?? activeItem.childCount) ?? vm.seasons.count
                if count > 0 {
                    Text(verbatim: count == 1 ? String(localized: "1 Season", bundle: AppState.currentBundle) : String(format: String(localized: "%lld Seasons", bundle: AppState.currentBundle), Int64(count)))
                        .metaStyle()
                }
            } else if activeItem.isSeason {
                if let seasonId = activeItem.id.isEmpty ? nil : activeItem.id,
                   let eps = vm.episodes[seasonId] {
                    let count = eps.count
                    if count > 0 {
                        Text(verbatim: count == 1 ? String(localized: "1 Episode", bundle: AppState.currentBundle) : String(format: String(localized: "%lld Episodes", bundle: AppState.currentBundle), Int64(count)))
                            .metaStyle()
                    }
                }
            } else if let mins = activeItem.runtimeMinutes, mins > 0 {
                Text(verbatim: String(format: String(localized: "%lld min.", bundle: AppState.currentBundle), Int64(mins)))
                    .metaStyle()
            }
            if let date = activeItem.formattedPremiereDate {
                Text(date).metaStyle()
            }
            if let rating = displayItem.officialRating ?? activeItem.officialRating {
                Text(rating)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.5), lineWidth: 1))
            }
        }
    }

    // MARK: - Main Content

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            overviewSection
            ratingsAndBadges
            if item.isSeries || item.isEpisode, !vm.seasons.isEmpty {
                episodeSection
            }
            if let people = displayItem.people, !people.isEmpty {
                castSection(people: people)
            }
            if !isFromDownloads, item.isMovie, !vm.similarItems.isEmpty {
                similarSection
            }
            mediaInfoSection
        }
        .padding(.bottom, 40)
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 10) {
            Button {
                guard !showPlayQualityDialog else { return }
                Task { await startPlayback() }
            } label: {
                playButtonContent
            }
            .buttonStyle(.plain)
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                    showPlayQualityDialog = true
                }
            )
            .popover(isPresented: $showPlayQualityDialog, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(String(localized: "Playback Quality", bundle: AppState.currentBundle),
                          systemImage: "play.circle.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.bottom, 2)

                    ForEach(Array(VideoQuality.allCases.enumerated()), id: \.element.id) { idx, q in
                        if idx > 0 { Divider() }
                        let isDirect = q == .direct
                        Button {
                            showPlayQualityDialog = false
                            playQualityOverride = q
                            Task { await startPlayback() }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: isDirect ? "bolt.fill" : "play.rectangle.fill")
                                    .font(.system(size: 15))
                                    .foregroundStyle(isDirect ? .green : .secondary)
                                    .frame(width: 24)
                                Text(isDirect ? "Direct Stream" : q.rawValue)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(isDirect ? .green : .primary)
                                Spacer()
                            }
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
                .frame(minWidth: 200)
                .presentationCompactAdaptation(.popover)
            }

            downloadTriggerButton
        }
    }

    @ViewBuilder
    private func glassButton(systemImage: String, label: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(active ? Color.accentColor : .white)
                .frame(width: 52, height: 52)
                .glassEffect(in: Circle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Download Trigger Button

    @ViewBuilder
    private var downloadTriggerButton: some View {
        let downloadedItem = dm.downloads.first { $0.id == activeItem.id }
        let isDownloaded = downloadedItem != nil
        let activeDownload = dm.activeTasks[activeItem.id]
        let isDownloading = activeDownload != nil
        let isQueued = dm.isQueued(activeItem.id)
        let isPaused = activeDownload?.isPaused == true || (!isDownloading && dm.isPaused(activeItem.id))
        let anySeriesDownloaded = activeItem.isSeries &&
            dm.downloads.contains { $0.seriesId == activeItem.id }

        if isDownloaded, let dl = downloadedItem, activeItem.isEpisode || activeItem.isMovie {
            // Downloaded: tap quality+size badge to open download detail sheet
            Button { showDownloadDetail = true } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(dl.quality)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                    if !dl.formattedSize.isEmpty {
                        Text(dl.formattedSize)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.25), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
        } else {
            Button {
                if isDownloading || isQueued || isPaused {
                    downloadPopoverStep = .progress
                    return
                }
                if anySeriesDownloaded { return }
                let hasSeasonContext = !activeItem.isMovie && selectedSeason != nil
                if hasSeasonContext {
                    downloadPopoverStep = .scope
                } else {
                    pendingDownloadSeason = false
                    downloadPopoverStep = .quality
                }
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white)

                    if isDownloading, let dl = activeDownload {
                        let progress = dl.progress
                        if progress > 0 {
                            ZStack {
                                Circle()
                                    .stroke(Color.black.opacity(0.15), lineWidth: 3)
                                Circle()
                                    .trim(from: 0, to: progress)
                                    .stroke(Color.black, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                    .rotationEffect(.degrees(-90))
                                    .animation(.linear(duration: 0.3), value: progress)
                            }
                            .frame(width: 22, height: 22)
                        } else {
                            ProgressView()
                                .tint(.black)
                                .scaleEffect(0.85)
                        }
                    } else if isQueued {
                        Image(systemName: "clock")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Color.black.opacity(0.5))
                    } else if isPaused {
                        Image(systemName: "pause.circle.fill")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(Color.black)
                    } else {
                        Image(systemName: anySeriesDownloaded ? "arrow.down.circle.fill" : "arrow.down.to.line")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Color.black)
                    }
                }
                .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .popover(item: $downloadPopoverStep, arrowEdge: .bottom) { step in
                Group {
                    if step == .progress {
                        let paused = !dm.isDownloading(activeItem.id) && dm.isPaused(activeItem.id)
                        downloadProgressPopover(
                            itemId: activeItem.id,
                            task: dm.activeTasks[activeItem.id],
                            isQueued: dm.isQueued(activeItem.id),
                            isPaused: dm.activeTasks[activeItem.id]?.isPaused == true || paused,
                            pausedItem: paused ? dm.pausedItems.first(where: { $0.id == activeItem.id }) : nil
                        )
                    } else {
                        downloadStepPopover(step: step)
                    }
                }
                .frame(width: 280)
                .presentationCompactAdaptation(.popover)
            }
            .alert(String(localized: "Delete Download", bundle: AppState.currentBundle), isPresented: $showDeleteConfirm) {
                Button(String(localized: "Delete", bundle: AppState.currentBundle), role: .destructive) { dm.deleteDownload(activeItem.id) }
                Button(String(localized: "Cancel", bundle: AppState.currentBundle), role: .cancel) {}
            } message: {
                Text(String(format: String(localized: "Remove \"%@\" from your downloads?", bundle: AppState.currentBundle), activeItem.name))
            }
        }
    }

    @ViewBuilder
    private func downloadProgressPopover(itemId: String, task: ActiveDownload?, isQueued: Bool, isPaused: Bool = false, pausedItem: PausedDownload? = nil) -> some View {
        let isTranscoding = task?.isTranscoding ?? pausedItem?.isTranscoding ?? false
        let isDirect = task?.isDirect ?? pausedItem?.isDirect ?? false
        let progress: Double = {
            if let task { return task.progress }
            guard let p = pausedItem, p.bytesExpected > 0 else { return 0 }
            return Double(p.bytesReceived) / Double(p.bytesExpected)
        }()
        let progressText: String = task?.formattedProgress ?? pausedItem?.formattedProgress ?? ""
        let tintColor: Color = isTranscoding ? .orange : (isDirect ? .green : .accentColor)

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                if isTranscoding {
                    Label(String(localized: "Transcoding", bundle: AppState.currentBundle), systemImage: "gearshape.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                } else if isDirect {
                    Label(String(localized: "Direct", bundle: AppState.currentBundle), systemImage: "bolt.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                } else if isQueued {
                    Label(String(localized: "Queued", bundle: AppState.currentBundle), systemImage: "clock")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                if isPaused {
                    Text("·").foregroundStyle(.tertiary)
                    Text(String(localized: "Paused", bundle: AppState.currentBundle))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                Spacer(minLength: 4)
                if !progressText.isEmpty {
                    Text(progressText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let task, !task.formattedSpeed.isEmpty, !isPaused {
                    Text("·").foregroundStyle(.tertiary)
                    Text(task.formattedSpeed)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)

            if task != nil || pausedItem != nil {
                if progress > 0 {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(tintColor)
                } else if !isPaused {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(tintColor)
                }
            }

            HStack(spacing: 8) {
                if isPaused {
                    Button {
                        dm.resumeDownload(itemId, appState: appState)
                    } label: {
                        Label(String(localized: "Resume", bundle: AppState.currentBundle), systemImage: "play.fill")
                            .font(.caption.weight(.medium))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                } else if let task, !task.isFailed {
                    Button {
                        dm.pauseDownload(itemId)
                    } label: {
                        Label(String(localized: "Pause", bundle: AppState.currentBundle), systemImage: "pause.fill")
                            .font(.caption.weight(.medium))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                Button(role: .destructive) {
                    dm.deleteDownload(itemId)
                    downloadPopoverStep = nil
                } label: {
                    Label(String(localized: "Cancel", bundle: AppState.currentBundle), systemImage: "xmark")
                        .font(.caption.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(16)
    }


    @ViewBuilder
    private func downloadStepPopover(step: DownloadPopoverStep) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch step {
            case .scope:
                Label(activeItem.isMovie
                      ? String(localized: "Download", bundle: AppState.currentBundle)
                      : String(localized: "Download Details", bundle: AppState.currentBundle),
                      systemImage: "arrow.down.circle.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.bottom, 2)

                Button {
                    pendingDownloadSeason = false
                    downloadPopoverStep = .quality
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "film")
                            .font(.system(size: 15))
                            .frame(width: 24)
                        Text(String(localized: "Download This Episode", bundle: AppState.currentBundle))
                            .font(.subheadline.weight(.medium))
                        Spacer()
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if let sid = selectedSeason?.id, vm.episodes[sid] != nil {
                    Divider()
                    Button {
                        pendingDownloadSeason = true
                        downloadPopoverStep = .quality
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "rectangle.stack.fill")
                                .font(.system(size: 15))
                                .frame(width: 24)
                            Text(String(localized: "Download Entire Season", bundle: AppState.currentBundle))
                                .font(.subheadline.weight(.medium))
                            Spacer()
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

            case .quality:
                Label(String(localized: "Resolution", bundle: AppState.currentBundle),
                      systemImage: "slider.horizontal.3")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.bottom, 2)

                ForEach(Array(qualities.enumerated()), id: \.offset) { idx, quality in
                    if idx > 0 { Divider() }
                    let isDirect = quality.bitrate == nil
                    Button {
                        if isDirect {
                            downloadPopoverStep = nil
                            if pendingDownloadSeason {
                                startSeasonDownload(quality: quality)
                            } else {
                                startDownload(quality: quality)
                            }
                            return
                        }
                        let audioStreams = downloadAudioStreams
                        let uniqueLangs = Set(audioStreams.map { $0.language ?? "und" })
                        if uniqueLangs.count > 1 {
                            pendingQuality = quality
                            downloadPopoverStep = .audio
                        } else {
                            downloadPopoverStep = nil
                            if pendingDownloadSeason {
                                startSeasonDownload(quality: quality)
                            } else {
                                startDownload(quality: quality)
                            }
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: isDirect ? "bolt.fill" : "arrow.down.circle")
                                .font(.system(size: 15))
                                .foregroundStyle(isDirect ? .green : .secondary)
                                .frame(width: 24)
                            Text(isDirect ? String(localized: "Original (Direct)", bundle: AppState.currentBundle) : quality.label)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(isDirect ? .green : .primary)
                            Spacer()
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

            case .audio:
                Label(String(localized: "Audio Language", bundle: AppState.currentBundle),
                      systemImage: "waveform")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.bottom, 2)

                ForEach(Array(downloadAudioStreams.enumerated()), id: \.element.index) { idx, stream in
                    if idx > 0 { Divider() }
                    Button {
                        selectedAudioStreamIndex = stream.index
                        downloadPopoverStep = nil
                        guard let quality = pendingQuality else { return }
                        if pendingDownloadSeason {
                            startSeasonDownload(quality: quality)
                        } else {
                            startDownload(quality: quality)
                        }
                        pendingQuality = nil
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.system(size: 15))
                                .foregroundStyle(.secondary)
                                .frame(width: 24)
                            Text(stream.audioLabel)
                                .font(.subheadline.weight(.medium))
                            Spacer()
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            case .progress:
                EmptyView()
            }
        }
        .padding(16)
    }

    /// Audio streams from the active item's details (for download audio picker).
    private var downloadAudioStreams: [JellyfinMediaStream] {
        let item = displayItem.id == activeItem.id ? displayItem : activeItem
        return item.mediaStreams?.filter(\.isAudio) ?? []
    }

    private func downloadURL(for item: JellyfinItem, quality: (label: String, bitrate: Int?), audioStreamIndex: Int? = nil) -> URL? {
        guard let bitrate = quality.bitrate else {
            return DownloadManager.directURL(itemId: item.id, serverURL: appState.serverURL, token: appState.token)
        }
        return DownloadManager.transcodedURL(itemId: item.id, serverURL: appState.serverURL, token: appState.token, maxBitrate: bitrate, audioStreamIndex: audioStreamIndex)
    }

    @ViewBuilder
    private func episodeContextMenu(episode: JellyfinItem) -> some View {
        let isPlayed = episode.userData?.played ?? false
        let isPartial = !isPlayed && (episode.userData?.playbackPositionTicks ?? 0) > 0

        if !isPlayed {
            Button {
                Task {
                    try? await JellyfinAPI.shared.setPlayed(
                        serverURL: appState.serverURL, itemId: episode.id,
                        userId: appState.userId, token: appState.token, played: true)
                    if let sid = selectedSeason?.id {
                        updateEpisodeUserData(seasonId: sid, episodeId: episode.id, played: true)
                    }
                }
            } label: {
                Label(String(localized: "Watched", bundle: AppState.currentBundle), systemImage: "eye.fill")
            }
        }

        if isPlayed || isPartial {
            Button {
                Task {
                    try? await JellyfinAPI.shared.setPlayed(
                        serverURL: appState.serverURL, itemId: episode.id,
                        userId: appState.userId, token: appState.token, played: false)
                    if let sid = selectedSeason?.id {
                        updateEpisodeUserData(seasonId: sid, episodeId: episode.id, played: false)
                    }
                }
            } label: {
                Label(String(localized: "Unwatched", bundle: AppState.currentBundle), systemImage: "eye.slash.fill")
            }
        }

        if dm.isDownloaded(episode.id) {
            Button(role: .destructive) {
                episodeDeleteTarget = episode
            } label: {
                Label(String(localized: "Delete Download", bundle: AppState.currentBundle), systemImage: "trash")
            }
        } else if dm.isPaused(episode.id) {
            Button {
                dm.resumeDownload(episode.id, appState: appState)
            } label: {
                Label(String(localized: "Resume Download", bundle: AppState.currentBundle), systemImage: "arrow.down.circle")
            }
        } else if dm.isDownloading(episode.id) || dm.isQueued(episode.id) {
            Button(role: .destructive) {
                dm.cancelDownload(episode.id)
            } label: {
                Label(String(localized: "Cancel Download", bundle: AppState.currentBundle), systemImage: "xmark.circle")
            }
        } else {
            Menu {
                ForEach(qualities, id: \.label) { quality in
                    Button(quality.bitrate == nil
                           ? String(localized: "Original (Direct)", bundle: AppState.currentBundle)
                           : quality.label) {
                        guard let url = downloadURL(for: episode, quality: quality) else { return }
                        dm.startDownload(item: episode, qualityLabel: quality.label, downloadURL: url, appState: appState)
                        if let people = displayItem.people, !people.isEmpty {
                            dm.downloadPeople(people, serverURL: appState.serverURL, token: appState.token)
                        }
                    }
                }
            } label: {
                Label(String(localized: "Download", bundle: AppState.currentBundle), systemImage: "arrow.down.circle")
            }
        }
    }

    private func updateEpisodeUserData(seasonId: String, episodeId: String, played: Bool) {
        if var eps = vm.episodes[seasonId],
           let idx = eps.firstIndex(where: { $0.id == episodeId }) {
            var ep = eps[idx]
            var ud = ep.userData ?? JellyfinUserData(playbackPositionTicks: 0, played: played, isFavorite: nil, playCount: nil)
            ud.played = played
            if played { ud.playbackPositionTicks = 0 }
            ep.userData = ud
            eps[idx] = ep
            vm.episodes[seasonId] = eps
        }
    }

    private func startDownload(quality: (label: String, bitrate: Int?)) {
        guard !activeItem.isSeries else { return }
        guard let url = downloadURL(for: activeItem, quality: quality, audioStreamIndex: selectedAudioStreamIndex) else { return }
        defer { selectedAudioStreamIndex = nil }
        // Use activeItem for the download metadata (correct type/name/id)
        // but enrich it with full details from displayItem when it matches
        let itemForDownload = (displayItem.id == activeItem.id) ? displayItem : activeItem
        dm.startDownload(item: itemForDownload, qualityLabel: quality.label, downloadURL: url, appState: appState)
        // Save series details if this is an episode on a series page
        if activeItem.isEpisode, let seriesId = activeItem.seriesId {
            // Save series-level details (ratings, cast, etc.)
            if displayItem.isSeries || displayItem.id == seriesId {
                DownloadManager.saveItemDetails(displayItem)
            }
        }
        // Also download people from series/movie level (displayItem)
        if let people = displayItem.people, !people.isEmpty {
            dm.downloadPeople(people, serverURL: appState.serverURL, token: appState.token)
        }
        // Fetch and cache full episode/movie details + people photos + subtitles
        Task {
            let detailItem: JellyfinItem
            if let full = try? await JellyfinAPI.shared.getItemDetails(
                serverURL: appState.serverURL, itemId: activeItem.id,
                userId: appState.userId, token: appState.token
            ) {
                DownloadManager.saveItemDetails(full)
                if let people = full.people, !people.isEmpty {
                    dm.downloadPeople(people, serverURL: appState.serverURL, token: appState.token)
                }
                detailItem = full
            } else {
                detailItem = (displayItem.id == activeItem.id) ? displayItem : activeItem
            }
            // Download subtitles using the episode's own mediaStreams (not series-level)
            let sourceId = detailItem.mediaSources?.first?.id ?? activeItem.id
            let subtitleStreams = detailItem.mediaStreams?.filter { $0.canDownloadAsSRT } ?? []
            if !subtitleStreams.isEmpty {
                dm.downloadSubtitles(itemId: activeItem.id, mediaSourceId: sourceId, streams: subtitleStreams, serverURL: appState.serverURL, token: appState.token)
            }
        }
    }

    private func startSeasonDownload(quality: (label: String, bitrate: Int?)) {
        guard let sid = selectedSeason?.id, let episodes = vm.episodes[sid] else { return }
        let audioIdx = selectedAudioStreamIndex
        selectedAudioStreamIndex = nil
        // Save series details + people photos for offline
        DownloadManager.saveItemDetails(displayItem)
        if let people = displayItem.people, !people.isEmpty {
            dm.downloadPeople(people, serverURL: appState.serverURL, token: appState.token)
        }
        for ep in episodes {
            guard !dm.isDownloaded(ep.id), !dm.isDownloading(ep.id), !dm.isQueued(ep.id) else { continue }
            guard let url = downloadURL(for: ep, quality: quality, audioStreamIndex: audioIdx) else { continue }
            dm.startDownload(item: ep, qualityLabel: quality.label, downloadURL: url, appState: appState)
        }
        // Fetch full details per episode to download subtitles + cache details
        Task {
            for ep in episodes {
                guard let details = try? await JellyfinAPI.shared.getItemDetails(
                    serverURL: appState.serverURL, itemId: ep.id,
                    userId: appState.userId, token: appState.token
                ) else { continue }
                DownloadManager.saveItemDetails(details)
                let sourceId = details.mediaSources?.first?.id ?? ep.id
                let subs = details.mediaStreams?.filter { $0.canDownloadAsSRT } ?? []
                if !subs.isEmpty {
                    dm.downloadSubtitles(itemId: ep.id, mediaSourceId: sourceId, streams: subs,
                                         serverURL: appState.serverURL, token: appState.token)
                }
            }
        }
    }

    // MARK: - Overview

    @ViewBuilder
    private var overviewSection: some View {
        if let overview = activeItem.overview ?? displayItem.overview, !overview.isEmpty {
            let needsExpand = overview.count > 150
            VStack(alignment: .center, spacing: 8) {
                Text(overview)
                    .font(.subheadline)
                    .foregroundStyle(Color(.label).opacity(0.72))
                    .lineSpacing(5)
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .overlay(alignment: .bottomTrailing) {
                        if needsExpand {
                            HStack(spacing: 0) {
                                LinearGradient(
                                    colors: [Color(.systemBackground).opacity(0),
                                             Color(.systemBackground)],
                                    startPoint: .leading, endPoint: .trailing
                                )
                                .frame(width: 44, height: 18)
                                HStack(spacing: 2) {
                                    Text(String(localized: "Show More", bundle: AppState.currentBundle))
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 9, weight: .bold))
                                }
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tint)
                                    .frame(height: 18)
                                    .background(Color(.systemBackground))
                            }
                        }
                    }
            }
            .padding(.horizontal, 16)
            .onTapGesture {
                guard needsExpand else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    overviewExpanded = true
                }
            }
            .onChange(of: activeItem.id) { _, _ in overviewExpanded = false }
        }
    }

    // MARK: - Overview Popup

    private func overviewPopup(_ text: String) -> some View {
        GeometryReader { geo in
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        overviewExpanded = false
                    }
                }
                .overlay {
                    Text(text)
                        .font(.subheadline)
                        .foregroundStyle(Color(.label))
                        .lineSpacing(5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(Color(.systemBackground).opacity(0.95), in: RoundedRectangle(cornerRadius: 14))
                        .padding(.horizontal, 24)
                        .frame(maxHeight: geo.size.height * 0.4, alignment: .center)
                }
        }
    }

    // MARK: - Ratings & Media Badges

    private struct MediaBadge: Identifiable {
        let id: String
        let icon: String?
        let label: String
    }

    @ViewBuilder
    private var ratingsAndBadges: some View {
        let mediaItem: JellyfinItem = {
            // 1) Episode: try cached details, then activeItem itself
            if activeItem.isEpisode {
                if let cached = DownloadManager.loadItemDetails(itemId: activeItem.id),
                   cached.mediaStreams != nil { return cached }
                if activeItem.mediaStreams != nil { return activeItem }
            }
            // 2) For movies/series: try fullItem, then activeItem
            if let full = vm.fullItem, full.mediaStreams != nil { return full }
            if activeItem.mediaStreams != nil { return activeItem }
            return displayItem
        }()
        let videoStream = mediaItem.mediaStreams?.first(where: { $0.isVideo })
        let audioStream = mediaItem.mediaStreams?.first(where: { $0.isAudio })
        let badges = buildMediaBadges(video: videoStream, audio: audioStream)
        let hasRatings = displayItem.communityRating != nil || displayItem.criticRating != nil

        if hasRatings || !badges.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    // TMDb rating
                    if let rating = displayItem.communityRating {
                        HStack(spacing: 5) {
                            Image("TMDbLogo")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 28, height: 28)
                            Text(String(format: "%.1f", rating))
                                .font(.subheadline.bold())
                                .foregroundStyle(.primary)
                        }
                    }
                    // Critic rating
                    if let critic = displayItem.criticRating {
                        HStack(spacing: 4) {
                            Image(systemName: "rosette")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text("\(Int(critic))%")
                                .font(.subheadline.bold())
                                .foregroundStyle(.primary)
                        }
                    }
                    // Media badges
                    ForEach(badges) { badge in
                        HStack(spacing: 3) {
                            if let icon = badge.icon {
                                Image(systemName: icon)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                            Text(badge.label)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary.opacity(0.4), lineWidth: 1))
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func buildMediaBadges(video: JellyfinMediaStream?, audio: JellyfinMediaStream?) -> [MediaBadge] {
        var badges: [MediaBadge] = []

        if let video {
            let codec = (video.codec ?? "").lowercased()
            if codec.contains("hevc") || codec.contains("h265") {
                badges.append(MediaBadge(id: "vcodec", icon: nil, label: "HEVC"))
            } else if codec.contains("h264") || codec.contains("avc") {
                badges.append(MediaBadge(id: "vcodec", icon: nil, label: "H.264"))
            } else if codec.contains("av1") {
                badges.append(MediaBadge(id: "vcodec", icon: nil, label: "AV1"))
            } else if !codec.isEmpty {
                badges.append(MediaBadge(id: "vcodec", icon: nil, label: codec.uppercased()))
            }

            if let w = video.width {
                if w >= 3840 {
                    badges.append(MediaBadge(id: "res", icon: "4k.tv", label: "UHD"))
                } else if w >= 1920 {
                    badges.append(MediaBadge(id: "res", icon: nil, label: "FHD"))
                } else if w >= 1280 {
                    badges.append(MediaBadge(id: "res", icon: nil, label: "HD"))
                }
            }

            let rangeType = video.videoRangeType ?? video.videoRange ?? ""
            switch rangeType {
            case "DOVIWithHDR10Plus":
                badges.append(MediaBadge(id: "dv", icon: "sparkles", label: "DV"))
                badges.append(MediaBadge(id: "hdr10p", icon: nil, label: "HDR10+"))
            case "DOVI":
                badges.append(MediaBadge(id: "dv", icon: "sparkles", label: "DV"))
            case "DOVIWithHDR10":
                badges.append(MediaBadge(id: "dv", icon: "sparkles", label: "DV"))
                badges.append(MediaBadge(id: "hdr10", icon: nil, label: "HDR10"))
            case "HDR10Plus":
                badges.append(MediaBadge(id: "hdr10p", icon: nil, label: "HDR10+"))
            case "HDR10":
                badges.append(MediaBadge(id: "hdr10", icon: nil, label: "HDR10"))
            case "HLG":
                badges.append(MediaBadge(id: "hlg", icon: nil, label: "HLG"))
            case "HDR":
                badges.append(MediaBadge(id: "hdr", icon: nil, label: "HDR"))
            default:
                break
            }
        }

        if let audio {
            let aCodec = (audio.codec ?? "").lowercased()
            if aCodec.contains("truehd") || aCodec.contains("atmos") {
                badges.append(MediaBadge(id: "acodec", icon: "hifispeaker.2.fill", label: "Atmos"))
            } else if aCodec.contains("eac3") || aCodec == "ac3" {
                badges.append(MediaBadge(id: "acodec", icon: "speaker.wave.3.fill", label: aCodec == "ac3" ? "DD" : "DD+"))
            } else if aCodec.contains("flac") {
                badges.append(MediaBadge(id: "acodec", icon: nil, label: "FLAC"))
            } else if aCodec.contains("dts") {
                badges.append(MediaBadge(id: "acodec", icon: nil, label: "DTS"))
            } else if !aCodec.isEmpty {
                badges.append(MediaBadge(id: "acodec", icon: nil, label: aCodec.uppercased()))
            }

            if let dt = audio.displayTitle?.lowercased() {
                if dt.contains("7.1") {
                    badges.append(MediaBadge(id: "channels", icon: nil, label: "7.1"))
                } else if dt.contains("5.1") {
                    badges.append(MediaBadge(id: "channels", icon: nil, label: "5.1"))
                }
            }
        }

        return badges
    }

    // MARK: - Episodes

    private var episodeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Season selector: dropdown Menu
            if vm.seasons.count > 1 {
                Menu {
                    ForEach(vm.seasons) { season in
                        Button { selectedSeason = season } label: {
                            if selectedSeason?.id == season.id {
                                Label(season.name, systemImage: "checkmark")
                            } else {
                                Text(season.name)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(selectedSeason?.name ?? String(localized: "Season", bundle: AppState.currentBundle))
                            .font(.subheadline.weight(.semibold))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                }
                .padding(.horizontal, 16)
            } else if let name = selectedSeason?.name {
                Text(name)
                    .font(.title3.bold())
                    .padding(.horizontal, 16)
            }

            // Episode horizontal scroll
            if let seasonId = selectedSeason?.id, let eps = vm.episodes[seasonId] {
                let highlightId = currentHighlightId(seasonId: seasonId)
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(eps) { episode in
                                Button {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        activeItem = episode
                                    }
                                } label: {
                                    EpisodeThumbnailView(
                                        episode: episode,
                                        serverURL: appState.serverURL,
                                        isCurrent: episode.id == highlightId
                                    )
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    episodeContextMenu(episode: episode)
                                } preview: {
                                    EpisodeThumbnailView(
                                        episode: episode,
                                        serverURL: appState.serverURL,
                                        isCurrent: false
                                    )
                                    .padding()
                                }
                                .id(episode.id)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                    }
                    .scrollClipDisabled()
                    .onAppear {
                        if let hid = highlightId {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                withAnimation { proxy.scrollTo(hid, anchor: .center) }
                            }
                        }
                    }
                    .onChange(of: activeItem.id) { _, _ in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            withAnimation { proxy.scrollTo(activeItem.id, anchor: .center) }
                        }
                    }
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding()
            }
        }
        .alert(String(localized: "Delete Download?", bundle: AppState.currentBundle), isPresented: Binding(
            get: { episodeDeleteTarget != nil },
            set: { if !$0 { episodeDeleteTarget = nil } }
        )) {
            Button(String(localized: "Delete", bundle: AppState.currentBundle), role: .destructive) {
                if let ep = episodeDeleteTarget {
                    dm.deleteDownload(ep.id)
                    if isFromDownloads, let sid = selectedSeason?.id {
                        // Pick adjacent episode before removing
                        if let eps = vm.episodes[sid],
                           let idx = eps.firstIndex(where: { $0.id == ep.id }) {
                            let neighbor = idx + 1 < eps.count ? eps[idx + 1]
                                         : idx > 0 ? eps[idx - 1] : nil
                            if let neighbor { activeItem = neighbor }
                        }
                        vm.episodes[sid]?.removeAll { $0.id == ep.id }
                    }
                }
                episodeDeleteTarget = nil
            }
            Button(String(localized: "Cancel", bundle: AppState.currentBundle), role: .cancel) { episodeDeleteTarget = nil }
        } message: {
            if let ep = episodeDeleteTarget {
                Text(String(format: String(localized: "Remove \"%@\" from your downloads?", bundle: AppState.currentBundle), ep.name))
            }
        }
    }

    // MARK: - Media Info

    @ViewBuilder
    private var mediaInfoSection: some View {
        let mediaItem: JellyfinItem = {
            if activeItem.isEpisode {
                if let cached = DownloadManager.loadItemDetails(itemId: activeItem.id),
                   cached.mediaSources != nil || cached.mediaStreams != nil { return cached }
                if activeItem.mediaStreams != nil || activeItem.mediaSources != nil { return activeItem }
            }
            if let full = vm.fullItem, full.mediaStreams != nil || full.mediaSources != nil { return full }
            if activeItem.mediaStreams != nil || activeItem.mediaSources != nil { return activeItem }
            return displayItem
        }()
        let source = mediaItem.mediaSources?.first
        let videoStream = mediaItem.mediaStreams?.first(where: { $0.isVideo })
        let audioStream = mediaItem.mediaStreams?.first(where: { $0.isAudio })

        if source != nil || videoStream != nil || audioStream != nil {
            VStack(alignment: .leading, spacing: 12) {
                Text(String(localized: "Media Info", bundle: AppState.currentBundle))
                    .font(.title3.bold())
                    .padding(.horizontal, 16)

                VStack(alignment: .leading, spacing: 6) {
                    if let path = source?.path {
                        let fileName = URL(fileURLWithPath: path).lastPathComponent
                        if !fileName.isEmpty {
                            Text(fileName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    if let size = source?.size {
                        let gb = Double(size) / 1_073_741_824
                        let sizeStr = gb >= 1
                            ? String(format: "%.2f GB", gb)
                            : String(format: "%.0f MB", Double(size) / 1_048_576)
                        Text(sizeStr)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let video = videoStream {
                        let res = video.height.map { "\($0)p" } ?? ""
                        let codec = (video.codec ?? "").uppercased()
                        let brStr = (video.bitRate ?? 0) > 0 ? String(format: "%.1f Mbps", Double(video.bitRate ?? 0) / 1_000_000) : nil
                        let parts = ([codec, res] + [brStr].compactMap { $0 }).filter { !$0.isEmpty }
                        if !parts.isEmpty {
                            Text(parts.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let audio = audioStream {
                        let parts = [audio.codec?.uppercased(), audio.displayTitle]
                            .compactMap { s -> String? in
                                guard let s, !s.isEmpty else { return nil }
                                return s
                            }
                        if !parts.isEmpty {
                            Text(parts.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: - Playback

    private func startPlayback() async {
        let target: JellyfinItem?
        if activeItem.isMovie || activeItem.isEpisode {
            target = activeItem
        } else if activeItem.isSeries {
            target = await vm.resumeEpisodeForSeries(appState: appState)
        } else {
            target = nil
        }
        guard let target else { return }
        // Scroll to top before rotating so content isn't mid-scroll when landscape kicks in
        withAnimation(.easeOut(duration: 0.2)) {
            detailScrollProxy?.scrollTo("detailTop", anchor: .top)
        }
        try? await Task.sleep(for: .milliseconds(250))
        // Rotate to landscape BEFORE presenting the fullScreenCover
        // to avoid visible portrait→landscape jank during presentation.
        AppDelegate.orientationLock = .landscape
        PlayerContainerView.rotate(to: .landscapeRight)
        try? await Task.sleep(for: .milliseconds(300))
        itemToPlay = target
    }

    @ViewBuilder
    private var playButtonContent: some View {
        let resumePos = activeItem.userData?.resumePositionSeconds
        let totalSecs = activeItem.runTimeTicks.map { Double($0) / 10_000_000 }
        let hasResume = (resumePos ?? 0) > 60

        HStack(spacing: 8) {
            Image(systemName: "play.fill")
            playButtonLabel
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.25), lineWidth: 0.5))
        .overlay(alignment: .leading) {
            if hasResume, let pos = resumePos, let total = totalSecs, total > 0 {
                let progress = min(pos / total, 1)
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(white: 1).opacity(0.12))
                        .frame(width: geo.size.width * progress)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    @ViewBuilder
    private var playButtonLabel: some View {
        if activeItem.isEpisode || activeItem.isMovie,
           let pos = activeItem.userData?.resumePositionSeconds, pos > 60 {
            Text(verbatim: String(format: String(localized: "Continue  %@", bundle: AppState.currentBundle), formatTimestamp(pos)))
        } else if activeItem.isSeries {
            let ep = selectedSeason.flatMap { vm.resumeEpisode(seasonId: $0.id) }
            if let ep, let pos = ep.userData?.resumePositionSeconds, pos > 60 {
                Text(verbatim: String(format: String(localized: "Continue  S%lldE%lld", bundle: AppState.currentBundle), Int64(ep.parentIndexNumber ?? 1), Int64(ep.indexNumber ?? 1)))
            } else if let ep, let epNum = ep.indexNumber {
                Text(verbatim: String(format: String(localized: "Play  S%lldE%lld", bundle: AppState.currentBundle), Int64(ep.parentIndexNumber ?? 1), Int64(epNum)))
            } else {
                Text(String(localized: "Play", bundle: AppState.currentBundle))
            }
        } else {
            Text(String(localized: "Play", bundle: AppState.currentBundle))
        }
    }

    // MARK: - Helpers

    private func currentHighlightId(seasonId: String) -> String? {
        if activeItem.isEpisode { return activeItem.id }
        return vm.resumeEpisode(seasonId: seasonId)?.id
    }

    // MARK: - Similar / Recommendations

    private var similarSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "Recommendations", bundle: AppState.currentBundle))
                .font(.title3.bold())
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(vm.similarItems) { similar in
                        VStack(alignment: .leading, spacing: 4) {
                            NavigationLink(value: similar) {
                                PosterCardView(item: similar, serverURL: appState.serverURL, showYear: false)
                            }
                            .buttonStyle(.plain)
                            HStack {
                                if let year = similar.productionYear {
                                    Text(String(year))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let ticks = similar.runTimeTicks, ticks > 0 {
                                    let mins = Int(Double(ticks) / 600_000_000)
                                    Text(String(format: String(localized: "%lld min", bundle: AppState.currentBundle), Int64(mins)))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .contextMenu {
                            Button {
                            } label: {
                                Label(String(localized: "Go to Detail", bundle: AppState.currentBundle), systemImage: "arrow.right.circle")
                            }
                        } preview: {
                            VStack(alignment: .leading, spacing: 4) {
                                PosterCardView(item: similar, serverURL: appState.serverURL, showYear: false, showShadow: false)
                                HStack {
                                    if let year = similar.productionYear {
                                        Text(String(year))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if let ticks = similar.runTimeTicks, ticks > 0 {
                                        let mins = Int(Double(ticks) / 600_000_000)
                                        Text(String(format: String(localized: "%lld min", bundle: AppState.currentBundle), Int64(mins)))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .padding()
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
    }

    private func similarCard(_ item: JellyfinItem, showShadow: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            PosterCardView(item: item, serverURL: appState.serverURL, showYear: false, showShadow: showShadow)
            HStack {
                if let year = item.productionYear {
                    Text(String(year))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let ticks = item.runTimeTicks, ticks > 0 {
                    let mins = Int(Double(ticks) / 600_000_000)
                    Text(String(format: String(localized: "%lld min", bundle: AppState.currentBundle), Int64(mins)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Cast

    private func castSection(people: [JellyfinPerson]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(localized: "Cast & Crew", bundle: AppState.currentBundle))
                .font(.title3.bold())
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(people.prefix(15)) { person in
                        CastCardView(person: person, serverURL: appState.serverURL)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func formatTimestamp(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        if h > 0 { return String(format: "%02d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Episode Thumbnail Card

struct EpisodeThumbnailView: View {
    let episode: JellyfinItem
    let serverURL: String
    let isCurrent: Bool

    private let cardWidth: CGFloat = 160
    private var cardHeight: CGFloat { cardWidth * 9 / 16 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                FallbackAsyncImage(
                    primaryURL: DownloadManager.localPosterURL(itemId: episode.id)
                        ?? DownloadManager.localBackdropURL(itemId: episode.id)
                        ?? JellyfinAPI.shared.imageURL(serverURL: serverURL, itemId: episode.id, imageType: "Primary", maxWidth: 320),
                    fallbackURL: episode.seriesId.flatMap { sid in
                        DownloadManager.localBackdropURL(itemId: sid)
                            ?? JellyfinAPI.shared.backdropURL(serverURL: serverURL, itemId: sid, maxWidth: 640)
                    },
                    placeholder: RoundedRectangle(cornerRadius: 10)
                        .fill(Color(.systemGray5))
                        .overlay(Image(systemName: "play.rectangle").foregroundStyle(.tertiary))
                )
                .frame(width: cardWidth, height: cardHeight)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                if let pos = episode.userData?.resumePositionSeconds,
                   let ticks = episode.runTimeTicks, ticks > 0 {
                    let progress = min(pos / (Double(ticks) / 10_000_000), 1.0)
                    VStack {
                        Spacer()
                        ProgressView(value: progress)
                            .tint(.white)
                            .padding(.horizontal, 6)
                            .padding(.bottom, 4)
                    }
                    .frame(width: cardWidth, height: cardHeight)
                }

                if episode.userData?.played == true {
                    VStack {
                        HStack {
                            Spacer()
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.white)
                                .background(Color.green, in: Circle())
                                .font(.caption)
                                .padding(5)
                        }
                        Spacer()
                    }
                    .frame(width: cardWidth, height: cardHeight)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isCurrent ? Color.accentColor : Color.clear, lineWidth: 2.5)
            )

            if let ep = episode.indexNumber {
                Text("\(ep). \(episode.name)")
                    .font(.caption.weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? .primary : .secondary)
                    .lineLimit(2)
                    .frame(width: cardWidth, alignment: .leading)
            }
        }
    }
}

// MARK: - Logo Title

struct LogoTitleView: View {
    let title: String
    let logoURL: URL?

    @State private var logoFailed = false

    var body: some View {
        if !logoFailed, let url = logoURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 260, maxHeight: 100)
                        .shadow(color: .black.opacity(0.6), radius: 6)
                case .failure:
                    fallbackText.onAppear { logoFailed = true }
                case .empty:
                    fallbackText.opacity(0)
                @unknown default:
                    fallbackText
                }
            }
        } else {
            fallbackText
        }
    }

    private var fallbackText: some View {
        Text(title)
            .font(.system(size: 30, weight: .bold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.5), radius: 4)
            .lineLimit(3)
    }
}

// MARK: - Cast Card

struct CastCardView: View {
    let person: JellyfinPerson
    let serverURL: String
    @EnvironmentObject private var appState: AppState
    @State private var showDetail = false
    @State private var imageVersion = 0

    private var hasImage: Bool { person.primaryImageTag != nil }

    private var imageURL: URL? {
        if let local = DownloadManager.localPersonURL(personId: person.id) {
            return local
        }
        guard var components = URLComponents(url: URL(string: serverURL)!.appendingPathComponent("Items/\(person.id)/Images/Primary"), resolvingAgainstBaseURL: false) else { return nil }
        var items = [URLQueryItem(name: "maxWidth", value: "200")]
        if imageVersion > 0 {
            items.append(URLQueryItem(name: "v", value: "\(imageVersion)"))
        }
        components.queryItems = items
        return components.url
    }

    private var placeholder: some View {
        Circle().fill(Color(.systemGray5))
            .overlay(
                Text(String(person.name.prefix(1)))
                    .font(.title2.bold())
                    .foregroundStyle(.secondary)
            )
    }

    private var isOffline: Bool { appState.manualOffline || appState.serverUnreachable }

    var body: some View {
        Button { if !isOffline { showDetail = true } } label: {
            VStack(spacing: 8) {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    case .failure:
                        placeholder
                    default:
                        if hasImage {
                            placeholder.overlay(ProgressView().scaleEffect(0.6).tint(.secondary))
                        } else {
                            placeholder
                        }
                    }
                }
                .frame(width: 72, height: 72)
                .clipShape(Circle())

                VStack(spacing: 2) {
                    Text(person.name)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    if let role = person.role, !role.isEmpty {
                        Text(role)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(width: 80)
            }
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showDetail) {
            PersonDetailView(person: person)
                .environmentObject(appState)
        }
        .task {
            guard !hasImage, !isOffline else { return }
            // No image tag — trigger server-side metadata refresh
            await JellyfinAPI.shared.refreshItemMetadata(
                serverURL: appState.serverURL,
                itemId: person.id,
                token: appState.token
            )
            // Wait for Jellyfin to download the image from TMDb
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            imageVersion += 1
        }
    }
}

// MARK: - Meta text style

private extension Text {
    func metaStyle() -> some View {
        self
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.75))
    }
}

// MARK: - Conditional modifier helper

private extension View {
    @ViewBuilder
    func modify<Content: View>(@ViewBuilder _ transform: (Self) -> Content) -> some View {
        transform(self)
    }
}



