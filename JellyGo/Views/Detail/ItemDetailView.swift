import SwiftUI

struct ItemDetailView: View {
    let item: JellyfinItem

    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var dm: DownloadManager
    @StateObject private var vm = ItemDetailViewModel()
    @State private var activeItem: JellyfinItem
    @State private var itemToPlay: JellyfinItem?
    @State private var selectedSeason: JellyfinItem?
    @State private var pullDown: CGFloat = 0
    @State private var showDownloadScopeDialog = false
    @State private var showDownloadQualityDialog = false
    @State private var pendingDownloadSeason = false
    @State private var showDeleteConfirm = false
    @State private var showDownloadDetail = false
    @State private var showDownloadProgress = false
    @State private var downloadedEpisodeTarget: String? = nil
    @State private var overviewExpanded = false
    @State private var showAudioDialog = false
    @State private var pendingQuality: (label: String, bitrate: Int?)? = nil
    @State private var selectedAudioStreamIndex: Int? = nil
    private let backdropHeight: CGFloat = 580
    private let qualities: [(label: String, bitrate: Int?)] = [
        ("Direct",  nil),
        ("1080p",   8_000_000),
        ("720p",    4_000_000),
        ("480p",    2_000_000),
        ("360p",    1_000_000),
    ]

    init(item: JellyfinItem) {
        self.item = item
        _activeItem = State(initialValue: item)
    }

    private var displayItem: JellyfinItem { vm.fullItem ?? activeItem }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                backdropOverlay
                Color(.systemBackground).frame(height: 24)
                mainContent
                    .background(Color(.systemBackground))
                Color(.systemBackground).frame(height: 100)
            }
        }
        .ignoresSafeArea(edges: .top)
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            geo.contentOffset.y + geo.contentInsets.top
        } action: { _, offset in
            pullDown = max(0, -offset)
        }
        .background(alignment: .top) {
            backdropBackground
                .ignoresSafeArea(edges: .top)
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
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
        .toolbar(.hidden, for: .tabBar)
        .fullScreenCover(item: $itemToPlay, onDismiss: {
            AppDelegate.orientationLock = .portrait
            PlayerContainerView.rotate(to: .portrait)
        }) { ep in
            let localURL = dm.downloads.first(where: { $0.id == ep.id })
                .flatMap { item -> URL? in
                    guard let url = item.localURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
                    return url
                }
            PlayerContainerView(item: ep, localURL: localURL)
                .environmentObject(appState)
        }
        .task {
            await vm.load(item: item, appState: appState)
            if item.isSeries {
                let seriesId = item.id
                // Offline fallback: if network failed and seasons didn't load, build from downloads
                if vm.seasons.isEmpty {
                    vm.buildOfflineData(from: dm.downloads, seriesId: seriesId)
                }
                // Check for downloaded episodes — prefer the most recent one
                let latestDownload = dm.downloads
                    .filter { ($0.seriesId ?? $0.id) == seriesId && $0.isEpisode }
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
                } else {
                    let season = await vm.bestSeasonToOpen(appState: appState)
                    selectedSeason = season ?? vm.seasons.first
                    if let sid = selectedSeason?.id, let ep = vm.resumeEpisode(seasonId: sid) {
                        activeItem = ep
                    }
                }
            } else {
                selectedSeason = vm.seasons.first(where: { $0.indexNumber == item.parentIndexNumber })
                    ?? vm.seasons.first
                if let sid = selectedSeason?.id {
                    await vm.loadEpisodes(seasonId: sid, appState: appState)
                }
            }
        }
        .onChange(of: selectedSeason) { _, newSeason in
            guard let sid = newSeason?.id else { return }
            Task {
                await vm.loadEpisodes(seasonId: sid, appState: appState)
                if item.isEpisode && newSeason?.indexNumber == item.parentIndexNumber {
                    activeItem = item
                } else if let dlId = downloadedEpisodeTarget,
                          let ep = vm.episodes[sid]?.first(where: { $0.id == dlId }) {
                    activeItem = ep
                    downloadedEpisodeTarget = nil
                } else if let ep = vm.resumeEpisode(seasonId: sid) {
                    activeItem = ep
                }
            }
        }
        .sheet(isPresented: $showDownloadDetail) {
            NavigationStack {
                DownloadedSeriesDetailView(
                    seriesId: activeItem.seriesId ?? activeItem.id
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
    }

    // MARK: - Backdrop Image (fixed at top via .background, grows on pull-down)

    private var backdropBackground: some View {
        let backdropId = activeItem.isEpisode ? (activeItem.seriesId ?? activeItem.id) : activeItem.id
        // Prefer local cached backdrop, fall back to remote
        let url = DownloadManager.localBackdropURL(itemId: backdropId)
            ?? JellyfinAPI.shared.backdropURL(serverURL: appState.serverURL, itemId: backdropId, maxWidth: 1280)
        let height = backdropHeight + pullDown
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
        .frame(height: height, alignment: .top)
        .clipped()
    }

    // MARK: - Backdrop Overlay (gradient + title + buttons, scrolls with content)

    private var backdropOverlay: some View {
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
            if let res = displayItem.videoResolution ?? activeItem.videoResolution {
                Text(res).metaStyle()
            }
        }
    }

    // MARK: - Main Content

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            overviewSection
            ratingsSection
            if item.isSeries || item.isEpisode, !vm.seasons.isEmpty {
                episodeSection
            }
            if let people = displayItem.people, !people.isEmpty {
                castSection(people: people)
            }
            mediaInfoSection
        }
        .padding(.bottom, 40)
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 10) {
            Button {
                Task { await startPlayback() }
            } label: {
                playButtonContent
            }
            .buttonStyle(.plain)

            downloadTriggerButton
        }
        .confirmationDialog(
            activeItem.isMovie ? String(localized: "Download", bundle: AppState.currentBundle) : String(localized: "Download Details", bundle: AppState.currentBundle),
            isPresented: $showDownloadScopeDialog,
            titleVisibility: .visible
        ) {
            Button("Download This Episode") {
                pendingDownloadSeason = false
                showDownloadQualityDialog = true
            }
            if let sid = selectedSeason?.id, vm.episodes[sid] != nil {
                Button("Download Entire Season") {
                    pendingDownloadSeason = true
                    showDownloadQualityDialog = true
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Resolution", isPresented: $showDownloadQualityDialog, titleVisibility: .visible) {
            ForEach(qualities, id: \.label) { quality in
                Button(quality.bitrate == nil ? String(localized: "Original (Direct)", bundle: AppState.currentBundle) : quality.label) {
                    // Direct → download immediately (all audio tracks included)
                    if quality.bitrate == nil {
                        if pendingDownloadSeason {
                            startSeasonDownload(quality: quality)
                        } else {
                            startDownload(quality: quality)
                        }
                        return
                    }
                    // Transcode → check if multiple audio languages
                    let audioStreams = downloadAudioStreams
                    let uniqueLangs = Set(audioStreams.map { $0.language ?? "und" })
                    if uniqueLangs.count > 1 {
                        pendingQuality = quality
                        showAudioDialog = true
                    } else {
                        if pendingDownloadSeason {
                            startSeasonDownload(quality: quality)
                        } else {
                            startDownload(quality: quality)
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Audio Language", isPresented: $showAudioDialog, titleVisibility: .visible) {
            ForEach(downloadAudioStreams, id: \.index) { stream in
                Button(stream.audioLabel) {
                    selectedAudioStreamIndex = stream.index
                    guard let quality = pendingQuality else { return }
                    if pendingDownloadSeason {
                        startSeasonDownload(quality: quality)
                    } else {
                        startDownload(quality: quality)
                    }
                    pendingQuality = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingQuality = nil }
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
        let anySeriesDownloaded = activeItem.isSeries &&
            dm.downloads.contains { $0.seriesId == activeItem.id }

        if isDownloaded, let dl = downloadedItem, activeItem.isEpisode || activeItem.isMovie {
            // Downloaded: show quality+size info + detail button
            HStack(spacing: 8) {
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

                Button { showDownloadDetail = true } label: {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.25), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
            }
        } else {
            Button {
                if isDownloading || isQueued {
                    showDownloadProgress = true
                    return
                }
                if anySeriesDownloaded { return }
                let hasSeasonContext = !activeItem.isMovie && selectedSeason != nil
                if hasSeasonContext {
                    showDownloadScopeDialog = true
                } else {
                    pendingDownloadSeason = false
                    showDownloadQualityDialog = true
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
                    } else {
                        Image(systemName: anySeriesDownloaded ? "arrow.down.circle.fill" : "arrow.down.to.line")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Color.black)
                    }
                }
                .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showDownloadProgress, attachmentAnchor: .point(.top), arrowEdge: .bottom) {
                downloadProgressPopover(task: activeDownload, isQueued: isQueued)
                    .presentationCompactAdaptation(.popover)
            }
            .alert("Delete Download", isPresented: $showDeleteConfirm) {
                Button("Delete", role: .destructive) { dm.deleteDownload(activeItem.id) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Remove \"\(activeItem.name)\" from your downloads?")
            }
        }
    }

    @ViewBuilder
    private func downloadProgressPopover(task: ActiveDownload?, isQueued: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if let task {
                    if task.isTranscoding {
                        Label("Transcoding", systemImage: "gearshape.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                    } else if task.isDirect {
                        Label("Direct", systemImage: "bolt.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                    Spacer()
                    Text(task.formattedProgress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !task.formattedSpeed.isEmpty {
                        Text("·").foregroundStyle(.tertiary)
                        Text(task.formattedSpeed)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if isQueued {
                    Label("Queued", systemImage: "clock")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            if let task, !task.isFailed {
                if task.progress > 0 {
                    ProgressView(value: task.progress)
                        .progressViewStyle(.linear)
                        .tint(task.isTranscoding ? .orange : (task.isDirect ? .green : .accentColor))
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(task.isTranscoding ? .orange : .accentColor)
                }
            }

            HStack(spacing: 8) {
                if let task, !task.isFailed {
                    Button {
                        dm.pauseDownload(activeItem.id)
                        showDownloadProgress = false
                    } label: {
                        Label("Pause", systemImage: "pause.fill")
                            .font(.caption.weight(.medium))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                Button(role: .destructive) {
                    dm.deleteDownload(activeItem.id)
                    showDownloadProgress = false
                } label: {
                    Label("Cancel Download", systemImage: "xmark")
                        .font(.caption.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .frame(minWidth: 260)
    }


    /// Audio streams from the active item's details (for download audio picker).
    private var downloadAudioStreams: [JellyfinMediaStream] {
        let item = displayItem.id == activeItem.id ? displayItem : activeItem
        return item.mediaStreams?.filter(\.isAudio) ?? []
    }

    private func downloadURL(for item: JellyfinItem, quality: (label: String, bitrate: Int?), audioStreamIndex: Int? = nil) -> URL? {
        if quality.bitrate == nil {
            return DownloadManager.directURL(itemId: item.id, serverURL: appState.serverURL, token: appState.token)
        } else {
            return DownloadManager.transcodedURL(itemId: item.id, serverURL: appState.serverURL, token: appState.token, maxBitrate: quality.bitrate!, audioStreamIndex: audioStreamIndex)
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
                if overviewExpanded {
                    Text(overview)
                        .font(.subheadline)
                        .foregroundStyle(Color(.label).opacity(0.72))
                        .lineSpacing(5)
                        .multilineTextAlignment(.center)
                        .transition(.opacity)
                } else {
                    // Collapsed: leading so truncation is at trailing edge, overlay fits last line
                    Text(overview)
                        .font(.subheadline)
                        .foregroundStyle(Color(.label).opacity(0.72))
                        .lineSpacing(5)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .bottomTrailing) {
                            if needsExpand {
                                HStack(spacing: 0) {
                                    LinearGradient(
                                        colors: [Color(.systemBackground).opacity(0),
                                                 Color(.systemBackground)],
                                        startPoint: .leading, endPoint: .trailing
                                    )
                                    .frame(width: 44, height: 18)
                                    Button {
                                        withAnimation(.easeInOut(duration: 0.25)) {
                                            overviewExpanded = true
                                        }
                                    } label: {
                                        HStack(spacing: 2) {
                                            Text(String(localized: "Show More", bundle: AppState.currentBundle))
                                            Image(systemName: "chevron.down")
                                                .font(.system(size: 10, weight: .semibold))
                                        }
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.tint)
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.leading, 2)
                                    .frame(height: 18)
                                    .background(Color(.systemBackground))
                                }
                            }
                        }
                        .transition(.opacity)
                }

                if overviewExpanded && needsExpand {
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            overviewExpanded = false
                        }
                    } label: {
                        Label(String(localized: "Show Less", bundle: AppState.currentBundle),
                              systemImage: "chevron.up")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .onChange(of: activeItem.id) { _, _ in overviewExpanded = false }
        }
    }

    // MARK: - Ratings

    @ViewBuilder
    private var ratingsSection: some View {
        // Episodes don't have standalone ratings; show only for movies and series
        if !item.isEpisode,
           displayItem.communityRating != nil || displayItem.criticRating != nil {
            HStack(spacing: 24) {
                if let rating = displayItem.communityRating {
                    HStack(alignment: .center, spacing: 8) {
                        Image("TMDbLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 36, height: 36)
                        Text(String(format: "%.1f", rating))
                            .font(.title3.bold())
                            .foregroundStyle(.primary)
                    }
                }
                if let critic = displayItem.criticRating {
                    HStack(alignment: .center, spacing: 6) {
                        Image(systemName: "rosette")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text("\(Int(critic))%")
                            .font(.title3.bold())
                            .foregroundStyle(.primary)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
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
                        Text(selectedSeason?.name ?? "Season")
                            .font(.subheadline.weight(.semibold))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color(.systemGray5), in: Capsule())
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
    }

    // MARK: - Media Info

    @ViewBuilder
    private var mediaInfoSection: some View {
        // For episodes, use activeItem's cached details so media info updates per episode
        let mediaItem: JellyfinItem = {
            if activeItem.isEpisode,
               let cached = DownloadManager.loadItemDetails(itemId: activeItem.id),
               cached.mediaSources != nil || cached.mediaStreams != nil {
                return cached
            }
            return displayItem
        }()
        let source = mediaItem.mediaSources?.first
        let videoStream = mediaItem.mediaStreams?.first(where: { $0.isVideo })
        let audioStream = mediaItem.mediaStreams?.first(where: { $0.isAudio })

        if source != nil || videoStream != nil || audioStream != nil {
            VStack(alignment: .leading, spacing: 12) {
                Text("Media Info")
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
                        let brStr = (video.bitRate ?? 0) > 0 ? String(format: "%.1f Mbps", Double(video.bitRate!) / 1_000_000) : nil
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
                Text("Play")
            }
        } else {
            Text("Play")
        }
    }

    // MARK: - Helpers

    private func currentHighlightId(seasonId: String) -> String? {
        if activeItem.isEpisode { return activeItem.id }
        return vm.resumeEpisode(seasonId: seasonId)?.id
    }

    // MARK: - Cast

    private func castSection(people: [JellyfinPerson]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Cast & Crew")
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
                        .frame(maxWidth: 260, maxHeight: 100, alignment: .leading)
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

    private var placeholder: some View {
        Circle().fill(Color(.systemGray5))
            .overlay(
                Text(String(person.name.prefix(1)))
                    .font(.title2.bold())
                    .foregroundStyle(.secondary)
            )
    }

    var body: some View {
        NavigationLink {
            PersonDetailView(person: person)
        } label: {
            VStack(spacing: 8) {
                AsyncImage(url: DownloadManager.localPersonURL(personId: person.id)
                    ?? JellyfinAPI.shared.personImageURL(serverURL: serverURL, person: person)) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    case .failure:
                        placeholder
                    default:
                        placeholder.overlay(ProgressView().scaleEffect(0.6).tint(.secondary))
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

