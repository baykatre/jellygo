import SwiftUI
import Combine
import os

@MainActor
final class ItemDetailViewModel: ObservableObject {
    @Published var fullItem: JellyfinItem?
    @Published var seasons: [JellyfinItem] = []
    @Published var episodes: [String: [JellyfinItem]] = [:]
    @Published var isLoading = false
    @Published var isFavorite = false
    @Published var isWatched = false
    @Published var similarItems: [JellyfinItem] = []

    func load(item: JellyfinItem, appState: AppState) async {
        isLoading = true
        isFavorite = item.userData?.isFavorite ?? false
        isWatched = item.userData?.played ?? false

        // Offline: load cached details immediately
        if !NetworkMonitor.shared.isConnected {
            loadOfflineData(item: item)
            isLoading = false
            return
        }

        async let detailsTask = JellyfinAPI.shared.getItemDetails(
            serverURL: appState.serverURL,
            itemId: item.id,
            userId: appState.userId,
            token: appState.token
        )

        if item.isSeries {
            async let seasonsTask = JellyfinAPI.shared.getItems(
                serverURL: appState.serverURL,
                userId: appState.userId,
                token: appState.token,
                parentId: item.id,
                itemTypes: ["Season"],
                sortBy: "IndexNumber",
                sortOrder: "Ascending",
                limit: 100
            )
            let details = try? await detailsTask
            let seasonsResponse = try? await seasonsTask
            if let details {
                fullItem = details
                isFavorite = details.userData?.isFavorite ?? isFavorite
                isWatched = details.userData?.played ?? isWatched
            }
            if let seasonsResponse {
                seasons = seasonsResponse.items
                if let first = seasons.first {
                    await loadEpisodes(seasonId: first.id, appState: appState)
                }
            }
        } else if item.isEpisode {
            // Load sibling episodes for the season
            if let seriesId = item.seriesId {
                async let episodesTask = JellyfinAPI.shared.getItems(
                    serverURL: appState.serverURL,
                    userId: appState.userId,
                    token: appState.token,
                    parentId: item.seriesId,
                    itemTypes: ["Season"],
                    sortBy: "IndexNumber",
                    sortOrder: "Ascending",
                    limit: 100
                )
                let details = try? await detailsTask
                let seasonsResponse = try? await episodesTask
                if let details {
                    fullItem = details
                    isFavorite = details.userData?.isFavorite ?? isFavorite
                    isWatched = details.userData?.played ?? isWatched
                }
                if let seasonsResponse {
                    seasons = seasonsResponse.items
                    // Find and load the current season
                    if let currentSeason = seasons.first(where: { $0.indexNumber == item.parentIndexNumber }) {
                        await loadEpisodes(seasonId: currentSeason.id, appState: appState)
                    } else if let first = seasons.first {
                        await loadEpisodes(seasonId: first.id, appState: appState)
                    }
                }
                _ = seriesId
            } else if let details = try? await detailsTask {
                fullItem = details
                isFavorite = details.userData?.isFavorite ?? isFavorite
                isWatched = details.userData?.played ?? isWatched
            }
        } else {
            if let details = try? await detailsTask {
                fullItem = details
                isFavorite = details.userData?.isFavorite ?? isFavorite
                isWatched = details.userData?.played ?? isWatched
            }
        }

        // Cache details + people photos + missing subtitles for offline
        if let details = fullItem {
            let dm = DownloadManager.shared
            let isDownloaded = dm.isDownloaded(item.id)
                || dm.downloads.contains(where: { $0.seriesId == item.id })
            if isDownloaded {
                DownloadManager.saveItemDetails(details)
                if let people = details.people, !people.isEmpty {
                    dm.downloadPeople(people, serverURL: appState.serverURL, token: appState.token)
                }
                // Auto-repair: download missing subtitles for this item
                if dm.isDownloaded(item.id) {
                    repairSubtitles(for: details, appState: appState)
                }
            }
        }

        isLoading = false

        // Load similar items for movies (only once)
        if item.isMovie, similarItems.isEmpty {
            var items = (try? await JellyfinAPI.shared.getSimilarItems(
                serverURL: appState.serverURL, itemId: item.id,
                userId: appState.userId, token: appState.token
            )) ?? []
            // Fallback: fill with random movies if similar list is short
            if items.count < 10 {
                let existingIds = Set(items.map(\.id) + [item.id])
                if let random = try? await JellyfinAPI.shared.getItems(
                    serverURL: appState.serverURL,
                    userId: appState.userId,
                    token: appState.token,
                    itemTypes: ["Movie"],
                    sortBy: "Random",
                    limit: 10 - items.count + 5,
                    recursive: true
                ) {
                    let unique = random.items.filter { !existingIds.contains($0.id) }
                    let needed = 10 - items.count
                    items.append(contentsOf: unique.prefix(needed))
                }
            }
            similarItems = items
        }

        // If no community rating, trigger metadata refresh and reload
        if fullItem?.communityRating == nil && !item.isEpisode {
            await JellyfinAPI.shared.refreshItemMetadata(
                serverURL: appState.serverURL,
                itemId: item.id,
                token: appState.token
            )
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            if let updated = try? await JellyfinAPI.shared.getItemDetails(
                serverURL: appState.serverURL,
                itemId: item.id,
                userId: appState.userId,
                token: appState.token
            ) {
                if updated.communityRating != nil {
                    fullItem = updated
                }
            }
        }
    }

    func reloadAfterPlayback(item: JellyfinItem, appState: AppState) async {
        // Clear episode cache so fresh data is fetched
        episodes = [:]
        await load(item: item, appState: appState)
    }

    func loadEpisodes(seasonId: String, appState: AppState, forceRefresh: Bool = false) async {
        guard forceRefresh || episodes[seasonId] == nil else { return }
        // Offline: episodes already populated by loadOfflineData
        guard NetworkMonitor.shared.isConnected else { return }
        do {
            let response = try await JellyfinAPI.shared.getItems(
                serverURL: appState.serverURL,
                userId: appState.userId,
                token: appState.token,
                parentId: seasonId,
                itemTypes: ["Episode"],
                sortBy: "IndexNumber",
                sortOrder: "Ascending",
                limit: 200
            )
            episodes[seasonId] = response.items
            // Cache full details for downloaded episodes (getItems returns minimal fields)
            let dm = DownloadManager.shared
            Task {
                for ep in response.items {
                    let isDownloaded = dm.isDownloaded(ep.id)
                    guard isDownloaded else { continue }
                    // Fetch full details (people, mediaStreams, mediaSources, ratings…)
                    if let full = try? await JellyfinAPI.shared.getItemDetails(
                        serverURL: appState.serverURL, itemId: ep.id,
                        userId: appState.userId, token: appState.token
                    ) {
                        DownloadManager.saveItemDetails(full)
                        // Auto-repair: download missing subtitles
                        let subs = full.mediaStreams?.filter { $0.canDownloadAsSRT } ?? []
                        let prefix = "\(ep.id)_"
                        let dir = DownloadManager.downloadsDirectory
                        let hasSrt = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
                            .contains { $0.hasPrefix(prefix) && $0.hasSuffix(".srt") } ?? false
                        if !subs.isEmpty && !hasSrt {
                            let sourceId = full.mediaSources?.first?.id ?? ep.id
                            dm.downloadSubtitles(
                                itemId: ep.id, mediaSourceId: sourceId,
                                streams: subs, serverURL: appState.serverURL, token: appState.token
                            )
                        }
                    }
                    dm.downloadPoster(itemId: ep.id, serverURL: appState.serverURL, token: appState.token)
                }
            }
        } catch {
            Logger(subsystem: "JellyGo", category: "ItemDetailViewModel").error("load failed: \(error)")
        }
    }

    /// Returns the episode to highlight and resume-play for a given season.
    /// Priority: partially watched → first unwatched → first episode
    func resumeEpisode(seasonId: String) -> JellyfinItem? {
        guard let eps = episodes[seasonId] else { return nil }
        if let partial = eps.first(where: { ($0.userData?.playbackPositionTicks ?? 0) > 0 }) {
            return partial
        }
        if let next = eps.first(where: { $0.userData?.played != true }) {
            return next
        }
        return eps.first
    }

    /// For a series: searches all loaded seasons for a partial watch,
    /// then falls back to first unwatched, then first episode ever.
    /// Loads the first season if nothing is loaded yet.
    func resumeEpisodeForSeries(appState: AppState) async -> JellyfinItem? {
        // Ensure at least the first season is loaded
        if let first = seasons.first {
            await loadEpisodes(seasonId: first.id, appState: appState)
        }

        // Check already-loaded seasons for a partial watch
        for season in seasons {
            if let eps = episodes[season.id],
               let partial = eps.first(where: { ($0.userData?.playbackPositionTicks ?? 0) > 0 }) {
                return partial
            }
        }

        // Load remaining seasons and check for next unwatched
        for season in seasons {
            await loadEpisodes(seasonId: season.id, appState: appState)
            if let eps = episodes[season.id],
               let next = eps.first(where: { $0.userData?.played != true }) {
                return next
            }
        }

        // All watched — return first episode of first season
        if let firstSeason = seasons.first {
            return episodes[firstSeason.id]?.first
        }
        return nil
    }

    /// Loads seasons one by one and returns the first season that has a partial watch
    /// or an unwatched episode. Falls back to the first season.
    func bestSeasonToOpen(appState: AppState) async -> JellyfinItem? {
        for season in seasons {
            await loadEpisodes(seasonId: season.id, appState: appState)
            guard let eps = episodes[season.id] else { continue }
            if eps.contains(where: { ($0.userData?.playbackPositionTicks ?? 0) > 0 }) { return season }
            if eps.contains(where: { $0.userData?.played != true }) { return season }
        }
        return seasons.first
    }

    /// Offline fallback: build synthetic seasons + episodes from downloaded items.
    /// Called when network is unavailable and seasons would otherwise be empty.
    func buildOfflineData(from downloads: [DownloadedItem], seriesId: String) {
        guard seasons.isEmpty else { return }
        let eps = downloads.filter { ($0.seriesId ?? $0.id) == seriesId && $0.isEpisode }
        guard !eps.isEmpty else { return }

        // Group by season number
        let grouped = Dictionary(grouping: eps) { $0.seasonNumber ?? 1 }
        let seasonNums = grouped.keys.sorted()

        seasons = seasonNums.map { num in
            let seasonId = "\(seriesId)_offline_s\(num)"
            return JellyfinItem(
                id: seasonId, name: "Season \(num)", type: "Season",
                overview: nil, productionYear: nil,
                communityRating: nil, criticRating: nil, runTimeTicks: nil,
                seriesName: eps.first?.seriesName, seriesId: seriesId,
                seasonName: "Season \(num)", indexNumber: num, parentIndexNumber: nil,
                userData: nil, imageBlurHashes: nil, primaryImageAspectRatio: nil,
                genres: nil, officialRating: nil, taglines: nil, people: nil,
                premiereDate: nil, mediaStreams: nil, mediaSources: nil,
                childCount: grouped[num]?.count, providerIds: nil,
                endDate: nil, productionLocations: nil, imageTags: nil
            )
        }

        for num in seasonNums {
            let seasonId = "\(seriesId)_offline_s\(num)"
            let seasonEps = (grouped[num] ?? []).sorted {
                ($0.episodeNumber ?? 0) < ($1.episodeNumber ?? 0)
            }
            episodes[seasonId] = seasonEps.map { dl in
                // Try loading cached full details, fall back to basic conversion
                DownloadManager.loadItemDetails(itemId: dl.id) ?? dl.toJellyfinItem()
            }
        }
    }

    /// Loads all data from locally cached JSON files for offline viewing.
    private func loadOfflineData(item: JellyfinItem) {
        // Load cached full item details
        if let cached = DownloadManager.loadItemDetails(itemId: item.id) {
            fullItem = cached
            isFavorite = cached.userData?.isFavorite ?? isFavorite
            isWatched = cached.userData?.played ?? isWatched
        }
        // For episodes, also try loading series details (ratings, cast live on the series)
        if item.isEpisode, let seriesId = item.seriesId,
           fullItem == nil || fullItem?.people == nil {
            if let seriesDetails = DownloadManager.loadItemDetails(itemId: seriesId) {
                // Use series details as fullItem if episode details missing or incomplete
                if fullItem == nil {
                    fullItem = seriesDetails
                }
            }
        }

        // For series/episodes, build seasons from cached episode details
        if item.isSeries || item.isEpisode {
            let seriesId = item.isSeries ? item.id : (item.seriesId ?? item.id)
            let dm = DownloadManager.shared

            // Find all downloaded episodes for this series
            let downloadedEps = dm.downloads.filter { ($0.seriesId ?? $0.id) == seriesId && $0.isEpisode }
            guard !downloadedEps.isEmpty else { return }

            // Group by season
            let grouped = Dictionary(grouping: downloadedEps) { $0.seasonNumber ?? 1 }
            let seasonNums = grouped.keys.sorted()

            seasons = seasonNums.map { num in
                let seasonId = "\(seriesId)_offline_s\(num)"
                return JellyfinItem(
                    id: seasonId, name: "Season \(num)", type: "Season",
                    overview: nil, productionYear: nil,
                    communityRating: nil, criticRating: nil, runTimeTicks: nil,
                    seriesName: downloadedEps.first?.seriesName, seriesId: seriesId,
                    seasonName: "Season \(num)", indexNumber: num, parentIndexNumber: nil,
                    userData: nil, imageBlurHashes: nil, primaryImageAspectRatio: nil,
                    genres: nil, officialRating: nil, taglines: nil, people: nil,
                    premiereDate: nil, mediaStreams: nil, mediaSources: nil,
                    childCount: grouped[num]?.count, providerIds: nil,
                    endDate: nil, productionLocations: nil, imageTags: nil
                )
            }

            for num in seasonNums {
                let seasonId = "\(seriesId)_offline_s\(num)"
                let seasonEps = (grouped[num] ?? []).sorted {
                    ($0.episodeNumber ?? 0) < ($1.episodeNumber ?? 0)
                }
                episodes[seasonId] = seasonEps.map { dl in
                    // Try loading cached full details, fall back to basic conversion
                    DownloadManager.loadItemDetails(itemId: dl.id) ?? dl.toJellyfinItem()
                }
            }
        }
    }

    /// Downloads missing subtitle files for a downloaded item.
    private func repairSubtitles(for item: JellyfinItem, appState: AppState) {
        let subs = item.mediaStreams?.filter { $0.canDownloadAsSRT } ?? []
        guard !subs.isEmpty else { return }
        let downloadsDir = DownloadManager.downloadsDirectory
        let prefix = "\(item.id)_"
        let existingFiles = (try? FileManager.default.contentsOfDirectory(atPath: downloadsDir.path))?.filter {
            $0.hasPrefix(prefix) && $0.hasSuffix(".srt")
        } ?? []
        // If any subtitle files already exist, skip repair
        guard existingFiles.isEmpty else { return }
        let sourceId = item.mediaSources?.first?.id ?? item.id
        DownloadManager.shared.downloadSubtitles(
            itemId: item.id, mediaSourceId: sourceId,
            streams: subs, serverURL: appState.serverURL, token: appState.token
        )
    }

    func toggleFavorite(item: JellyfinItem, appState: AppState) async {
        let newValue = !isFavorite
        isFavorite = newValue
        try? await JellyfinAPI.shared.setFavorite(
            serverURL: appState.serverURL,
            itemId: item.id,
            userId: appState.userId,
            token: appState.token,
            isFavorite: newValue
        )
    }

    func toggleWatched(item: JellyfinItem, appState: AppState) async {
        let newValue = !isWatched
        isWatched = newValue
        try? await JellyfinAPI.shared.setPlayed(
            serverURL: appState.serverURL,
            itemId: item.id,
            userId: appState.userId,
            token: appState.token,
            played: newValue
        )
    }
}
