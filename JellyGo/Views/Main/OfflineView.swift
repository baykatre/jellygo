import SwiftUI

struct OfflineView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var dm: DownloadManager
    @State private var heroPlayItem: JellyfinItem?
    @State private var showSettings = false

    // MARK: - Computed Data

    private var allItems: [JellyfinItem] {
        dm.downloads.map { dl in
            DownloadManager.loadItemDetails(itemId: dl.id) ?? dl.toJellyfinItem()
        }
    }

    /// Featured items for the hero banner: movies + one per series (with backdrop)
    private var featuredItems: [JellyfinItem] {
        var items: [JellyfinItem] = []
        var seenSeriesIds = Set<String>()
        var seenSeriesNames = Set<String>()

        // Sort by added date (most recent first)
        let sorted = dm.downloads.sorted { $0.addedDate > $1.addedDate }

        for dl in sorted {
            if dl.isMovie {
                let item = DownloadManager.loadItemDetails(itemId: dl.id) ?? dl.toJellyfinItem()
                items.append(item)
            } else if dl.isEpisode {
                // Dedup by seriesId first, then by seriesName as fallback
                if let sid = dl.seriesId {
                    guard !seenSeriesIds.contains(sid) else { continue }
                    seenSeriesIds.insert(sid)
                } else if let sname = dl.seriesName {
                    guard !seenSeriesNames.contains(sname) else { continue }
                    seenSeriesNames.insert(sname)
                }
                let sid = dl.seriesId ?? dl.id
                // Use series details if cached, otherwise build from episode
                if let seriesDetails = DownloadManager.loadItemDetails(itemId: sid) {
                    items.append(seriesDetails)
                } else {
                    // Build a synthetic series item
                    items.append(JellyfinItem(
                        id: sid, name: dl.seriesName ?? dl.name, type: "Series",
                        overview: dl.overview, productionYear: dl.productionYear,
                        communityRating: dl.communityRating, criticRating: nil, runTimeTicks: nil,
                        seriesName: nil, seriesId: nil,
                        seasonName: nil, indexNumber: nil, parentIndexNumber: nil,
                        userData: nil, imageBlurHashes: nil, primaryImageAspectRatio: nil,
                        genres: dl.genres, officialRating: dl.officialRating, taglines: nil, people: nil,
                        premiereDate: nil, mediaStreams: nil, mediaSources: nil,
                        childCount: nil, providerIds: nil,
                        endDate: nil, productionLocations: nil
                    ))
                }
            }
        }

        return Array(items.prefix(8))
    }

    /// Items with a saved playback position (partially watched)
    private var continueWatching: [JellyfinItem] {
        dm.downloads.compactMap { dl -> JellyfinItem? in
            let pos = LocalPlaybackStore.position(for: dl.id)
            guard pos > 2 else { return nil }
            let item = DownloadManager.loadItemDetails(itemId: dl.id) ?? dl.toJellyfinItem()
            // Skip if fully watched
            if item.userData?.played == true { return nil }
            return item
        }
        .sorted { a, b in
            // Most recently watched first (higher position = more recent activity, rough heuristic)
            (a.userData?.playbackPositionTicks ?? 0) > (b.userData?.playbackPositionTicks ?? 0)
        }
    }

    /// Next unwatched episode per downloaded series
    private var nextUp: [JellyfinItem] {
        let episodes = dm.downloads.filter(\.isEpisode)
        let grouped = Dictionary(grouping: episodes) { $0.seriesId ?? $0.id }
        var results: [JellyfinItem] = []

        for (_, eps) in grouped {
            let sorted = eps.sorted {
                ($0.seasonNumber ?? 0, $0.episodeNumber ?? 0) < ($1.seasonNumber ?? 0, $1.episodeNumber ?? 0)
            }
            // Find first episode that isn't fully watched and has no saved position
            for ep in sorted {
                let item = DownloadManager.loadItemDetails(itemId: ep.id) ?? ep.toJellyfinItem()
                let pos = LocalPlaybackStore.position(for: ep.id)
                if item.userData?.played != true && pos <= 2 {
                    results.append(item)
                    break
                }
            }
        }
        return results
    }

    /// Dynamic content sections grouped by Jellyfin type.
    /// Episodes are collapsed into unique series entries.
    private var contentSections: [(type: String, title: String, items: [JellyfinItem])] {
        // Build unique items: standalone items + unique series from episodes
        var itemsByType: [String: [JellyfinItem]] = [:]
        var seenSeriesIds = Set<String>()
        var seenSeriesNames = Set<String>()

        for dl in dm.downloads {
            if dl.isEpisode {
                // Dedup by seriesId first, then by seriesName as fallback
                if let sid = dl.seriesId {
                    guard !seenSeriesIds.contains(sid) else { continue }
                    seenSeriesIds.insert(sid)
                } else if let sname = dl.seriesName {
                    guard !seenSeriesNames.contains(sname) else { continue }
                    seenSeriesNames.insert(sname)
                }
                let sid = dl.seriesId ?? dl.id
                let item: JellyfinItem
                if let details = DownloadManager.loadItemDetails(itemId: sid) {
                    item = details
                } else {
                    item = JellyfinItem(
                        id: sid, name: dl.seriesName ?? dl.name, type: "Series",
                        overview: dl.overview, productionYear: dl.productionYear,
                        communityRating: dl.communityRating, criticRating: nil, runTimeTicks: nil,
                        seriesName: nil, seriesId: nil,
                        seasonName: nil, indexNumber: nil, parentIndexNumber: nil,
                        userData: nil, imageBlurHashes: nil, primaryImageAspectRatio: nil,
                        genres: dl.genres, officialRating: dl.officialRating, taglines: nil, people: nil,
                        premiereDate: nil, mediaStreams: nil, mediaSources: nil,
                        childCount: nil, providerIds: nil,
                        endDate: nil, productionLocations: nil
                    )
                }
                itemsByType["Series", default: []].append(item)
            } else {
                let item = DownloadManager.loadItemDetails(itemId: dl.id) ?? dl.toJellyfinItem()
                itemsByType[dl.type, default: []].append(item)
            }
        }

        // Define display order for known types; unknown types appear at the end
        let typeOrder: [String] = ["Movie", "Series", "MusicVideo", "BoxSet", "Audio"]

        return itemsByType.keys
            .sorted { a, b in
                let ia = typeOrder.firstIndex(of: a) ?? Int.max
                let ib = typeOrder.firstIndex(of: b) ?? Int.max
                return ia < ib
            }
            .map { type in
                (type: type, title: Self.sectionTitle(for: type), items: itemsByType[type]!)
            }
    }

    /// Maps Jellyfin item type to a user-facing section title.
    private static func sectionTitle(for type: String) -> String {
        switch type {
        case "Movie":      return String(localized: "Movies", bundle: AppState.currentBundle)
        case "Series":     return String(localized: "TV Shows", bundle: AppState.currentBundle)
        case "MusicVideo": return String(localized: "Music Videos", bundle: AppState.currentBundle)
        case "BoxSet":     return String(localized: "Collections", bundle: AppState.currentBundle)
        case "Audio":      return String(localized: "Music", bundle: AppState.currentBundle)
        case "Book":       return String(localized: "Books", bundle: AppState.currentBundle)
        default:           return type + "s"
        }
    }

    // MARK: - Body

    @State private var selectedTab: Int = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab(String(localized: "Home", bundle: AppState.currentBundle), systemImage: "house.fill", value: 0) {
                offlineHomeTab
            }
            Tab(String(localized: "Downloads", bundle: AppState.currentBundle), systemImage: "arrow.down.circle.fill", value: 1) {
                DownloadsView()
            }
        }
    }

    private var offlineHomeTab: some View {
        NavigationStack {
            Group {
                if dm.downloads.isEmpty {
                    ContentUnavailableView {
                        Label(String(localized: "No Downloads", bundle: AppState.currentBundle), systemImage: "wifi.slash")
                    } description: {
                        Text(String(localized: "You're offline. Download content while connected to browse here.", bundle: AppState.currentBundle))
                    }
                } else {
                    ScrollView(showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 0) {

                            // Hero Banner
                            if !featuredItems.isEmpty {
                                HeroBannerView(
                                    items: featuredItems,
                                    serverURL: appState.serverURL,
                                    onPlay: { item in
                                        // Series banner → navigate to detail, movie → play
                                        guard item.isMovie || item.isEpisode else { return }
                                        AppDelegate.orientationLock = .landscape
                                        PlayerContainerView.rotate(to: .landscapeRight)
                                        Task {
                                            try? await Task.sleep(for: .milliseconds(300))
                                            heroPlayItem = item
                                        }
                                    }
                                )
                            }

                            // Content sections
                            VStack(alignment: .leading, spacing: 32) {
                                if !continueWatching.isEmpty {
                                    continueWatchingSection
                                }
                                if !nextUp.isEmpty {
                                    nextUpSection
                                }
                                ForEach(contentSections, id: \.type) { section in
                                    contentSection(title: section.title, items: section.items)
                                }
                            }
                            .padding(.top, 28)
                            .padding(.bottom, 40)
                        }
                    }
                    .ignoresSafeArea(edges: .top)
                    .scrollEdgeEffectStyle(.none, for: .top)
                    .coordinateSpace(name: "homeScroll")
                }
            }
            .background(Color(.systemBackground).ignoresSafeArea())
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { offlineBadge }
                        .buttonStyle(.plain)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape.fill")
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.6), radius: 3, x: 0, y: 1)
                    }
                }
            }
            .navigationDestination(isPresented: $showSettings) {
                SettingsView()
            }
            .navigationDestination(for: JellyfinItem.self) { item in
                ItemDetailView(item: item, isFromDownloads: true)
            }
            .fullScreenCover(item: $heroPlayItem, onDismiss: {
                appState.isPlayerActive = false
                AppDelegate.orientationLock = .portrait
                PlayerContainerView.rotate(to: .portrait)
            }) { item in
                let localURL = dm.downloads.first(where: { $0.id == item.id })
                    .flatMap { dl -> URL? in
                        guard let url = dl.localURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
                        return url
                    }
                PlayerContainerView(item: item, localURL: localURL)
                    .environmentObject(appState)
                    .onAppear { appState.isPlayerActive = true }
            }
        }
    }

    // MARK: - User Profile Badge

    private var offlineBadge: some View {
        HStack(spacing: 10) {
            avatarCircle

            VStack(alignment: .leading, spacing: 2) {
                Text(appState.username)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 3, x: 0, y: 1)

                HStack(spacing: 5) {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 9, weight: .bold))
                    Text(String(localized: "Offline", bundle: AppState.currentBundle))
                        .font(.caption.weight(.medium))
                }
                .foregroundStyle(.orange)
                .shadow(color: .black.opacity(0.6), radius: 3, x: 0, y: 1)
            }
        }
        .padding(.trailing, 16)
        .fixedSize()
    }

    private var avatarCircle: some View {
        Group {
            if let localURL = DownloadManager.localUserAvatarURL(userId: appState.userId) {
                AsyncImage(url: localURL) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable()
                            .scaledToFill()
                            .frame(width: 36, height: 36)
                            .clipShape(Circle())
                    default:
                        avatarFallback
                    }
                }
            } else {
                avatarFallback
            }
        }
    }

    private var avatarFallback: some View {
        Circle()
            .fill(.white.opacity(0.25))
            .frame(width: 36, height: 36)
            .overlay {
                Text(appState.username.prefix(1).uppercased())
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }

    // MARK: - Sections

    private var continueWatchingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeaderView(title: "\(String(localized: "Continue Watching", bundle: AppState.currentBundle))")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(continueWatching) { item in
                        NavigationLink(value: item) {
                            BackdropCardView(item: item, serverURL: appState.serverURL)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private var nextUpSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeaderView(title: "\(String(localized: "Next Up", bundle: AppState.currentBundle))")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(nextUp) { item in
                        NavigationLink(value: item) {
                            BackdropCardView(item: item, serverURL: appState.serverURL)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private func contentSection(title: String, items: [JellyfinItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeaderView(title: LocalizedStringKey(title))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(items) { item in
                        NavigationLink(value: item) {
                            PosterCardView(item: item, serverURL: appState.serverURL, width: 120)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }
}
